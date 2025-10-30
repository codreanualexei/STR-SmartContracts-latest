const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("Can deploy, mint, get Data, and setup SALES role", function () {
  let owner;
  let secondAddress;
  let treasury;
  let StrDomainsNFTInstance;
  let RoyaltySplitterInstance;
  let RoyaltySplitterFactoryInstance;
  let mintingBlock;

  before(async function () {
    [owner, secondAddress, treasury] = await ethers.getSigners(); //get treasury and owner accounts

    // 1) RoyaltySplitter deployment
    const Splitter = await ethers.getContractFactory("RoyaltySplitter");
    RoyaltySplitterInstance = await Splitter.deploy();
    await RoyaltySplitterInstance.waitForDeployment();
    const splitterImplAddr = await RoyaltySplitterInstance.getAddress();
    //console.log("RoyaltySplitter implementation:", splitterImplAddr);

    // 2) RoyaltySplitterFactory
    const Factory = await ethers.getContractFactory("RoyaltySplitterFactory");
    RoyaltySplitterFactoryInstance = await Factory.deploy(splitterImplAddr);
    await RoyaltySplitterFactoryInstance.waitForDeployment();
    const factoryAddr = await RoyaltySplitterFactoryInstance.getAddress();
    //console.log("RoyaltySplitterFactory:", factoryAddr);

    // 3) StrDomainsNFT (реестр с фикс-роялти 5%: 2% создателю, 3% казне)
    const Registry = await ethers.getContractFactory("StrDomainsNFT");
    // последний аргумент в конструкторе игнорируется (для совместимости)
    StrDomainsNFTInstance = await Registry.deploy(
      "Str Domains",
      "STRDOM",
      treasury,
      factoryAddr,
      500,
    );
    await StrDomainsNFTInstance.waitForDeployment();
    const registryAddr = await StrDomainsNFTInstance.getAddress();
    //console.log("StrDomainsNFT:", registryAddr);
  });

  it("should deploy the contract", async function () {
    expect(await StrDomainsNFTInstance.name()).to.equal("Str Domains");
  });

  it("should mint", async function () {
    const tx = await StrDomainsNFTInstance.connect(owner).mint(
      owner.address,
      "example.str",
      "exampleDomainName.str",
    );
    const txData = await tx.wait();
    mintingBlock = await ethers.provider.getBlock(txData.blockNumber);

    expect(await StrDomainsNFTInstance.ownerOf(1)).to.equal(owner.address);
  });

  it("should get right token metadata", async function () {
    const data = await StrDomainsNFTInstance.getTokenData(1);
    const uri = data[2];
    expect(uri).to.equal("example.str");
  });

  it("should get right token domain name", async function () {
    const tx = await StrDomainsNFTInstance.connect(owner).mint(
      owner.address,
      "test.str",
      "exampleDomainName2.str",
    );
    await tx.wait();
    const data = await StrDomainsNFTInstance.getTokenDataByDomain(
      "exampleDomainName2.str",
    );
    const uri = data[2];
    expect(uri).to.equal("test.str");
  });

  it("should burn token", async function () {
    const tx = await StrDomainsNFTInstance.connect(owner).burn(2);
    await tx.wait();
    await expect(
      StrDomainsNFTInstance.getTokenDataByDomain("exampleDomainName2.str"),
    ).to.be.revertedWith("domain not found");
  });

  it("should remint burned domain", async function () {
    const tx = await StrDomainsNFTInstance.connect(owner).mint(
      owner.address,
      "reminted.str",
      "exampleDomainName2.str",
    );
    await tx.wait();
    const data = await StrDomainsNFTInstance.getTokenDataByDomain(
      "exampleDomainName2.str",
    );
    const uri = data[2];
    expect(uri).to.equal("reminted.str");
    expect(data[0]).to.equal(owner.address); //creator
    expect(Number(data[5])).to.equal(3); //tokenId
  });

  it("should get right mint timestamp", async function () {
    const mintedAt = await StrDomainsNFTInstance.mintedAt(1);
    expect(mintedAt).to.equal(mintingBlock.timestamp); //compare timestamp from SC with block timestamp got at minting time
  });

  it("should allow SALES_ROLE to record sale", async function () {
    const tokenId = 1;
    const price = ethers.parseEther("1");
    const buyer = secondAddress.address;

    // Grant SALES_ROLE to secondAccount
    await StrDomainsNFTInstance.grantRole(
      await StrDomainsNFTInstance.SALES_ROLE(),
      secondAddress.address,
    );

    // Check if secondAccount has SALES_ROLE
    const hasRole = await StrDomainsNFTInstance.hasRole(
      await StrDomainsNFTInstance.SALES_ROLE(),
      secondAddress.address,
    );
    expect(hasRole).to.be.true;

    // Record sale
    //expect(await StrDomainsNFTInstance.connect(secondAddress).recordSale(tokenId, price, buyer)).to.emit(StrDomainsNFTInstance, 'SaleRecorded').withArgs(tokenId, price, buyer, anyValue);
  });

  it("should not allow non-SALES_ROLE to record sale", async function () {
    const tokenId = 1;
    const price = ethers.parseEther("1");
    const buyer = secondAddress.address;

    //check if owner has SALES_ROLE
    const hasRole = await StrDomainsNFTInstance.hasRole(
      await StrDomainsNFTInstance.SALES_ROLE(),
      owner.address,
    );

    //expect(hasRole).to.be.false;

    await expect(
      StrDomainsNFTInstance.connect(owner).recordSale(tokenId, price, buyer),
    ).to.be.revertedWithCustomError(
      StrDomainsNFTInstance,
      "AccessControlUnauthorizedAccount",
    );
  });

  it("should not allow non-SALES_ROLE after call revokeRole method", async function () {
    const tokenId = 1;
    const price = ethers.parseEther("1");
    const buyer = secondAddress.address;

    //check if owner has SALES_ROLE
    const hasRole = await StrDomainsNFTInstance.hasRole(
      await StrDomainsNFTInstance.SALES_ROLE(),
      owner.address,
    );

    hasRole
      ? await StrDomainsNFTInstance.revokeRole(
          await StrDomainsNFTInstance.SALES_ROLE(),
          secondAddress.address,
        )
      : null;
    //make test failing
    expect(hasRole).to.be.false;

    await expect(
      StrDomainsNFTInstance.connect(owner).recordSale(tokenId, price, buyer),
    ).to.be.revertedWithCustomError(
      StrDomainsNFTInstance,
      "AccessControlUnauthorizedAccount",
    );
  });
});

