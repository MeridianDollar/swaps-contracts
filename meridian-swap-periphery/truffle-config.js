require('dotenv').config();
const HDWalletProvider = require('@truffle/hdwallet-provider');

module.exports = {
  contracts_build_directory: "./build/truffle",
  networks: {
    telos: {
      network_id: 40,
      provider: () =>
        new HDWalletProvider(
        process.env.PRIVATE_KEY,
        "https://mainnet.telos.net/evm"
      ),
      gas: 77743400,
      gasPrice: 5038078036860000000
    }
  },
  compilers: {
    solc: {
      version: "0.6.6",
      settings: {
        optimizer: {
          enabled: true,
          runs: 1
        }
      }
    }
  },
  db: {
    enabled: false
  }
};
