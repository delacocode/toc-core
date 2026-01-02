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

// Format duration in human readable form
function formatDuration(seconds: number): string {
  if (seconds <= 0) return "0s";
  if (seconds < 60) return `${seconds}s`;
  if (seconds < 3600) return `${Math.floor(seconds / 60)}m ${seconds % 60}s`;
  if (seconds < 86400) {
    const h = Math.floor(seconds / 3600);
    const m = Math.floor((seconds % 3600) / 60);
    return `${h}h ${m}m`;
  }
  const d = Math.floor(seconds / 86400);
  const h = Math.floor((seconds % 86400) / 3600);
  return `${d}d ${h}h`;
}

// Format timestamp to local time
function formatTime(timestamp: number): string {
  return new Date(timestamp * 1000).toLocaleString();
}

// Get status indicator
function getStatusIndicator(isPast: boolean, isActive: boolean): string {
  if (isPast) return "✅";
  if (isActive) return "⏳";
  return "⏸️";
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
    if (totalCreated === 0n) {
      console.log("   No TOCs created yet.\n");
      console.log(`💡 Create one: QUESTION="Your question?" npx hardhat run scripts/create-toc.ts --network ${network}`);
      return;
    }

    const start = totalCreated > 5n ? totalCreated - 4n : 1n;
    console.log(`📋 Recent TOCs:\n`);

    for (let i = totalCreated; i >= start && i >= 1n; i--) {
      try {
        const toc = await publicClient.readContract({
          address: addresses.registry,
          abi: registryAbi,
          functionName: "getTOCInfo",
          args: [i],
        }) as any;

        const stateIcon = toc.state === 7 ? "✅" : toc.state === 4 ? "⏳" : toc.state === 3 ? "🟢" : "⚪";
        console.log(`   ${stateIcon} #${i}: ${STATE_NAMES[toc.state]} | ${toc.resolver.slice(0, 10)}...`);
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

    const now = Math.floor(Date.now() / 1000);

    // Header with state
    const stateEmoji = {
      0: "⚫", // NONE
      1: "🟡", // PENDING
      2: "🔴", // REJECTED
      3: "🟢", // ACTIVE
      4: "⏳", // RESOLVING
      5: "⚠️", // DISPUTED_ROUND_1
      6: "🚨", // DISPUTED_ROUND_2
      7: "✅", // RESOLVED
      8: "❌", // CANCELLED
    }[toc.state] || "❓";

    console.log(`═══════════════════════════════════════════════════════════`);
    console.log(`  TOC #${tocId}  ${stateEmoji} ${STATE_NAMES[toc.state]}`);
    console.log(`═══════════════════════════════════════════════════════════\n`);

    // Question (if OptimisticResolver)
    if (toc.resolver.toLowerCase() === addresses.optimisticResolver.toLowerCase()) {
      try {
        const question = await publicClient.readContract({
          address: addresses.optimisticResolver,
          abi: resolverAbi,
          functionName: "getTocQuestion",
          args: [BigInt(tocId)],
        }) as string;

        // Parse and display nicely
        const lines = question.split("\n").filter(l => l.trim());
        for (const line of lines) {
          if (line.startsWith("Q:")) {
            console.log(`❓ ${line.substring(2).trim()}`);
          } else if (line.startsWith("Description:")) {
            console.log(`📝 ${line.substring(12).trim()}`);
          } else if (line.startsWith("Resolution Source:") && line.substring(18).trim()) {
            console.log(`🔗 ${line.substring(18).trim()}`);
          } else if (line.startsWith("Resolution Time:")) {
            const ts = line.match(/timestamp:(\d+)/);
            if (ts) {
              console.log(`📅 Resolves after: ${formatTime(Number(ts[1]))}`);
            }
          }
        }
        console.log();
      } catch {
        // Question not available
      }
    }

    // Result (if resolved)
    if (toc.result && toc.result !== "0x") {
      try {
        const [answer] = decodeAbiParameters(parseAbiParameters("bool"), toc.result);
        console.log(`┌─────────────────────────────────────────────────────────┐`);
        console.log(`│  RESULT: ${answer ? "YES ✅" : "NO ❌"}${toc.hasCorrectedResult ? " (corrected via dispute)" : ""}`.padEnd(59) + "│");
        console.log(`└─────────────────────────────────────────────────────────┘\n`);
      } catch {
        console.log(`📦 Result (raw): ${toc.result}\n`);
      }
    }

    // Addresses
    console.log(`📍 Addresses:`);
    console.log(`   Resolver:      ${toc.resolver}`);
    console.log(`   TruthKeeper:   ${toc.truthKeeper}\n`);

    // Timeline based on state
    console.log(`⏱️  Timeline:`);

    const disputeDeadline = Number(toc.disputeDeadline);
    const tkDeadline = Number(toc.truthKeeperDeadline);
    const escalationDeadline = Number(toc.escalationDeadline);
    const postDisputeDeadline = Number(toc.postDisputeDeadline);
    const resolutionTime = Number(toc.resolutionTime);

    if (toc.state === 3) { // ACTIVE
      console.log(`   🟢 ACTIVE - Awaiting resolution proposal`);
      console.log(`   ├─ Dispute window:    ${formatDuration(Number(toc.disputeWindow))}`);
      console.log(`   ├─ TruthKeeper window: ${formatDuration(Number(toc.truthKeeperWindow))}`);
      console.log(`   ├─ Escalation window: ${formatDuration(Number(toc.escalationWindow))}`);
      console.log(`   └─ Post-resolution:   ${formatDuration(Number(toc.postResolutionWindow))}`);
    } else if (toc.state === 4) { // RESOLVING
      const remaining = disputeDeadline - now;
      console.log(`   ✅ Resolution proposed at: ${formatTime(resolutionTime)}`);
      console.log(`   ⏳ Dispute window:`);
      if (remaining > 0) {
        console.log(`      ├─ Ends at:    ${formatTime(disputeDeadline)}`);
        console.log(`      ├─ Remaining:  ${formatDuration(remaining)}`);
        console.log(`      └─ Status:     OPEN - Anyone can dispute`);
      } else {
        console.log(`      ├─ Ended at:   ${formatTime(disputeDeadline)}`);
        console.log(`      └─ Status:     CLOSED - Ready to finalize`);
      }
    } else if (toc.state === 5) { // DISPUTED_ROUND_1
      const remaining = tkDeadline - now;
      console.log(`   ⚠️  DISPUTED - TruthKeeper reviewing`);
      console.log(`   ├─ TK Deadline: ${formatTime(tkDeadline)}`);
      if (remaining > 0) {
        console.log(`   ├─ Remaining:   ${formatDuration(remaining)}`);
      } else {
        console.log(`   ├─ Deadline passed - Awaiting TK decision`);
      }
      console.log(`   └─ Next: TruthKeeper will approve or reject dispute`);
    } else if (toc.state === 6) { // DISPUTED_ROUND_2
      const remaining = escalationDeadline - now;
      console.log(`   🚨 ESCALATED - Under admin review`);
      console.log(`   ├─ Escalation Deadline: ${formatTime(escalationDeadline)}`);
      if (remaining > 0) {
        console.log(`   └─ Remaining: ${formatDuration(remaining)}`);
      }
    } else if (toc.state === 7) { // RESOLVED
      console.log(`   ✅ FINALIZED at: ${formatTime(resolutionTime)}`);
      if (postDisputeDeadline > 0 && postDisputeDeadline > now) {
        const remaining = postDisputeDeadline - now;
        console.log(`   ⏳ Post-resolution dispute window:`);
        console.log(`      ├─ Ends at:   ${formatTime(postDisputeDeadline)}`);
        console.log(`      └─ Remaining: ${formatDuration(remaining)}`);
      }
    }

    // Actions
    console.log(`\n💡 Actions:`);
    switch (toc.state) {
      case 3: // ACTIVE
        console.log(`   Propose resolution:`);
        console.log(`   $ TOC_ID=${tocId} ANSWER=true JUSTIFICATION="reason" npx hardhat run scripts/resolve-toc.ts --network ${network}`);
        break;
      case 4: // RESOLVING
        if (disputeDeadline > now) {
          console.log(`   ⏳ Wait for dispute window to close (${formatDuration(disputeDeadline - now)} remaining)`);
          console.log(`   Or dispute this resolution if you disagree.`);
        } else {
          console.log(`   Finalize the resolution:`);
          console.log(`   $ TOC_ID=${tocId} npx hardhat run scripts/finalize-toc.ts --network ${network}`);
        }
        break;
      case 5: // DISPUTED_ROUND_1
        console.log(`   Awaiting TruthKeeper decision.`);
        break;
      case 6: // DISPUTED_ROUND_2
        console.log(`   Awaiting admin/community decision.`);
        break;
      case 7: // RESOLVED
        console.log(`   ✅ TOC is finalized. No further action needed.`);
        break;
      default:
        console.log(`   Check state and take appropriate action.`);
    }

    console.log();

  } catch (error: any) {
    console.error("❌ Failed to query TOC:", error.shortMessage || error.message);
  }
}

main().catch(console.error);
