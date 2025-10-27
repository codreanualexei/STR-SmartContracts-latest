import { ethers } from "hardhat";
import * as dotenv from "dotenv";
dotenv.config();

async function main() {
  const [signer] = await ethers.getSigners();
  const registryAddr = process.env.REGISTRY_ADDRESS;
  if (!registryAddr) throw new Error("Set REGISTRY_ADDRESS in .env");

  // кому минтим и какой URI
  const to = process.env.MINT_TO ?? signer.address;
  const uri = process.env.MINT_URI ?? "ipfs://QmYourMetadataCid/metadata.json";

  console.log("Minters account:", signer.address);
  console.log("Registry:", registryAddr);
  console.log("Mint to:", to);
  console.log("URI:", uri);

  const Registry = await ethers.getContractFactory("StrDomainsNFT");
  const registry = Registry.attach(registryAddr);

  const tx = await registry.mint(to, uri);
  const receipt = await tx.wait();
  console.log("Tx:", receipt?.hash);

  // ищем событие Transfer для определения tokenId
  const transferEvt = receipt?.logs
    .map((l) => {
      try {
        return registry.interface.parseLog(l);
      } catch {
        return null;
      }
    })
    .find((e) => e && e.name === "Transfer");

  if (transferEvt) {
    const tokenId = transferEvt.args?.tokenId?.toString();
    console.log("Minted tokenId:", tokenId);
  } else {
    console.log("Minted (tokenId not parsed, check explorer).");
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
