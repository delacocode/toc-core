/**
 * Create a TOC on Sepolia
 * Reads configuration from ignition/config/sepolia.json
 *
 * Usage: npx hardhat run scripts/sepolia/create-toc.ts --network sepolia
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
  optimisticResolver: deployed["OptimisticResolver#OptimisticResolver"] as `0x${string}`,
  truthKeeper: deployed["SimpleTruthKeeper#SimpleTruthKeeper"] as `0x${string}`,
};

// Templates
const TEMPLATE = {
  ARBITRARY: 1,
  SPORTS: 2,
  EVENT: 3,
} as const;

// Registry ABI (minimal)
const REGISTRY_ABI = [
  {
    name: "createTOC",
    type: "function",
    inputs: [
      { name: "resolver", type: "address" },
      { name: "templateId", type: "uint32" },
      { name: "payload", type: "bytes" },
      { name: "disputeWindow", type: "uint256" },
      { name: "truthKeeperWindow", type: "uint256" },
      { name: "escalationWindow", type: "uint256" },
      { name: "postResolutionWindow", type: "uint256" },
      { name: "truthKeeper", type: "address" },
    ],
    outputs: [{ name: "tocId", type: "uint256" }],
    stateMutability: "payable",
  },
  {
    name: "tocCounter",
    type: "function",
    inputs: [],
    outputs: [{ name: "", type: "uint256" }],
    stateMutability: "view",
  },
] as const;

// Encode ArbitraryPayload
function encodeArbitraryPayload(question: string, description: string, resolutionSource: string, resolutionTime: bigint): `0x${string}` {
  return encodeAbiParameters(
    parseAbiParameters("string question, string description, string resolutionSource, uint256 resolutionTime"),
    [question, description, resolutionSource, resolutionTime]
  );
}

async function main() {
  console.log("\n📝 Creating TOC on Sepolia\n");

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

  // Get current TOC count
  const currentCount = await publicClient.readContract({
    address: ADDRESSES.registry,
    abi: REGISTRY_ABI,
    functionName: "tocCounter",
  });

  // Create an arbitrary question
  const question = "Will ETH be above $5000 on January 1st, 2026?";
  const description = "This question resolves YES if the price of ETH is above $5000 USD at any point on January 1st, 2026 according to CoinGecko.";
  const resolutionSource = "https://www.coingecko.com/en/coins/ethereum";
  const resolutionTime = BigInt(Math.floor(Date.now() / 1000) + 86400 * 365); // 1 year from now

  const payload = encodeArbitraryPayload(question, description, resolutionSource, resolutionTime);

  // Time windows (in seconds) - must be <= 1 day for RESOLVER trust level
  const disputeWindow = 300n; // 5 minutes (for testing)
  const truthKeeperWindow = 300n; // 5 minutes
  const escalationWindow = 300n; // 5 minutes
  const postResolutionWindow = 300n; // 5 minutes

  // Calculate value: protocol fee + resolution bond
  const protocolFee = BigInt(config.registry.fees.protocolFeeStandard);
  const resolutionBond = BigInt(config.registry.bonds.resolution.minAmount);
  const value = protocolFee + resolutionBond;

  console.log("📋 TOC Details:");
  console.log(`   Question: ${question}`);
  console.log(`   Template: ARBITRARY (1)`);
  console.log(`   Resolver: ${ADDRESSES.optimisticResolver}`);
  console.log(`   TruthKeeper: ${ADDRESSES.truthKeeper}`);
  console.log(`   Protocol fee: ${formatEther(protocolFee)} ETH`);
  console.log(`   Resolution bond: ${formatEther(resolutionBond)} ETH`);
  console.log(`   Total value: ${formatEther(value)} ETH`);
  console.log(`   Time windows: 5 minutes each (for testing)`);
  console.log();

  try {
    console.log("⏳ Sending transaction...");

    const hash = await walletClient.writeContract({
      address: ADDRESSES.registry,
      abi: REGISTRY_ABI,
      functionName: "createTOC",
      args: [
        ADDRESSES.optimisticResolver,
        TEMPLATE.ARBITRARY,
        payload,
        disputeWindow,
        truthKeeperWindow,
        escalationWindow,
        postResolutionWindow,
        ADDRESSES.truthKeeper,
      ],
      value,
    });

    console.log(`   Tx hash: ${hash}`);
    console.log("⏳ Waiting for confirmation...");

    const receipt = await publicClient.waitForTransactionReceipt({ hash });
    console.log(`   Block: ${receipt.blockNumber}`);

    // The new TOC ID should be currentCount + 1
    const newTocId = currentCount + 1n;

    console.log("\n✅ TOC Created!");
    console.log(`   TOC ID: ${newTocId}`);
    console.log(`   Transaction: https://sepolia.etherscan.io/tx/${hash}`);
    console.log(`\n💡 Next: TOC_ID=${newTocId} npx hardhat run scripts/sepolia/resolve-toc.ts --network sepolia`);

  } catch (error: any) {
    console.error("\n❌ Failed to create TOC:");
    console.error(error.shortMessage || error.message);
    if (error.cause?.reason) {
      console.error("Reason:", error.cause.reason);
    }
  }
}

main().catch(console.error);
