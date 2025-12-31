/**
 * Setup script - configures deployed contracts
 * Reads configuration from ignition/config/<network>.json
 *
 * Usage: npx hardhat run scripts/setup.ts --network <network>
 */

import { formatEther, encodeFunctionData } from "viem";
import {
  getNetwork,
  loadConfig,
  loadDeployedAddresses,
  getChainConfig,
  createClients,
} from "./lib/config.js";

// Minimal ABIs
const REGISTRY_ABI = [
  { name: "addAcceptableResolutionBond", type: "function", inputs: [{ name: "token", type: "address" }, { name: "minAmount", type: "uint256" }], outputs: [], stateMutability: "nonpayable" },
  { name: "addAcceptableDisputeBond", type: "function", inputs: [{ name: "token", type: "address" }, { name: "minAmount", type: "uint256" }], outputs: [], stateMutability: "nonpayable" },
  { name: "addAcceptableEscalationBond", type: "function", inputs: [{ name: "token", type: "address" }, { name: "minAmount", type: "uint256" }], outputs: [], stateMutability: "nonpayable" },
  { name: "addWhitelistedTruthKeeper", type: "function", inputs: [{ name: "tk", type: "address" }], outputs: [], stateMutability: "nonpayable" },
  { name: "setProtocolFeeStandard", type: "function", inputs: [{ name: "fee", type: "uint256" }], outputs: [], stateMutability: "nonpayable" },
  { name: "setTreasury", type: "function", inputs: [{ name: "treasury", type: "address" }], outputs: [], stateMutability: "nonpayable" },
  { name: "registerResolver", type: "function", inputs: [{ name: "resolver", type: "address" }], outputs: [], stateMutability: "nonpayable" },
] as const;

const TRUTH_KEEPER_ABI = [
  { name: "setResolverAllowed", type: "function", inputs: [{ name: "resolver", type: "address" }, { name: "allowed", type: "bool" }], outputs: [], stateMutability: "nonpayable" },
] as const;

async function main() {
  const network = getNetwork();
  const { chainId } = getChainConfig(network);
  const config = loadConfig(network);
  const addresses = loadDeployedAddresses(chainId);
  const { publicClient, walletClient, account } = createClients(network);

  console.log(`\n🔧 Setting up TOC System on ${network}\n`);
  console.log(`🔑 Account: ${account.address}\n`);

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

  // 1. Set bonds
  console.log("1️⃣  Setting bonds...");
  const { bonds } = config.registry;

  await sendTx(
    `Resolution bond: ${formatEther(BigInt(bonds.resolution.minAmount))} ETH`,
    addresses.registry,
    encodeFunctionData({
      abi: REGISTRY_ABI,
      functionName: "addAcceptableResolutionBond",
      args: [bonds.resolution.token as `0x${string}`, BigInt(bonds.resolution.minAmount)],
    })
  );

  await sendTx(
    `Dispute bond: ${formatEther(BigInt(bonds.dispute.minAmount))} ETH`,
    addresses.registry,
    encodeFunctionData({
      abi: REGISTRY_ABI,
      functionName: "addAcceptableDisputeBond",
      args: [bonds.dispute.token as `0x${string}`, BigInt(bonds.dispute.minAmount)],
    })
  );

  await sendTx(
    `Escalation bond: ${formatEther(BigInt(bonds.escalation.minAmount))} ETH`,
    addresses.registry,
    encodeFunctionData({
      abi: REGISTRY_ABI,
      functionName: "addAcceptableEscalationBond",
      args: [bonds.escalation.token as `0x${string}`, BigInt(bonds.escalation.minAmount)],
    })
  );

  // 2. Set treasury and fees
  console.log("\n2️⃣  Setting treasury & fees...");

  await sendTx(
    `Treasury: ${config.registry.treasury}`,
    addresses.registry,
    encodeFunctionData({
      abi: REGISTRY_ABI,
      functionName: "setTreasury",
      args: [config.registry.treasury as `0x${string}`],
    })
  );

  await sendTx(
    `Protocol fee: ${formatEther(BigInt(config.registry.fees.protocolFeeStandard))} ETH`,
    addresses.registry,
    encodeFunctionData({
      abi: REGISTRY_ABI,
      functionName: "setProtocolFeeStandard",
      args: [BigInt(config.registry.fees.protocolFeeStandard)],
    })
  );

  // 3. Whitelist TruthKeeper
  console.log("\n3️⃣  Whitelisting TruthKeeper...");

  await sendTx(
    `TruthKeeper: ${addresses.truthKeeper}`,
    addresses.registry,
    encodeFunctionData({
      abi: REGISTRY_ABI,
      functionName: "addWhitelistedTruthKeeper",
      args: [addresses.truthKeeper],
    })
  );

  // 4. Register resolvers
  console.log("\n4️⃣  Registering resolvers...");

  const resolverAddresses: Record<string, `0x${string}`> = {
    OptimisticResolver: addresses.optimisticResolver,
    PythPriceResolver: addresses.pythResolver,
  };

  for (const [name, resolverConfig] of Object.entries(config.resolvers)) {
    const address = resolverAddresses[name];
    if (!address) continue;

    if (resolverConfig.register) {
      await sendTx(
        `Register ${name}`,
        addresses.registry,
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
      addresses.truthKeeper,
      encodeFunctionData({
        abi: TRUTH_KEEPER_ABI,
        functionName: "setResolverAllowed",
        args: [address, true],
      })
    );
  }

  console.log("\n✅ Setup complete!\n");
  console.log("📋 Configuration Summary:");
  console.log(`   Network:         ${network}`);
  console.log(`   Resolution bond: ${formatEther(BigInt(bonds.resolution.minAmount))} ETH`);
  console.log(`   Dispute bond:    ${formatEther(BigInt(bonds.dispute.minAmount))} ETH`);
  console.log(`   Escalation bond: ${formatEther(BigInt(bonds.escalation.minAmount))} ETH`);
  console.log(`   Protocol fee:    ${formatEther(BigInt(config.registry.fees.protocolFeeStandard))} ETH`);
  console.log(`   Treasury:        ${config.registry.treasury}`);
  console.log();
}

main().catch(console.error);
