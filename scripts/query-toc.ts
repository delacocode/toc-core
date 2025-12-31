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

const REGISTRY_ABI = [
  {
    name: "getTOC",
    type: "function",
    inputs: [{ name: "tocId", type: "uint256" }],
    outputs: [
      {
        name: "",
        type: "tuple",
        components: [
          { name: "resolver", type: "address" },
          { name: "truthKeeper", type: "address" },
          { name: "creator", type: "address" },
          { name: "createdAt", type: "uint256" },
          { name: "resolvedAt", type: "uint256" },
          { name: "state", type: "uint8" },
          { name: "result", type: "bytes" },
          { name: "disputeWindow", type: "uint256" },
          { name: "truthKeeperWindow", type: "uint256" },
          { name: "escalationWindow", type: "uint256" },
          { name: "postResolutionWindow", type: "uint256" },
        ],
      },
    ],
    stateMutability: "view",
  },
  {
    name: "tocCounter",
    type: "function",
    inputs: [],
    outputs: [{ name: "", type: "uint256" }],
    stateMutability: "view",
  },
] as const;

const RESOLVER_ABI = [
  {
    name: "getTocQuestion",
    type: "function",
    inputs: [{ name: "tocId", type: "uint256" }],
    outputs: [{ name: "", type: "string" }],
    stateMutability: "view",
  },
] as const;

const STATE_NAMES = ["NONE", "PENDING", "ACTIVE", "PROPOSED", "DISPUTED", "ESCALATED", "RESOLVED", "REJECTED"];

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

  console.log(`\n🔍 Querying TOC${tocId ? ` #${tocId}` : "s"} on ${network}\n`);

  const counter = await publicClient.readContract({
    address: addresses.registry,
    abi: REGISTRY_ABI,
    functionName: "tocCounter",
  });

  console.log(`📊 Total TOCs created: ${counter}\n`);

  if (!tocId) {
    const start = counter > 5n ? counter - 5n : 1n;
    console.log(`📋 Recent TOCs (${start} to ${counter}):\n`);

    for (let i = counter; i >= start && i >= 1n; i--) {
      try {
        const toc = await publicClient.readContract({
          address: addresses.registry,
          abi: REGISTRY_ABI,
          functionName: "getTOC",
          args: [i],
        });
        console.log(`   #${i}: ${STATE_NAMES[toc.state]} | Creator: ${toc.creator.slice(0, 10)}...`);
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
      abi: REGISTRY_ABI,
      functionName: "getTOC",
      args: [BigInt(tocId)],
    });

    console.log(`📋 TOC #${tocId} Details:\n`);
    console.log(`   State:         ${STATE_NAMES[toc.state] || toc.state}`);
    console.log(`   Resolver:      ${toc.resolver}`);
    console.log(`   TruthKeeper:   ${toc.truthKeeper}`);
    console.log(`   Creator:       ${toc.creator}`);
    console.log(`   Created:       ${new Date(Number(toc.createdAt) * 1000).toISOString()}`);

    if (toc.resolvedAt > 0n) {
      console.log(`   Resolved:      ${new Date(Number(toc.resolvedAt) * 1000).toISOString()}`);
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
          abi: RESOLVER_ABI,
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
      } catch {
        console.log(`\n📦 Result (raw): ${toc.result}`);
      }
    }

    console.log("\n💡 Next action:");
    switch (toc.state) {
      case 2:
        console.log(`   TOC_ID=${tocId} npx hardhat run scripts/resolve-toc.ts --network ${network}`);
        break;
      case 3:
        const disputeEnd = Number(toc.resolvedAt) + Number(toc.disputeWindow);
        const now = Math.floor(Date.now() / 1000);
        if (now < disputeEnd) {
          console.log(`   Wait ${formatDuration(BigInt(disputeEnd - now))} for dispute window, then:`);
        } else {
          console.log("   Dispute window ended. Run:");
        }
        console.log(`   TOC_ID=${tocId} npx hardhat run scripts/finalize-toc.ts --network ${network}`);
        break;
      case 6:
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
