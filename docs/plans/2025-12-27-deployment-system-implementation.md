# Deployment System Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Implement a complete Hardhat Ignition deployment system for TOC-core contracts with support for Sepolia testnet and L2 mainnets.

**Architecture:** Declarative Ignition modules for contract deployment, separate TypeScript scripts for post-deployment configuration. MockPythOracle enables testnet testing without real oracle data. Per-network parameter files configure environment-specific values.

**Tech Stack:** Hardhat 3, Hardhat Ignition, viem, TypeScript, Solidity 0.8.29

---

## Task 1: Create MockPythOracle Contract

**Files:**
- Create: `contracts/mocks/MockPythOracle.sol`

**Step 1: Create the MockPythOracle contract**

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "@pythnetwork/pyth-sdk-solidity/IPyth.sol";
import "@pythnetwork/pyth-sdk-solidity/PythStructs.sol";

/// @title MockPythOracle
/// @notice Mock Pyth oracle for testnet deployment
/// @dev Accepts ABI-encoded price updates, charges 1 wei per update to match production flow
contract MockPythOracle {
    mapping(bytes32 => PythStructs.Price) private prices;

    error InsufficientFee();
    error PriceTooOld();

    /// @notice Update price feeds with encoded payloads
    /// @dev Each update: abi.encode(priceId, price, conf, expo, publishTime)
    /// @param updateData Array of ABI-encoded price updates
    function updatePriceFeeds(bytes[] calldata updateData) external payable {
        if (msg.value < updateData.length) revert InsufficientFee();

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

    /// @notice Get price without recency check
    function getPriceUnsafe(bytes32 id) external view returns (PythStructs.Price memory) {
        return prices[id];
    }

    /// @notice Get price with age validation
    function getPriceNoOlderThan(bytes32 id, uint age) external view returns (PythStructs.Price memory) {
        if (block.timestamp - prices[id].publishTime > age) revert PriceTooOld();
        return prices[id];
    }

    /// @notice Calculate fee for updates (1 wei per update)
    function getUpdateFee(bytes[] calldata updateData) external pure returns (uint) {
        return updateData.length;
    }

    /// @notice Get valid time period (60 seconds for mock)
    function getValidTimePeriod() external pure returns (uint) {
        return 60;
    }
}
```

**Step 2: Compile to verify contract is valid**

Run: `npx hardhat compile`
Expected: Compilation successful, no errors

**Step 3: Commit**

```bash
git add contracts/mocks/MockPythOracle.sol
git commit -m "feat: add MockPythOracle for testnet deployment"
```

---

## Task 2: Create TOCRegistry Ignition Module

**Files:**
- Create: `ignition/modules/TOCRegistry.ts`
- Delete: `ignition/modules/Counter.ts`

**Step 1: Create TOCRegistry module**

```typescript
import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";

const TOCRegistryModule = buildModule("TOCRegistry", (m) => {
  const registry = m.contract("TOCRegistry");
  return { registry };
});

export default TOCRegistryModule;
```

**Step 2: Delete Counter.ts placeholder**

Run: `rm ignition/modules/Counter.ts`

**Step 3: Commit**

```bash
git add ignition/modules/TOCRegistry.ts
git rm ignition/modules/Counter.ts
git commit -m "feat: add TOCRegistry Ignition module, remove Counter placeholder"
```

---

## Task 3: Create OptimisticResolver Ignition Module

**Files:**
- Create: `ignition/modules/OptimisticResolver.ts`

**Step 1: Create OptimisticResolver module**

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

**Step 2: Commit**

```bash
git add ignition/modules/OptimisticResolver.ts
git commit -m "feat: add OptimisticResolver Ignition module"
```

---

## Task 4: Create PythPriceResolver Ignition Module

**Files:**
- Create: `ignition/modules/PythPriceResolver.ts`

**Step 1: Create PythPriceResolver module**

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

**Step 2: Commit**

```bash
git add ignition/modules/PythPriceResolver.ts
git commit -m "feat: add PythPriceResolver Ignition module"
```

---

## Task 5: Create SimpleTruthKeeper Ignition Module

**Files:**
- Create: `ignition/modules/SimpleTruthKeeper.ts`

**Step 1: Create SimpleTruthKeeper module**

```typescript
import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";
import TOCRegistryModule from "./TOCRegistry";

const SimpleTruthKeeperModule = buildModule("SimpleTruthKeeper", (m) => {
  const { registry } = m.useModule(TOCRegistryModule);
  const owner = m.getParameter("truthKeeperOwner");
  const minDisputeWindow = m.getParameter("minDisputeWindow", 3600);
  const minTKWindow = m.getParameter("minTruthKeeperWindow", 86400);

  const truthKeeper = m.contract("SimpleTruthKeeper", [
    registry,
    owner,
    minDisputeWindow,
    minTKWindow,
  ]);
  return { truthKeeper };
});

export default SimpleTruthKeeperModule;
```

**Step 2: Commit**

```bash
git add ignition/modules/SimpleTruthKeeper.ts
git commit -m "feat: add SimpleTruthKeeper Ignition module"
```

---

## Task 6: Create MockPythOracle Ignition Module

**Files:**
- Create: `ignition/modules/MockPythOracle.ts`

**Step 1: Create MockPythOracle module**

```typescript
import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";

const MockPythOracleModule = buildModule("MockPythOracle", (m) => {
  const mock = m.contract("MockPythOracle");
  return { mock };
});

export default MockPythOracleModule;
```

**Step 2: Commit**

```bash
git add ignition/modules/MockPythOracle.ts
git commit -m "feat: add MockPythOracle Ignition module for testnet"
```

---

## Task 7: Create TOCSystem Composite Module

**Files:**
- Create: `ignition/modules/TOCSystem.ts`

**Step 1: Create TOCSystem module that composes all modules**

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

**Step 2: Commit**

```bash
git add ignition/modules/TOCSystem.ts
git commit -m "feat: add TOCSystem composite Ignition module"
```

---

## Task 8: Create Parameter Files

**Files:**
- Create: `ignition/parameters/sepolia.json`
- Create: `ignition/parameters/base.json`
- Create: `ignition/parameters/arbitrum.json`
- Create: `ignition/parameters/polygon.json`

**Step 1: Create sepolia.json (testnet)**

```json
{
  "PythPriceResolver": {
    "pythAddress": "0x0000000000000000000000000000000000000000"
  },
  "SimpleTruthKeeper": {
    "truthKeeperOwner": "0x0000000000000000000000000000000000000000",
    "minDisputeWindow": 300,
    "minTruthKeeperWindow": 600
  }
}
```

Note: `pythAddress` will be updated after MockPythOracle is deployed. `truthKeeperOwner` should be set to deployer address before deployment.

**Step 2: Create base.json (mainnet)**

```json
{
  "PythPriceResolver": {
    "pythAddress": "0x8250f4aF4B972684F7b336503E2D6dFeDeB1487a"
  },
  "SimpleTruthKeeper": {
    "truthKeeperOwner": "0x0000000000000000000000000000000000000000",
    "minDisputeWindow": 3600,
    "minTruthKeeperWindow": 86400
  }
}
```

**Step 3: Create arbitrum.json**

```json
{
  "PythPriceResolver": {
    "pythAddress": "0xff1a0f4744e8582DF1aE09D5611b887B6a12925C"
  },
  "SimpleTruthKeeper": {
    "truthKeeperOwner": "0x0000000000000000000000000000000000000000",
    "minDisputeWindow": 3600,
    "minTruthKeeperWindow": 86400
  }
}
```

**Step 4: Create polygon.json**

```json
{
  "PythPriceResolver": {
    "pythAddress": "0xff1a0f4744e8582DF1aE09D5611b887B6a12925C"
  },
  "SimpleTruthKeeper": {
    "truthKeeperOwner": "0x0000000000000000000000000000000000000000",
    "minDisputeWindow": 3600,
    "minTruthKeeperWindow": 86400
  }
}
```

**Step 5: Commit**

```bash
git add ignition/parameters/
git commit -m "feat: add parameter files for all networks"
```

---

## Task 9: Create Configuration Script

**Files:**
- Create: `scripts/configure-system.ts`

**Step 1: Create the configuration script**

```typescript
import hre from "hardhat";
import { zeroAddress } from "viem";
import fs from "fs";
import path from "path";

// Configuration values (adjust per network)
const CONFIG = {
  sepolia: {
    treasury: "0x0000000000000000000000000000000000000000", // Set before running
    protocolFeeStandard: 10000000000000000n, // 0.01 ETH
    minResolutionBond: 100000000000000000n, // 0.1 ETH
    minDisputeBond: 100000000000000000n, // 0.1 ETH
    minEscalationBond: 50000000000000000n, // 0.05 ETH
    tkShareBasisPoints: 4000n, // 40%
  },
  base: {
    treasury: "0x0000000000000000000000000000000000000000", // Set before running
    protocolFeeStandard: 10000000000000000n, // 0.01 ETH
    minResolutionBond: 1000000000000000000n, // 1 ETH
    minDisputeBond: 1000000000000000000n, // 1 ETH
    minEscalationBond: 500000000000000000n, // 0.5 ETH
    tkShareBasisPoints: 4000n, // 40%
  },
  arbitrum: {
    treasury: "0x0000000000000000000000000000000000000000", // Set before running
    protocolFeeStandard: 10000000000000000n,
    minResolutionBond: 1000000000000000000n,
    minDisputeBond: 1000000000000000000n,
    minEscalationBond: 500000000000000000n,
    tkShareBasisPoints: 4000n,
  },
  polygon: {
    treasury: "0x0000000000000000000000000000000000000000", // Set before running
    protocolFeeStandard: 10000000000000000n,
    minResolutionBond: 1000000000000000000n,
    minDisputeBond: 1000000000000000000n,
    minEscalationBond: 500000000000000000n,
    tkShareBasisPoints: 4000n,
  },
} as const;

// AccountabilityTier enum value for TK_GUARANTEED
const TK_GUARANTEED = 1;

async function main() {
  const network = hre.network.name as keyof typeof CONFIG;

  if (!CONFIG[network]) {
    throw new Error(`No configuration found for network: ${network}`);
  }

  const config = CONFIG[network];

  // Load deployed addresses from Ignition
  const deploymentPath = path.join(
    __dirname,
    "..",
    "ignition",
    "deployments",
    `chain-${hre.network.config.chainId}`,
    "deployed_addresses.json"
  );

  if (!fs.existsSync(deploymentPath)) {
    throw new Error(`Deployment not found at ${deploymentPath}. Run deploy first.`);
  }

  const deployedAddresses = JSON.parse(fs.readFileSync(deploymentPath, "utf-8"));

  console.log(`\nConfiguring TOCRegistry on ${network}...`);
  console.log(`Using deployed addresses from: ${deploymentPath}\n`);

  const registry = await hre.viem.getContractAt(
    "TOCRegistry",
    deployedAddresses["TOCRegistry#TOCRegistry"]
  );

  // 1. Set treasury
  console.log("1. Setting treasury...");
  const treasuryTx = await registry.write.setTreasuryAddress([config.treasury]);
  console.log(`   TX: ${treasuryTx}`);

  // 2. Set protocol fees
  console.log("2. Setting protocol fees...");
  const feeTx = await registry.write.setProtocolFeeStandard([config.protocolFeeStandard]);
  console.log(`   TX: ${feeTx}`);

  // 3. Add acceptable bonds (native ETH = zeroAddress)
  console.log("3. Adding acceptable resolution bond...");
  const resBondTx = await registry.write.addAcceptableResolutionBond([
    zeroAddress,
    config.minResolutionBond,
  ]);
  console.log(`   TX: ${resBondTx}`);

  console.log("4. Adding acceptable dispute bond...");
  const disBondTx = await registry.write.addAcceptableDisputeBond([
    zeroAddress,
    config.minDisputeBond,
  ]);
  console.log(`   TX: ${disBondTx}`);

  console.log("5. Adding acceptable escalation bond...");
  const escBondTx = await registry.write.addAcceptableEscalationBond([
    zeroAddress,
    config.minEscalationBond,
  ]);
  console.log(`   TX: ${escBondTx}`);

  // 4. Set TruthKeeper revenue share
  console.log("6. Setting TK share...");
  const tkShareTx = await registry.write.setTKSharePercent([
    TK_GUARANTEED,
    config.tkShareBasisPoints,
  ]);
  console.log(`   TX: ${tkShareTx}`);

  // 5. Whitelist the TruthKeeper
  console.log("7. Whitelisting TruthKeeper...");
  const tkAddr = deployedAddresses["SimpleTruthKeeper#SimpleTruthKeeper"];
  const whitelistTx = await registry.write.addWhitelistedTruthKeeper([tkAddr]);
  console.log(`   TX: ${whitelistTx}`);

  // 6. Register resolvers
  console.log("8. Registering OptimisticResolver...");
  const optAddr = deployedAddresses["OptimisticResolver#OptimisticResolver"];
  const optTx = await registry.write.registerResolver([optAddr]);
  console.log(`   TX: ${optTx}`);

  console.log("9. Registering PythPriceResolver...");
  const pythAddr = deployedAddresses["PythPriceResolver#PythPriceResolver"];
  const pythTx = await registry.write.registerResolver([pythAddr]);
  console.log(`   TX: ${pythTx}`);

  console.log("\nConfiguration complete!");
  console.log("\nDeployed addresses:");
  console.log(`  TOCRegistry: ${deployedAddresses["TOCRegistry#TOCRegistry"]}`);
  console.log(`  OptimisticResolver: ${optAddr}`);
  console.log(`  PythPriceResolver: ${pythAddr}`);
  console.log(`  SimpleTruthKeeper: ${tkAddr}`);
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
```

**Step 2: Commit**

```bash
git add scripts/configure-system.ts
git commit -m "feat: add post-deployment configuration script"
```

---

## Task 10: Update Hardhat Config with Networks

**Files:**
- Modify: `hardhat.config.ts`

**Step 1: Update hardhat.config.ts to add network configurations**

Replace entire file with:

```typescript
import type { HardhatUserConfig } from "hardhat/config";
import HardhatToolboxViem from "@nomicfoundation/hardhat-toolbox-viem";
import { vars } from "hardhat/config";

const MNEMONIC = vars.get(
  "MNEMONIC",
  "test test test test test test test test test test test junk"
);

const config: HardhatUserConfig = {
  solidity: {
    version: "0.8.29",
    settings: {
      viaIR: true,
      optimizer: {
        enabled: true,
        runs: 200,
      },
    },
  },
  plugins: [HardhatToolboxViem],
  paths: {
    sources: "./contracts",
    tests: "./test",
    cache: "./cache_hardhat",
    artifacts: "./artifacts",
  },
  // Exclude Foundry test files from compilation
  ignore: ["contracts/test/**/*.sol"],
  networks: {
    sepolia: {
      url: vars.get("SEPOLIA_RPC_URL", "https://rpc.sepolia.org"),
      chainId: 11155111,
      accounts: {
        mnemonic: MNEMONIC,
        path: "m/44'/60'/0'/0",
        count: 5,
      },
    },
    base: {
      url: vars.get("BASE_RPC_URL", "https://mainnet.base.org"),
      chainId: 8453,
      accounts: {
        mnemonic: MNEMONIC,
        path: "m/44'/60'/0'/0",
        count: 5,
      },
    },
    arbitrum: {
      url: vars.get("ARBITRUM_RPC_URL", "https://arb1.arbitrum.io/rpc"),
      chainId: 42161,
      accounts: {
        mnemonic: MNEMONIC,
        path: "m/44'/60'/0'/0",
        count: 5,
      },
    },
    polygon: {
      url: vars.get("POLYGON_RPC_URL", "https://polygon-rpc.com"),
      chainId: 137,
      accounts: {
        mnemonic: MNEMONIC,
        path: "m/44'/60'/0'/0",
        count: 5,
      },
    },
  },
};

export default config;
```

**Step 2: Compile to verify config is valid**

Run: `npx hardhat compile`
Expected: Compilation successful

**Step 3: Commit**

```bash
git add hardhat.config.ts
git commit -m "feat: add network configurations for deployment"
```

---

## Task 11: Update Package.json with Deploy Scripts

**Files:**
- Modify: `package.json`

**Step 1: Add deployment and configuration scripts**

Update the scripts section to:

```json
{
  "scripts": {
    "test": "hardhat test",
    "compile": "hardhat compile",
    "clean": "hardhat clean",
    "deploy:mock-pyth": "hardhat ignition deploy ignition/modules/MockPythOracle.ts --network sepolia",
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

**Step 2: Commit**

```bash
git add package.json
git commit -m "feat: add deployment and configuration npm scripts"
```

---

## Task 12: Create Deployment Documentation

**Files:**
- Create: `docs/DEPLOYMENT.md`

**Step 1: Create DEPLOYMENT.md**

```markdown
# TOC Deployment Guide

## Prerequisites

- Node.js 18+
- Mnemonic with ETH for gas on target network
- RPC URLs for target networks

## Environment Setup

Set up Hardhat variables (stored securely, not in .env):

```bash
# Set mnemonic
npx hardhat vars set MNEMONIC

# Set RPC URLs
npx hardhat vars set SEPOLIA_RPC_URL
npx hardhat vars set BASE_RPC_URL
npx hardhat vars set ARBITRUM_RPC_URL
npx hardhat vars set POLYGON_RPC_URL
```

## Testnet Deployment (Sepolia)

### Step 1: Deploy MockPythOracle

```bash
npm run deploy:mock-pyth
```

Note the deployed MockPythOracle address and update `ignition/parameters/sepolia.json`:
```json
{
  "PythPriceResolver": {
    "pythAddress": "<DEPLOYED_MOCK_PYTH_ADDRESS>"
  }
}
```

### Step 2: Update TruthKeeper Owner

Update `ignition/parameters/sepolia.json` with your admin address:
```json
{
  "SimpleTruthKeeper": {
    "truthKeeperOwner": "<YOUR_ADMIN_ADDRESS>"
  }
}
```

### Step 3: Deploy TOC System

```bash
npm run deploy:sepolia
```

### Step 4: Configure System

Update treasury address in `scripts/configure-system.ts`, then:

```bash
npm run configure:sepolia
```

### Step 5: Verify Contracts (Optional)

```bash
npx hardhat ignition verify chain-11155111 --network sepolia
```

## Mainnet Deployment (Base/Arbitrum/Polygon)

### Step 1: Update Parameters

Edit the appropriate parameter file:
- `ignition/parameters/base.json`
- `ignition/parameters/arbitrum.json`
- `ignition/parameters/polygon.json`

Set `truthKeeperOwner` to your production multisig address.

### Step 2: Update Configuration

In `scripts/configure-system.ts`, set the treasury address for your network.

### Step 3: Deploy

```bash
npm run deploy:base  # or arbitrum, polygon
```

### Step 4: Configure

```bash
npm run configure:base  # or arbitrum, polygon
```

## Network-Specific Information

| Network | Chain ID | Pyth Address |
|---------|----------|--------------|
| Sepolia | 11155111 | MockPythOracle (deploy first) |
| Base | 8453 | 0x8250f4aF4B972684F7b336503E2D6dFeDeB1487a |
| Arbitrum | 42161 | 0xff1a0f4744e8582DF1aE09D5611b887B6a12925C |
| Polygon | 137 | 0xff1a0f4744e8582DF1aE09D5611b887B6a12925C |

## Deployment Artifacts

After deployment, Ignition saves state to:
```
ignition/deployments/chain-<chainId>/
  ├── deployed_addresses.json  # Contract addresses
  ├── journal.json             # Deployment journal
  └── artifacts/               # Contract artifacts
```

**Important:** Commit the `ignition/deployments/` directory to version control.

## Post-Deployment Checklist

- [ ] Verify treasury address is correct
- [ ] Verify TruthKeeper owner is multisig (for mainnet)
- [ ] Test createTOC flow
- [ ] Verify contracts on block explorer
- [ ] Commit deployment artifacts to git

## Resuming Failed Deployments

If deployment fails midway, simply re-run the same command:

```bash
npm run deploy:sepolia
```

Ignition automatically resumes from where it left off.
```

**Step 2: Commit**

```bash
git add docs/DEPLOYMENT.md
git commit -m "docs: add deployment guide"
```

---

## Task 13: Final Verification

**Step 1: Compile all contracts**

Run: `npx hardhat compile`
Expected: Compilation successful with no errors

**Step 2: Run existing tests to ensure nothing broke**

Run: `npx hardhat test`
Expected: All tests pass

**Step 3: Verify Ignition modules load correctly**

Run: `npx hardhat ignition visualize ignition/modules/TOCSystem.ts`
Expected: Shows dependency graph of all modules

**Step 4: Final commit with summary**

```bash
git add -A
git commit -m "feat: complete Hardhat Ignition deployment system

- Added MockPythOracle for testnet with payload decoding
- Created 6 Ignition modules (Registry, Resolvers, TruthKeeper, System)
- Added parameter files for Sepolia, Base, Arbitrum, Polygon
- Created post-deployment configuration script
- Updated hardhat.config.ts with network configs
- Added npm scripts for deploy/configure workflows
- Added comprehensive deployment documentation"
```

---

## Summary

This implementation creates:

| Component | Files |
|-----------|-------|
| Mock Contract | `contracts/mocks/MockPythOracle.sol` |
| Ignition Modules | 6 files in `ignition/modules/` |
| Parameters | 4 files in `ignition/parameters/` |
| Scripts | `scripts/configure-system.ts` |
| Config | Updated `hardhat.config.ts`, `package.json` |
| Docs | `docs/DEPLOYMENT.md` |

Total: 13 tasks, ~15 commits
