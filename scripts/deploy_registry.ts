import { ethers } from "hardhat";
import * as dotenv from "dotenv";
dotenv.config();

async function main() {
  const isProduction = process.env.PRODUCTION === "true";
  console.log("isProduction:", isProduction);
  const [deployer, marketplaceTreasury, RoyaltyNftTreasury] =
    await ethers.getSigners();

  console.log("Deploying with:", deployer.address);

  const balance = await deployer.provider.getBalance(deployer.address);
  console.log("Deployer balance:", ethers.formatEther(balance));

  if (isProduction) {
    //If we deploy in production, check if we have the private key set
    if (!process.env.PRIVATE_KEY_DEPLOY)
      throw new Error("Set PRIVATE_KEY_DEPLOY .env");
  }

  //check all env variables
  if (!process.env.MARKETPLACE_TREASURY)
    throw new Error("Set MARKETPLACE_TREASURY in .env");
  if (!process.env.NFT_ROYALTY_TREASURY)
    throw new Error("Set NFT_ROYALTY_TREASURY in .env");
  if (!process.env.FEE_MARKETPLACE_BPS)
    throw new Error("Set FEE_MARKETPLACE_BPS in .env");
  if (!process.env.ROYALTY) throw new Error("Set ROYALTY in .env");

  const MARKETPLACE_TREASURY = isProduction
    ? process.env.MARKETPLACE_TREASURY
    : marketplaceTreasury.address;
  const FEE_MARKETPLACE_BPS = isProduction
    ? process.env.FEE_MARKETPLACE_BPS
    : 250; // 2.5%
  const NFT_ROYALTY_TREASURY = isProduction
    ? process.env.NFT_ROYALTY_TREASURY
    : RoyaltyNftTreasury.address;
  const ROYALTY = isProduction ? process.env.ROYALTY : 500; // 5%

  // 1) RoyaltySplitter (имплементация)
  const Splitter = await ethers.getContractFactory("RoyaltySplitter");
  const splitterImpl = await Splitter.deploy();
  await splitterImpl.waitForDeployment();
  const splitterImplAddr = await splitterImpl.getAddress();
  console.log("RoyaltySplitter implementation:", splitterImplAddr);

  // 2) RoyaltySplitterFactory (клоны EIP-1167)
  const Factory = await ethers.getContractFactory("RoyaltySplitterFactory");
  const factory = await Factory.deploy(splitterImplAddr);
  await factory.waitForDeployment();
  const factoryAddr = await factory.getAddress();
  console.log("RoyaltySplitterFactory:", factoryAddr);

  //3) StrDomainsNFT (реестр с фикс-роялти 5%: 2% создателю, 3% казне)
  const Registry = await ethers.getContractFactory("StrDomainsNFT");
  // последний аргумент в конструкторе игнорируется (для совместимости)
  const registry = await Registry.deploy(
    "Str Domains",
    "STRDOM",
    NFT_ROYALTY_TREASURY,
    factoryAddr,
    ROYALTY,
  );
  await registry.waitForDeployment();
  const registryAddr = await registry.getAddress();
  console.log("StrDomainsNFT:", registryAddr);

  // 4)Marketplace deployment
  const Marketplace = await ethers.getContractFactory("Marketplace");
  const MarketplaceInstance = await Marketplace.deploy(
    MARKETPLACE_TREASURY,
    FEE_MARKETPLACE_BPS,
  );
  await MarketplaceInstance.waitForDeployment();
  const marketplaceAddr = await MarketplaceInstance.getAddress();

  const SALES_ROLE = ethers.id("SALES_ROLE");

  const tx = await registry.grantRole(SALES_ROLE, marketplaceAddr);
  await tx.wait();

  const hasRole = await registry.hasRole(SALES_ROLE, marketplaceAddr);
  if (!hasRole) throw new Error("Marketplace should have SALES_ROLE");

  console.log("\nDONE ✅ below you can find all the setup data");
  console.log("===============================\n");

  console.log(`Deployer: ${deployer.address}\n`);

  console.log(`SPLITTER_IMPLEMENTATION_ADDRESS=${splitterImplAddr}`);
  console.log(`SPLITTER_FACTORY_ADDRESS=${factoryAddr}`);
  console.log(`STR_DOMAIN_NFT_COLLECTION=${registryAddr}`);
  console.log(`MARKETPLACE_ADDRESS=${marketplaceAddr}`);

  console.log(`\n=============Treasury==========\n`);

  console.log(`NFT_ROYALTY_TREASURY=${NFT_ROYALTY_TREASURY}`);
  console.log(`MARKETPLACE_TREASURY=${MARKETPLACE_TREASURY}`);

  console.log("\n===============================\n");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
