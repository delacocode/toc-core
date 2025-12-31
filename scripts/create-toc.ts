/**
 * Create a TOC on any supported network
 *
 * Usage: npx hardhat run scripts/create-toc.ts --network <network>
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
  const network = getNetwork();
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

  // Create an arbitrary question
  const question = "Will ETH be above $5000 on January 1st, 2026?";
  const description = "This question resolves YES if the price of ETH is above $5000 USD at any point on January 1st, 2026 according to CoinGecko.";
  const resolutionSource = "https://www.coingecko.com/en/coins/ethereum";
  const resolutionTime = BigInt(Math.floor(Date.now() / 1000) + 86400 * 365); // 1 year from now

  const payload = encodeArbitraryPayload(question, description, resolutionSource, resolutionTime);

  // Time windows (in seconds) - short for testing
  const disputeWindow = 300n; // 5 minutes
  const truthKeeperWindow = 300n;
  const escalationWindow = 300n;
  const postResolutionWindow = 300n;

  // Calculate value: protocol fee + resolution bond
  const protocolFee = BigInt(config.registry.fees.protocolFeeStandard);
  const resolutionBond = BigInt(config.registry.bonds.resolution.minAmount);
  const value = protocolFee + resolutionBond;

  console.log("📋 TOC Details:");
  console.log(`   Question: ${question}`);
  console.log(`   Template: ARBITRARY (1)`);
  console.log(`   Resolver: ${addresses.optimisticResolver}`);
  console.log(`   TruthKeeper: ${addresses.truthKeeper}`);
  console.log(`   Protocol fee: ${formatEther(protocolFee)} ETH`);
  console.log(`   Resolution bond: ${formatEther(resolutionBond)} ETH`);
  console.log(`   Total value: ${formatEther(value)} ETH`);
  console.log(`   Time windows: 5 minutes each (for testing)`);
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
    console.log(`\n💡 Next: TOC_ID=${newTocId} npx hardhat run scripts/resolve-toc.ts --network ${network}`);

  } catch (error: any) {
    console.error("\n❌ Failed to create TOC:");
    console.error(error.shortMessage || error.message);
    if (error.cause?.reason) {
      console.error("Reason:", error.cause.reason);
    }
  }
}

main().catch(console.error);
