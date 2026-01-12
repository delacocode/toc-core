/**
 * Query TOC(s) on any supported network
 *
 * Usage: npx hardhat run scripts/query-toc.ts --network <network>
 *        TOC_ID=1 npx hardhat run scripts/query-toc.ts --network <network>
 */

import { decodeAbiParameters, parseAbiParameters, formatEther } from "viem";
import {
  getNetwork,
  loadConfig,
  loadDeployedAddresses,
  getChainConfig,
  createClients,
} from "./lib/config.js";
import { getRegistryAbi, getResolverAbi, getPythResolverAbi, STATE_NAMES } from "./lib/abis.js";

// Pyth price feed ID to asset name mapping
const PYTH_PRICE_IDS: Record<string, string> = {
  "0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43": "BTC/USD",
  "0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace": "ETH/USD",
  "0xef0d8b6fda2ceba41da15d4095d1da392a0d2f8ed0c6c7bc0f4cfac8c280b56d": "SOL/USD",
  "0xeaa020c61cc479712813461ce153894a96a6c00b21ed0cfc2798d1f9a9e9c94a": "USDC/USD",
  "0x2b89b9dc8fdf9f34709a5b106b472f0f39bb6ca9ce04b0fd7f2e971688e2e53b": "USDT/USD",
};

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

// Format Pyth price (8 decimals) to USD
function formatPythPrice(rawPrice: string): string {
  const price = Number(rawPrice) / 1e8;
  return price.toLocaleString("en-US", { style: "currency", currency: "USD", maximumFractionDigits: 0 });
}

// Parse and format Pyth question to human-readable form
function formatPythQuestion(question: string, asset?: string): string {
  const assetPrefix = asset ? `${asset} ` : "";

  // Pattern: "Will price be above/below X at timestamp Y?"
  const snapshotMatch = question.match(/Will price be (above|below) (-?\d+) at timestamp (\d+)\?/);
  if (snapshotMatch) {
    const [, direction, rawPrice, timestamp] = snapshotMatch;
    const price = formatPythPrice(rawPrice);
    const time = formatTime(Number(timestamp));
    return `Will ${assetPrefix}price be ${direction} ${price} at ${time}?`;
  }

  // Pattern: "Will price be between X and Y at timestamp Z?"
  const rangeMatch = question.match(/Will price be between (-?\d+) and (-?\d+) at timestamp (\d+)\?/);
  if (rangeMatch) {
    const [, rawLower, rawUpper, timestamp] = rangeMatch;
    const lower = formatPythPrice(rawLower);
    const upper = formatPythPrice(rawUpper);
    const time = formatTime(Number(timestamp));
    return `Will ${assetPrefix}price be between ${lower} and ${upper} at ${time}?`;
  }

  // Pattern: "Will price reach above/below X by timestamp Y?"
  const reachedMatch = question.match(/Will price reach (above|below) (-?\d+) by timestamp (\d+)\?/);
  if (reachedMatch) {
    const [, direction, rawPrice, timestamp] = reachedMatch;
    const price = formatPythPrice(rawPrice);
    const time = formatTime(Number(timestamp));
    return `Will ${assetPrefix}price reach ${direction} ${price} by ${time}?`;
  }

  // Fallback: return original
  return question;
}

// Get asset name from Pyth price ID
function getAssetFromPriceId(priceId: string): string {
  return PYTH_PRICE_IDS[priceId.toLowerCase()] || "Unknown";
}

