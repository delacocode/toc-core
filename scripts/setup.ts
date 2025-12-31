/**
 * Setup script - configures deployed contracts (idempotent)
 * Reads configuration from ignition/config/<network>.json
 * Checks state before sending transactions to avoid duplicates
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

// Minimal ABIs with view functions for idempotency checks
const REGISTRY_ABI = [
  // Write functions
  { name: "addAcceptableResolutionBond", type: "function", inputs: [{ name: "token", type: "address" }, { name: "minAmount", type: "uint256" }], outputs: [], stateMutability: "nonpayable" },
  { name: "addAcceptableDisputeBond", type: "function", inputs: [{ name: "token", type: "address" }, { name: "minAmount", type: "uint256" }], outputs: [], stateMutability: "nonpayable" },
  { name: "addAcceptableEscalationBond", type: "function", inputs: [{ name: "token", type: "address" }, { name: "minAmount", type: "uint256" }], outputs: [], stateMutability: "nonpayable" },
  { name: "addWhitelistedTruthKeeper", type: "function", inputs: [{ name: "tk", type: "address" }], outputs: [], stateMutability: "nonpayable" },
  { name: "setProtocolFeeStandard", type: "function", inputs: [{ name: "fee", type: "uint256" }], outputs: [], stateMutability: "nonpayable" },
  { name: "setTreasury", type: "function", inputs: [{ name: "treasury", type: "address" }], outputs: [], stateMutability: "nonpayable" },
  { name: "registerResolver", type: "function", inputs: [{ name: "resolver", type: "address" }], outputs: [], stateMutability: "nonpayable" },
  // View functions for idempotency
  { name: "isAcceptableResolutionBond", type: "function", inputs: [{ name: "token", type: "address" }, { name: "amount", type: "uint256" }], outputs: [{ name: "", type: "bool" }], stateMutability: "view" },
  { name: "isAcceptableDisputeBond", type: "function", inputs: [{ name: "token", type: "address" }, { name: "amount", type: "uint256" }], outputs: [{ name: "", type: "bool" }], stateMutability: "view" },
  { name: "isAcceptableEscalationBond", type: "function", inputs: [{ name: "token", type: "address" }, { name: "amount", type: "uint256" }], outputs: [{ name: "", type: "bool" }], stateMutability: "view" },
  { name: "isWhitelistedTruthKeeper", type: "function", inputs: [{ name: "tk", type: "address" }], outputs: [{ name: "", type: "bool" }], stateMutability: "view" },
  { name: "isRegisteredResolver", type: "function", inputs: [{ name: "resolver", type: "address" }], outputs: [{ name: "", type: "bool" }], stateMutability: "view" },
  { name: "treasury", type: "function", inputs: [], outputs: [{ name: "", type: "address" }], stateMutability: "view" },
  { name: "protocolFeeStandard", type: "function", inputs: [], outputs: [{ name: "", type: "uint256" }], stateMutability: "view" },
] as const;

const TRUTH_KEEPER_ABI = [
  { name: "setResolverAllowed", type: "function", inputs: [{ name: "resolver", type: "address" }, { name: "allowed", type: "bool" }], outputs: [], stateMutability: "nonpayable" },
  { name: "allowedResolvers", type: "function", inputs: [{ name: "resolver", type: "address" }], outputs: [{ name: "", type: "bool" }], stateMutability: "view" },
] as const;

async function main() {
  const network = await getNetwork();
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
      console.log(` ❌ Failed: ${error.shortMessage || error.message}`);
      throw error;
    }
  }

  // 1. Set bonds
  console.log("1️⃣  Setting bonds...");
  const { bonds } = config.registry;

  // Check if resolution bond already set
  const resolutionBondOk = await publicClient.readContract({
    address: addresses.registry,
    abi: REGISTRY_ABI,
    functionName: "isAcceptableResolutionBond",
    args: [bonds.resolution.token as `0x${string}`, BigInt(bonds.resolution.minAmount)],
  });
  if (resolutionBondOk) {
    console.log(`   Resolution bond: ${formatEther(BigInt(bonds.resolution.minAmount))} ETH... ⏭️  Already set`);
  } else {
    await sendTx(
      `Resolution bond: ${formatEther(BigInt(bonds.resolution.minAmount))} ETH`,
      addresses.registry,
      encodeFunctionData({
        abi: REGISTRY_ABI,
        functionName: "addAcceptableResolutionBond",
        args: [bonds.resolution.token as `0x${string}`, BigInt(bonds.resolution.minAmount)],
      })
    );
  }

  // Check if dispute bond already set
  const disputeBondOk = await publicClient.readContract({
    address: addresses.registry,
    abi: REGISTRY_ABI,
    functionName: "isAcceptableDisputeBond",
    args: [bonds.dispute.token as `0x${string}`, BigInt(bonds.dispute.minAmount)],
  });
  if (disputeBondOk) {
    console.log(`   Dispute bond: ${formatEther(BigInt(bonds.dispute.minAmount))} ETH... ⏭️  Already set`);
  } else {
    await sendTx(
      `Dispute bond: ${formatEther(BigInt(bonds.dispute.minAmount))} ETH`,
      addresses.registry,
      encodeFunctionData({
        abi: REGISTRY_ABI,
        functionName: "addAcceptableDisputeBond",
        args: [bonds.dispute.token as `0x${string}`, BigInt(bonds.dispute.minAmount)],
      })
    );
  }

  // Check if escalation bond already set
  const escalationBondOk = await publicClient.readContract({
    address: addresses.registry,
    abi: REGISTRY_ABI,
    functionName: "isAcceptableEscalationBond",
    args: [bonds.escalation.token as `0x${string}`, BigInt(bonds.escalation.minAmount)],
  });
  if (escalationBondOk) {
    console.log(`   Escalation bond: ${formatEther(BigInt(bonds.escalation.minAmount))} ETH... ⏭️  Already set`);
  } else {
    await sendTx(
      `Escalation bond: ${formatEther(BigInt(bonds.escalation.minAmount))} ETH`,
      addresses.registry,
      encodeFunctionData({
        abi: REGISTRY_ABI,
        functionName: "addAcceptableEscalationBond",
        args: [bonds.escalation.token as `0x${string}`, BigInt(bonds.escalation.minAmount)],
      })
    );
  }

  // 2. Set treasury and fees
  console.log("\n2️⃣  Setting treasury & fees...");

  // Check if treasury already set
  const currentTreasury = await publicClient.readContract({
    address: addresses.registry,
    abi: REGISTRY_ABI,
    functionName: "treasury",
  });
  if (currentTreasury.toLowerCase() === config.registry.treasury.toLowerCase()) {
    console.log(`   Treasury: ${config.registry.treasury}... ⏭️  Already set`);
  } else {
    await sendTx(
      `Treasury: ${config.registry.treasury}`,
      addresses.registry,
      encodeFunctionData({
        abi: REGISTRY_ABI,
        functionName: "setTreasury",
        args: [config.registry.treasury as `0x${string}`],
      })
    );
  }

  // Check if protocol fee already set
  const currentFee = await publicClient.readContract({
    address: addresses.registry,
    abi: REGISTRY_ABI,
    functionName: "protocolFeeStandard",
  });
  if (currentFee === BigInt(config.registry.fees.protocolFeeStandard)) {
    console.log(`   Protocol fee: ${formatEther(BigInt(config.registry.fees.protocolFeeStandard))} ETH... ⏭️  Already set`);
  } else {
    await sendTx(
      `Protocol fee: ${formatEther(BigInt(config.registry.fees.protocolFeeStandard))} ETH`,
      addresses.registry,
      encodeFunctionData({
        abi: REGISTRY_ABI,
        functionName: "setProtocolFeeStandard",
        args: [BigInt(config.registry.fees.protocolFeeStandard)],
      })
    );
  }

  // 3. Whitelist TruthKeeper
  console.log("\n3️⃣  Whitelisting TruthKeeper...");

  const tkWhitelisted = await publicClient.readContract({
    address: addresses.registry,
    abi: REGISTRY_ABI,
    functionName: "isWhitelistedTruthKeeper",
    args: [addresses.truthKeeper],
  });
  if (tkWhitelisted) {
    console.log(`   TruthKeeper: ${addresses.truthKeeper}... ⏭️  Already whitelisted`);
  } else {
    await sendTx(
      `TruthKeeper: ${addresses.truthKeeper}`,
      addresses.registry,
      encodeFunctionData({
        abi: REGISTRY_ABI,
        functionName: "addWhitelistedTruthKeeper",
        args: [addresses.truthKeeper],
      })
    );
  }

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
      const isRegistered = await publicClient.readContract({
        address: addresses.registry,
        abi: REGISTRY_ABI,
        functionName: "isRegisteredResolver",
        args: [address],
      });
      if (isRegistered) {
        console.log(`   Register ${name}... ⏭️  Already registered`);
      } else {
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
  }

  // 5. Allow resolvers in TruthKeeper
  console.log("\n5️⃣  Allowing resolvers in TruthKeeper...");

  for (const resolverName of config.truthKeeper.allowedResolvers) {
    const address = resolverAddresses[resolverName];
    if (!address) continue;

    const isAllowed = await publicClient.readContract({
      address: addresses.truthKeeper,
      abi: TRUTH_KEEPER_ABI,
      functionName: "allowedResolvers",
      args: [address],
    });
    if (isAllowed) {
      console.log(`   Allow ${resolverName}... ⏭️  Already allowed`);
    } else {
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
