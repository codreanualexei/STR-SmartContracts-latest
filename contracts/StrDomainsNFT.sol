// SPDX-License-Identifier: MIT 
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Burnable.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/common/ERC2981.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IRoyaltySplitterFactory {
    function createSplitter(
        address creator,
        address treasury,
        uint16 creatorBps,
        uint16 treasuryBps
    ) external returns (address splitter);
}

interface IRoyaltySplitter {
    function depositToken(address token, uint256 amount) external;
}

/// ERC721 with EIP-2981 support, roles, and per-token royalty splitters (2% creator, 3% treasury).
contract StrDomainsNFT is ERC721URIStorage, ERC721Burnable, ERC2981, AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;
    // Roles
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant SALES_ROLE  = keccak256("SALES_ROLE");

    // Royalty configuration
    uint96 public constant DEFAULT_ROYALTY_BPS   = 500;  // 5% of sale price
    uint16 public constant CREATOR_SHARE_IN_ROY  = 4000; // 40% of royalty (2% of sale price)
    uint16 public constant TREASURY_SHARE_IN_ROY = 6000; // 60% of royalty (3% of sale price)

    // Tracks the last minted token id
    uint256 private _lastId;

    address public treasury;
    IRoyaltySplitterFactory public splitterFactory;

    mapping(uint256 => address) private _creator;
    mapping(uint256 => uint64)  private _mintedAt;
    mapping(uint256 => uint256) private _lastSalePrice;
    mapping(uint256 => uint64)  private _lastSaleAt;
    mapping(string => uint256) private _domainToTokenId;
    mapping(uint256 => string) private _tokenIdToDomain;

    event TreasuryUpdated(address indexed newTreasury);
    event DefaultRoyaltyUpdated(address indexed receiver, uint96 bps);
    event Minted(uint256 indexed tokenId, address indexed to, address indexed creator, string tokenURI, string domain);
    event SaleRecorded(uint256 indexed tokenId, uint256 price, address indexed buyer, uint64 at);
    event SplitterFactoryUpdated(address indexed newFactory);
    event TokenSplitterSet(uint256 indexed tokenId, address indexed splitter, uint96 royaltyBps);
    event ERC20SaleSettled(
        uint256 indexed tokenId,
        address indexed paymentToken,
        uint256 price,
        address indexed buyer,
        address seller,
        uint256 royaltyAmount
    );

    constructor(
        string memory name_,
        string memory symbol_,
        address treasury_,
        address splitterFactory_,
        uint96 /*ignored*/
    ) ERC721(name_, symbol_) {
        require(treasury_ != address(0), "treasury=0");
        require(splitterFactory_ != address(0), "factory=0");

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(MINTER_ROLE, msg.sender);

        treasury = treasury_;
        splitterFactory = IRoyaltySplitterFactory(splitterFactory_);

        _setDefaultRoyalty(treasury, DEFAULT_ROYALTY_BPS);
        emit DefaultRoyaltyUpdated(treasury, DEFAULT_ROYALTY_BPS);
        emit SplitterFactoryUpdated(splitterFactory_);
    }

    // ---------- MINT ----------
    function mint(address to, string memory uri, string memory domainName)
        external
        onlyRole(MINTER_ROLE)
        returns (uint256 tokenId)
    {
        require(to != address(0), "to=0");
        require(bytes(domainName).length > 0, "domain empty");
        require(_domainToTokenId[domainName] == 0, "domain exists");

        tokenId = ++_lastId;
        _safeMint(to, tokenId);
        _setTokenURI(tokenId, uri);

        _creator[tokenId]  = to;
        _mintedAt[tokenId] = uint64(block.timestamp);
        _domainToTokenId[domainName] = tokenId;
        _tokenIdToDomain[tokenId] = domainName;

        address splitter = splitterFactory.createSplitter(
            to,
            treasury,
            CREATOR_SHARE_IN_ROY,
            TREASURY_SHARE_IN_ROY
        );
        _setTokenRoyalty(tokenId, splitter, DEFAULT_ROYALTY_BPS);
        emit TokenSplitterSet(tokenId, splitter, DEFAULT_ROYALTY_BPS);

        emit Minted(tokenId, to, to, uri, domainName);
    }

    // ---------- ROYALTY ADMIN ----------
    function setTreasury(address newTreasury) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newTreasury != address(0), "treasury=0");
        treasury = newTreasury;
        _setDefaultRoyalty(newTreasury, DEFAULT_ROYALTY_BPS);
        emit TreasuryUpdated(newTreasury);
        emit DefaultRoyaltyUpdated(newTreasury, DEFAULT_ROYALTY_BPS);
    }

    function setSplitterFactory(address newFactory) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newFactory != address(0), "factory=0");
        splitterFactory = IRoyaltySplitterFactory(newFactory);
        emit SplitterFactoryUpdated(newFactory);
    }

    // ---------- GETTERS ----------
    function getLastId() external view returns (uint256) {
        return _lastId;
    }

    function getTokenData(uint256 tokenId)
        external
        view
        returns (address creator, uint64 mintedAt_, string memory uri, uint256 lastPrice, uint64 lastAt, string memory domainName)
    {
        _requireOwned(tokenId);
        domainName  = _tokenIdToDomain[tokenId];
        creator     = _creator[tokenId];
        mintedAt_   = _mintedAt[tokenId];
        uri         = tokenURI(tokenId);
        lastPrice   = _lastSalePrice[tokenId];
        lastAt      = _lastSaleAt[tokenId];
        
    }


    function getTokenDataByDomain(string memory domainName)
        external
        view
        returns (address creator, uint64 mintedAt_, string memory uri, uint256 lastPrice, uint64 lastAt, uint256 tokenId)
    {
        tokenId = _domainToTokenId[domainName];
        require(tokenId != 0, "domain not found");
        _requireOwned(tokenId);
        creator   = _creator[tokenId];
        mintedAt_ = _mintedAt[tokenId];
        uri       = tokenURI(tokenId);
        lastPrice = _lastSalePrice[tokenId];
        lastAt    = _lastSaleAt[tokenId];
    }

    function creatorOf(uint256 tokenId) external view returns (address) {
        _requireOwned(tokenId);
        return _creator[tokenId];
    }

    function mintedAt(uint256 tokenId) external view returns (uint64) {
        _requireOwned(tokenId);
        return _mintedAt[tokenId];
    }

    function lastSaleOf(uint256 tokenId) external view returns (uint256 price, uint64 at) {
        _requireOwned(tokenId);
        return (_lastSalePrice[tokenId], _lastSaleAt[tokenId]);
    }


    // ---------- SALES RECORDING ----------
    function recordSale(uint256 tokenId, uint256 price, address buyer) external onlyRole(SALES_ROLE) {
        _requireOwned(tokenId);
        _lastSalePrice[tokenId] = price;
        _lastSaleAt[tokenId]    = uint64(block.timestamp);
        emit SaleRecorded(tokenId, price, buyer, _lastSaleAt[tokenId]);
    }

    function settleSaleERC20(
        uint256 tokenId,
        address paymentToken,
        uint256 price,
        address seller,
        address buyer
    ) external onlyRole(SALES_ROLE) nonReentrant {
        _requireOwned(tokenId);
        require(paymentToken != address(0), "token=0");
        require(price > 0, "price=0");
        require(buyer != address(0), "buyer=0");

        address currentOwner = ownerOf(tokenId);
        require(currentOwner == seller, "seller!=owner");
        require(buyer != seller, "buyer=seller");

        IERC20 token = IERC20(paymentToken);
        token.safeTransferFrom(buyer, address(this), price);

        (address royaltyReceiver, uint256 royaltyAmount) = royaltyInfo(tokenId, price);
        uint256 sellerProceeds = price - royaltyAmount;

        if (royaltyAmount > 0 && royaltyReceiver != address(0)) {
            uint256 currentAllowance = token.allowance(address(this), royaltyReceiver);
            if (currentAllowance != 0) {
                token.forceApprove(royaltyReceiver, 0);
            }
            token.forceApprove(royaltyReceiver, royaltyAmount);
            bool deposited = _tryDepositToken(royaltyReceiver, paymentToken, royaltyAmount);
            token.forceApprove(royaltyReceiver, 0);
            if (!deposited) {
                token.safeTransfer(royaltyReceiver, royaltyAmount);
            }
        }

        if (sellerProceeds > 0) {
            token.safeTransfer(seller, sellerProceeds);
        }

        _safeTransfer(seller, buyer, tokenId);

        uint64 nowTs = uint64(block.timestamp);
        _lastSalePrice[tokenId] = price;
        _lastSaleAt[tokenId] = nowTs;

        emit SaleRecorded(tokenId, price, buyer, nowTs);
        emit ERC20SaleSettled(tokenId, paymentToken, price, buyer, seller, royaltyAmount);
    }

    function _tryDepositToken(address splitter, address token, uint256 amount) private returns (bool) {
        if (splitter == address(0) || splitter.code.length == 0) {
            return false;
        }

        try IRoyaltySplitter(splitter).depositToken(token, amount) {
            return true;
        } catch {
            return false;
        }
    }

    // ---------- BURN OVERRIDE ----------
    function burn(uint256 tokenId) public override onlyRole(DEFAULT_ADMIN_ROLE) {
        // Clean up domain mappings when token is burned
        string memory domainName = _tokenIdToDomain[tokenId];
        if (bytes(domainName).length > 0) {
            delete _domainToTokenId[domainName];
            delete _tokenIdToDomain[tokenId];
        }
        super.burn(tokenId);
    }

    // ---------- OVERRIDES ----------
    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721, ERC721URIStorage, ERC2981, AccessControl)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }

    function tokenURI(uint256 tokenId)
        public
        view
        override(ERC721, ERC721URIStorage)
        returns (string memory)
    {
        return super.tokenURI(tokenId);
    }
}