async function main() {
  const tocId = process.env.TOC_ID;
  const network = await getNetwork();
  const { chainId } = getChainConfig(network);
  const config = loadConfig(network);
  const addresses = loadDeployedAddresses(chainId);
  const { publicClient } = createClients(network);
  const registryAbi = getRegistryAbi();
  const resolverAbi = getResolverAbi();
  const pythResolverAbi = getPythResolverAbi();

  // Bond amounts from config
  const bonds = {
    resolution: BigInt(config.registry.bonds.resolution.minAmount),
    dispute: BigInt(config.registry.bonds.dispute.minAmount),
    escalation: BigInt(config.registry.bonds.escalation.minAmount),
  };

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

    console.log(`═══════════════════════════════════════════════════════════════`);
    console.log(`  TOC #${tocId}  ${stateEmoji} ${STATE_NAMES[toc.state]}`);
    console.log(`═══════════════════════════════════════════════════════════════\n`);

    // Detect resolver type
    const isOptimisticResolver = toc.resolver.toLowerCase() === addresses.optimisticResolver.toLowerCase();
    const isPythResolver = toc.resolver.toLowerCase() === addresses.pythResolver.toLowerCase();

    // Question (from resolver)
    if (isOptimisticResolver) {
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
    } else if (isPythResolver) {
      try {
        // Get TOC details to extract the priceId
        let asset = "";
        try {
          const [, creationPayload] = await publicClient.readContract({
            address: addresses.pythResolver,
            abi: pythResolverAbi,
            functionName: "getTocDetails",
            args: [BigInt(tocId)],
          }) as [number, `0x${string}`];

          // Decode to get priceId (first bytes32 in payload)
          const decoded = decodeAbiParameters(
            [
              { name: "priceId", type: "bytes32" },
              { name: "threshold", type: "int64" },
              { name: "isAbove", type: "bool" },
              { name: "deadline", type: "uint256" },
            ],
            creationPayload
          );
          asset = getAssetFromPriceId(decoded[0]);
        } catch {
          // Could not decode, continue without asset name
        }

        const question = await publicClient.readContract({
          address: addresses.pythResolver,
          abi: pythResolverAbi,
          functionName: "getTocQuestion",
          args: [BigInt(tocId)],
        }) as string;

        // Parse Pyth question and format nicely
        // Format: "Will price be above/below X at timestamp Y?" or "Will price be between X and Y at timestamp Z?"
        const formattedQuestion = formatPythQuestion(question, asset);
        console.log(`🔮 ${formattedQuestion}`);
        console.log(`📊 Resolver: Pyth Oracle (automatic price resolution)`);
        if (asset) {
          console.log(`📈 Asset: ${asset}`);
        }

        // Show deadline info for Pyth TOCs
        try {
          const [, creationPayload] = await publicClient.readContract({
            address: addresses.pythResolver,
            abi: pythResolverAbi,
            functionName: "getTocDetails",
            args: [BigInt(tocId)],
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
          const deadline = Number(decoded[3]);
          const remaining = deadline - now;

          console.log(`⏰ Settlement deadline: ${formatTime(deadline)} (unix: ${deadline})`);
          if (remaining > 0) {
            console.log(`   ⏳ Can settle in: ${formatDuration(remaining)}`);
          } else {
            console.log(`   ✅ Ready to settle now!`);
          }
        } catch {
          // Could not decode deadline
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
        console.log(`┌───────────────────────────────────────────────────────────────┐`);
        console.log(`│  RESULT: ${answer ? "YES ✅" : "NO ❌"}${toc.hasCorrectedResult ? " (corrected via dispute)" : ""}`.padEnd(65) + "│");
        console.log(`└───────────────────────────────────────────────────────────────┘\n`);
      } catch {
        console.log(`📦 Result (raw): ${toc.result}\n`);
      }
    }

    // Addresses
    console.log(`📍 Addresses:`);
    console.log(`   Creator:       ${toc.creator}`);
    console.log(`   Resolver:      ${toc.resolver}`);
    console.log(`   TruthKeeper:   ${toc.truthKeeper}\n`);

    // Timeline based on state
    const disputeDeadline = Number(toc.disputeDeadline);
    const tkDeadline = Number(toc.truthKeeperDeadline);
    const escalationDeadline = Number(toc.escalationDeadline);
    const postDisputeDeadline = Number(toc.postDisputeDeadline);
    const resolutionTime = Number(toc.resolutionTime);

    console.log(`⏱️  Current Status:`);

    if (toc.state === 3) { // ACTIVE
      console.log(`   🟢 ACTIVE - Awaiting resolution proposal\n`);
      console.log(`   Configured time windows:`);
      console.log(`   ├─ Dispute window:     ${formatDuration(Number(toc.disputeWindow))}`);
      console.log(`   ├─ TruthKeeper window: ${formatDuration(Number(toc.truthKeeperWindow))}`);
      console.log(`   ├─ Escalation window:  ${formatDuration(Number(toc.escalationWindow))}`);
      console.log(`   └─ Post-resolution:    ${formatDuration(Number(toc.postResolutionWindow))}`);
    } else if (toc.state === 4) { // RESOLVING
      const remaining = disputeDeadline - now;
      console.log(`   ✅ Resolution proposed at: ${formatTime(resolutionTime)}`);
      console.log(`   ⏳ Dispute window:`);
      if (remaining > 0) {
        console.log(`      ├─ Ends at:    ${formatTime(disputeDeadline)}`);
        console.log(`      ├─ Remaining:  ${formatDuration(remaining)}`);
        console.log(`      └─ Status:     🟡 OPEN - Anyone can dispute`);
      } else {
        console.log(`      ├─ Ended at:   ${formatTime(disputeDeadline)}`);
        console.log(`      └─ Status:     🟢 CLOSED - Ready to finalize`);
      }
    } else if (toc.state === 5) { // DISPUTED_ROUND_1
      const remaining = tkDeadline - now;
      console.log(`   ⚠️  DISPUTED - TruthKeeper reviewing`);
      console.log(`   ├─ TK Deadline: ${formatTime(tkDeadline)}`);
      if (remaining > 0) {
        console.log(`   ├─ Remaining:   ${formatDuration(remaining)}`);
      } else {
        console.log(`   ├─ Deadline passed`);
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

    // Possible Actions with requirements
    console.log(`\n💡 Possible Actions:\n`);

    switch (toc.state) {
      case 3: // ACTIVE
        if (isPythResolver) {
          // Pyth resolver - automatic resolution with price data
          console.log(`   ┌─────────────────────────────────────────────────────────────┐`);
          console.log(`   │  1. RESOLVE WITH PYTH PRICE DATA                            │`);
          console.log(`   ├─────────────────────────────────────────────────────────────┤`);
          console.log(`   │  Bond required:  None (automatic resolution)                │`);
          console.log(`   │  Condition:      Deadline must have passed                  │`);
          console.log(`   │  Data required:  Pyth price update from Hermes API          │`);
          console.log(`   │  Next state:     RESOLVED (immediate, no dispute)           │`);
          console.log(`   ├─────────────────────────────────────────────────────────────┤`);
          console.log(`   │  Command:                                                   │`);
          console.log(`   │  $ TOC_ID=${tocId} npx hardhat run \\`.padEnd(62) + "│");
          console.log(`   │    scripts/resolve-pyth-toc.ts --network ${network}`.padEnd(62) + "│");
          console.log(`   └─────────────────────────────────────────────────────────────┘`);
        } else {
          // Optimistic resolver - manual proposal with bond
          console.log(`   ┌─────────────────────────────────────────────────────────────┐`);
          console.log(`   │  1. PROPOSE RESOLUTION                                      │`);
          console.log(`   ├─────────────────────────────────────────────────────────────┤`);
          console.log(`   │  Bond required:  ${formatEther(bonds.resolution)} ETH`.padEnd(62) + "│");
          console.log(`   │  Condition:      Anyone can propose                         │`);
          console.log(`   │  Next state:     RESOLVING (dispute window opens)           │`);
          console.log(`   │  Timeline:       ${formatDuration(Number(toc.disputeWindow))} dispute window starts`.padEnd(62) + "│");
          console.log(`   ├─────────────────────────────────────────────────────────────┤`);
          console.log(`   │  Command:                                                   │`);
          console.log(`   │  $ TOC_ID=${tocId} ANSWER=true \\`.padEnd(62) + "│");
          console.log(`   │    JUSTIFICATION="your reasoning" \\`.padEnd(62) + "│");
          console.log(`   │    npx hardhat run scripts/resolve-toc.ts --network ${network}`.padEnd(62) + "│");
          console.log(`   └─────────────────────────────────────────────────────────────┘`);
        }
        break;

      case 4: // RESOLVING
        const remaining = disputeDeadline - now;
        if (remaining > 0) {
          console.log(`   ┌─────────────────────────────────────────────────────────────┐`);
          console.log(`   │  1. DISPUTE (challenge the proposed resolution)             │`);
          console.log(`   ├─────────────────────────────────────────────────────────────┤`);
          console.log(`   │  Bond required:  ${formatEther(bonds.dispute)} ETH`.padEnd(62) + "│");
          console.log(`   │  Condition:      Disagree with proposed answer              │`);
          console.log(`   │  Time left:      ${formatDuration(remaining)}`.padEnd(62) + "│");
          console.log(`   │  Next state:     DISPUTED_ROUND_1 (TruthKeeper reviews)     │`);
          console.log(`   └─────────────────────────────────────────────────────────────┘`);
          console.log();
          console.log(`   ┌─────────────────────────────────────────────────────────────┐`);
          console.log(`   │  2. WAIT FOR FINALIZATION                                   │`);
          console.log(`   ├─────────────────────────────────────────────────────────────┤`);
          console.log(`   │  Bond required:  None (anyone can call finalize)            │`);
          console.log(`   │  Condition:      Wait for dispute window to close           │`);
          console.log(`   │  Time left:      ${formatDuration(remaining)}`.padEnd(62) + "│");
          console.log(`   │  Next state:     RESOLVED                                   │`);
          console.log(`   └─────────────────────────────────────────────────────────────┘`);
        } else {
          console.log(`   ┌─────────────────────────────────────────────────────────────┐`);
          console.log(`   │  1. FINALIZE                                                │`);
          console.log(`   ├─────────────────────────────────────────────────────────────┤`);
          console.log(`   │  Bond required:  None                                       │`);
          console.log(`   │  Condition:      Dispute window has closed ✓                │`);
          console.log(`   │  Next state:     RESOLVED (final, immutable)                │`);
          console.log(`   ├─────────────────────────────────────────────────────────────┤`);
          console.log(`   │  Command:                                                   │`);
          console.log(`   │  $ TOC_ID=${tocId} npx hardhat run scripts/finalize-toc.ts \\`.padEnd(62) + "│");
          console.log(`   │    --network ${network}`.padEnd(62) + "│");
          console.log(`   └─────────────────────────────────────────────────────────────┘`);
        }
        break;

      case 5: // DISPUTED_ROUND_1
        console.log(`   ┌─────────────────────────────────────────────────────────────┐`);
        console.log(`   │  AWAITING TRUTHKEEPER DECISION                              │`);
        console.log(`   ├─────────────────────────────────────────────────────────────┤`);
        console.log(`   │  TruthKeeper will either:                                   │`);
        console.log(`   │  • APPROVE dispute → Result corrected, disputer wins bond   │`);
        console.log(`   │  • REJECT dispute  → Original result stands                 │`);
        console.log(`   │                                                             │`);
        console.log(`   │  If you disagree with TK decision, you can escalate:        │`);
        console.log(`   │  Bond required:  ${formatEther(bonds.escalation)} ETH (escalation)`.padEnd(62) + "│");
        console.log(`   │  Next state:     DISPUTED_ROUND_2 (admin review)            │`);
        console.log(`   └─────────────────────────────────────────────────────────────┘`);
        break;

      case 6: // DISPUTED_ROUND_2
        console.log(`   ┌─────────────────────────────────────────────────────────────┐`);
        console.log(`   │  AWAITING ADMIN/COMMUNITY DECISION                          │`);
        console.log(`   ├─────────────────────────────────────────────────────────────┤`);
        console.log(`   │  This is the final escalation level.                        │`);
        console.log(`   │  Admin or community governance will make final decision.    │`);
        console.log(`   └─────────────────────────────────────────────────────────────┘`);
        break;

      case 7: // RESOLVED
        if (postDisputeDeadline > 0 && postDisputeDeadline > now) {
          const postRemaining = postDisputeDeadline - now;
          console.log(`   ┌─────────────────────────────────────────────────────────────┐`);
          console.log(`   │  POST-RESOLUTION DISPUTE WINDOW OPEN                        │`);
          console.log(`   ├─────────────────────────────────────────────────────────────┤`);
          console.log(`   │  You can still dispute if new evidence emerges              │`);
          console.log(`   │  Bond required:  ${formatEther(bonds.dispute)} ETH`.padEnd(62) + "│");
          console.log(`   │  Time left:      ${formatDuration(postRemaining)}`.padEnd(62) + "│");
          console.log(`   └─────────────────────────────────────────────────────────────┘`);
        } else {
          console.log(`   ┌─────────────────────────────────────────────────────────────┐`);
          console.log(`   │  ✅ FINAL - NO FURTHER ACTIONS AVAILABLE                    │`);
          console.log(`   ├─────────────────────────────────────────────────────────────┤`);
          console.log(`   │  This TOC is fully resolved and immutable.                  │`);
          console.log(`   │  The result cannot be changed.                              │`);
          console.log(`   └─────────────────────────────────────────────────────────────┘`);
        }
        break;

      default:
        console.log(`   State ${toc.state} - check contract for available actions.`);
    }

    // Bond summary
    console.log(`\n💰 Bond Requirements (this network):`);
    console.log(`   Resolution:  ${formatEther(bonds.resolution)} ETH`);
    console.log(`   Dispute:     ${formatEther(bonds.dispute)} ETH`);
    console.log(`   Escalation:  ${formatEther(bonds.escalation)} ETH`);

    console.log();

  } catch (error: any) {
    console.error("❌ Failed to query TOC:", error.shortMessage || error.message);
  }
}

main().catch(console.error);