describe("Transfer", function () {
  let owner;
  let secondAccount;
  let treasury;
  let StrDomainsNFTInstance;
  let RoyaltySplitterInstance;
  let RoyaltySplitterFactoryInstance;

  before(async function () {
    [owner, secondAccount, treasury] = await ethers.getSigners(); //get treasury and owner accounts

    // 1) RoyaltySplitter deployment
    const Splitter = await ethers.getContractFactory("RoyaltySplitter");
    RoyaltySplitterInstance = await Splitter.deploy();
    await RoyaltySplitterInstance.waitForDeployment();
    const splitterImplAddr = await RoyaltySplitterInstance.getAddress();
    //console.log("RoyaltySplitter implementation:", splitterImplAddr);

    // 2) RoyaltySplitterFactory
    const Factory = await ethers.getContractFactory("RoyaltySplitterFactory");
    RoyaltySplitterFactoryInstance = await Factory.deploy(splitterImplAddr);
    await RoyaltySplitterFactoryInstance.waitForDeployment();
    const factoryAddr = await RoyaltySplitterFactoryInstance.getAddress();
    //console.log("RoyaltySplitterFactory:", factoryAddr);

    // 3) StrDomainsNFT (реестр с фикс-роялти 5%: 2% создателю, 3% казне)
    const Registry = await ethers.getContractFactory("StrDomainsNFT");
    // последний аргумент в конструкторе игнорируется (для совместимости)
    StrDomainsNFTInstance = await Registry.deploy(
      "Str Domains",
      "STRDOM",
      treasury,
      factoryAddr,
      500,
    );
    await StrDomainsNFTInstance.waitForDeployment();
    const registryAddr = await StrDomainsNFTInstance.getAddress();
    //console.log("StrDomainsNFT:", registryAddr);

    // mint
    const tx = await StrDomainsNFTInstance.connect(owner).mint(
      owner.address,
      "example.str",
      "exampleDomainName2.str",
    );
    await tx.wait();
    expect(await StrDomainsNFTInstance.ownerOf(1)).to.equal(owner.address);
  });

  it("should transfer nft token", async function () {
    const tx = await StrDomainsNFTInstance.connect(owner).transferFrom(
      owner.address,
      secondAccount.address,
      1,
    );
    await tx.wait();
    expect(await StrDomainsNFTInstance.ownerOf(1)).to.equal(
      secondAccount.address,
    );
  });
});

