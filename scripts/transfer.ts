import { ethers } from "hardhat";
import * as dotenv from "dotenv";
dotenv.config();

/**
 * ENV параметры:
 *  - REGISTRY_ADDRESS=0x...
 *  - TOKEN_ID=500000
 *  - TO=0x... (получатель)
 *  - USE_SAFE=true|false        (по умолчанию true -> safeTransferFrom)
 *  - DATA=0x...                 (опционально, hex-строка для safeTransferFrom с data)
 *
 * ВАЖНО: скрипт подписывает транзакцию текущим signer'ом (первый в hardhat),
 * убедись, что это владелец токена ИЛИ уже approved-оператор.
 */

async function main() {
  const registryAddr = process.env.REGISTRY_ADDRESS!;
  const tokenIdEnv = process.env.TOKEN_ID;
  const to = process.env.TO!;
  if (!registryAddr) throw new Error("Set REGISTRY_ADDRESS in .env");
  if (!tokenIdEnv) throw new Error("Set TOKEN_ID in env");
  if (!to) throw new Error("Set TO in env");

  const tokenId = BigInt(tokenIdEnv);
  const useSafe = (process.env.USE_SAFE ?? "true").toLowerCase() !== "false";
  const dataHex = process.env.DATA;

  const [signer] = await ethers.getSigners();
  console.log("Signer:", signer.address);
  console.log("Registry:", registryAddr);
  console.log("TokenID:", tokenId.toString());
  console.log("To:", to);
  console.log("Mode:", useSafe ? "safeTransferFrom" : "transferFrom");

  const Registry = await ethers.getContractFactory("StrDomainsNFT");
  const nft = Registry.attach(registryAddr).connect(signer);

  // Текущий владелец
  const owner = await nft.ownerOf(tokenId);
  console.log("Current owner:", owner);

  // Проверяем права: либо signer = владелец, либо уже есть approve
  const isOwner = owner.toLowerCase() === signer.address.toLowerCase();
  let allowed = isOwner;

  if (!allowed) {
    const approved = await nft
      .getApproved(tokenId)
      .catch(() => ethers.ZeroAddress);
    const isApprovedForAll = await nft
      .isApprovedForAll(owner, signer.address)
      .catch(() => false);
    console.log("Approved for token:", approved);
    console.log("isApprovedForAll:", isApprovedForAll);
    allowed =
      (approved && approved.toLowerCase?.() === signer.address.toLowerCase()) ||
      Boolean(isApprovedForAll);
  }

  if (!allowed) {
    throw new Error(
      "Signer не владелец и не одобрен. Попроси владельца выдать approve(tokenId) или setApprovalForAll(signer,true).",
    );
  }

  // Выполняем перевод
  let tx;
  if (useSafe) {
    if (dataHex && dataHex !== "") {
      const dataBytes = ethers.getBytes(dataHex);
      tx = await nft["safeTransferFrom(address,address,uint256,bytes)"](
        owner,
        to,
        tokenId,
        dataBytes,
      );
    } else {
      tx = await nft["safeTransferFrom(address,address,uint256)"](
        owner,
        to,
        tokenId,
      );
    }
  } else {
    tx = await nft.transferFrom(owner, to, tokenId);
  }

  console.log("Tx sent:", tx.hash);
  const rc = await tx.wait();
  console.log("Mined in block:", rc?.blockNumber);

  // Проверим нового владельца
  const newOwner = await nft.ownerOf(tokenId);
  console.log("New owner:", newOwner);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
