import { config as dotenv } from "dotenv";
dotenv();

import "@nomicfoundation/hardhat-toolbox";
import { HardhatUserConfig } from "hardhat/config";

const config: HardhatUserConfig = {
  solidity: {
    version: "0.8.24",
    settings: { optimizer: { enabled: true, runs: 200 } },
  },
  networks: {
    amoy: {
      url: process.env.AMOY_RPC_URL || "",
      accounts: process.env.MNEMONIC
        ? {
            mnemonic: process.env.MNEMONIC,
            initialIndex: 0,
            count: 10,
            path: "m/44'/60'/0'/0",
          }
        : [],
      chainId: 80002,
    },
    polygon: {
      url: process.env.POLYGON_RPC_URL || "",
      accounts: process.env.PRIVATE_KEY_DEPLOY
        ? [process.env.PRIVATE_KEY_DEPLOY]
        : [],
      chainId: 137,
    },
    localhost: {
      url: "http://127.0.0.1:8545",
      chainId: 31337, // Default chain ID for Hardhat local node
    },
  },
  etherscan: {
    apiKey: {
      polygonAmoy: process.env.POLYGONSCAN_API_KEY || "",
      polygon: process.env.POLYGONSCAN_API_KEY || "",
    },
  },
};

export default config;
