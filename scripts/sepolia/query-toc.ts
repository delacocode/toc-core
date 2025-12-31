/**
 * Query a TOC on Sepolia
 * Reads deployed addresses from ignition deployment
 *
 * Usage: TOC_ID=1 npx hardhat run scripts/sepolia/query-toc.ts --network sepolia
 */

import { createPublicClient, http, decodeAbiParameters, parseAbiParameters } from "viem";
import { sepolia } from "viem/chains";
import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";
import "dotenv/config";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

// Load deployed addresses
const deployedPath = path.join(__dirname, "../../ignition/deployments/chain-11155111/deployed_addresses.json");
const deployed = JSON.parse(fs.readFileSync(deployedPath, "utf-8"));

const ADDRESSES = {
  registry: deployed["TOCRegistry#TOCRegistry"] as `0x${string}`,
  optimisticResolver: deployed["OptimisticResolver#OptimisticResolver"] as `0x${string}`,
};

// Registry ABI
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

// OptimisticResolver ABI
const RESOLVER_ABI = [
  {
    name: "getTocQuestion",
    type: "function",
    inputs: [{ name: "tocId", type: "uint256" }],
    outputs: [{ name: "", type: "string" }],
    stateMutability: "view",
  },
] as const;

// State names
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

  console.log(`\n🔍 Querying TOC${tocId ? ` #${tocId}` : "s"} on Sepolia\n`);

  const rpcUrl = process.env.SEPOLIA_RPC_URL;
  if (!rpcUrl) throw new Error("SEPOLIA_RPC_URL not set in .env");

  const publicClient = createPublicClient({
    chain: sepolia,
    transport: http(rpcUrl),
  });

  // Get total count
  const counter = await publicClient.readContract({
    address: ADDRESSES.registry,
    abi: REGISTRY_ABI,
    functionName: "tocCounter",
  });

  console.log(`📊 Total TOCs created: ${counter}\n`);

  if (!tocId) {
    // List recent TOCs
    const start = counter > 5n ? counter - 5n : 1n;
    console.log(`📋 Recent TOCs (${start} to ${counter}):\n`);

    for (let i = counter; i >= start && i >= 1n; i--) {
      try {
        const toc = await publicClient.readContract({
          address: ADDRESSES.registry,
          abi: REGISTRY_ABI,
          functionName: "getTOC",
          args: [i],
        });

        console.log(`   #${i}: ${STATE_NAMES[toc.state]} | Creator: ${toc.creator.slice(0, 10)}...`);
      } catch {
        // Skip invalid TOCs
      }
    }

    console.log(`\n💡 For details: TOC_ID=<id> npx hardhat run scripts/sepolia/query-toc.ts --network sepolia`);
    return;
  }

  // Query specific TOC
  try {
    const toc = await publicClient.readContract({
      address: ADDRESSES.registry,
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

    // Try to get question from resolver
    if (toc.resolver.toLowerCase() === ADDRESSES.optimisticResolver.toLowerCase()) {
      try {
        const question = await publicClient.readContract({
          address: ADDRESSES.optimisticResolver,
          abi: RESOLVER_ABI,
          functionName: "getTocQuestion",
          args: [BigInt(tocId)],
        });
        console.log(`\n❓ Question:\n   ${question}`);
      } catch {
        // Question might not be available
      }
    }

    // Parse result if available
    if (toc.result && toc.result !== "0x") {
      try {
        const [answer] = decodeAbiParameters(parseAbiParameters("bool"), toc.result);
        console.log(`\n✅ Result: ${answer ? "YES" : "NO"}`);
      } catch {
        console.log(`\n📦 Result (raw): ${toc.result}`);
      }
    }

    // Show next action hint
    console.log("\n💡 Next action:");
    switch (toc.state) {
      case 2: // ACTIVE
        console.log(`   TOC_ID=${tocId} npx hardhat run scripts/sepolia/resolve-toc.ts --network sepolia`);
        break;
      case 3: // PROPOSED
        const disputeEnd = Number(toc.resolvedAt) + Number(toc.disputeWindow);
        const now = Math.floor(Date.now() / 1000);
        if (now < disputeEnd) {
          console.log(`   Wait ${formatDuration(BigInt(disputeEnd - now))} for dispute window to end, then:`);
        } else {
          console.log("   Dispute window ended. Run:");
        }
        console.log(`   TOC_ID=${tocId} npx hardhat run scripts/sepolia/finalize-toc.ts --network sepolia`);
        break;
      case 6: // RESOLVED
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
