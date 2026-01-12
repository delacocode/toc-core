/**
 * List all TOCs and their states
 * Usage: npx hardhat run scripts/list-tocs.ts --network sepolia
 */

import { decodeAbiParameters, MulticallReturnType } from "viem";
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

  // Build multicall for all TOC info
  const tocIds = Array.from({ length: total }, (_, i) => BigInt(i + 1));

  const tocInfoCalls = tocIds.map(id => ({
    address: addresses.registry as `0x${string}`,
    abi: registryAbi,
    functionName: "getTOCInfo",
    args: [id],
  }));

  // Batch fetch all TOC info
  const tocResults = await publicClient.multicall({
    contracts: tocInfoCalls,
    allowFailure: true,
  });

  // Collect Pyth and Optimistic TOC IDs for second batch
  const pythTocIds: bigint[] = [];
  const optimisticTocIds: bigint[] = [];

  for (let i = 0; i < tocResults.length; i++) {
    const result = tocResults[i];
    if (result.status === "success") {
      const toc = result.result as any;
      if (toc.resolver.toLowerCase() === addresses.pythResolver.toLowerCase()) {
        pythTocIds.push(tocIds[i]);
      } else if (toc.resolver.toLowerCase() === addresses.optimisticResolver.toLowerCase()) {
        optimisticTocIds.push(tocIds[i]);
      }
    }
  }

  // Batch fetch Pyth details
  const pythDetailsCalls = pythTocIds.map(id => ({
    address: addresses.pythResolver as `0x${string}`,
    abi: pythAbi,
    functionName: "getTocDetails",
    args: [id],
  }));

  // Batch fetch Optimistic questions
  const optimisticQuestionCalls = optimisticTocIds.map(id => ({
    address: addresses.optimisticResolver as `0x${string}`,
    abi: optimisticAbi,
    functionName: "getTocQuestion",
    args: [id],
  }));

  const [pythResults, optimisticResults] = await Promise.all([
    pythDetailsCalls.length > 0
      ? publicClient.multicall({ contracts: pythDetailsCalls, allowFailure: true })
      : Promise.resolve([]),
    optimisticQuestionCalls.length > 0
      ? publicClient.multicall({ contracts: optimisticQuestionCalls, allowFailure: true })
      : Promise.resolve([]),
  ]);

  // Build lookup maps
  const pythDetailsMap = new Map<string, any>();
  pythTocIds.forEach((id, i) => {
    const result = pythResults[i];
    if (result?.status === "success") {
      pythDetailsMap.set(id.toString(), result.result);
    }
  });

  const optimisticQuestionsMap = new Map<string, string>();
  optimisticTocIds.forEach((id, i) => {
    const result = optimisticResults[i];
    if (result?.status === "success") {
      optimisticQuestionsMap.set(id.toString(), result.result as string);
    }
  });

  // Fetch optimistic deadlines for sorting
  const optimisticDeadlineCalls = optimisticTocIds.map(id => ({
    address: addresses.optimisticResolver as `0x${string}`,
    abi: optimisticAbi,
    functionName: "getTocDeadline",
    args: [id],
  }));

  const optimisticDeadlineResults = optimisticDeadlineCalls.length > 0
    ? await publicClient.multicall({ contracts: optimisticDeadlineCalls, allowFailure: true })
    : [];

  const optimisticDeadlinesMap = new Map<string, number>();
  optimisticTocIds.forEach((id, i) => {
    const result = optimisticDeadlineResults[i];
    if (result?.status === "success") {
      optimisticDeadlinesMap.set(id.toString(), Number(result.result as bigint));
    }
  });

  // Build display data with deadlines for sorting
  interface TocDisplay {
    id: bigint;
    state: number;
    stateName: string;
    marker: string;
    question: string;
    deadline: number;
    isOpen: boolean;
  }

  const tocDisplays: TocDisplay[] = [];

  for (let i = 0; i < tocResults.length; i++) {
    const tocId = tocIds[i];
    const result = tocResults[i];

    if (result.status !== "success") {
      console.log(`❌ #${tocId} ERROR: ${(result.error as any)?.shortMessage || "Failed to fetch"}`);
      continue;
    }

    const toc = result.result as any;
    const stateName = STATE_NAMES[toc.state] || `UNKNOWN(${toc.state})`;
    const isOpen = toc.state === 3 || toc.state === 4;

    const marker = isOpen ? "🟢" : toc.state === 7 ? "✅" : toc.state === 8 ? "❌" : "⚪";
    const isPyth = toc.resolver.toLowerCase() === addresses.pythResolver.toLowerCase();
    const isOptimistic = toc.resolver.toLowerCase() === addresses.optimisticResolver.toLowerCase();

    let question = "";
    let deadline = 0;

    if (isPyth) {
      const details = pythDetailsMap.get(tocId.toString());
      if (details) {
        try {
          const [templateId, creationPayload] = details as [number, `0x${string}`];

          if (templateId === 0) { // SNAPSHOT
            const decoded = decodeAbiParameters(
              [
                { name: "priceId", type: "bytes32" },
                { name: "threshold", type: "int64" },
                { name: "isAbove", type: "bool" },
                { name: "deadline", type: "uint256" },
              ],
              creationPayload
            );
            const asset = PYTH_PRICE_IDS[decoded[0].toLowerCase()] || "Unknown";
            const price = formatPythPrice(decoded[1]);
            const direction = decoded[2] ? "above" : "below";
            deadline = Number(decoded[3]);
            question = `${asset} ${direction} ${price} by ${formatTime(deadline)}`;
          } else if (templateId === 1) { // RANGE
            const decoded = decodeAbiParameters(
              [
                { name: "priceId", type: "bytes32" },
                { name: "lowerBound", type: "int64" },
                { name: "upperBound", type: "int64" },
                { name: "deadline", type: "uint256" },
              ],
              creationPayload
            );
            const asset = PYTH_PRICE_IDS[decoded[0].toLowerCase()] || "Unknown";
            deadline = Number(decoded[3]);
            question = `${asset} between ${formatPythPrice(decoded[1])}-${formatPythPrice(decoded[2])} by ${formatTime(deadline)}`;
          } else { // REACHED_BY
            const decoded = decodeAbiParameters(
              [
                { name: "priceId", type: "bytes32" },
                { name: "targetPrice", type: "int64" },
                { name: "isAbove", type: "bool" },
                { name: "deadline", type: "uint256" },
              ],
              creationPayload
            );
            const asset = PYTH_PRICE_IDS[decoded[0].toLowerCase()] || "Unknown";
            const price = formatPythPrice(decoded[1]);
            const direction = decoded[2] ? "above" : "below";
            deadline = Number(decoded[3]);
            question = `${asset} reaches ${direction} ${price} by ${formatTime(deadline)}`;
          }
        } catch {
          question = "Pyth TOC";
        }
      } else {
        question = "Pyth TOC";
      }
    } else if (isOptimistic) {
      const rawQuestion = optimisticQuestionsMap.get(tocId.toString());
      deadline = optimisticDeadlinesMap.get(tocId.toString()) || 0;
      if (rawQuestion) {
        const match = rawQuestion.match(/Q:\s*(.+?)(?:\n|$)/);
        question = match ? match[1].slice(0, 50) + (match[1].length > 50 ? "..." : "") : "Optimistic TOC";
      } else {
        question = "Optimistic TOC";
      }
    } else {
      question = `Resolver: ${toc.resolver.slice(0, 10)}...`;
    }

    tocDisplays.push({ id: tocId, state: toc.state, stateName, marker, question, deadline, isOpen });
  }

  // Sort: active TOCs by deadline (soonest first), then resolved/other by ID
  const activeTocs = tocDisplays.filter(t => t.isOpen).sort((a, b) => a.deadline - b.deadline);
  const otherTocs = tocDisplays.filter(t => !t.isOpen);

  // Display active TOCs first (sorted by deadline)
  const now = Math.floor(Date.now() / 1000);

  for (const t of activeTocs) {
    const ready = t.deadline > 0 && t.deadline <= now ? " 🔔 READY" : "";
    console.log(`${t.marker} #${t.id} [${t.stateName}]${ready} ${t.question}`);
  }

  // Then other TOCs
  for (const t of otherTocs) {
    console.log(`${t.marker} #${t.id} [${t.stateName}] ${t.question}`);
  }

  console.log(`\n🟢 Open TOCs (ACTIVE/RESOLVING): ${activeTocs.length}`);

  const readyToResolve = activeTocs.filter(t => t.deadline > 0 && t.deadline <= now);
  if (readyToResolve.length > 0) {
    console.log(`🔔 Ready to resolve: ${readyToResolve.map(t => `#${t.id}`).join(", ")}`);
  }

  console.log(`\n💡 Details: TOC_ID=<id> npx hardhat run scripts/query-toc.ts --network ${network}`);
}

main().catch(console.error);
