/**
 * Create a TOC on any supported network
 *
 * Usage: npx hardhat run scripts/create-toc.ts --network <network>
 *
 * Environment variables:
 *   QUESTION         - The question to resolve (required)
 *   DESCRIPTION      - Detailed description (optional)
 *   SOURCE           - Resolution source URL (optional)
 *   RESOLUTION_TIME  - Unix timestamp for resolution (optional, default: 1 year)
 *   DISPUTE_WINDOW   - Dispute window in seconds (optional, default: 300)
 *   TK_WINDOW        - TruthKeeper window in seconds (optional, default: 300)
 *   ESCALATION_WINDOW - Escalation window in seconds (optional, default: 300)
 *   POST_RESOLUTION_WINDOW - Post-resolution window in seconds (optional, default: 300)
 *
 * Example:
 *   QUESTION="Will ETH be above $5000 on Jan 1, 2026?" \
 *   DESCRIPTION="Resolves YES if ETH price exceeds $5000 USD" \
 *   SOURCE="https://coingecko.com/en/coins/ethereum" \
 *   npx hardhat run scripts/create-toc.ts --network sepolia
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
  // Get configuration from env vars
  const question = process.env.QUESTION;
  if (!question) {
    console.error("Error: QUESTION environment variable is required");
    console.error("\nUsage:");
    console.error('  QUESTION="Will ETH hit $5000?" npx hardhat run scripts/create-toc.ts --network sepolia');
    console.error("\nOptional variables:");
    console.error("  DESCRIPTION      - Detailed description");
    console.error("  SOURCE           - Resolution source URL");
    console.error("  RESOLUTION_TIME  - Unix timestamp for resolution");
    console.error("  DISPUTE_WINDOW   - Dispute window in seconds (default: 300)");
    console.error("  TK_WINDOW        - TruthKeeper window in seconds (default: 300)");
    console.error("  ESCALATION_WINDOW - Escalation window in seconds (default: 300)");
    console.error("  POST_RESOLUTION_WINDOW - Post-resolution window in seconds (default: 300)");
    process.exit(1);
  }

  const description = process.env.DESCRIPTION || "";
  const resolutionSource = process.env.SOURCE || "";
  const resolutionTime = process.env.RESOLUTION_TIME
    ? BigInt(process.env.RESOLUTION_TIME)
    : BigInt(Math.floor(Date.now() / 1000) + 86400 * 365); // Default: 1 year from now

  // Time windows (in seconds)
  const disputeWindow = BigInt(process.env.DISPUTE_WINDOW || "300");
  const truthKeeperWindow = BigInt(process.env.TK_WINDOW || "300");
  const escalationWindow = BigInt(process.env.ESCALATION_WINDOW || "300");
  const postResolutionWindow = BigInt(process.env.POST_RESOLUTION_WINDOW || "300");

  const network = await getNetwork();
  const { chainId } = getChainConfig(network);
  const config = loadConfig(network);
  const addresses = loadDeployedAddresses(chainId);
  const { publicClient, walletClient, account } = createClients(network);

  console.log(`\n📝 Creating TOC on ${network}\n`);
  console.log(`🔑 Account: ${account.address}\n`);

  // Get current TOC count
  const currentCount = await publicClient.readContract({
    address: addresses.registry,
    abi: REGISTRY_ABI,
    functionName: "tocCounter",
  });

  const payload = encodeArbitraryPayload(question, description, resolutionSource, resolutionTime);

  // Calculate value: protocol fee + resolution bond
  const protocolFee = BigInt(config.registry.fees.protocolFeeStandard);
  const resolutionBond = BigInt(config.registry.bonds.resolution.minAmount);
  const value = protocolFee + resolutionBond;

  console.log("📋 TOC Details:");
  console.log(`   Question: ${question}`);
  if (description) console.log(`   Description: ${description}`);
  if (resolutionSource) console.log(`   Source: ${resolutionSource}`);
  console.log(`   Resolution time: ${new Date(Number(resolutionTime) * 1000).toISOString()}`);
  console.log(`   Template: ARBITRARY (1)`);
  console.log(`   Resolver: ${addresses.optimisticResolver}`);
  console.log(`   TruthKeeper: ${addresses.truthKeeper}`);
  console.log(`   Protocol fee: ${formatEther(protocolFee)} ETH`);
  console.log(`   Resolution bond: ${formatEther(resolutionBond)} ETH`);
  console.log(`   Total value: ${formatEther(value)} ETH`);
  console.log(`   Time windows: dispute=${disputeWindow}s, tk=${truthKeeperWindow}s, escalation=${escalationWindow}s, post=${postResolutionWindow}s`);
  console.log();

  try {
    console.log("⏳ Sending transaction...");

    const hash = await walletClient.writeContract({
      address: addresses.registry,
      abi: REGISTRY_ABI,
      functionName: "createTOC",
      args: [
        addresses.optimisticResolver,
        TEMPLATE.ARBITRARY,
        payload,
        disputeWindow,
        truthKeeperWindow,
        escalationWindow,
        postResolutionWindow,
        addresses.truthKeeper,
      ],
      value,
    });

    console.log(`   Tx hash: ${hash}`);
    console.log("⏳ Waiting for confirmation...");

    const receipt = await publicClient.waitForTransactionReceipt({ hash });
    console.log(`   Block: ${receipt.blockNumber}`);

    const newTocId = currentCount + 1n;

    console.log("\n✅ TOC Created!");
    console.log(`   TOC ID: ${newTocId}`);
    console.log(`   Transaction: ${getExplorerTxUrl(network, hash)}`);
    console.log(`\n💡 Next steps:`);
    console.log(`   Query:   TOC_ID=${newTocId} npx hardhat run scripts/query-toc.ts --network ${network}`);
    console.log(`   Resolve: TOC_ID=${newTocId} npx hardhat run scripts/resolve-toc.ts --network ${network}`);

  } catch (error: any) {
    console.error("\n❌ Failed to create TOC:");
    console.error(error.shortMessage || error.message);
    if (error.cause?.reason) {
      console.error("Reason:", error.cause.reason);
    }
  }
}

main().catch(console.error);
