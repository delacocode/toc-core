/**
 * Setup script for Sepolia deployment
 * Reads configuration from ignition/config/sepolia.json
 *
 * Usage: npx hardhat run scripts/sepolia/setup.ts --network sepolia
 */

import { createPublicClient, createWalletClient, http, formatEther, encodeFunctionData } from "viem";
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
  pythResolver: deployed["PythPriceResolver#PythPriceResolver"] as `0x${string}`,
  truthKeeper: deployed["SimpleTruthKeeper#SimpleTruthKeeper"] as `0x${string}`,
};

// Minimal ABIs
const REGISTRY_ABI = [
  { name: "addAcceptableResolutionBond", type: "function", inputs: [{ name: "token", type: "address" }, { name: "minAmount", type: "uint256" }], outputs: [], stateMutability: "nonpayable" },
  { name: "addAcceptableDisputeBond", type: "function", inputs: [{ name: "token", type: "address" }, { name: "minAmount", type: "uint256" }], outputs: [], stateMutability: "nonpayable" },
  { name: "addAcceptableEscalationBond", type: "function", inputs: [{ name: "token", type: "address" }, { name: "minAmount", type: "uint256" }], outputs: [], stateMutability: "nonpayable" },
  { name: "addWhitelistedTruthKeeper", type: "function", inputs: [{ name: "tk", type: "address" }], outputs: [], stateMutability: "nonpayable" },
  { name: "setProtocolFeeStandard", type: "function", inputs: [{ name: "fee", type: "uint256" }], outputs: [], stateMutability: "nonpayable" },
  { name: "setTreasury", type: "function", inputs: [{ name: "treasury", type: "address" }], outputs: [], stateMutability: "nonpayable" },
  { name: "registerResolver", type: "function", inputs: [{ name: "resolver", type: "address" }], outputs: [], stateMutability: "nonpayable" },
  { name: "owner", type: "function", inputs: [], outputs: [{ type: "address" }], stateMutability: "view" },
] as const;

const TRUTH_KEEPER_ABI = [
  { name: "setResolverAllowed", type: "function", inputs: [{ name: "resolver", type: "address" }, { name: "allowed", type: "bool" }], outputs: [], stateMutability: "nonpayable" },
] as const;

