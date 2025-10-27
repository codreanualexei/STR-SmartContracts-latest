// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// Мини-интерфейс твоего NFT контракта (StrDomainsNFT)
interface IStrDomainsNFT {
    function ownerOf(uint256 tokenId) external view returns (address);
    function safeTransferFrom(address from, address to, uint256 tokenId) external;
    function royaltyInfo(uint256 tokenId, uint256 salePrice) external view returns (address receiver, uint256 royaltyAmount);
    function recordSale(uint256 tokenId, uint256 price, address buyer) external;
    function getApproved(uint256 tokenId) external view returns (address);
    function isApprovedForAll(address owner, address operator) external view returns (bool);

}

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

/// Маркетплейс с фикс-прайс листингами и выплатой роялти (EIP-2981).
/// Платёж — нативный токен сети (MATIC). Комиссия маркетплейса накапливается и выводится через withdrawFees().
contract Marketplace is AccessControl, ReentrancyGuard, IERC721Receiver {
    bytes32 public constant ADMIN_ROLE = DEFAULT_ADMIN_ROLE;

    struct Listing {
        address seller;
        address nft;
        uint256 tokenId;
        uint256 price; // в wei
        bool active;
    }

    // комиссия маркетплейса (bps, 10000 = 100%)
    uint96  public marketplaceFeeBps;
    address public feeTreasury;   // адрес по умолчанию для вывода комиссии
    uint256 public accruedFees;   // накопленная комиссия (в wei)

    uint256 public lastListingId;
    mapping(uint256 => Listing) public listings;

    event Listed(uint256 indexed listingId, address indexed seller, address indexed nft, uint256 tokenId, uint256 price);
    event ListingUpdated(uint256 indexed listingId, uint256 newPrice);
    event ListingCanceled(uint256 indexed listingId);
    event Purchased(
        uint256 indexed listingId,
        address indexed buyer,
        uint256 price,
        address royaltyReceiver,
        uint256 royaltyAmount,
        uint256 feeAmount,
        uint256 sellerAmount
    );
    event FeeWithdrawn(address indexed to, uint256 amount);
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
        marketplaceFeeBps = _feeBps; // напр. 250 = 2.5%
    }

    /* =========================
                ADMIN
       ========================= */

    function setMarketplaceFeeBps(uint96 feeBps) external onlyRole(ADMIN_ROLE) {
        require(feeBps <= 2_000, "fee too high"); // защитный лимит 20%
        marketplaceFeeBps = feeBps;
    }

    function setFeeTreasury(address t) external onlyRole(ADMIN_ROLE) {
        require(t != address(0), "treasury=0");
        feeTreasury = t;
    }

    /// Вывести накопленную комиссию маркетплейса.
    /// Если 'to' == address(0), средства отправятся на feeTreasury.
    function withdrawFees() external onlyRole(ADMIN_ROLE) nonReentrant {
        address recipient =feeTreasury;
        uint256 amount = accruedFees;
        require(amount > 0, "no fees");
        accruedFees = 0;
        (bool ok, ) = payable(recipient).call{ value: amount }("");
        require(ok, "withdraw fail");
        emit FeeWithdrawn(recipient, amount);
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
            active: true
        });

        emit Listed(listingId, msg.sender, nft, tokenId, price);
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

        emit Purchased(listingId, msg.sender, L.price, royaltyReceiver, royaltyAmount, feeAmount, sellerAmount);
    }

    /* =========================
                 VIEWS
       ========================= */

    function getListing(uint256 listingId) external view returns (Listing memory) {
        return listings[listingId];
    }
}
