// SPDX-License-Identifier: MIT 
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Burnable.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/common/ERC2981.sol";

interface IRoyaltySplitterFactory {
    function createSplitter(
        address creator,
        address treasury,
        uint16 creatorBps,
        uint16 treasuryBps
    ) external returns (address splitter);
}

/// ERC721 с EIP-2981, ролями и пер-токенными сплиттерами (2% создателю, 3% казне).
contract StrDomainsNFT is ERC721URIStorage, ERC721Burnable, ERC2981, AccessControl {
    // Роли
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant SALES_ROLE  = keccak256("SALES_ROLE");

    // Роялти
    uint96 public constant DEFAULT_ROYALTY_BPS   = 500;  // 5% от цены
    uint16 public constant CREATOR_SHARE_IN_ROY  = 4000; // 40% от роялти (2% от цены)
    uint16 public constant TREASURY_SHARE_IN_ROY = 6000; // 60% от роялти (3% от цены)

    //Token id = can modify  X+_lastId 
    uint256 private _lastId;

    address public treasury;
    IRoyaltySplitterFactory public splitterFactory;

    mapping(uint256 => address) private _creator;
    mapping(uint256 => uint64)  private _mintedAt;
    mapping(uint256 => uint256) private _lastSalePrice;
    mapping(uint256 => uint64)  private _lastSaleAt;

    event TreasuryUpdated(address indexed newTreasury);
    event DefaultRoyaltyUpdated(address indexed receiver, uint96 bps);
    event Minted(uint256 indexed tokenId, address indexed to, address indexed creator, string tokenURI);
    event SaleRecorded(uint256 indexed tokenId, uint256 price, address indexed buyer, uint64 at);
    event SplitterFactoryUpdated(address indexed newFactory);
    event TokenSplitterSet(uint256 indexed tokenId, address indexed splitter, uint96 royaltyBps);

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
    function mint(address to, string memory uri)
        external
        onlyRole(MINTER_ROLE)
        returns (uint256 tokenId)
    {
        require(to != address(0), "to=0");

        tokenId = ++_lastId;
        _safeMint(to, tokenId);
        _setTokenURI(tokenId, uri);

        _creator[tokenId]  = to;
        _mintedAt[tokenId] = uint64(block.timestamp);

        address splitter = splitterFactory.createSplitter(
            to,
            treasury,
            CREATOR_SHARE_IN_ROY,
            TREASURY_SHARE_IN_ROY
        );
        _setTokenRoyalty(tokenId, splitter, DEFAULT_ROYALTY_BPS);
        emit TokenSplitterSet(tokenId, splitter, DEFAULT_ROYALTY_BPS);

        emit Minted(tokenId, to, to, uri);
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

    function getTokenData(uint256 tokenId)
        external
        view
        returns (address creator, uint64 mintedAt_, string memory uri, uint256 lastPrice, uint64 lastAt)
    {
        _requireOwned(tokenId);
        creator   = _creator[tokenId];
        mintedAt_ = _mintedAt[tokenId];
        uri       = tokenURI(tokenId);
        lastPrice = _lastSalePrice[tokenId];
        lastAt    = _lastSaleAt[tokenId];
    }

    // ---------- SALES RECORDING ----------
    function recordSale(uint256 tokenId, uint256 price, address buyer) external onlyRole(SALES_ROLE) {
        _requireOwned(tokenId);
        _lastSalePrice[tokenId] = price;
        _lastSaleAt[tokenId]    = uint64(block.timestamp);
        emit SaleRecorded(tokenId, price, buyer, _lastSaleAt[tokenId]);
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
