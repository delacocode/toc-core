# TOC Deployment System Design

## Overview

Complete Hardhat Ignition deployment system for TOC-core smart contracts with support for Sepolia testnet and multiple L2 mainnets (Base, Arbitrum, Polygon).

## Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Deployment tool | Hardhat Ignition | Declarative, resumable, tracks state |
| Configuration | Separate scripts | Config changes more often than deployments |
| Upgrades | Immutable | Simplicity for initial version |
| Wallet | Mnemonic-based | HD derivation, same addresses across networks |
| Pyth (testnet) | MockPythOracle | Accepts encoded payloads like production |

## File Structure

```
ignition/
  modules/
    TOCRegistry.ts          # Core registry deployment
    OptimisticResolver.ts   # Depends on registry
    PythPriceResolver.ts    # Depends on registry + Pyth address
    SimpleTruthKeeper.ts    # Depends on registry
    MockPythOracle.ts       # Testnet only
    TOCSystem.ts            # Composes all modules together

  parameters/
    sepolia.json            # Testnet config
    base.json               # Base mainnet
    arbitrum.json           # Arbitrum mainnet
    polygon.json            # Polygon mainnet

scripts/
  configure-system.ts       # Full initial configuration
  utils/
    get-deployed.ts         # Helper to read Ignition deployment artifacts

contracts/mocks/
  MockPythOracle.sol        # Mock for testnet with payload decoding

docs/
  DEPLOYMENT.md             # Deployment guide
```

## Ignition Modules

### TOCRegistry.ts
```typescript
import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";

const TOCRegistryModule = buildModule("TOCRegistry", (m) => {
  const registry = m.contract("TOCRegistry");
  return { registry };
});

export default TOCRegistryModule;
```

### OptimisticResolver.ts
```typescript
import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";
import TOCRegistryModule from "./TOCRegistry";

const OptimisticResolverModule = buildModule("OptimisticResolver", (m) => {
  const { registry } = m.useModule(TOCRegistryModule);
  const resolver = m.contract("OptimisticResolver", [registry]);
  return { resolver };
});

export default OptimisticResolverModule;
```

### PythPriceResolver.ts
```typescript
import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";
import TOCRegistryModule from "./TOCRegistry";

const PythPriceResolverModule = buildModule("PythPriceResolver", (m) => {
  const { registry } = m.useModule(TOCRegistryModule);
  const pythAddress = m.getParameter("pythAddress");
  const resolver = m.contract("PythPriceResolver", [pythAddress, registry]);
  return { resolver };
});

export default PythPriceResolverModule;
```

### SimpleTruthKeeper.ts
```typescript
import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";
import TOCRegistryModule from "./TOCRegistry";

const SimpleTruthKeeperModule = buildModule("SimpleTruthKeeper", (m) => {
  const { registry } = m.useModule(TOCRegistryModule);
  const owner = m.getParameter("truthKeeperOwner");
  const minDisputeWindow = m.getParameter("minDisputeWindow", 3600);
  const minTKWindow = m.getParameter("minTruthKeeperWindow", 86400);

  const truthKeeper = m.contract("SimpleTruthKeeper", [
    registry, owner, minDisputeWindow, minTKWindow
  ]);
  return { truthKeeper };
});

export default SimpleTruthKeeperModule;
```

### MockPythOracle.ts (testnet only)
```typescript
import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";

const MockPythOracleModule = buildModule("MockPythOracle", (m) => {
  const mock = m.contract("MockPythOracle");
  return { mock };
});

export default MockPythOracleModule;
```

### TOCSystem.ts
```typescript
import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";
import TOCRegistryModule from "./TOCRegistry";
import OptimisticResolverModule from "./OptimisticResolver";
import PythPriceResolverModule from "./PythPriceResolver";
import SimpleTruthKeeperModule from "./SimpleTruthKeeper";

const TOCSystemModule = buildModule("TOCSystem", (m) => {
  const { registry } = m.useModule(TOCRegistryModule);
  const { resolver: optimisticResolver } = m.useModule(OptimisticResolverModule);
  const { resolver: pythResolver } = m.useModule(PythPriceResolverModule);
  const { truthKeeper } = m.useModule(SimpleTruthKeeperModule);

  return { registry, optimisticResolver, pythResolver, truthKeeper };
});

export default TOCSystemModule;
```

## MockPythOracle Contract

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "@pythnetwork/pyth-sdk-solidity/IPyth.sol";
import "@pythnetwork/pyth-sdk-solidity/PythStructs.sol";

