/**
 * Resolve a TOC on Sepolia
 * Reads configuration from ignition/config/sepolia.json
 *
 * Usage: TOC_ID=1 npx hardhat run scripts/sepolia/resolve-toc.ts --network sepolia
 */

import { createPublicClient, createWalletClient, http, encodeAbiParameters, parseAbiParameters, formatEther } from "viem";
import { mnemonicToAccount } from "viem/accounts";
import { sepolia } from "viem/chains";
import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";
import "dotenv/config";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

// Load config
const configPath = path.join(__dirname, "../../ignition/config/sepolia.json");
const config = JSON.parse(fs.readFileSync(configPath, "utf-8"));

// Load deployed addresses
const deployedPath = path.join(__dirname, "../../ignition/deployments/chain-11155111/deployed_addresses.json");
const deployed = JSON.parse(fs.readFileSync(deployedPath, "utf-8"));

const ADDRESSES = {
  registry: deployed["TOCRegistry#TOCRegistry"] as `0x${string}`,
};

const ETH = "0x0000000000000000000000000000000000000000" as const;

// Registry ABI (minimal)
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

// State names
const STATE_NAMES = ["NONE", "PENDING", "ACTIVE", "PROPOSED", "DISPUTED", "ESCALATED", "RESOLVED", "REJECTED"];

// Encode AnswerPayload for OptimisticResolver
function encodeAnswerPayload(answer: boolean, justification: string): `0x${string}` {
  return encodeAbiParameters(
    parseAbiParameters("bool answer, string justification"),
    [answer, justification]
  );
}

async function main() {
  const tocId = process.env.TOC_ID;
  if (!tocId) {
    console.error("Usage: TOC_ID=<id> npx hardhat run scripts/sepolia/resolve-toc.ts --network sepolia");
    process.exit(1);
  }

  // Resolution parameters (can be customized via env vars)
  const answer = process.env.ANSWER !== "false"; // Default to YES
  const justification = process.env.JUSTIFICATION || "Resolution based on available data.";

  console.log(`\n⚖️  Resolving TOC #${tocId} on Sepolia\n`);

  const mnemonic = process.env.MNEMONIC;
  if (!mnemonic) throw new Error("MNEMONIC not set in .env");

  const rpcUrl = process.env.SEPOLIA_RPC_URL;
  if (!rpcUrl) throw new Error("SEPOLIA_RPC_URL not set in .env");

  const account = mnemonicToAccount(mnemonic);
  console.log(`🔑 Account: ${account.address}\n`);

  const publicClient = createPublicClient({
    chain: sepolia,
    transport: http(rpcUrl),
  });

  const walletClient = createWalletClient({
    account,
    chain: sepolia,
    transport: http(rpcUrl),
  });

  // First, check the TOC state
  console.log("📋 Checking TOC state...");
  try {
    const toc = await publicClient.readContract({
      address: ADDRESSES.registry,
      abi: REGISTRY_ABI,
      functionName: "getTOC",
      args: [BigInt(tocId)],
    });

    console.log(`   State: ${STATE_NAMES[toc.state] || toc.state}`);
    console.log(`   Resolver: ${toc.resolver}`);
    console.log(`   Created: ${new Date(Number(toc.createdAt) * 1000).toISOString()}`);

    if (toc.state !== 2) { // Not ACTIVE
      console.error(`\n❌ TOC is not in ACTIVE state (current: ${STATE_NAMES[toc.state]})`);
      process.exit(1);
    }
  } catch (error: any) {
    console.error("Failed to get TOC:", error.shortMessage || error.message);
    process.exit(1);
  }

  // Resolution bond from config
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
      address: ADDRESSES.registry,
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
    console.log(`   Transaction: https://sepolia.etherscan.io/tx/${hash}`);
    console.log(`\n💡 The TOC is now in PROPOSED state.`);
    console.log(`   Wait for the dispute window to expire, then run:`);
    console.log(`   TOC_ID=${tocId} npx hardhat run scripts/sepolia/finalize-toc.ts --network sepolia`);

  } catch (error: any) {
    console.error("\n❌ Failed to resolve TOC:");
    console.error(error.shortMessage || error.message);
    if (error.cause?.reason) {
      console.error("Reason:", error.cause.reason);
    }
  }
}

main().catch(console.error);