describe("Treasury", function () {
  let owner;
  let secondAccount;
  let treasury;
  let StrDomainsNFTInstance;
  let RoyaltySplitterInstance;
  let RoyaltySplitterFactoryInstance;

  before(async function () {
    [owner, secondAccount, treasury] = await ethers.getSigners(); //get treasury and owner accounts

    // 1) RoyaltySplitter deployment
    const Splitter = await ethers.getContractFactory("RoyaltySplitter");
    RoyaltySplitterInstance = await Splitter.deploy();
    await RoyaltySplitterInstance.waitForDeployment();
    const splitterImplAddr = await RoyaltySplitterInstance.getAddress();
    //console.log("RoyaltySplitter implementation:", splitterImplAddr);

    // 2) RoyaltySplitterFactory
    const Factory = await ethers.getContractFactory("RoyaltySplitterFactory");
    RoyaltySplitterFactoryInstance = await Factory.deploy(splitterImplAddr);
    await RoyaltySplitterFactoryInstance.waitForDeployment();
    const factoryAddr = await RoyaltySplitterFactoryInstance.getAddress();
    //console.log("RoyaltySplitterFactory:", factoryAddr);

    // 3) StrDomainsNFT (реестр с фикс-роялти 5%: 2% создателю, 3% казне)
    const Registry = await ethers.getContractFactory("StrDomainsNFT");
    // последний аргумент в конструкторе игнорируется (для совместимости)
    StrDomainsNFTInstance = await Registry.deploy(
      "Str Domains",
      "STRDOM",
      treasury,
      factoryAddr,
      500,
    );
    await StrDomainsNFTInstance.waitForDeployment();
    const registryAddr = await StrDomainsNFTInstance.getAddress();
    //console.log("StrDomainsNFT:", registryAddr);
  });

  it("should be able to set treasury when owner", async function () {
    const tx = await StrDomainsNFTInstance.connect(owner).setTreasury(
      secondAccount.address,
    );
    await tx.wait();
    expect(await StrDomainsNFTInstance.treasury()).to.equal(
      secondAccount.address,
    );
  });

  it("should not be able to set treasury when it's not the owner", async function () {
    await expect(
      StrDomainsNFTInstance.connect(secondAccount).setTreasury(owner.address),
    ).to.be.revertedWithCustomError(
      StrDomainsNFTInstance,
      "AccessControlUnauthorizedAccount",
    ); //Expected to throw an error with "AccessControlUnauthorizedAccount"
  });
});

describe("SplitterFactory", function () {
  let owner;
  let secondAccount;
  let treasury;
  let StrDomainsNFTInstance;
  let RoyaltySplitterInstance;
  let RoyaltySplitterFactoryInstance;

  before(async function () {
    [owner, secondAccount, treasury] = await ethers.getSigners(); //get treasury and owner accounts

    // 1) RoyaltySplitter deployment
    const Splitter = await ethers.getContractFactory("RoyaltySplitter");
    RoyaltySplitterInstance = await Splitter.deploy();
    await RoyaltySplitterInstance.waitForDeployment();
    const splitterImplAddr = await RoyaltySplitterInstance.getAddress();
    //console.log("RoyaltySplitter implementation:", splitterImplAddr);

    // 2) RoyaltySplitterFactory
    const Factory = await ethers.getContractFactory("RoyaltySplitterFactory");
    RoyaltySplitterFactoryInstance = await Factory.deploy(splitterImplAddr);
    await RoyaltySplitterFactoryInstance.waitForDeployment();
    const factoryAddr = await RoyaltySplitterFactoryInstance.getAddress();
    //console.log("RoyaltySplitterFactory:", factoryAddr);

    // 3) StrDomainsNFT (реестр с фикс-роялти 5%: 2% создателю, 3% казне)
    const Registry = await ethers.getContractFactory("StrDomainsNFT");
    // последний аргумент в конструкторе игнорируется (для совместимости)
    StrDomainsNFTInstance = await Registry.deploy(
      "Str Domains",
      "STRDOM",
      treasury,
      factoryAddr,
      500,
    );
    await StrDomainsNFTInstance.waitForDeployment();
    const registryAddr = await StrDomainsNFTInstance.getAddress();
    //console.log("StrDomainsNFT:", registryAddr);
  });

  it("should be able to set new SplitterFactory when owner", async function () {
    const Factory = await ethers.getContractFactory("RoyaltySplitterFactory");
    const factory = await Factory.deploy(RoyaltySplitterInstance);
    await factory.waitForDeployment();
    const factoryAddress = await factory.getAddress();

    const tx =
      await StrDomainsNFTInstance.connect(owner).setSplitterFactory(
        factoryAddress,
      );
    await tx.wait();

    expect(await StrDomainsNFTInstance.splitterFactory()).to.equal(
      factoryAddress,
    );
  });

  it("should not be able to set new SplitterFactory when not owner", async function () {
    const Factory = await ethers.getContractFactory("RoyaltySplitterFactory");
    const factory = await Factory.deploy(RoyaltySplitterInstance);
    await factory.waitForDeployment();
    const factoryAddress = await factory.getAddress();

    await expect(
      StrDomainsNFTInstance.connect(secondAccount).setSplitterFactory(
        factoryAddress,
      ),
    ).to.be.revertedWithCustomError(
      StrDomainsNFTInstance,
      "AccessControlUnauthorizedAccount",
    );
  });
});
