/**
 * List all TOCs and their states
 * Usage: npx hardhat run scripts/list-tocs.ts --network sepolia
 */

import { decodeAbiParameters } from "viem";
import {
  getNetwork,
  loadDeployedAddresses,
  getChainConfig,
  createClients,
} from "./lib/config.js";
import { getRegistryAbi, getPythResolverAbi, getResolverAbi, STATE_NAMES } from "./lib/abis.js";

// Pyth price feed ID to asset name mapping
const PYTH_PRICE_IDS: Record<string, string> = {
  "0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43": "BTC/USD",
  "0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace": "ETH/USD",
  "0xef0d8b6fda2ceba41da15d4095d1da392a0d2f8ed0c6c7bc0f4cfac8c280b56d": "SOL/USD",
  "0xeaa020c61cc479712813461ce153894a96a6c00b21ed0cfc2798d1f9a9e9c94a": "USDC/USD",
  "0x2b89b9dc8fdf9f34709a5b106b472f0f39bb6ca9ce04b0fd7f2e971688e2e53b": "USDT/USD",
};

function formatPythPrice(rawPrice: bigint): string {
  const price = Number(rawPrice) / 1e8;
  return price.toLocaleString("en-US", { style: "currency", currency: "USD", maximumFractionDigits: 0 });
}

function formatTime(timestamp: number): string {
  return new Date(timestamp * 1000).toLocaleDateString("en-US", {
    month: "short",
    day: "numeric",
    hour: "numeric",
    minute: "2-digit",
  });
}

async function main() {
  const network = await getNetwork();
  const { chainId } = getChainConfig(network);
  const addresses = loadDeployedAddresses(chainId);
  const { publicClient } = createClients(network);
  const registryAbi = getRegistryAbi();
  const pythAbi = getPythResolverAbi();
  const optimisticAbi = getResolverAbi();

  const nextId = await publicClient.readContract({
    address: addresses.registry,
    abi: registryAbi,
    functionName: "nextTocId",
  }) as bigint;

  const total = Number(nextId) - 1;
  console.log(`\n📊 TOCs on ${network}: ${total}\n`);

  if (total === 0) {
    console.log("   No TOCs created yet.\n");
    return;
  }

  let openCount = 0;

  for (let i = 1n; i < nextId; i++) {
    try {
      const toc = await publicClient.readContract({
        address: addresses.registry,
        abi: registryAbi,
        functionName: "getTOCInfo",
        args: [i],
      }) as any;

      const stateName = STATE_NAMES[toc.state] || `UNKNOWN(${toc.state})`;
      const isOpen = toc.state === 3 || toc.state === 4;
      if (isOpen) openCount++;

      const marker = isOpen ? "🟢" : toc.state === 7 ? "✅" : toc.state === 8 ? "❌" : "⚪";
      const isPyth = toc.resolver.toLowerCase() === addresses.pythResolver.toLowerCase();
      const isOptimistic = toc.resolver.toLowerCase() === addresses.optimisticResolver.toLowerCase();

      let question = "";
      let asset = "";

      if (isPyth) {
        try {
          // Get TOC details to extract asset
          const [, creationPayload] = await publicClient.readContract({
            address: addresses.pythResolver,
            abi: pythAbi,
            functionName: "getTocDetails",
            args: [i],
          }) as [number, `0x${string}`];

          const decoded = decodeAbiParameters(
            [
              { name: "priceId", type: "bytes32" },
              { name: "threshold", type: "int64" },
              { name: "isAbove", type: "bool" },
              { name: "deadline", type: "uint256" },
            ],
            creationPayload
          );

          asset = PYTH_PRICE_IDS[decoded[0].toLowerCase()] || "Unknown";
          const price = formatPythPrice(decoded[1]);
          const direction = decoded[2] ? "above" : "below";
          const deadline = formatTime(Number(decoded[3]));
          question = `${asset} ${direction} ${price} by ${deadline}`;
        } catch {
          question = "Pyth TOC";
        }
      } else if (isOptimistic) {
        try {
          const rawQuestion = await publicClient.readContract({
            address: addresses.optimisticResolver,
            abi: optimisticAbi,
            functionName: "getTocQuestion",
            args: [i],
          }) as string;
          // Extract just the question part
          const match = rawQuestion.match(/Q:\s*(.+?)(?:\n|$)/);
          question = match ? match[1].slice(0, 50) + (match[1].length > 50 ? "..." : "") : "Optimistic TOC";
        } catch {
          question = "Optimistic TOC";
        }
      } else {
        question = `Resolver: ${toc.resolver.slice(0, 10)}...`;
      }

      console.log(`${marker} #${i} [${stateName}] ${question}`);
    } catch (e: any) {
      console.log(`❌ #${i} ERROR: ${e.shortMessage || e.message}`);
    }
  }

  console.log(`\n🟢 Open TOCs (ACTIVE/RESOLVING): ${openCount}`);
  console.log(`\n💡 Details: TOC_ID=<id> npx hardhat run scripts/query-toc.ts --network ${network}`);
}

main().catch(console.error);
