/**
 * Resolve a Pyth TOC using price data from Hermes API
 *
 * Usage: TOC_ID=3 npx hardhat run scripts/resolve-pyth-toc.ts --network <network>
 *
 * This script:
 * 1. Fetches the TOC details to get the price feed ID and deadline
 * 2. Fetches price update data from Pyth Hermes API
 * 3. Submits the resolution to the registry
 */

import { encodeAbiParameters, parseAbiParameters } from "viem";
import {
  getNetwork,
  loadConfig,
  loadDeployedAddresses,
  getChainConfig,
  createClients,
  getExplorerTxUrl,
} from "./lib/config.js";
import { getRegistryAbi, getPythResolverAbi, STATE_NAMES, ETH_ADDRESS } from "./lib/abis.js";
import { PYTH_TEMPLATE, pythPriceToUsd } from "./lib/payloads.js";

// Hermes API endpoints
const HERMES_API = "https://hermes.pyth.network";

interface PythVaaResponse {
  binary: {
    data: string[];
  };
}

async function fetchPythUpdateData(priceId: string, publishTime?: number): Promise<string[]> {
  // Remove 0x prefix if present
  const cleanPriceId = priceId.startsWith("0x") ? priceId.slice(2) : priceId;

  let url: string;
  if (publishTime) {
    // Get VAA for specific timestamp
    url = `${HERMES_API}/v2/updates/price/${publishTime}?ids[]=${cleanPriceId}&encoding=base64`;
  } else {
    // Get latest VAA
    url = `${HERMES_API}/v2/updates/price/latest?ids[]=${cleanPriceId}&encoding=base64`;
  }

  console.log(`   Fetching from: ${url.replace(cleanPriceId, cleanPriceId.slice(0, 8) + "...")}`);

  const response = await fetch(url);
  if (!response.ok) {
    throw new Error(`Hermes API error: ${response.status} ${response.statusText}`);
  }

  const data = await response.json() as PythVaaResponse;

  if (!data.binary?.data || data.binary.data.length === 0) {
    throw new Error("No price update data returned from Hermes");
  }

  return data.binary.data;
}

function base64ToHex(base64: string): `0x${string}` {
  const binary = Buffer.from(base64, "base64");
  return `0x${binary.toString("hex")}` as `0x${string}`;
}

