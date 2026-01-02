/**
 * Create a Pyth-based TOC on any supported network
 *
 * Usage: npx hardhat run scripts/create-pyth-toc.ts --network <network>
 *
 * Environment variables:
 *   ASSET            - Asset pair (required: BTC/USD, ETH/USD, SOL/USD, etc.)
 *   TEMPLATE         - Template type: snapshot, range, reached_by (default: snapshot)
 *   THRESHOLD        - Price threshold in USD (for snapshot/reached_by)
 *   DIRECTION        - For snapshot/reached_by: "above" or "below" (default: above)
 *   LOWER            - Lower bound in USD (for range template)
 *   UPPER            - Upper bound in USD (for range template)
 *   DEADLINE         - Unix timestamp or "+Xm/+Xh/+Xd" format (default: +1h)
 *   PRICE_ID         - Custom Pyth price ID (overrides ASSET)
 *
 * Examples:
 *   # Will BTC be above $100k in 1 hour?
 *   ASSET=BTC/USD THRESHOLD=100000 DIRECTION=above DEADLINE=+1h \
 *     npx hardhat run scripts/create-pyth-toc.ts --network sepolia
 *
 *   # Will ETH be between $3000-$4000 in 30 minutes?
 *   ASSET=ETH/USD TEMPLATE=range LOWER=3000 UPPER=4000 DEADLINE=+30m \
 *     npx hardhat run scripts/create-pyth-toc.ts --network sepolia
 *
 *   # Will BTC reach $150k before end of year?
 *   ASSET=BTC/USD TEMPLATE=reached_by THRESHOLD=150000 DEADLINE=1735689600 \
 *     npx hardhat run scripts/create-pyth-toc.ts --network sepolia
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
import {
  PYTH_TEMPLATE,
  PYTH_PRICE_IDS,
  encodeSnapshotPayload,
  encodeRangePayload,
  encodeReachedByPayload,
  usdToPythPrice,
} from "./lib/payloads.js";
import { getRegistryAbi } from "./lib/abis.js";

// Parse deadline from various formats
function parseDeadline(deadlineStr: string): bigint {
  const now = Math.floor(Date.now() / 1000);

  // Relative format: +30m, +1h, +2d
  if (deadlineStr.startsWith("+")) {
    const value = parseInt(deadlineStr.slice(1, -1));
    const unit = deadlineStr.slice(-1);

    let seconds: number;
    switch (unit) {
      case "m":
        seconds = value * 60;
        break;
      case "h":
        seconds = value * 3600;
        break;
      case "d":
        seconds = value * 86400;
        break;
      default:
        throw new Error(`Unknown time unit: ${unit}. Use m (minutes), h (hours), or d (days)`);
    }
    return BigInt(now + seconds);
  }

  // Absolute timestamp
  return BigInt(deadlineStr);
}

async function main() {
  const asset = process.env.ASSET;
  const template = (process.env.TEMPLATE || "snapshot").toLowerCase();

  // Get price ID
  let priceId = process.env.PRICE_ID;
  if (!priceId) {
    if (!asset) {
      console.error("Error: ASSET or PRICE_ID environment variable is required");
      console.error("\nUsage:");
      console.error('  ASSET=BTC/USD THRESHOLD=100000 npx hardhat run scripts/create-pyth-toc.ts --network sepolia');
      console.error("\nSupported assets:", Object.keys(PYTH_PRICE_IDS).join(", "));
      console.error("Or provide a custom PRICE_ID for other assets.");
      console.error("\nTemplates:");
      console.error("  snapshot   - Is price above/below threshold at deadline? (default)");
      console.error("  range      - Is price within range at deadline?");
      console.error("  reached_by - Did price reach target before deadline?");
      process.exit(1);
    }
    priceId = PYTH_PRICE_IDS[asset as keyof typeof PYTH_PRICE_IDS];
    if (!priceId) {
      console.error(`Unknown asset: ${asset}`);
      console.error("Supported assets:", Object.keys(PYTH_PRICE_IDS).join(", "));
      console.error("Or provide a custom PRICE_ID.");
      process.exit(1);
    }
  }

  // Parse deadline
  const deadlineStr = process.env.DEADLINE || "+1h";
  const deadline = parseDeadline(deadlineStr);

  // Build template-specific payload
  let templateId: number;
  let payload: `0x${string}`;
  let questionDesc: string;

  if (template === "snapshot") {
    const threshold = process.env.THRESHOLD;
    if (!threshold) {
      console.error("Error: THRESHOLD is required for snapshot template");
      process.exit(1);
    }
    const direction = (process.env.DIRECTION || "above").toLowerCase();
    const isAbove = direction === "above";

    templateId = PYTH_TEMPLATE.SNAPSHOT;
    payload = encodeSnapshotPayload({
      priceId: priceId as `0x${string}`,
      threshold: usdToPythPrice(parseFloat(threshold)),
      isAbove,
      deadline,
    });
    questionDesc = `Will ${asset || "price"} be ${direction} $${threshold} at deadline?`;
  } else if (template === "range") {
    const lower = process.env.LOWER;
    const upper = process.env.UPPER;
    if (!lower || !upper) {
      console.error("Error: LOWER and UPPER are required for range template");
      process.exit(1);
    }

    templateId = PYTH_TEMPLATE.RANGE;
    payload = encodeRangePayload({
      priceId: priceId as `0x${string}`,
      lowerBound: usdToPythPrice(parseFloat(lower)),
      upperBound: usdToPythPrice(parseFloat(upper)),
      deadline,
    });
    questionDesc = `Will ${asset || "price"} be between $${lower} and $${upper} at deadline?`;
  } else if (template === "reached_by") {
    const threshold = process.env.THRESHOLD;
    if (!threshold) {
      console.error("Error: THRESHOLD is required for reached_by template");
      process.exit(1);
    }
    const direction = (process.env.DIRECTION || "above").toLowerCase();
    const isAbove = direction === "above";

    templateId = PYTH_TEMPLATE.REACHED_BY;
    payload = encodeReachedByPayload({
      priceId: priceId as `0x${string}`,
      targetPrice: usdToPythPrice(parseFloat(threshold)),
      isAbove,
      deadline,
    });
    questionDesc = `Will ${asset || "price"} reach ${direction} $${threshold} before deadline?`;
  } else {
    console.error(`Unknown template: ${template}`);
    console.error("Valid templates: snapshot, range, reached_by");
    process.exit(1);
  }

  const network = await getNetwork();
  const { chainId } = getChainConfig(network);
  const config = loadConfig(network);
  const addresses = loadDeployedAddresses(chainId);
  const { publicClient, walletClient, account } = createClients(network);
  const abi = getRegistryAbi();

  console.log(`\n📝 Creating Pyth TOC on ${network}\n`);
  console.log(`🔑 Account: ${account.address}\n`);

  // Get next TOC ID
  const nextId = await publicClient.readContract({
    address: addresses.registry,
    abi,
    functionName: "nextTocId",
  });

  // Pyth TOCs go directly to ACTIVE, no bonds needed for creation
  const protocolFee = BigInt(config.registry.fees.protocolFeeStandard);
  const value = protocolFee;

  // Use short time windows for testing
  const disputeWindow = BigInt(process.env.DISPUTE_WINDOW || "300");
  const truthKeeperWindow = BigInt(process.env.TK_WINDOW || "300");
  const escalationWindow = BigInt(process.env.ESCALATION_WINDOW || "300");
  const postResolutionWindow = BigInt(process.env.POST_RESOLUTION_WINDOW || "300");

  console.log("📋 TOC Details:");
  console.log(`   Question: ${questionDesc}`);
  console.log(`   Asset: ${asset || "(custom price ID)"}`);
  console.log(`   Price ID: ${priceId.slice(0, 10)}...${priceId.slice(-8)}`);
  console.log(`   Template: ${template.toUpperCase()} (${templateId})`);
  console.log(`   Deadline: ${new Date(Number(deadline) * 1000).toLocaleString()}`);
  console.log(`   Resolver: ${addresses.pythResolver}`);
  console.log(`   TruthKeeper: ${addresses.truthKeeper}`);
  console.log(`   Protocol fee: ${formatEther(protocolFee)} ETH`);
  console.log();

  try {
    console.log("⏳ Sending transaction...");

    const hash = await walletClient.writeContract({
      address: addresses.registry,
      abi,
      functionName: "createTOC",
      args: [
        addresses.pythResolver,
        templateId,
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

    const newTocId = nextId;

    console.log("\n✅ Pyth TOC Created!");
    console.log(`   TOC ID: ${newTocId}`);
    console.log(`   State: ACTIVE (Pyth TOCs are immediately active)`);
    console.log(`   Transaction: ${getExplorerTxUrl(network, hash)}`);
    console.log(`\n💡 Next steps:`);
    console.log(`   Query:   TOC_ID=${newTocId} npx hardhat run scripts/query-toc.ts --network ${network}`);
    console.log(`   Resolve: TOC_ID=${newTocId} npx hardhat run scripts/resolve-pyth-toc.ts --network ${network}`);
    console.log(`   (Resolution requires Pyth price update data from Hermes API)`);

  } catch (error: any) {
    console.error("\n❌ Failed to create TOC:");
    console.error(error.shortMessage || error.message);
    if (error.cause?.reason) {
      console.error("Reason:", error.cause.reason);
    }
  }
}

main().catch(console.error);
