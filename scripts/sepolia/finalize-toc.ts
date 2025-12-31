/**
 * Finalize a TOC on Sepolia
 * Reads deployed addresses from ignition deployment
 *
 * Usage: TOC_ID=1 npx hardhat run scripts/sepolia/finalize-toc.ts --network sepolia
 */

import { createPublicClient, createWalletClient, http } from "viem";
import { mnemonicToAccount } from "viem/accounts";
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
};

// Registry ABI (minimal)
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

// State names
const STATE_NAMES = ["NONE", "PENDING", "ACTIVE", "PROPOSED", "DISPUTED", "ESCALATED", "RESOLVED", "REJECTED"];

async function main() {
  const tocId = process.env.TOC_ID;
  if (!tocId) {
    console.error("Usage: TOC_ID=<id> npx hardhat run scripts/sepolia/finalize-toc.ts --network sepolia");
    process.exit(1);
  }

  console.log(`\n🏁 Finalizing TOC #${tocId} on Sepolia\n`);

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

  // Check TOC state
  console.log("📋 Checking TOC state...");
  try {
    const toc = await publicClient.readContract({
      address: ADDRESSES.registry,
      abi: REGISTRY_ABI,
      functionName: "getTOC",
      args: [BigInt(tocId)],
    });

    console.log(`   Current state: ${STATE_NAMES[toc.state] || toc.state}`);

    if (toc.state === 6) { // RESOLVED
      console.log("\n✅ TOC is already finalized!");
      return;
    }

    if (toc.state !== 3) { // Not PROPOSED
      console.error(`\n❌ TOC must be in PROPOSED state to finalize (current: ${STATE_NAMES[toc.state]})`);
      process.exit(1);
    }

    // Check if dispute window has passed
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

  // Finalize
  try {
    console.log("\n⏳ Sending finalize transaction...");

    const hash = await walletClient.writeContract({
      address: ADDRESSES.registry,
      abi: REGISTRY_ABI,
      functionName: "finalizeTOC",
      args: [BigInt(tocId)],
    });

    console.log(`   Tx hash: ${hash}`);
    console.log("⏳ Waiting for confirmation...");

    const receipt = await publicClient.waitForTransactionReceipt({ hash });
    console.log(`   Block: ${receipt.blockNumber}`);

    console.log("\n✅ TOC Finalized!");
    console.log(`   Transaction: https://sepolia.etherscan.io/tx/${hash}`);

    // Show final state
    const toc = await publicClient.readContract({
      address: ADDRESSES.registry,
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
