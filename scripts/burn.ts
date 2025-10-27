import { ethers } from "hardhat";
import * as dotenv from "dotenv";
dotenv.config();

async function main() {
  const registryAddr = process.env.REGISTRY_ADDRESS!;
  const tokenId = BigInt(process.env.BURN_TOKEN_ID!); // например, 500000

  const [signer] = await ethers.getSigners();
  console.log(
    "Burner:",
    signer.address,
    "Registry:",
    registryAddr,
    "TokenID:",
    tokenId.toString(),
  );

  const Registry = await ethers.getContractFactory("StrDomainsNFT");
  const nft = Registry.attach(registryAddr);

  const tx = await nft.burn(tokenId); // требует: владелец токена ИЛИ approved
  const rc = await tx.wait();
  console.log("Burned. Tx:", rc?.hash);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