async function main() {
  console.log("\n🔧 Setting up TOC System on Sepolia\n");
  console.log(`📄 Config: ${configPath}\n`);

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

  // Helper to send tx
  async function sendTx(description: string, to: `0x${string}`, data: `0x${string}`) {
    process.stdout.write(`   ${description}...`);
    try {
      const hash = await walletClient.sendTransaction({ to, data });
      await publicClient.waitForTransactionReceipt({ hash });
      console.log(` ✅ ${hash.slice(0, 18)}...`);
      return hash;
    } catch (error: any) {
      if (error.message?.includes("already") || error.message?.includes("exists")) {
        console.log(" ⏭️  Already done");
        return null;
      }
      console.log(` ❌ Failed: ${error.shortMessage || error.message}`);
      throw error;
    }
  }

  // 1. Set bonds from config
  console.log("1️⃣  Setting bonds...");
  const { bonds } = config.registry;

  await sendTx(
    `Resolution bond: ${formatEther(BigInt(bonds.resolution.minAmount))} ETH`,
    ADDRESSES.registry,
    encodeFunctionData({
      abi: REGISTRY_ABI,
      functionName: "addAcceptableResolutionBond",
      args: [bonds.resolution.token as `0x${string}`, BigInt(bonds.resolution.minAmount)],
    })
  );

  await sendTx(
    `Dispute bond: ${formatEther(BigInt(bonds.dispute.minAmount))} ETH`,
    ADDRESSES.registry,
    encodeFunctionData({
      abi: REGISTRY_ABI,
      functionName: "addAcceptableDisputeBond",
      args: [bonds.dispute.token as `0x${string}`, BigInt(bonds.dispute.minAmount)],
    })
  );

  await sendTx(
    `Escalation bond: ${formatEther(BigInt(bonds.escalation.minAmount))} ETH`,
    ADDRESSES.registry,
    encodeFunctionData({
      abi: REGISTRY_ABI,
      functionName: "addAcceptableEscalationBond",
      args: [bonds.escalation.token as `0x${string}`, BigInt(bonds.escalation.minAmount)],
    })
  );

  // 2. Set treasury and fees from config
  console.log("\n2️⃣  Setting treasury & fees...");

  await sendTx(
    `Treasury: ${config.registry.treasury}`,
    ADDRESSES.registry,
    encodeFunctionData({
      abi: REGISTRY_ABI,
      functionName: "setTreasury",
      args: [config.registry.treasury as `0x${string}`],
    })
  );

  await sendTx(
    `Protocol fee: ${formatEther(BigInt(config.registry.fees.protocolFeeStandard))} ETH`,
    ADDRESSES.registry,
    encodeFunctionData({
      abi: REGISTRY_ABI,
      functionName: "setProtocolFeeStandard",
      args: [BigInt(config.registry.fees.protocolFeeStandard)],
    })
  );

  // 3. Whitelist TruthKeeper
  console.log("\n3️⃣  Whitelisting TruthKeeper...");

  await sendTx(
    `TruthKeeper: ${ADDRESSES.truthKeeper}`,
    ADDRESSES.registry,
    encodeFunctionData({
      abi: REGISTRY_ABI,
      functionName: "addWhitelistedTruthKeeper",
      args: [ADDRESSES.truthKeeper],
    })
  );

  // 4. Register resolvers
  console.log("\n4️⃣  Registering resolvers...");

  const resolverAddresses: Record<string, `0x${string}`> = {
    OptimisticResolver: ADDRESSES.optimisticResolver,
    PythPriceResolver: ADDRESSES.pythResolver,
  };

  for (const [name, resolverConfig] of Object.entries(config.resolvers)) {
    const address = resolverAddresses[name];
    if (!address) continue;

    if ((resolverConfig as any).register) {
      await sendTx(
        `Register ${name}`,
        ADDRESSES.registry,
        encodeFunctionData({
          abi: REGISTRY_ABI,
          functionName: "registerResolver",
          args: [address],
        })
      );
    }
  }

  // 5. Allow resolvers in TruthKeeper
  console.log("\n5️⃣  Allowing resolvers in TruthKeeper...");

  for (const resolverName of config.truthKeeper.allowedResolvers) {
    const address = resolverAddresses[resolverName];
    if (!address) continue;

    await sendTx(
      `Allow ${resolverName}`,
      ADDRESSES.truthKeeper,
      encodeFunctionData({
        abi: TRUTH_KEEPER_ABI,
        functionName: "setResolverAllowed",
        args: [address, true],
      })
    );
  }

  console.log("\n✅ Setup complete!\n");
  console.log("📋 Configuration Summary:");
  console.log(`   Resolution bond: ${formatEther(BigInt(bonds.resolution.minAmount))} ETH`);
  console.log(`   Dispute bond:    ${formatEther(BigInt(bonds.dispute.minAmount))} ETH`);
  console.log(`   Escalation bond: ${formatEther(BigInt(bonds.escalation.minAmount))} ETH`);
  console.log(`   Protocol fee:    ${formatEther(BigInt(config.registry.fees.protocolFeeStandard))} ETH`);
  console.log(`   Treasury:        ${config.registry.treasury}`);
  console.log();
  console.log("📋 Deployed Addresses:");
  console.log(`   Registry:           ${ADDRESSES.registry}`);
  console.log(`   OptimisticResolver: ${ADDRESSES.optimisticResolver}`);
  console.log(`   PythResolver:       ${ADDRESSES.pythResolver}`);
  console.log(`   TruthKeeper:        ${ADDRESSES.truthKeeper}`);
  console.log();
}

main().catch(console.error);
