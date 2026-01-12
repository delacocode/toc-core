/**
 * Export all TOC artifacts for consumer projects
 *
 * Usage: npx hardhat run scripts/export-all.ts
 *
 * Exports:
 *   - exports/{network}/addresses.json  - Deployed contract addresses
 *   - exports/{network}/abis/*.json     - Contract ABIs
 *   - exports/toc-types.ts              - TypeScript types (with PYTH_PRICE_IDS synced)
 *   - exports/index.ts                  - Main export file
 */

import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";
import { PYTH_PRICE_IDS, PYTH_PRICE_NAMES } from "./lib/payloads.js";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

// Network configurations
const NETWORKS: Record<string, { chainId: number; name: string }> = {
  sepolia: { chainId: 11155111, name: "Sepolia Testnet" },
  base: { chainId: 8453, name: "Base" },
};

// Contract name mappings (Ignition format -> export format)
const CONTRACT_MAPPINGS: Record<string, string> = {
  "TruthEngine#TruthEngine": "registry",
  "OptimisticResolver#OptimisticResolver": "optimisticResolver",
  "PythPriceResolver#PythPriceResolver": "pythResolver",
  "SimpleTruthKeeper#SimpleTruthKeeper": "truthKeeper",
  "MockPythOracle#MockPythOracle": "mockPyth",
};

// ABIs to export
const ABIS_TO_EXPORT = [
  "TruthEngine",
  "ITruthEngine",
  "OptimisticResolver",
  "PythPriceResolver",
  "SimpleTruthKeeper",
];

function loadIgnitionDeployment(chainId: number): Record<string, string> | null {
  const deployedPath = path.join(
    __dirname,
    `../ignition/deployments/chain-${chainId}/deployed_addresses.json`
  );
  if (!fs.existsSync(deployedPath)) return null;
  return JSON.parse(fs.readFileSync(deployedPath, "utf-8"));
}

function transformAddresses(deployed: Record<string, string>): Record<string, string> {
  const result: Record<string, string> = {};
  for (const [ignitionName, address] of Object.entries(deployed)) {
    const exportName = CONTRACT_MAPPINGS[ignitionName];
    if (exportName) result[exportName] = address;
  }
  return result;
}

function exportAddresses() {
  console.log("📍 Exporting addresses...\n");

  let networksFound = 0;

  for (const [networkName, config] of Object.entries(NETWORKS)) {
    const deployed = loadIgnitionDeployment(config.chainId);
    if (!deployed) continue;

    const addresses = transformAddresses(deployed);
    if (!addresses.registry) continue;

    // Create network export directory
    const networkDir = path.join(__dirname, `../exports/${networkName}`);
    fs.mkdirSync(networkDir, { recursive: true });

    // Write addresses
    const addressesExport = {
      chainId: config.chainId,
      name: config.name,
      contracts: {
        registry: addresses.registry,
        optimisticResolver: addresses.optimisticResolver || "",
        pythResolver: addresses.pythResolver || "",
        truthKeeper: addresses.truthKeeper || "",
        ...(addresses.mockPyth && { mockPyth: addresses.mockPyth }),
      },
    };

    fs.writeFileSync(
      path.join(networkDir, "addresses.json"),
      JSON.stringify(addressesExport, null, 2)
    );

    console.log(`   ✅ ${networkName}: ${addresses.registry.slice(0, 10)}...`);
    networksFound++;
  }

  return networksFound;
}

function exportAbis() {
  console.log("\n📄 Exporting ABIs...\n");

  // Use sepolia as source for ABIs (they're the same across networks)
  const abiSourceDir = path.join(__dirname, "../artifacts/contracts");
  const exportDir = path.join(__dirname, "../exports/sepolia/abis");
  fs.mkdirSync(exportDir, { recursive: true });

  for (const contractName of ABIS_TO_EXPORT) {
    // Find the artifact
    let artifactPath: string | null = null;
    const possiblePaths = [
      path.join(abiSourceDir, `TruthEngine/${contractName}.sol/${contractName}.json`),
      path.join(abiSourceDir, `resolvers/${contractName}.sol/${contractName}.json`),
      path.join(abiSourceDir, `${contractName}.sol/${contractName}.json`),
    ];

    for (const p of possiblePaths) {
      if (fs.existsSync(p)) {
        artifactPath = p;
        break;
      }
    }

    if (!artifactPath) {
      console.log(`   ⚠️  ${contractName}: not found`);
      continue;
    }

    const artifact = JSON.parse(fs.readFileSync(artifactPath, "utf-8"));
    fs.writeFileSync(
      path.join(exportDir, `${contractName}.json`),
      JSON.stringify(artifact.abi, null, 2)
    );
    console.log(`   ✅ ${contractName}`);
  }
}

