// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// Minimal interface for the StrDomainsNFT contract
interface IStrDomainsNFT {
    function ownerOf(uint256 tokenId) external view returns (address);
    function safeTransferFrom(address from, address to, uint256 tokenId) external;
    function royaltyInfo(uint256 tokenId, uint256 salePrice) external view returns (address receiver, uint256 royaltyAmount);
    function recordSale(uint256 tokenId, uint256 price, address buyer) external;
    function getApproved(uint256 tokenId) external view returns (address);
    function isApprovedForAll(address owner, address operator) external view returns (bool);

}

interface IRoyaltySplitter {
    function depositToken(address token, uint256 amount) external;
}

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// Fixed-price marketplace with royalty payouts (EIP-2981 compatible).
/// Supports native-token payments and ERC20 settlements. Marketplace fees accumulate and can be withdrawn via withdraw functions.
contract Marketplace is AccessControl, ReentrancyGuard, IERC721Receiver {
    bytes32 public constant ADMIN_ROLE = DEFAULT_ADMIN_ROLE;
    using SafeERC20 for IERC20;

    struct Listing {
        address seller;
        address nft;
        uint256 tokenId;
        uint256 price; // denominated in wei when paymentToken == address(0)
        address paymentToken; // address(0) => native token
        bool active;
    }

    // Marketplace fee (basis points, 10000 = 100%)
    uint96  public marketplaceFeeBps;
    address public feeTreasury;   // default recipient for accrued fees
    uint256 public accruedFees;   // accumulated native-token fees (in wei)
    mapping(address => uint256) public accruedTokenFees; // payment token => accrued fees

    uint256 public lastListingId;
    mapping(uint256 => Listing) public listings;

    event Listed(
        uint256 indexed listingId,
        address indexed seller,
        address indexed nft,
        uint256 tokenId,
        uint256 price,
        address paymentToken
    );
    event ListingUpdated(uint256 indexed listingId, uint256 newPrice);
    event ListingCanceled(uint256 indexed listingId);
    event Purchased(
        uint256 indexed listingId,
        address indexed buyer,
        uint256 price,
        address royaltyReceiver,
        uint256 royaltyAmount,
        uint256 feeAmount,
        uint256 sellerAmount,
        address paymentToken
    );
    event FeeWithdrawn(address indexed to, uint256 amount);
    event TokenFeeWithdrawn(address indexed token, address indexed to, uint256 amount);
    event SaleRecordingSuccess(uint256 indexed tokenId, uint256 price, address indexed buyer);
    event SaleRecordingFailed(uint256 indexed tokenId, uint256 price, address indexed buyer);
    event ReceivedNFT(
    address operator,
    address indexed from,
    uint256 indexed tokenId,
    address indexed nftContract
    );



    constructor(address _feeTreasury, uint96 _feeBps) {
        require(_feeTreasury != address(0), "treasury=0");
        _grantRole(ADMIN_ROLE, msg.sender);
        feeTreasury = _feeTreasury;
        marketplaceFeeBps = _feeBps; // e.g., 250 = 2.5%
    }

    /* =========================
                ADMIN
       ========================= */

    function setMarketplaceFeeBps(uint96 feeBps) external onlyRole(ADMIN_ROLE) {
        require(feeBps <= 2_000, "fee too high"); // safety cap at 20%
        marketplaceFeeBps = feeBps;
    }

    function setFeeTreasury(address t) external onlyRole(ADMIN_ROLE) {
        require(t != address(0), "treasury=0");
        feeTreasury = t;
    }

    /// Withdraw accumulated native-token marketplace fees to the fee treasury.
    function withdrawFees() external onlyRole(ADMIN_ROLE) nonReentrant {
        address recipient = feeTreasury;
        uint256 amount = accruedFees;
        require(amount > 0, "no fees");
        accruedFees = 0;
        (bool ok, ) = payable(recipient).call{ value: amount }("");
        require(ok, "withdraw fail");
        emit FeeWithdrawn(recipient, amount);
    }

    function withdrawTokenFees(address token) external onlyRole(ADMIN_ROLE) nonReentrant {
        require(token != address(0), "token=0");
        uint256 amount = accruedTokenFees[token];
        require(amount > 0, "no fees");
        accruedTokenFees[token] = 0;
        IERC20(token).safeTransfer(feeTreasury, amount);
        emit TokenFeeWithdrawn(token, feeTreasury, amount);
    }

    /* =========================
               LISTINGS
       ========================= */

    function listToken(address nft, uint256 tokenId, uint256 price) external returns (uint256 listingId) {
        require(price > 0, "price=0");
        require(IStrDomainsNFT(nft).ownerOf(tokenId) == msg.sender, "not owner");
        require(
            IStrDomainsNFT(nft).getApproved(tokenId) == address(this) ||
            IStrDomainsNFT(nft).isApprovedForAll(msg.sender, address(this)),
            "not approved"
        );

        // Transfer NFT to marketplace (escrow)
        // Requires prior approval from user
        IStrDomainsNFT(nft).safeTransferFrom(msg.sender, address(this), tokenId);

        listingId = ++lastListingId;
        listings[listingId] = Listing({
            seller: msg.sender,
            nft: nft,
            tokenId: tokenId,
            price: price,
            paymentToken: address(0),
            active: true
        });

        emit Listed(listingId, msg.sender, nft, tokenId, price, address(0));
    }

    function listTokenERC20(address nft, uint256 tokenId, uint256 price, address paymentToken)
        external
        returns (uint256 listingId)
    {
        require(paymentToken != address(0), "token=0");
        require(price > 0, "price=0");
        require(IStrDomainsNFT(nft).ownerOf(tokenId) == msg.sender, "not owner");
        require(
            IStrDomainsNFT(nft).getApproved(tokenId) == address(this) ||
                IStrDomainsNFT(nft).isApprovedForAll(msg.sender, address(this)),
            "not approved"
        );

        IStrDomainsNFT(nft).safeTransferFrom(msg.sender, address(this), tokenId);

        listingId = ++lastListingId;
        listings[listingId] = Listing({
            seller: msg.sender,
            nft: nft,
            tokenId: tokenId,
            price: price,
            paymentToken: paymentToken,
            active: true
        });

        emit Listed(listingId, msg.sender, nft, tokenId, price, paymentToken);
    }

    function updateListing(uint256 listingId, uint256 newPrice) external {
        Listing storage L = listings[listingId];
        require(L.active, "!active");
        require(L.seller == msg.sender, "not seller");
        require(newPrice > 0, "price=0");
        L.price = newPrice;
        emit ListingUpdated(listingId, newPrice);
    }

function cancelListing(uint256 listingId) external nonReentrant {
    Listing storage L = listings[listingId];
    require(L.active, " not active");
    require(L.seller == msg.sender, "not seller");
    require(IStrDomainsNFT(L.nft).ownerOf(L.tokenId) == address(this), "market not owner");

    L.active = false;

    // Return NFT from marketplace escrow to the seller
    IStrDomainsNFT(L.nft).safeTransferFrom(address(this), msg.sender, L.tokenId);

    emit ListingCanceled(listingId);
}

function onERC721Received(
    address operator,
    address from,
    uint256 tokenId,
    bytes calldata data
) external override returns (bytes4) {
    emit ReceivedNFT(operator, from, tokenId, msg.sender);
    return IERC721Receiver.onERC721Received.selector;
}




    // Buy nft domain
    function buy(uint256 listingId) external payable nonReentrant {
        Listing storage L = listings[listingId];
        require(L.active, " not active");
        require(L.paymentToken == address(0), "payment token set");
        require(msg.value == L.price, "bad value");
        require(IStrDomainsNFT(L.nft).ownerOf(L.tokenId) == address(this), "Marketplace doesn't hold the NFT Domain"); //Check ownership
        
        L.active = false;
        // 1) Fetch the royalty to be paid
        (address royaltyReceiver, uint256 royaltyAmount) = IStrDomainsNFT(L.nft).royaltyInfo(L.tokenId, L.price);
        // 2) Calculate fees for marketplace
        uint256 feeAmount = (L.price * marketplaceFeeBps) / 10_000;
        accruedFees += feeAmount;
        // 3) Calculate the seller amount to be paid
        uint256 sellerAmount = L.price - royaltyAmount - feeAmount;

        // payment of royalty, and amount to the seller
        if (royaltyAmount > 0) {
            (bool okR, ) = payable(royaltyReceiver).call{ value: royaltyAmount }("");
            require(okR, "royalty fail");
        }
        {
            (bool okS, ) = payable(L.seller).call{ value: sellerAmount }("");
            require(okS, "seller fail");
        }

        // Domain/NFT transfer from marketplace contract to the buyer
        IStrDomainsNFT(L.nft).safeTransferFrom(address(this), msg.sender, L.tokenId);


        // Recod new sale on collection contract
        try IStrDomainsNFT(L.nft).recordSale(L.tokenId, L.price, msg.sender) {

             emit SaleRecordingSuccess(L.tokenId, L.price, msg.sender);
        } catch {
            emit SaleRecordingFailed(L.tokenId, L.price, msg.sender);
         }

        emit Purchased(
            listingId,
            msg.sender,
            L.price,
            royaltyReceiver,
            royaltyAmount,
            feeAmount,
            sellerAmount,
            address(0)
        );
    }

    function buyWithERC20(uint256 listingId) external nonReentrant {
        Listing storage L = listings[listingId];
        require(L.active, " not active");
        address paymentToken = L.paymentToken;
        require(paymentToken != address(0), "native listing");
        require(
            IStrDomainsNFT(L.nft).ownerOf(L.tokenId) == address(this),
            "Marketplace doesn't hold the NFT Domain"
        );

        L.active = false;
        uint256 price = L.price;
        address seller = L.seller;

        IERC20 token = IERC20(paymentToken);
        token.safeTransferFrom(msg.sender, address(this), price);

        uint256 feeAmount = (price * marketplaceFeeBps) / 10_000;
        if (feeAmount > 0) {
            accruedTokenFees[paymentToken] += feeAmount;
        }

        (address royaltyReceiver, uint256 royaltyAmount) = IStrDomainsNFT(L.nft).royaltyInfo(L.tokenId, price);
        uint256 sellerAmount = price - royaltyAmount - feeAmount;

        if (royaltyAmount > 0 && royaltyReceiver != address(0)) {
            if (!_tryDepositToken(token, paymentToken, royaltyReceiver, royaltyAmount)) {
                token.safeTransfer(royaltyReceiver, royaltyAmount);
            }
        }

        if (sellerAmount > 0) {
            token.safeTransfer(seller, sellerAmount);
        }

        IStrDomainsNFT(L.nft).safeTransferFrom(address(this), msg.sender, L.tokenId);

        try IStrDomainsNFT(L.nft).recordSale(L.tokenId, price, msg.sender) {
            emit SaleRecordingSuccess(L.tokenId, price, msg.sender);
        } catch {
            emit SaleRecordingFailed(L.tokenId, price, msg.sender);
        }

        emit Purchased(
            listingId,
            msg.sender,
            price,
            royaltyReceiver,
            royaltyAmount,
            feeAmount,
            sellerAmount,
            paymentToken
        );
    }


    /* =========================
                 VIEWS
       ========================= */

    function getListing(uint256 listingId) external view returns (Listing memory) {
        return listings[listingId];
    }

    function _tryDepositToken(
        IERC20 token,
        address paymentToken,
        address royaltyReceiver,
        uint256 royaltyAmount
    ) private returns (bool) {
        if (royaltyReceiver == address(0)) {
            return false;
        }
        if (royaltyReceiver.code.length == 0) {
            return false;
        }
        if (royaltyAmount == 0) {
            return true;
        }

        token.safeIncreaseAllowance(royaltyReceiver, royaltyAmount);
        try IRoyaltySplitter(royaltyReceiver).depositToken(paymentToken, royaltyAmount) {
            token.safeApprove(royaltyReceiver, 0);
            return true;
        } catch {
            token.safeApprove(royaltyReceiver, 0);
            return false;
        }
    }
}
