require("@nomicfoundation/hardhat-toolbox");
require('hardhat-abi-exporter');

/** @type import('hardhat/config').HardhatUserConfig */
module.exports = {
    gasReporter: {
        currency: 'USD',
        enabled: false,
        gasPrice: 50
    },
    contractSizer: {
        runOnCompile: true
    },
    abiExporter: {
        runOnCompile: false,
        path: './abi',
        clear: true,
        flat: true,
        spacing: 2
    },
    solidity: {
        version: "0.8.17",
        settings: {
            optimizer: {
                enabled: true,
                runs: 200
            }
        }
    },
    networks: {
        hardhat: {
            allowUnlimitedContractSize: true,
            chainId: 22224
        },
        fakenet: {
            url: 'http://localhost:20545',
            chainId: 22224,
            accounts: [
                "163f5f0f9a621d72fedd85ffca3d08d131ab4e812181e0d30ffd1c885d20aac7"
            ]
        },
        testnet: {
            url: 'http://localhost:20545',
            chainId: 22223,
            accounts: [
                "794ab11e60f5558a04680627eeebf6eb57201ff4e7f686926cc960c75f781ee2"
            ]
        }
    }
};
