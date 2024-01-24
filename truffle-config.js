require('dotenv').config();
const mnemonic = process.env.MNEMONIC;

const HDWalletProvider = require('@truffle/hdwallet-provider');


module.exports = {
  networks: {
    bsc: {
      provider: () => new HDWalletProvider(mnemonic, `https://bsc-dataseed4.binance.org/`),
      network_id: 56,
      gas: 25000000, 
      gasPrice: 3000000000,
      skipDryRun: true     // Skip dry run before migrations
    },
    // BSC Testnet
    bsctest: {
      provider: () => new HDWalletProvider(mnemonic, `https://data-seed-prebsc-2-s3.binance.org:8545/`),
      network_id: 97,
      gas: 10000000,
      gasPrice: 3000000000,
      skipDryRun: true
    },

    development: {
      host: "127.0.0.1",  // Ganache default
      port: 7545,         // Ganache GUI default port, for CLI it might be 8545
      network_id: 5777,
      gas: 900000,
      gasPrice: 3000000000
    }
  },

  mocha: {
    // timeout: 100000
  },

  compilers: {
    solc: {
      version: "0.8.23",      
      docker: false,        
      settings: {  
       optimizer: {
         enabled: true,
         runs: 200
       },
       evmVersion: "paris",
       viaIR: true
      }
    }
  },
};
