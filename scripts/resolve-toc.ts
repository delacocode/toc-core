/**
 * Resolve a TOC on any supported network
 *
 * Usage: TOC_ID=1 npx hardhat run scripts/resolve-toc.ts --network <network>
 * Options: ANSWER=false JUSTIFICATION="reason"
 */

import { formatEther } from "viem";
import {
  getNetwork,
  loadConfig,
  loadDeployedAddresses,
  getChainConfig,
  createClients,
  getExplorerTxUrl,
} from "./lib/config.js";
import { encodeAnswerPayload } from "./lib/payloads.js";
import { getRegistryAbi, STATE_NAMES, ETH_ADDRESS } from "./lib/abis.js";

async function main() {
  const tocId = process.env.TOC_ID;
  if (!tocId) {
    console.error("Usage: TOC_ID=<id> npx hardhat run scripts/resolve-toc.ts --network <network>");
    process.exit(1);
  }

  const answer = process.env.ANSWER !== "false";
  const justification = process.env.JUSTIFICATION || "Resolution based on available data.";

  const network = await getNetwork();
  const { chainId } = getChainConfig(network);
  const config = loadConfig(network);
  const addresses = loadDeployedAddresses(chainId);
  const { publicClient, walletClient, account } = createClients(network);
  const abi = getRegistryAbi();

  console.log(`\n⚖️  Resolving TOC #${tocId} on ${network}\n`);
  console.log(`🔑 Account: ${account.address}\n`);

  // Check TOC state
  console.log("📋 Checking TOC state...");
  try {
    const toc = await publicClient.readContract({
      address: addresses.registry,
      abi,
      functionName: "getTOCInfo",
      args: [BigInt(tocId)],
    }) as any;

    console.log(`   State: ${STATE_NAMES[toc.state] || toc.state}`);
    console.log(`   Resolver: ${toc.resolver}`);

    if (toc.state !== 3) { // ACTIVE
      console.error(`\n❌ TOC is not in ACTIVE state (current: ${STATE_NAMES[toc.state]})`);
      process.exit(1);
    }
  } catch (error: any) {
    console.error("Failed to get TOC:", error.shortMessage || error.message);
    process.exit(1);
  }

  const bondAmount = BigInt(config.registry.bonds.resolution.minAmount);
  const payload = encodeAnswerPayload({ answer, justification });

  console.log("\n📋 Resolution Details:");
  console.log(`   Answer: ${answer ? "YES" : "NO"}`);
  console.log(`   Justification: ${justification}`);
  console.log(`   Bond: ${formatEther(bondAmount)} ETH`);
  console.log();

  try {
    console.log("⏳ Sending transaction...");

    const hash = await walletClient.writeContract({
      address: addresses.registry,
      abi,
      functionName: "resolveTOC",
      args: [BigInt(tocId), ETH_ADDRESS, bondAmount, payload],
      value: bondAmount,
    });

    console.log(`   Tx hash: ${hash}`);
    console.log("⏳ Waiting for confirmation...");

    const receipt = await publicClient.waitForTransactionReceipt({ hash });
    console.log(`   Block: ${receipt.blockNumber}`);

    console.log("\n✅ TOC Resolved (Proposed)!");
    console.log(`   Transaction: ${getExplorerTxUrl(network, hash)}`);
    console.log(`\n💡 Wait for dispute window, then run:`);
    console.log(`   TOC_ID=${tocId} npx hardhat run scripts/finalize-toc.ts --network ${network}`);

  } catch (error: any) {
    console.error("\n❌ Failed to resolve TOC:");
    console.error(error.shortMessage || error.message);
    if (error.cause?.reason) {
      console.error("Reason:", error.cause.reason);
    }
  }
}

main().catch(console.error);
