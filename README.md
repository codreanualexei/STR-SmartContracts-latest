# Sample Hardhat Project

This project demonstrates a basic Hardhat use case. It comes with a sample contract, a test for that contract, and a Hardhat Ignition module that deploys that contract.

Try running some of the following tasks:

```shell
npx hardhat help
npx hardhat test
REPORT_GAS=true npx hardhat test
npx hardhat node
npx hardhat ignition deploy ./ignition/modules/Lock.ts
```



Probleme:

Daca cinev face un marketplace are optiunea sa nu plateasca royalty.

solutia: rescriem hook-ul _beforeTokenTransfer(), si impunem sa verifice SALES_ROLE inainte de orice transfer.

function _beforeTokenTransfer(
    address from,
    address to,
    uint256 tokenId,
    uint256 batchSize
) internal override {

    if (from != address(0) && to != address(0)) {
        require(
            hasRole(SALES_ROLE, msg.sender), // Check if the caller has SALES_ROLE
            "unauthorized operator"
        );
    }
    super._beforeTokenTransfer(from, to, tokenId, batchSize);
}


Dar daca facem asta restrictionam userii sa trasfere NFT-urile (domeniile) intre ei, si trsferul se va face doar prin market place sau alte wallet-uri autorizate cu SALES_ROLE flag.
