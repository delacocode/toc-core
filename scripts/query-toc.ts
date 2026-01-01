/**
 * Query TOC(s) on any supported network
 *
 * Usage: npx hardhat run scripts/query-toc.ts --network <network>
 *        TOC_ID=1 npx hardhat run scripts/query-toc.ts --network <network>
 */

import { decodeAbiParameters, parseAbiParameters } from "viem";
import {
  getNetwork,
  loadDeployedAddresses,
  getChainConfig,
  createClients,
} from "./lib/config.js";
import { getRegistryAbi, getResolverAbi, STATE_NAMES } from "./lib/abis.js";

function formatDuration(seconds: bigint): string {
  const s = Number(seconds);
  if (s < 60) return `${s}s`;
  if (s < 3600) return `${Math.floor(s / 60)}m`;
  if (s < 86400) return `${Math.floor(s / 3600)}h`;
  return `${Math.floor(s / 86400)}d`;
}

async function main() {
  const tocId = process.env.TOC_ID;
  const network = await getNetwork();
  const { chainId } = getChainConfig(network);
  const addresses = loadDeployedAddresses(chainId);
  const { publicClient } = createClients(network);
  const registryAbi = getRegistryAbi();
  const resolverAbi = getResolverAbi();

  console.log(`\n🔍 Querying TOC${tocId ? ` #${tocId}` : "s"} on ${network}\n`);

  const nextId = await publicClient.readContract({
    address: addresses.registry,
    abi: registryAbi,
    functionName: "nextTocId",
  }) as bigint;

  const totalCreated = nextId - 1n;
  console.log(`📊 Total TOCs created: ${totalCreated}\n`);

  if (!tocId) {
    const start = totalCreated > 5n ? totalCreated - 4n : 1n;
    console.log(`📋 Recent TOCs (${start} to ${totalCreated}):\n`);

    for (let i = totalCreated; i >= start && i >= 1n; i--) {
      try {
        const toc = await publicClient.readContract({
          address: addresses.registry,
          abi: registryAbi,
          functionName: "getTOCInfo",
          args: [i],
        }) as any;
        console.log(`   #${i}: ${STATE_NAMES[toc.state] || toc.state} | Resolver: ${toc.resolver.slice(0, 10)}...`);
      } catch {
        // Skip
      }
    }

    console.log(`\n💡 For details: TOC_ID=<id> npx hardhat run scripts/query-toc.ts --network ${network}`);
    return;
  }

  try {
    const toc = await publicClient.readContract({
      address: addresses.registry,
      abi: registryAbi,
      functionName: "getTOCInfo",
      args: [BigInt(tocId)],
    }) as any;

    console.log(`📋 TOC #${tocId} Details:\n`);
    console.log(`   State:         ${STATE_NAMES[toc.state] || toc.state}`);
    console.log(`   Resolver:      ${toc.resolver}`);
    console.log(`   TruthKeeper:   ${toc.truthKeeper}`);
    console.log(`   Resolved:      ${toc.isResolved}`);

    if (toc.resolutionTime > 0n) {
      console.log(`   Resolution at: ${new Date(Number(toc.resolutionTime) * 1000).toISOString()}`);
    }

    console.log(`\n⏱️  Time Windows:`);
    console.log(`   Dispute:       ${formatDuration(toc.disputeWindow)}`);
    console.log(`   TruthKeeper:   ${formatDuration(toc.truthKeeperWindow)}`);
    console.log(`   Escalation:    ${formatDuration(toc.escalationWindow)}`);
    console.log(`   PostResolution: ${formatDuration(toc.postResolutionWindow)}`);

    if (toc.resolver.toLowerCase() === addresses.optimisticResolver.toLowerCase()) {
      try {
        const question = await publicClient.readContract({
          address: addresses.optimisticResolver,
          abi: resolverAbi,
          functionName: "getTocQuestion",
          args: [BigInt(tocId)],
        });
        console.log(`\n❓ Question:\n   ${question}`);
      } catch {
        // Question not available
      }
    }

    if (toc.result && toc.result !== "0x") {
      try {
        const [answer] = decodeAbiParameters(parseAbiParameters("bool"), toc.result);
        console.log(`\n✅ Result: ${answer ? "YES" : "NO"}`);
        if (toc.hasCorrectedResult) {
          console.log(`   (Result was corrected via dispute)`);
        }
      } catch {
        console.log(`\n📦 Result (raw): ${toc.result}`);
      }
    }

    console.log("\n💡 Next action:");
    switch (toc.state) {
      case 3: // ACTIVE
        console.log(`   TOC_ID=${tocId} npx hardhat run scripts/resolve-toc.ts --network ${network}`);
        break;
      case 4: // RESOLVING
        const now = Math.floor(Date.now() / 1000);
        if (now < Number(toc.disputeDeadline)) {
          const remaining = Number(toc.disputeDeadline) - now;
          console.log(`   Wait ${formatDuration(BigInt(remaining))} for dispute window, then:`);
        } else {
          console.log("   Dispute window ended. Run:");
        }
        console.log(`   TOC_ID=${tocId} npx hardhat run scripts/finalize-toc.ts --network ${network}`);
        break;
      case 7: // RESOLVED
        console.log("   TOC is finalized. No further action needed.");
        break;
      default:
        console.log("   Check state and take appropriate action");
    }

  } catch (error: any) {
    console.error("❌ Failed to query TOC:", error.shortMessage || error.message);
  }
}

main().catch(console.error);
