/**
 * Finalize a TOC on any supported network
 *
 * Usage: TOC_ID=1 npx hardhat run scripts/finalize-toc.ts --network <network>
 */

import {
  getNetwork,
  loadDeployedAddresses,
  getChainConfig,
  createClients,
  getExplorerTxUrl,
} from "./lib/config.js";

const REGISTRY_ABI = [
  {
    name: "finalizeTOC",
    type: "function",
    inputs: [{ name: "tocId", type: "uint256" }],
    outputs: [],
    stateMutability: "nonpayable",
  },
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
] as const;

const STATE_NAMES = ["NONE", "PENDING", "ACTIVE", "PROPOSED", "DISPUTED", "ESCALATED", "RESOLVED", "REJECTED"];

async function main() {
  const tocId = process.env.TOC_ID;
  if (!tocId) {
    console.error("Usage: TOC_ID=<id> npx hardhat run scripts/finalize-toc.ts --network <network>");
    process.exit(1);
  }

  const network = getNetwork();
  const { chainId } = getChainConfig(network);
  const addresses = loadDeployedAddresses(chainId);
  const { publicClient, walletClient, account } = createClients(network);

  console.log(`\n🏁 Finalizing TOC #${tocId} on ${network}\n`);
  console.log(`🔑 Account: ${account.address}\n`);

  // Check TOC state
  console.log("📋 Checking TOC state...");
  try {
    const toc = await publicClient.readContract({
      address: addresses.registry,
      abi: REGISTRY_ABI,
      functionName: "getTOC",
      args: [BigInt(tocId)],
    });

    console.log(`   Current state: ${STATE_NAMES[toc.state] || toc.state}`);

    if (toc.state === 6) {
      console.log("\n✅ TOC is already finalized!");
      return;
    }

    if (toc.state !== 3) {
      console.error(`\n❌ TOC must be in PROPOSED state (current: ${STATE_NAMES[toc.state]})`);
      process.exit(1);
    }

    const disputeEnd = Number(toc.resolvedAt) + Number(toc.disputeWindow);
    const now = Math.floor(Date.now() / 1000);

    if (now < disputeEnd) {
      const remaining = disputeEnd - now;
      console.log(`\n⏳ Dispute window not yet expired.`);
      console.log(`   Time remaining: ${remaining}s (${Math.ceil(remaining / 60)} minutes)`);
      console.log(`   Expires at: ${new Date(disputeEnd * 1000).toISOString()}`);
      process.exit(1);
    }

    console.log("   Dispute window has expired ✓");

  } catch (error: any) {
    console.error("Failed to get TOC:", error.shortMessage || error.message);
    process.exit(1);
  }

  try {
    console.log("\n⏳ Sending finalize transaction...");

    const hash = await walletClient.writeContract({
      address: addresses.registry,
      abi: REGISTRY_ABI,
      functionName: "finalizeTOC",
      args: [BigInt(tocId)],
    });

    console.log(`   Tx hash: ${hash}`);
    console.log("⏳ Waiting for confirmation...");

    const receipt = await publicClient.waitForTransactionReceipt({ hash });
    console.log(`   Block: ${receipt.blockNumber}`);

    console.log("\n✅ TOC Finalized!");
    console.log(`   Transaction: ${getExplorerTxUrl(network, hash)}`);

    const toc = await publicClient.readContract({
      address: addresses.registry,
      abi: REGISTRY_ABI,
      functionName: "getTOC",
      args: [BigInt(tocId)],
    });

    console.log(`\n📋 Final State: ${STATE_NAMES[toc.state]}`);

  } catch (error: any) {
    console.error("\n❌ Failed to finalize TOC:");
    console.error(error.shortMessage || error.message);
    if (error.cause?.reason) {
      console.error("Reason:", error.cause.reason);
    }
  }
}

main().catch(console.error);