contract MockPythOracle is IPyth {
    mapping(bytes32 => PythStructs.Price) private prices;

    // Accepts encoded payload like real Pyth
    // Each update: abi.encode(priceId, price, conf, expo, publishTime)
    function updatePriceFeeds(bytes[] calldata updateData) external payable override {
        require(msg.value >= updateData.length, "Insufficient fee"); // 1 wei per update

        for (uint i = 0; i < updateData.length; i++) {
            (
                bytes32 priceId,
                int64 price,
                uint64 conf,
                int32 expo,
                uint publishTime
            ) = abi.decode(updateData[i], (bytes32, int64, uint64, int32, uint));

            prices[priceId] = PythStructs.Price({
                price: price,
                conf: conf,
                expo: expo,
                publishTime: publishTime
            });
        }
    }

    function getPriceUnsafe(bytes32 id) external view override returns (PythStructs.Price memory) {
        return prices[id];
    }

    function getPriceNoOlderThan(bytes32 id, uint age) external view override returns (PythStructs.Price memory) {
        require(block.timestamp - prices[id].publishTime <= age, "Price too old");
        return prices[id];
    }

    function getUpdateFee(bytes[] calldata updateData) external pure override returns (uint) {
        return updateData.length; // 1 wei per price update
    }

    // Stub remaining IPyth interface methods
    function getValidTimePeriod() external pure override returns (uint) { return 60; }
    function getPrice(bytes32) external pure override returns (PythStructs.Price memory) { revert("Use getPriceUnsafe"); }
    function getEmaPrice(bytes32) external pure override returns (PythStructs.Price memory) { revert("Not implemented"); }
    function getEmaPriceUnsafe(bytes32) external pure override returns (PythStructs.Price memory) { revert("Not implemented"); }
    function getEmaPriceNoOlderThan(bytes32, uint) external pure override returns (PythStructs.Price memory) { revert("Not implemented"); }
    function updatePriceFeedsIfNecessary(bytes[] calldata, bytes32[] calldata, uint64[] calldata) external payable override { revert("Not implemented"); }
    function parsePriceFeedUpdates(bytes[] calldata, bytes32[] calldata, uint64, uint64) external payable override returns (PythStructs.PriceFeed[] memory) { revert("Not implemented"); }
    function parsePriceFeedUpdatesUnique(bytes[] calldata, bytes32[] calldata, uint64, uint64) external payable override returns (PythStructs.PriceFeed[] memory) { revert("Not implemented"); }
}
```

## Parameter Files

### sepolia.json (testnet)
```json
{
  "PythPriceResolver": {
    "pythAddress": "DEPLOYED_MOCK_PYTH_ADDRESS"
  },
  "SimpleTruthKeeper": {
    "truthKeeperOwner": "0xYOUR_TESTNET_ADMIN",
    "minDisputeWindow": 300,
    "minTruthKeeperWindow": 600
  },
  "ConfigureSystem": {
    "treasury": "0xYOUR_TESTNET_TREASURY",
    "protocolFeeStandard": "10000000000000000",
    "minResolutionBond": "100000000000000000",
    "minDisputeBond": "100000000000000000",
    "minEscalationBond": "50000000000000000",
    "tkShareBasisPoints": 4000
  }
}
```

### base.json (mainnet)
```json
{
  "PythPriceResolver": {
    "pythAddress": "0x8250f4aF4B972684F7b336503E2D6dFeDeB1487a"
  },
  "SimpleTruthKeeper": {
    "truthKeeperOwner": "0xYOUR_PRODUCTION_MULTISIG",
    "minDisputeWindow": 3600,
    "minTruthKeeperWindow": 86400
  },
  "ConfigureSystem": {
    "treasury": "0xYOUR_PRODUCTION_TREASURY",
    "protocolFeeStandard": "10000000000000000",
    "minResolutionBond": "1000000000000000000",
    "minDisputeBond": "1000000000000000000",
    "minEscalationBond": "500000000000000000",
    "tkShareBasisPoints": 4000
  }
}
```

### Pyth Addresses by Network

| Network | Pyth Address | Chain ID |
|---------|--------------|----------|
| Sepolia | MockPythOracle (deployed) | 11155111 |
| Base | 0x8250f4aF4B972684F7b336503E2D6dFeDeB1487a | 8453 |
| Arbitrum | 0xff1a0f4744e8582DF1aE09D5611b887B6a12925C | 42161 |
| Polygon | 0xff1a0f4744e8582DF1aE09D5611b887B6a12925C | 137 |

## Configuration Script

### scripts/configure-system.ts
```typescript
import hre from "hardhat";
import { zeroAddress, parseEther } from "viem";
import { AccountabilityTier } from "../test/helpers/types";