function generatePythPriceIdsCode(): string {
  // Group by category
  const categories: Record<string, [string, string][]> = {
    "Major Cryptocurrencies": [],
    "L1 & L2 Tokens": [],
    "DeFi Tokens": [],
    "Meme Coins": [],
    "Stablecoins": [],
    "US Equities": [],
    "Forex": [],
    "Precious Metals": [],
  };

  const categoryMap: Record<string, string[]> = {
    "Major Cryptocurrencies": ["BTC/USD", "ETH/USD", "SOL/USD", "XRP/USD", "DOGE/USD", "LTC/USD", "BCH/USD", "ZEC/USD"],
    "L1 & L2 Tokens": ["AVAX/USD", "NEAR/USD", "ATOM/USD", "SUI/USD", "APT/USD", "SEI/USD", "TIA/USD", "INJ/USD", "ARB/USD", "OP/USD"],
    "DeFi Tokens": ["LINK/USD", "UNI/USD", "AAVE/USD", "JUP/USD", "PYTH/USD"],
    "Meme Coins": ["PEPE/USD", "WIF/USD", "BONK/USD", "DEGEN/USD", "WLD/USD", "TOSHI/USD"],
    "Stablecoins": ["USDC/USD", "USDT/USD"],
    "US Equities": ["AAPL/USD", "TSLA/USD", "NVDA/USD", "AMZN/USD", "GOOGL/USD", "MSFT/USD", "META/USD", "AMD/USD", "COIN/USD", "MSTR/USD", "GME/USD", "AMC/USD", "SPY/USD", "QQQ/USD"],
    "Forex": ["EUR/USD", "GBP/USD", "USD/JPY", "AUD/USD", "USD/CAD", "USD/CHF"],
    "Precious Metals": ["XAU/USD", "XAG/USD", "XPT/USD", "XPD/USD"],
  };

  for (const [name, id] of Object.entries(PYTH_PRICE_IDS)) {
    for (const [category, assets] of Object.entries(categoryMap)) {
      if (assets.includes(name)) {
        categories[category].push([name, id]);
        break;
      }
    }
  }

  let output = `/** Common Pyth price feed IDs (same across all networks) */
export const PYTH_PRICE_IDS = {`;

  for (const [category, items] of Object.entries(categories)) {
    if (items.length === 0) continue;
    output += `\n  // ${category}`;
    for (const [name, id] of items) {
      output += `\n  "${name}": "${id}",`;
    }
  }

  output += `\n} as const;

// Reverse lookup: price ID -> asset name
export const PYTH_PRICE_NAMES: Record<string, string> = Object.fromEntries(
  Object.entries(PYTH_PRICE_IDS).map(([name, id]) => [id.toLowerCase(), name])
);`;

  return output;
}

function syncTocTypes() {
  console.log("\n🔄 Syncing toc-types.ts...\n");

  const tocTypesPath = path.join(__dirname, "../exports/toc-types.ts");
  let content = fs.readFileSync(tocTypesPath, "utf-8");

  // Find and replace PYTH_PRICE_IDS section
  const startMarker = "// ============ Pyth Price Feed IDs ============";
  const endMarker = "// ============ Utility Functions ============";

  const startIdx = content.indexOf(startMarker);
  const endIdx = content.indexOf(endMarker);

  if (startIdx === -1 || endIdx === -1) {
    console.log("   ⚠️  Could not find PYTH section markers, skipping sync");
    return;
  }

  const newPythSection = `${startMarker}\n\n${generatePythPriceIdsCode()}\n\n`;
  content = content.slice(0, startIdx) + newPythSection + content.slice(endIdx);

  fs.writeFileSync(tocTypesPath, content);
  console.log(`   ✅ PYTH_PRICE_IDS: ${Object.keys(PYTH_PRICE_IDS).length} price feeds`);
  console.log(`   ✅ PYTH_PRICE_NAMES: reverse lookup added`);
}

async function main() {
  console.log("\n📦 TOC Export All\n");
  console.log("=".repeat(50));

  const networksExported = exportAddresses();
  exportAbis();
  syncTocTypes();

  console.log("\n" + "=".repeat(50));
  console.log("\n✅ Export complete!\n");
  console.log(`   Networks: ${networksExported}`);
  console.log(`   ABIs: ${ABIS_TO_EXPORT.length}`);
  console.log(`   Pyth feeds: ${Object.keys(PYTH_PRICE_IDS).length}`);
  console.log("\n📁 Output: exports/\n");
}

main().catch(console.error);