async function main() {
  const tocId = process.env.TOC_ID;
  if (!tocId) {
    console.error("Usage: TOC_ID=<id> npx hardhat run scripts/resolve-pyth-toc.ts --network <network>");
    process.exit(1);
  }

  const network = await getNetwork();
  const { chainId } = getChainConfig(network);
  const config = loadConfig(network);
  const addresses = loadDeployedAddresses(chainId);
  const { publicClient, walletClient, account } = createClients(network);
  const registryAbi = getRegistryAbi();
  const pythResolverAbi = getPythResolverAbi();

  console.log(`\n🔮 Resolving Pyth TOC #${tocId} on ${network}\n`);
  console.log(`🔑 Account: ${account.address}\n`);

  // Get TOC info
  console.log("📋 Fetching TOC details...");
  let toc: any;
  try {
    toc = await publicClient.readContract({
      address: addresses.registry,
      abi: registryAbi,
      functionName: "getTOCInfo",
      args: [BigInt(tocId)],
    });
  } catch (error: any) {
    console.error("Failed to get TOC:", error.shortMessage || error.message);
    process.exit(1);
  }

  console.log(`   State: ${STATE_NAMES[toc.state] || toc.state}`);
  console.log(`   Resolver: ${toc.resolver}`);

  // Verify it's a Pyth resolver TOC
  if (toc.resolver.toLowerCase() !== addresses.pythResolver.toLowerCase()) {
    console.error("\n❌ This TOC does not use PythPriceResolver");
    console.error("   Use scripts/resolve-toc.ts for OptimisticResolver TOCs");
    process.exit(1);
  }

  // Check state
  if (toc.state !== 3) { // Not ACTIVE
    console.error(`\n❌ TOC is not in ACTIVE state (current: ${STATE_NAMES[toc.state]})`);
    process.exit(1);
  }

  // Get TOC details from resolver
  console.log("\n📊 Fetching Pyth TOC parameters...");
  const [templateId, payload] = await publicClient.readContract({
    address: addresses.pythResolver,
    abi: pythResolverAbi,
    functionName: "getTocDetails",
    args: [BigInt(tocId)],
  }) as [number, `0x${string}`];

  console.log(`   Template: ${templateId === 0 ? "SNAPSHOT" : templateId === 1 ? "RANGE" : "REACHED_BY"}`);

  // Get template-specific data
  let priceId: string;
  let deadline: bigint;
  let threshold: bigint | undefined;
  let isAbove: boolean | undefined;

  if (templateId === PYTH_TEMPLATE.SNAPSHOT) {
    const data = await publicClient.readContract({
      address: addresses.pythResolver,
      abi: pythResolverAbi,
      functionName: "getSnapshotData",
      args: [BigInt(tocId)],
    }) as any;
    priceId = data.priceId;
    deadline = data.deadline;
    threshold = data.threshold;
    isAbove = data.isAbove;
    console.log(`   Price ID: ${priceId.slice(0, 10)}...${priceId.slice(-8)}`);
    console.log(`   Threshold: $${pythPriceToUsd(threshold).toLocaleString()}`);
    console.log(`   Direction: ${isAbove ? "above" : "below"}`);
    console.log(`   Deadline: ${new Date(Number(deadline) * 1000).toLocaleString()}`);
  } else if (templateId === PYTH_TEMPLATE.RANGE) {
    const data = await publicClient.readContract({
      address: addresses.pythResolver,
      abi: pythResolverAbi,
      functionName: "getRangeData",
      args: [BigInt(tocId)],
    }) as any;
    priceId = data.priceId;
    deadline = data.deadline;
    console.log(`   Price ID: ${priceId.slice(0, 10)}...${priceId.slice(-8)}`);
    console.log(`   Range: $${pythPriceToUsd(data.lowerBound).toLocaleString()} - $${pythPriceToUsd(data.upperBound).toLocaleString()}`);
    console.log(`   Deadline: ${new Date(Number(deadline) * 1000).toLocaleString()}`);
  } else {
    const data = await publicClient.readContract({
      address: addresses.pythResolver,
      abi: pythResolverAbi,
      functionName: "getReachedByData",
      args: [BigInt(tocId)],
    }) as any;
    priceId = data.priceId;
    deadline = data.deadline;
    threshold = data.targetPrice;
    isAbove = data.isAbove;
    console.log(`   Price ID: ${priceId.slice(0, 10)}...${priceId.slice(-8)}`);
    console.log(`   Target: $${pythPriceToUsd(threshold).toLocaleString()} (${isAbove ? "above" : "below"})`);
    console.log(`   Deadline: ${new Date(Number(deadline) * 1000).toLocaleString()}`);
  }

  // Check deadline
  const now = Math.floor(Date.now() / 1000);
  if (templateId !== PYTH_TEMPLATE.REACHED_BY && now < Number(deadline)) {
    const remaining = Number(deadline) - now;
    console.error(`\n❌ Deadline not yet reached`);
    console.error(`   Time remaining: ${Math.ceil(remaining / 60)} minutes`);
    process.exit(1);
  }

  // Fetch Pyth price update data at the deadline timestamp
  console.log("\n📡 Fetching Pyth price data from Hermes...");
  const targetTimestamp = Number(deadline);
  console.log(`   Target timestamp: ${new Date(targetTimestamp * 1000).toLocaleString()}`);

  let updateDataBase64: string[];
  try {
    // Fetch price at the deadline timestamp (resolver requires price within 5 seconds of deadline)
    updateDataBase64 = await fetchPythUpdateData(priceId, targetTimestamp);
    console.log(`   Received ${updateDataBase64.length} price update(s)`);
  } catch (error: any) {
    console.error("Failed to fetch Pyth data:", error.message);
    process.exit(1);
  }

  // Convert base64 to hex bytes
  const updateDataHex = updateDataBase64.map(base64ToHex);

  // Encode as bytes[] for the resolver
  const encodedUpdateData = encodeAbiParameters(
    parseAbiParameters("bytes[]"),
    [updateDataHex]
  );

  // Get Pyth fee (for updating price feeds)
  const pythAddress = config.pyth.address as `0x${string}`;
  const pythAbi = [
    {
      name: "getUpdateFee",
      type: "function",
      inputs: [{ name: "updateData", type: "bytes[]" }],
      outputs: [{ name: "feeAmount", type: "uint256" }],
      stateMutability: "view",
    },
  ] as const;

  const pythFee = await publicClient.readContract({
    address: pythAddress,
    abi: pythAbi,
    functionName: "getUpdateFee",
    args: [updateDataHex],
  });

  console.log(`   Pyth update fee: ${Number(pythFee) / 1e18} ETH`);

  // Resolution bond (even for Pyth, registry might require minimal bond)
  const resolutionBond = BigInt(config.registry.bonds.resolution.minAmount);
  const totalValue = resolutionBond + pythFee;

  // Check resolver's ETH balance for Pyth fees
  const resolverBalance = await publicClient.getBalance({ address: addresses.pythResolver });
  console.log(`   Resolver ETH balance: ${Number(resolverBalance) / 1e18} ETH`);

  // Fund resolver if needed (resolver needs ETH to pay Pyth)
  if (resolverBalance < pythFee) {
    const fundAmount = pythFee * 10n; // Fund with 10x the fee for future uses
    console.log(`\n💰 Funding PythPriceResolver with ${Number(fundAmount) / 1e18} ETH...`);

    const fundHash = await walletClient.sendTransaction({
      to: addresses.pythResolver,
      value: fundAmount,
    });
    await publicClient.waitForTransactionReceipt({ hash: fundHash });
    console.log(`   Funded! Tx: ${fundHash.slice(0, 10)}...`);
  }

  console.log("\n📋 Resolution Details:");
  console.log(`   Resolution bond: ${Number(resolutionBond) / 1e18} ETH`);
  console.log(`   Pyth fee: ${Number(pythFee) / 1e18} ETH`);

  try {
    console.log("\n⏳ Sending resolution transaction...");

    const hash = await walletClient.writeContract({
      address: addresses.registry,
      abi: registryAbi,
      functionName: "resolveTOC",
      args: [BigInt(tocId), ETH_ADDRESS, resolutionBond, encodedUpdateData],
      value: resolutionBond, // Only bond, Pyth fee comes from resolver balance
    });

    console.log(`   Tx hash: ${hash}`);
    console.log("⏳ Waiting for confirmation...");

    const receipt = await publicClient.waitForTransactionReceipt({ hash });
    console.log(`   Block: ${receipt.blockNumber}`);

    // Get updated TOC info
    const updatedToc = await publicClient.readContract({
      address: addresses.registry,
      abi: registryAbi,
      functionName: "getTOCInfo",
      args: [BigInt(tocId)],
    }) as any;

    console.log("\n✅ Pyth TOC Resolved!");
    console.log(`   New state: ${STATE_NAMES[updatedToc.state]}`);
    console.log(`   Transaction: ${getExplorerTxUrl(network, hash)}`);

    // Try to decode result
    if (updatedToc.result && updatedToc.result !== "0x") {
      try {
        const [answer] = await publicClient.readContract({
          address: addresses.pythResolver,
          abi: pythResolverAbi,
          functionName: "getTocDetails",
          args: [BigInt(tocId)],
        }) as any;
        // The result is already a boolean encoded
        const resultBool = updatedToc.result === "0x0000000000000000000000000000000000000000000000000000000000000001";
        console.log(`   Result: ${resultBool ? "YES ✅" : "NO ❌"}`);
      } catch {
        console.log(`   Result (raw): ${updatedToc.result}`);
      }
    }

    console.log(`\n💡 Query: TOC_ID=${tocId} npx hardhat run scripts/query-toc.ts --network ${network}`);

  } catch (error: any) {
    console.error("\n❌ Failed to resolve TOC:");
    console.error(error.shortMessage || error.message);
    if (error.cause?.reason) {
      console.error("Reason:", error.cause.reason);
    }
    if (error.cause?.data) {
      console.error("Data:", error.cause.data);
    }
  }
}

main().catch(console.error);
