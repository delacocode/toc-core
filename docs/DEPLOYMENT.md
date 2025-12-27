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