async function main() {
  const network = hre.network.name;

  // Load deployed addresses from Ignition
  const deployedAddresses = await import(
    `../ignition/deployments/${network}/deployed_addresses.json`
  );

  // Load parameters
  const params = await import(`../ignition/parameters/${network}.json`);
  const config = params.ConfigureSystem;

  // Get contract instances
  const publicClient = await hre.viem.getPublicClient();
  const [deployer] = await hre.viem.getWalletClients();

  const registry = await hre.viem.getContractAt(
    "TOCRegistry",
    deployedAddresses["TOCRegistry#TOCRegistry"]
  );

  console.log("Configuring TOCRegistry...");

  // 1. Set treasury
  console.log("  Setting treasury...");
  await registry.write.setTreasuryAddress([config.treasury]);

  // 2. Set protocol fees
  console.log("  Setting protocol fees...");
  await registry.write.setProtocolFeeStandard([BigInt(config.protocolFeeStandard)]);

  // 3. Add acceptable bonds (native ETH = zeroAddress)
  console.log("  Adding acceptable bonds...");
  await registry.write.addAcceptableResolutionBond([zeroAddress, BigInt(config.minResolutionBond)]);
  await registry.write.addAcceptableDisputeBond([zeroAddress, BigInt(config.minDisputeBond)]);
  await registry.write.addAcceptableEscalationBond([zeroAddress, BigInt(config.minEscalationBond)]);

  // 4. Set TruthKeeper revenue share
  console.log("  Setting TK share...");
  await registry.write.setTKSharePercent([
    AccountabilityTier.TK_GUARANTEED,
    BigInt(config.tkShareBasisPoints)
  ]);

  // 5. Whitelist the TruthKeeper
  console.log("  Whitelisting TruthKeeper...");
  await registry.write.addWhitelistedTruthKeeper([
    deployedAddresses["SimpleTruthKeeper#SimpleTruthKeeper"]
  ]);

  // 6. Register resolvers
  console.log("  Registering resolvers...");
  await registry.write.registerResolver([
    deployedAddresses["OptimisticResolver#OptimisticResolver"]
  ]);
  await registry.write.registerResolver([
    deployedAddresses["PythPriceResolver#PythPriceResolver"]
  ]);

  console.log("Configuration complete!");
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
```

## Hardhat Config Updates

### hardhat.config.ts additions
```typescript
import { vars } from "hardhat/config";

const MNEMONIC = vars.get("MNEMONIC", "test test test test test test test test test test test junk");

const config: HardhatUserConfig = {
  solidity: {
    version: "0.8.29",
    settings: {
      viaIR: true,
      optimizer: { enabled: true, runs: 200 },
    },
  },
  networks: {
    sepolia: {
      url: vars.get("SEPOLIA_RPC_URL", ""),
      accounts: {
        mnemonic: MNEMONIC,
        path: "m/44'/60'/0'/0",
        count: 5,
      },
    },
    base: {
      url: vars.get("BASE_RPC_URL", "https://mainnet.base.org"),
      accounts: {
        mnemonic: MNEMONIC,
        path: "m/44'/60'/0'/0",
        count: 5,
      },
    },
    arbitrum: {
      url: vars.get("ARBITRUM_RPC_URL", "https://arb1.arbitrum.io/rpc"),
      accounts: {
        mnemonic: MNEMONIC,
        path: "m/44'/60'/0'/0",
        count: 5,
      },
    },
    polygon: {
      url: vars.get("POLYGON_RPC_URL", "https://polygon-rpc.com"),
      accounts: {
        mnemonic: MNEMONIC,
        path: "m/44'/60'/0'/0",
        count: 5,
      },
    },
  },
};
```

## Package.json Scripts

```json
{
  "scripts": {
    "test": "hardhat test",
    "compile": "hardhat compile",
    "clean": "hardhat clean",

    "deploy:sepolia": "hardhat ignition deploy ignition/modules/TOCSystem.ts --network sepolia --parameters ignition/parameters/sepolia.json",
    "deploy:base": "hardhat ignition deploy ignition/modules/TOCSystem.ts --network base --parameters ignition/parameters/base.json",
    "deploy:arbitrum": "hardhat ignition deploy ignition/modules/TOCSystem.ts --network arbitrum --parameters ignition/parameters/arbitrum.json",
    "deploy:polygon": "hardhat ignition deploy ignition/modules/TOCSystem.ts --network polygon --parameters ignition/parameters/polygon.json",

    "configure:sepolia": "hardhat run scripts/configure-system.ts --network sepolia",
    "configure:base": "hardhat run scripts/configure-system.ts --network base",
    "configure:arbitrum": "hardhat run scripts/configure-system.ts --network arbitrum",
    "configure:polygon": "hardhat run scripts/configure-system.ts --network polygon"
  }
}
```

## Deployment Workflow

```bash
# 1. Set mnemonic (Hardhat 3 vars)
npx hardhat vars set MNEMONIC
npx hardhat vars set SEPOLIA_RPC_URL

# 2. Deploy contracts
npm run deploy:sepolia

# 3. Configure system
npm run configure:sepolia

# 4. Verify on explorer (optional)
npx hardhat ignition verify sepolia-deployment --network sepolia
```

## Implementation Checklist

- [ ] Create MockPythOracle.sol contract
- [ ] Create Ignition modules (6 files)
- [ ] Create parameter files (4 files)
- [ ] Create configure-system.ts script
- [ ] Update hardhat.config.ts with network configs
- [ ] Update package.json with deploy scripts
- [ ] Create DEPLOYMENT.md documentation
- [ ] Test full deployment on Sepolia
- [ ] Delete Counter.ts placeholder

## Sources

- [Hardhat Ignition Getting Started](https://hardhat.org/ignition/docs/getting-started)
- [Creating Ignition Modules](https://hardhat.org/ignition/docs/guides/creating-modules)
- [Deploying with Scripts](https://hardhat.org/ignition/docs/guides/scripts)
