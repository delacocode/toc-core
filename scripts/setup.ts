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
import { getRegistryAbi, getTruthKeeperAbi } from "./lib/abis.js";

async function main() {
  const network = await getNetwork();
  const { chainId } = getChainConfig(network);
  const config = loadConfig(network);
  const addresses = loadDeployedAddresses(chainId);
  const { publicClient, walletClient, account } = createClients(network);
  const registryAbi = getRegistryAbi();
  const truthKeeperAbi = getTruthKeeperAbi();

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
    abi: registryAbi,
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
        abi: registryAbi,
        functionName: "addAcceptableResolutionBond",
        args: [bonds.resolution.token as `0x${string}`, BigInt(bonds.resolution.minAmount)],
      })
    );
  }

  // Check if dispute bond already set
  const disputeBondOk = await publicClient.readContract({
    address: addresses.registry,
    abi: registryAbi,
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
        abi: registryAbi,
        functionName: "addAcceptableDisputeBond",
        args: [bonds.dispute.token as `0x${string}`, BigInt(bonds.dispute.minAmount)],
      })
    );
  }

  // Check if escalation bond already set
  const escalationBondOk = await publicClient.readContract({
    address: addresses.registry,
    abi: registryAbi,
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
        abi: registryAbi,
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
    abi: registryAbi,
    functionName: "treasury",
  }) as string;
  if (currentTreasury.toLowerCase() === config.registry.treasury.toLowerCase()) {
    console.log(`   Treasury: ${config.registry.treasury}... ⏭️  Already set`);
  } else {
    await sendTx(
      `Treasury: ${config.registry.treasury}`,
      addresses.registry,
      encodeFunctionData({
        abi: registryAbi,
        functionName: "setTreasury",
        args: [config.registry.treasury as `0x${string}`],
      })
    );
  }

  // Check if protocol fee already set
  const currentFee = await publicClient.readContract({
    address: addresses.registry,
    abi: registryAbi,
    functionName: "protocolFeeStandard",
  }) as bigint;
  if (currentFee === BigInt(config.registry.fees.protocolFeeStandard)) {
    console.log(`   Protocol fee: ${formatEther(BigInt(config.registry.fees.protocolFeeStandard))} ETH... ⏭️  Already set`);
  } else {
    await sendTx(
      `Protocol fee: ${formatEther(BigInt(config.registry.fees.protocolFeeStandard))} ETH`,
      addresses.registry,
      encodeFunctionData({
        abi: registryAbi,
        functionName: "setProtocolFeeStandard",
        args: [BigInt(config.registry.fees.protocolFeeStandard)],
      })
    );
  }

  // 3. Whitelist TruthKeeper
  console.log("\n3️⃣  Whitelisting TruthKeeper...");

  const tkWhitelisted = await publicClient.readContract({
    address: addresses.registry,
    abi: registryAbi,
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
        abi: registryAbi,
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
        abi: registryAbi,
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
            abi: registryAbi,
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
      abi: truthKeeperAbi,
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
          abi: truthKeeperAbi,
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
