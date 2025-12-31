/**
 * Resolve a TOC on any supported network
 *
 * Usage: TOC_ID=1 npx hardhat run scripts/resolve-toc.ts --network <network>
 * Options: ANSWER=false JUSTIFICATION="reason"
 */

import { encodeAbiParameters, parseAbiParameters, formatEther } from "viem";
import {
  getNetwork,
  loadConfig,
  loadDeployedAddresses,
  getChainConfig,
  createClients,
  getExplorerTxUrl,
} from "./lib/config.js";

const ETH = "0x0000000000000000000000000000000000000000" as const;

const REGISTRY_ABI = [
  {
    name: "resolveTOC",
    type: "function",
    inputs: [
      { name: "tocId", type: "uint256" },
      { name: "bondToken", type: "address" },
      { name: "bondAmount", type: "uint256" },
      { name: "payload", type: "bytes" },
    ],
    outputs: [],
    stateMutability: "payable",
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

function encodeAnswerPayload(answer: boolean, justification: string): `0x${string}` {
  return encodeAbiParameters(
    parseAbiParameters("bool answer, string justification"),
    [answer, justification]
  );
}

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

  console.log(`\n⚖️  Resolving TOC #${tocId} on ${network}\n`);
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

    console.log(`   State: ${STATE_NAMES[toc.state] || toc.state}`);
    console.log(`   Resolver: ${toc.resolver}`);
    console.log(`   Created: ${new Date(Number(toc.createdAt) * 1000).toISOString()}`);

    if (toc.state !== 2) {
      console.error(`\n❌ TOC is not in ACTIVE state (current: ${STATE_NAMES[toc.state]})`);
      process.exit(1);
    }
  } catch (error: any) {
    console.error("Failed to get TOC:", error.shortMessage || error.message);
    process.exit(1);
  }

  const bondAmount = BigInt(config.registry.bonds.resolution.minAmount);
  const payload = encodeAnswerPayload(answer, justification);

  console.log("\n📋 Resolution Details:");
  console.log(`   Answer: ${answer ? "YES" : "NO"}`);
  console.log(`   Justification: ${justification}`);
  console.log(`   Bond: ${formatEther(bondAmount)} ETH`);
  console.log();

  try {
    console.log("⏳ Sending transaction...");

    const hash = await walletClient.writeContract({
      address: addresses.registry,
      abi: REGISTRY_ABI,
      functionName: "resolveTOC",
      args: [BigInt(tocId), ETH, bondAmount, payload],
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
