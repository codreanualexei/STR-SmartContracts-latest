const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("BUY", function () {
  const feeMarketplaceBps = 250; //2.5%
  const feeRoyaltyBps = 500; //5%

  let minterAccount,
    seller1,
    seller2,
    buyer1, //Buyer and original creator of STR domain
    buyer2, //Buyer who buys from marketplace
    marketplaceTreasury, //Marketplace treasury wallet
    NftRoyaltyTreasury; //NFT royalty treasury wallet
  let StrDomainsNFTInstance;
  let RoyaltySplitterFactoryInstance;
  let MarketplaceInstance;

  let paidAmount;

  before(async function () {
    // reset wallets to initial state before tx fees
    await hre.network.provider.request({ method: "hardhat_reset", params: [] });

    [
      minterAccount,
      seller1,
      seller2,
      buyer1,
      buyer2,
      marketplaceTreasury,
      NftRoyaltyTreasury,
    ] = await ethers.getSigners(); //get treasury and owner accounts

    //display addresses each line
    // console.log(minterAccount.address);
    // console.log(seller1.address);
    // console.log(seller2.address);
    // console.log(buyer1.address);
    // console.log(buyer2.address);
    // console.log(marketplaceTreasury.address);
    // console.log(NftRoyaltyTreasury.address);

    // 1) RoyaltySplitter deployment as implementation reference for factory
    const Splitter = await ethers.getContractFactory("RoyaltySplitter");
    RoyaltySplitterInstance = await Splitter.deploy();
    await RoyaltySplitterInstance.waitForDeployment();
    const splitterImplAddr = await RoyaltySplitterInstance.getAddress();
    //

    // 2) RoyaltySplitterFactory
    const Factory = await ethers.getContractFactory("RoyaltySplitterFactory");
    RoyaltySplitterFactoryInstance = await Factory.deploy(splitterImplAddr);
    await RoyaltySplitterFactoryInstance.waitForDeployment();
    const factoryAddr = await RoyaltySplitterFactoryInstance.getAddress();
    //console.log("RoyaltySplitterFactory:", factoryAddr);
    //

    // 3) StrDomainsNFT deployment - collection of NFTs
    const collection = await ethers.getContractFactory("StrDomainsNFT");
    StrDomainsNFTInstance = await collection.deploy(
      "Str Domains",
      "STRDOM",
      NftRoyaltyTreasury.address,
      factoryAddr,
      feeRoyaltyBps,
    );
    await StrDomainsNFTInstance.waitForDeployment();
    const registryAddr = await StrDomainsNFTInstance.getAddress();
    //console.log("StrDomainsNFT:", registryAddr);
    //

    // 4)Marketplace deployment
    const Marketplace = await ethers.getContractFactory("Marketplace");
    MarketplaceInstance = await Marketplace.deploy(
      marketplaceTreasury.address,
      feeMarketplaceBps,
    );
    await MarketplaceInstance.waitForDeployment();
    const marketplaceAddr = await MarketplaceInstance.getAddress();
    //console.log("Marketplace:", marketplaceAddr);
    //
  });

  it("STR customer buy domain and STR mint new domain", async function () {
    const tx = await StrDomainsNFTInstance.connect(minterAccount).mint(
      buyer1.address,
      "example.str",
    );
    await tx.wait();
    expect(await StrDomainsNFTInstance.ownerOf(1)).to.equal(buyer1.address);
  });

  it("STR Buyer list domain on marketplace", async function () {
    //Approve marketplace to manage NFT
    const approveTx = await StrDomainsNFTInstance.connect(buyer1).approve(
      MarketplaceInstance.target,
      1,
    );

    await approveTx.wait();
    //List token on marketplace
    const listTx = await MarketplaceInstance.connect(buyer1).listToken(
      await StrDomainsNFTInstance.getAddress(),
      1,
      ethers.parseEther("0.1"), //price 1 ETH
    );
    const receipt = await listTx.wait();

    //Check the listed token
    const listedToken = await MarketplaceInstance.getListing(1);
    expect(listedToken.seller).to.equal(buyer1.address);
    expect(listedToken.nft).to.equal(StrDomainsNFTInstance.target);
    expect(listedToken.tokenId).to.equal(1);
    expect(listedToken.price).to.equal(ethers.parseEther("0.1"));
  });

  it("Check ownership of the Marketplace contract to be true after listing", async function () {
    //Gen owner of the token after lising it
    const owner = await StrDomainsNFTInstance.connect(buyer1).ownerOf(1);

    expect(owner).to.equal(await MarketplaceInstance.getAddress());
  });

  it("STR Buyer list cannot dublicate the listing domain on marketplace (cannot list if the domain is listed already)", async function () {
    //List token on marketplace second time
   await expect(
    MarketplaceInstance.connect(buyer1).listToken(
      await StrDomainsNFTInstance.getAddress(),
      1,
      ethers.parseEther("0.1")
    )
  ).to.be.revertedWith("not owner");
    
  });

  it("STR Buyer2 buy domain from marketplace, check marketplace treasury fees and seller balance", async function () {
    //Check initial balances
    const sellerInitialBalance = await ethers.provider.getBalance(
      buyer1.address,
    );
    const marketplaceInitialBalance = await ethers.provider.getBalance(
      marketplaceTreasury.address,
    );

    //get the listing details
    const listing = await MarketplaceInstance.getListing(1);

    //Buy the token
    const buyTx = await MarketplaceInstance.connect(buyer2).buy(1, {
      value: listing.price,
    });
    const receipt = await buyTx.wait();
    //Check new owner of the token
    expect(await StrDomainsNFTInstance.ownerOf(1)).to.equal(buyer2.address);
    //Marketplace should receive 2.5% fee
    await MarketplaceInstance.connect(minterAccount).withdrawFees();
    //Check final balances
    const sellerFinalBalance = await ethers.provider.getBalance(buyer1.address);
    const marketplaceFinalBalance = await ethers.provider.getBalance(
      marketplaceTreasury.address,
    );

    //test final balances
    //Seller should receive 92.5% (100% - 2.5% - 5% royalty fee)
    expect(sellerFinalBalance).to.equal(
      sellerInitialBalance + ethers.parseEther("0.0925"),
    );
    expect(marketplaceFinalBalance).to.equal(
      marketplaceInitialBalance + ethers.parseEther("0.0025"),
    );
  });

  it("Check ownership of the buyer to be true after buying", async function () {
    //Gen owner of the token after lising it
    const owner = await StrDomainsNFTInstance.connect(buyer1).ownerOf(1);

    expect(owner).to.equal(await buyer2.getAddress());
  });

  it("Check royalty ballance in nft treasury wallet", async function () {
    //Check royalty treasury balance
    const royaltyTreasuryInitialBalance = await ethers.provider.getBalance(
      NftRoyaltyTreasury.address,
    );

    //get the listing details
    const listing = await MarketplaceInstance.getListing(1);

    //Get splitter address
    const [splitterAddr, royaltyAmount] =
      await StrDomainsNFTInstance.royaltyInfo(1, listing.price);

    const RoyaltySplitter = await ethers.getContractAt(
      "RoyaltySplitter",
      splitterAddr,
    );

    const tx = await RoyaltySplitter.connect(NftRoyaltyTreasury).withdraw();
    const receipt = await tx.wait();

    const gasUsed = receipt.gasUsed;
    const effectiveGasPrice = receipt.gasPrice || receipt.effectiveGasPrice;
    const txFee = gasUsed * effectiveGasPrice;

    // Check royalty treasury balance after sale
    const royaltyTreasuryFinalBalance = await ethers.provider.getBalance(
      NftRoyaltyTreasury.address,
    );

    // Convert to BigInt for all math
    const expectedRoyalty = ethers.parseEther("0.003"); // BigInt already

    const expectedFinalBalance =
      royaltyTreasuryInitialBalance + expectedRoyalty - txFee;

    expect(royaltyTreasuryFinalBalance).to.equal(expectedFinalBalance);
  });

  it("Check fees for original creator of STR domain", async function () {
    //Check royalty treasury balance
    const royaltyOriginalCreatorBalance = await ethers.provider.getBalance(
      buyer1.address,
    );

    //get the listing details
    const listing = await MarketplaceInstance.getListing(1);

    //Get splitter address
    const [splitterAddr, royaltyAmount] =
      await StrDomainsNFTInstance.royaltyInfo(1, listing.price);

    const RoyaltySplitter = await ethers.getContractAt(
      "RoyaltySplitter",
      splitterAddr,
    );

    const tx = await RoyaltySplitter.connect(buyer1).withdraw();
    const receipt = await tx.wait();

    const gasUsed = receipt.gasUsed;
    const effectiveGasPrice = receipt.gasPrice || receipt.effectiveGasPrice;
    const txFee = gasUsed * effectiveGasPrice;

    // Check royalty treasury balance after sale
    const royaltyOriginalCreatorFinalBalance = await ethers.provider.getBalance(
      buyer1.address,
    );

    // Convert to BigInt for all math
    const expectedRoyalty = ethers.parseEther("0.002"); // BigInt already

    const expectedFinalBalance =
      royaltyOriginalCreatorBalance + expectedRoyalty - txFee;

    expect(royaltyOriginalCreatorFinalBalance).to.equal(expectedFinalBalance);
  });
});
