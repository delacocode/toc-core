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
import { getRegistryAbi, STATE_NAMES } from "./lib/abis.js";

async function main() {
  const tocId = process.env.TOC_ID;
  if (!tocId) {
    console.error("Usage: TOC_ID=<id> npx hardhat run scripts/finalize-toc.ts --network <network>");
    process.exit(1);
  }

  const network = await getNetwork();
  const { chainId } = getChainConfig(network);
  const addresses = loadDeployedAddresses(chainId);
  const { publicClient, walletClient, account } = createClients(network);
  const abi = getRegistryAbi();

  console.log(`\n🏁 Finalizing TOC #${tocId} on ${network}\n`);
  console.log(`🔑 Account: ${account.address}\n`);

  // Check TOC state
  console.log("📋 Checking TOC state...");
  let disputeDeadline: bigint;

  try {
    const toc = await publicClient.readContract({
      address: addresses.registry,
      abi,
      functionName: "getTOCInfo",
      args: [BigInt(tocId)],
    }) as any;

    console.log(`   Current state: ${STATE_NAMES[toc.state] || toc.state}`);
    disputeDeadline = toc.disputeDeadline;

    if (toc.state === 7) { // RESOLVED
      console.log("\n✅ TOC is already finalized!");
      return;
    }

    if (toc.state !== 4) { // RESOLVING
      console.error(`\n❌ TOC must be in RESOLVING state (current: ${STATE_NAMES[toc.state]})`);
      process.exit(1);
    }

    const now = Math.floor(Date.now() / 1000);

    if (now < Number(disputeDeadline)) {
      const remaining = Number(disputeDeadline) - now;
      console.log(`\n⏳ Dispute window not yet expired.`);
      console.log(`   Time remaining: ${remaining}s (${Math.ceil(remaining / 60)} minutes)`);
      console.log(`   Expires at: ${new Date(Number(disputeDeadline) * 1000).toISOString()}`);
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
      abi,
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
      abi,
      functionName: "getTOCInfo",
      args: [BigInt(tocId)],
    }) as any;

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
