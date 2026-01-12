/**
 * Admin resolves an escalated dispute (Round 2)
 * Usage: TOC_ID=4 RESOLUTION=uphold ANSWER=true npx hardhat run scripts/admin-resolve.ts --network base
 *
 * RESOLUTION options:
 *   uphold  - Disputer was right, correct the result
 *   reject  - Original result stands, disputer loses bond
 *   cancel  - Cancel the TOC, refund all
 */

import { encodeAbiParameters, parseAbiParameters } from "viem";
import {
  getNetwork,
  loadDeployedAddresses,
  getChainConfig,
  createClients,
  getExplorerTxUrl,
} from "./lib/config.js";
import { getRegistryAbi, STATE_NAMES } from "./lib/abis.js";

// DisputeResolution enum
const RESOLUTION = {
  UPHOLD_DISPUTE: 0,
  REJECT_DISPUTE: 1,
  CANCEL_TOC: 2,
  TOO_EARLY: 3,
} as const;

async function main() {
  const tocId = process.env.TOC_ID;
  const resolutionStr = process.env.RESOLUTION?.toLowerCase();
  const answer = process.env.ANSWER;

  if (!tocId || !resolutionStr) {
    console.error("Usage: TOC_ID=<id> RESOLUTION=<uphold|reject|cancel> [ANSWER=true|false] npx hardhat run scripts/admin-resolve.ts --network <network>");
    process.exit(1);
  }

  let resolution: number;
  switch (resolutionStr) {
    case "uphold":
      resolution = RESOLUTION.UPHOLD_DISPUTE;
      break;
    case "reject":
      resolution = RESOLUTION.REJECT_DISPUTE;
      break;
    case "cancel":
      resolution = RESOLUTION.CANCEL_TOC;
      break;
    case "tooearly":
      resolution = RESOLUTION.TOO_EARLY;
      break;
    default:
      console.error("Invalid RESOLUTION. Use: uphold, reject, cancel, or tooearly");
      process.exit(1);
  }

  const network = await getNetwork();
  const { chainId } = getChainConfig(network);
  const addresses = loadDeployedAddresses(chainId);
  const { publicClient, walletClient, account } = createClients(network);
  const registryAbi = getRegistryAbi();

  console.log(`\n⚖️  Admin Resolving TOC #${tocId} on ${network}\n`);
  console.log(`🔑 Account: ${account.address}\n`);

  // Check state
  const toc = await publicClient.readContract({
    address: addresses.registry,
    abi: registryAbi,
    functionName: "getTOCInfo",
    args: [BigInt(tocId)],
  }) as any;

  console.log(`   Current state: ${STATE_NAMES[toc.state]}`);

  if (toc.state !== 6) { // DISPUTED_ROUND_2
    console.error(`\n❌ TOC is not in DISPUTED_ROUND_2 state`);
    process.exit(1);
  }

  // Encode corrected result if provided
  let correctedResult = "0x" as `0x${string}`;
  if (answer !== undefined) {
    const boolAnswer = answer.toLowerCase() === "true";
    correctedResult = encodeAbiParameters(parseAbiParameters("bool"), [boolAnswer]);
  }

  const resolutionNames = ["UPHOLD_DISPUTE", "REJECT_DISPUTE", "CANCEL_TOC", "TOO_EARLY"];
  console.log(`\n📋 Resolution Details:`);
  console.log(`   Decision: ${resolutionNames[resolution]}`);
  if (answer !== undefined) {
    console.log(`   Corrected Answer: ${answer.toUpperCase()}`);
  }

  try {
    console.log("\n⏳ Sending admin resolution...");

    const hash = await walletClient.writeContract({
      address: addresses.registry,
      abi: registryAbi,
      functionName: "resolveEscalation",
      args: [BigInt(tocId), resolution, correctedResult],
    });

    console.log(`   Tx hash: ${hash}`);
    await publicClient.waitForTransactionReceipt({ hash });

    const updatedToc = await publicClient.readContract({
      address: addresses.registry,
      abi: registryAbi,
      functionName: "getTOCInfo",
      args: [BigInt(tocId)],
    }) as any;

    console.log("\n✅ Admin Resolution Applied!");
    console.log(`   New state: ${STATE_NAMES[updatedToc.state]}`);
    console.log(`   Transaction: ${getExplorerTxUrl(network, hash)}`);

  } catch (error: any) {
    console.error("\n❌ Failed:", error.shortMessage || error.message);
  }
}

main().catch(console.error);
