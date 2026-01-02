/**
 * Export deployed addresses to a consumer-friendly JSON format
 *
 * Usage:
 *   npx hardhat run scripts/export-addresses.ts
 *
 * Output: exports/toc-addresses.json
 *
 * The exported file can be consumed by other projects (e.g., coco prediction market)
 */

import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

// Network configurations
const NETWORKS: Record<string, { chainId: number; name: string }> = {
  sepolia: { chainId: 11155111, name: "Sepolia Testnet" },
  base: { chainId: 8453, name: "Base" },
  bsc: { chainId: 56, name: "BNB Smart Chain" },
  arbitrum: { chainId: 42161, name: "Arbitrum One" },
  polygon: { chainId: 137, name: "Polygon" },
  localhost: { chainId: 31337, name: "Localhost" },
};

// Contract name mappings (Ignition format -> export format)
const CONTRACT_MAPPINGS: Record<string, string> = {
  "TOCRegistry#TOCRegistry": "registry",
  "OptimisticResolver#OptimisticResolver": "optimisticResolver",
  "PythPriceResolver#PythPriceResolver": "pythResolver",
  "SimpleTruthKeeper#SimpleTruthKeeper": "truthKeeper",
  "MockPythOracle#MockPythOracle": "mockPyth",
};

interface NetworkAddresses {
  chainId: number;
  name: string;
  registry: string;
  optimisticResolver: string;
  pythResolver: string;
  truthKeeper: string;
  mockPyth?: string;
}

interface ExportedAddresses {
  version: string;
  exportedAt: string;
  networks: Record<string, NetworkAddresses>;
}

function loadIgnitionDeployment(chainId: number): Record<string, string> | null {
  const deployedPath = path.join(
    __dirname,
    `../ignition/deployments/chain-${chainId}/deployed_addresses.json`
  );

  if (!fs.existsSync(deployedPath)) {
    return null;
  }

  return JSON.parse(fs.readFileSync(deployedPath, "utf-8"));
}

function transformAddresses(deployed: Record<string, string>): Record<string, string> {
  const result: Record<string, string> = {};

  for (const [ignitionName, address] of Object.entries(deployed)) {
    const exportName = CONTRACT_MAPPINGS[ignitionName];
    if (exportName) {
      result[exportName] = address;
    }
  }

  return result;
}

async function main() {
  console.log("\n📦 Exporting TOC deployed addresses\n");

  const exported: ExportedAddresses = {
    version: "1.0.0",
    exportedAt: new Date().toISOString(),
    networks: {},
  };

  let networksFound = 0;

  for (const [networkName, config] of Object.entries(NETWORKS)) {
    const deployed = loadIgnitionDeployment(config.chainId);

    if (deployed) {
      const addresses = transformAddresses(deployed);

      // Only include if we have the core contracts
      if (addresses.registry) {
        exported.networks[networkName] = {
          chainId: config.chainId,
          name: config.name,
          registry: addresses.registry,
          optimisticResolver: addresses.optimisticResolver || "",
          pythResolver: addresses.pythResolver || "",
          truthKeeper: addresses.truthKeeper || "",
          ...(addresses.mockPyth && { mockPyth: addresses.mockPyth }),
        };

        console.log(`✅ ${networkName} (chain ${config.chainId})`);
        console.log(`   Registry: ${addresses.registry}`);
        if (addresses.optimisticResolver) console.log(`   OptimisticResolver: ${addresses.optimisticResolver}`);
        if (addresses.pythResolver) console.log(`   PythResolver: ${addresses.pythResolver}`);
        if (addresses.truthKeeper) console.log(`   TruthKeeper: ${addresses.truthKeeper}`);
        console.log();
        networksFound++;
      }
    }
  }

  if (networksFound === 0) {
    console.error("❌ No deployments found");
    process.exit(1);
  }

  // Create exports directory
  const exportsDir = path.join(__dirname, "../exports");
  if (!fs.existsSync(exportsDir)) {
    fs.mkdirSync(exportsDir, { recursive: true });
  }

  // Write the export file
  const exportPath = path.join(exportsDir, "toc-addresses.json");
  fs.writeFileSync(exportPath, JSON.stringify(exported, null, 2));

  console.log(`📄 Exported to: ${exportPath}`);
  console.log(`   Networks: ${networksFound}`);
  console.log(`\n💡 Copy this file to your consumer project (e.g., coco)`);
}

main().catch(console.error);
