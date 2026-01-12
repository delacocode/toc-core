/**
 * Dispute a TOC resolution
 * Usage: TOC_ID=4 REASON="Disagree with resolution" npx hardhat run scripts/dispute-toc.ts --network base
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
import { getRegistryAbi, STATE_NAMES, ETH_ADDRESS } from "./lib/abis.js";

async function main() {
  const tocId = process.env.TOC_ID;
  const reason = process.env.REASON || "Disputing the proposed resolution";
  const proposedAnswer = process.env.ANSWER; // "true" or "false" for proposed correct answer

  if (!tocId) {
    console.error("Usage: TOC_ID=<id> REASON=\"your reason\" [ANSWER=true|false] npx hardhat run scripts/dispute-toc.ts --network <network>");
    process.exit(1);
  }

  const network = await getNetwork();
  const { chainId } = getChainConfig(network);
  const config = loadConfig(network);
  const addresses = loadDeployedAddresses(chainId);
  const { publicClient, walletClient, account } = createClients(network);
  const registryAbi = getRegistryAbi();

  console.log(`\n⚔️  Disputing TOC #${tocId} on ${network}\n`);
  console.log(`🔑 Account: ${account.address}\n`);

  // Check TOC state
  console.log("📋 Checking TOC state...");
  const toc = await publicClient.readContract({
    address: addresses.registry,
    abi: registryAbi,
    functionName: "getTOCInfo",
    args: [BigInt(tocId)],
  }) as any;

  console.log(`   State: ${STATE_NAMES[toc.state] || toc.state}`);

  if (toc.state !== 4) { // RESOLVING
    console.error(`\n❌ TOC is not in RESOLVING state (current: ${STATE_NAMES[toc.state]})`);
    console.error("   Can only dispute during the dispute window");
    process.exit(1);
  }

  // Check if can be disputed
  const canDispute = await publicClient.readContract({
    address: addresses.registry,
    abi: registryAbi,
    functionName: "canDispute",
    args: [BigInt(tocId)],
  });

  if (!canDispute) {
    console.error("\n❌ TOC cannot be disputed (window may have passed or already disputed)");
    process.exit(1);
  }

  // Dispute bond
  const disputeBond = BigInt(config.registry.bonds.dispute.minAmount);

  // Encode proposed result if provided
  let proposedResult = "0x" as `0x${string}`;
  if (proposedAnswer !== undefined) {
    const answer = proposedAnswer.toLowerCase() === "true";
    proposedResult = encodeAbiParameters(parseAbiParameters("bool"), [answer]);
  }

  console.log(`\n📋 Dispute Details:`);
  console.log(`   Reason: ${reason}`);
  console.log(`   Bond: ${Number(disputeBond) / 1e18} ETH`);
  if (proposedAnswer !== undefined) {
    console.log(`   Proposed Answer: ${proposedAnswer.toUpperCase()}`);
  }

  try {
    console.log("\n⏳ Sending dispute transaction...");

    const evidenceURI = process.env.EVIDENCE || "";

    const hash = await walletClient.writeContract({
      address: addresses.registry,
      abi: registryAbi,
      functionName: "dispute",
      args: [BigInt(tocId), ETH_ADDRESS, disputeBond, reason, evidenceURI, proposedResult],
      value: disputeBond,
    });

    console.log(`   Tx hash: ${hash}`);
    console.log("⏳ Waiting for confirmation...");

    const receipt = await publicClient.waitForTransactionReceipt({ hash });
    console.log(`   Block: ${receipt.blockNumber}`);

    // Get updated state
    const updatedToc = await publicClient.readContract({
      address: addresses.registry,
      abi: registryAbi,
      functionName: "getTOCInfo",
      args: [BigInt(tocId)],
    }) as any;

    console.log("\n✅ Dispute Filed!");
    console.log(`   New state: ${STATE_NAMES[updatedToc.state]}`);
    console.log(`   Transaction: ${getExplorerTxUrl(network, hash)}`);

  } catch (error: any) {
    console.error("\n❌ Failed to dispute:");
    console.error(error.shortMessage || error.message);
  }
}

main().catch(console.error);
