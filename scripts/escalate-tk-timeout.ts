/**
 * Escalate when TruthKeeper times out
 * Usage: TOC_ID=4 npx hardhat run scripts/escalate-tk-timeout.ts --network base
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
    console.error("Usage: TOC_ID=<id> npx hardhat run scripts/escalate-tk-timeout.ts --network <network>");
    process.exit(1);
  }

  const network = await getNetwork();
  const { chainId } = getChainConfig(network);
  const addresses = loadDeployedAddresses(chainId);
  const { publicClient, walletClient, account } = createClients(network);
  const registryAbi = getRegistryAbi();

  console.log(`\n⏰ Escalating TK Timeout for TOC #${tocId} on ${network}\n`);

  // Check state
  const toc = await publicClient.readContract({
    address: addresses.registry,
    abi: registryAbi,
    functionName: "getTOCInfo",
    args: [BigInt(tocId)],
  }) as any;

  console.log(`   Current state: ${STATE_NAMES[toc.state]}`);

  if (toc.state !== 5) { // DISPUTED_ROUND_1
    console.error(`\n❌ TOC is not in DISPUTED_ROUND_1 state`);
    process.exit(1);
  }

  try {
    console.log("\n⏳ Sending escalate transaction...");

    const hash = await walletClient.writeContract({
      address: addresses.registry,
      abi: registryAbi,
      functionName: "escalateTruthKeeperTimeout",
      args: [BigInt(tocId)],
    });

    console.log(`   Tx hash: ${hash}`);
    await publicClient.waitForTransactionReceipt({ hash });

    const updatedToc = await publicClient.readContract({
      address: addresses.registry,
      abi: registryAbi,
      functionName: "getTOCInfo",
      args: [BigInt(tocId)],
    }) as any;

    console.log("\n✅ Escalated to Round 2!");
    console.log(`   New state: ${STATE_NAMES[updatedToc.state]}`);
    console.log(`   Transaction: ${getExplorerTxUrl(network, hash)}`);

  } catch (error: any) {
    console.error("\n❌ Failed:", error.shortMessage || error.message);
  }
}

main().catch(console.error);
