/**
 * Post-Deployment Configuration Script
 *
 * Configures the TOC system after deployment:
 * - Sets bond requirements
 * - Configures fees
 * - Whitelists TruthKeeper
 * - Registers resolvers
 * - Allows resolvers in TruthKeeper
 *
 * Usage:
 *   npx hardhat run scripts/configure-deployment.ts --network sepolia
 */

import { network } from "hardhat";
import { createPublicClient, createWalletClient, http, parseEther, formatEther } from "viem";
import { mnemonicToAccount } from "viem/accounts";
import { sepolia, arbitrum, polygon, base, bsc } from "viem/chains";
import * as fs from "fs";
import * as path from "path";

// Contract ABIs (minimal for configuration)
const REGISTRY_ABI = [
  "function addAcceptableResolutionBond(address token, uint256 minAmount) external",
  "function addAcceptableDisputeBond(address token, uint256 minAmount) external",
  "function addAcceptableEscalationBond(address token, uint256 minAmount) external",
  "function addWhitelistedTruthKeeper(address tk) external",
  "function setProtocolFeeStandard(uint256 fee) external",
  "function setTKSharePercent(uint8 tier, uint256 basisPoints) external",
  "function setTreasury(address treasury) external",
  "function registerResolver(address resolver) external",
  "function setResolverTrust(address resolver, uint8 trust) external",
  "function owner() view returns (address)",
  "function treasury() view returns (address)",
] as const;

const TRUTH_KEEPER_ABI = [
  "function setResolverAllowed(address resolver, bool allowed) external",
  "function setResolversAllowed(address[] resolvers, bool allowed) external",
  "function owner() view returns (address)",
  "function allowedResolvers(address) view returns (bool)",
] as const;

// Trust levels
const ResolverTrust = {
  NONE: 0,
  RESOLVER: 1,
  VERIFIED: 2,
  SYSTEM: 3,
} as const;

// Accountability tiers
const AccountabilityTier = {
  RESOLVER: 0,
  TK_GUARANTEED: 1,
  SYSTEM: 2,
} as const;

// Chain mapping
const chains: Record<string, typeof sepolia> = {
  sepolia,
  arbitrum,
  polygon,
  base,
  bsc,
};

interface DeployedAddresses {
  "TOCRegistry#TOCRegistry": string;
  "OptimisticResolver#OptimisticResolver": string;
  "PythPriceResolver#PythPriceResolver"?: string;
  "SimpleTruthKeeper#SimpleTruthKeeper": string;
}

interface Config {
  network: string;
  chainId: number;
  registry: {
    bonds: {
      resolution: { token: string; minAmount: string };
      dispute: { token: string; minAmount: string };
      escalation: { token: string; minAmount: string };
    };
    fees: {
      protocolFeeStandard: string;
      tkSharePercent: {
        TK_GUARANTEED: number;
        SYSTEM: number;
      };
    };
    treasury: string;
  };
  truthKeeper: {
    owner: string;
    minDisputeWindow: number;
    minTruthKeeperWindow: number;
    allowedResolvers: string[];
  };
  resolvers: Record<string, { register: boolean; trust: keyof typeof ResolverTrust }>;
  pyth: {
    address: string;
  };
}

async function main() {
  const networkName = network.name;
  console.log(`\n🔧 Configuring TOC System on ${networkName}\n`);

  // Load config
  const configPath = path.join(__dirname, `../ignition/config/${networkName}.json`);
  if (!fs.existsSync(configPath)) {
    throw new Error(`Config file not found: ${configPath}`);
  }
  const config: Config = JSON.parse(fs.readFileSync(configPath, "utf-8"));

  // Load deployed addresses
  const deploymentPath = path.join(
    __dirname,
    `../ignition/deployments/chain-${config.chainId}/deployed_addresses.json`
  );
  if (!fs.existsSync(deploymentPath)) {
    throw new Error(`Deployment not found: ${deploymentPath}\nRun deployment first: npx hardhat ignition deploy ignition/modules/TOCSystem.ts --network ${networkName}`);
  }
  const deployed: DeployedAddresses = JSON.parse(fs.readFileSync(deploymentPath, "utf-8"));

  console.log("📋 Deployed Addresses:");
  console.log(`   Registry:        ${deployed["TOCRegistry#TOCRegistry"]}`);
  console.log(`   OptimisticResolver: ${deployed["OptimisticResolver#OptimisticResolver"]}`);
  if (deployed["PythPriceResolver#PythPriceResolver"]) {
    console.log(`   PythResolver:    ${deployed["PythPriceResolver#PythPriceResolver"]}`);
  }
  console.log(`   TruthKeeper:     ${deployed["SimpleTruthKeeper#SimpleTruthKeeper"]}`);
  console.log();

  // Validate config
  if (config.registry.treasury === "0xYOUR_TREASURY_ADDRESS") {
    throw new Error("Please set treasury address in config file");
  }
  if (config.truthKeeper.owner === "0xYOUR_OWNER_ADDRESS") {
    throw new Error("Please set truthKeeper owner address in config file");
  }

  // Setup clients
  const chain = chains[networkName];
  if (!chain) {
    throw new Error(`Unsupported network: ${networkName}`);
  }

  const mnemonic = process.env.MNEMONIC;
  if (!mnemonic) {
    throw new Error("MNEMONIC environment variable not set");
  }

  const account = mnemonicToAccount(mnemonic);
  const rpcUrl = (network.config as any).url;

  const publicClient = createPublicClient({
    chain,
    transport: http(rpcUrl),
  });

  const walletClient = createWalletClient({
    account,
    chain,
    transport: http(rpcUrl),
  });

  console.log(`🔑 Deployer: ${account.address}\n`);

  const registryAddress = deployed["TOCRegistry#TOCRegistry"] as `0x${string}`;
  const truthKeeperAddress = deployed["SimpleTruthKeeper#SimpleTruthKeeper"] as `0x${string}`;
  const optimisticResolverAddress = deployed["OptimisticResolver#OptimisticResolver"] as `0x${string}`;
  const pythResolverAddress = deployed["PythPriceResolver#PythPriceResolver"] as `0x${string}` | undefined;

  // Helper to send tx
  async function sendTx(description: string, to: `0x${string}`, data: `0x${string}`) {
    process.stdout.write(`   ${description}...`);
    try {
      const hash = await walletClient.sendTransaction({ to, data });
      await publicClient.waitForTransactionReceipt({ hash });
      console.log(` ✅ ${hash.slice(0, 10)}...`);
      return hash;
    } catch (error: any) {
      if (error.message?.includes("already")) {
        console.log(" ⏭️  Already configured");
        return null;
      }
      console.log(` ❌ Failed`);
      throw error;
    }
  }

  // Import viem's encodeFunctionData
  const { encodeFunctionData } = await import("viem");

  // 1. Configure Registry Bonds
  console.log("1️⃣  Configuring bonds...");

  await sendTx(
    `Resolution bond: ${formatEther(BigInt(config.registry.bonds.resolution.minAmount))} ETH`,
    registryAddress,
    encodeFunctionData({
      abi: [{ name: "addAcceptableResolutionBond", type: "function", inputs: [{ name: "token", type: "address" }, { name: "minAmount", type: "uint256" }], outputs: [], stateMutability: "nonpayable" }],
      functionName: "addAcceptableResolutionBond",
      args: [config.registry.bonds.resolution.token as `0x${string}`, BigInt(config.registry.bonds.resolution.minAmount)],
    })
  );

  await sendTx(
    `Dispute bond: ${formatEther(BigInt(config.registry.bonds.dispute.minAmount))} ETH`,
    registryAddress,
    encodeFunctionData({
      abi: [{ name: "addAcceptableDisputeBond", type: "function", inputs: [{ name: "token", type: "address" }, { name: "minAmount", type: "uint256" }], outputs: [], stateMutability: "nonpayable" }],
      functionName: "addAcceptableDisputeBond",
      args: [config.registry.bonds.dispute.token as `0x${string}`, BigInt(config.registry.bonds.dispute.minAmount)],
    })
  );

  await sendTx(
    `Escalation bond: ${formatEther(BigInt(config.registry.bonds.escalation.minAmount))} ETH`,
    registryAddress,
    encodeFunctionData({
      abi: [{ name: "addAcceptableEscalationBond", type: "function", inputs: [{ name: "token", type: "address" }, { name: "minAmount", type: "uint256" }], outputs: [], stateMutability: "nonpayable" }],
      functionName: "addAcceptableEscalationBond",
      args: [config.registry.bonds.escalation.token as `0x${string}`, BigInt(config.registry.bonds.escalation.minAmount)],
    })
  );

  // 2. Configure Fees
  console.log("\n2️⃣  Configuring fees...");

  await sendTx(
    `Protocol fee: ${formatEther(BigInt(config.registry.fees.protocolFeeStandard))} ETH`,
    registryAddress,
    encodeFunctionData({
      abi: [{ name: "setProtocolFeeStandard", type: "function", inputs: [{ name: "fee", type: "uint256" }], outputs: [], stateMutability: "nonpayable" }],
      functionName: "setProtocolFeeStandard",
      args: [BigInt(config.registry.fees.protocolFeeStandard)],
    })
  );

  await sendTx(
    `TK share (TK_GUARANTEED): ${config.registry.fees.tkSharePercent.TK_GUARANTEED / 100}%`,
    registryAddress,
    encodeFunctionData({
      abi: [{ name: "setTKSharePercent", type: "function", inputs: [{ name: "tier", type: "uint8" }, { name: "basisPoints", type: "uint256" }], outputs: [], stateMutability: "nonpayable" }],
      functionName: "setTKSharePercent",
      args: [AccountabilityTier.TK_GUARANTEED, BigInt(config.registry.fees.tkSharePercent.TK_GUARANTEED)],
    })
  );

  await sendTx(
    `TK share (SYSTEM): ${config.registry.fees.tkSharePercent.SYSTEM / 100}%`,
    registryAddress,
    encodeFunctionData({
      abi: [{ name: "setTKSharePercent", type: "function", inputs: [{ name: "tier", type: "uint8" }, { name: "basisPoints", type: "uint256" }], outputs: [], stateMutability: "nonpayable" }],
      functionName: "setTKSharePercent",
      args: [AccountabilityTier.SYSTEM, BigInt(config.registry.fees.tkSharePercent.SYSTEM)],
    })
  );

  // 3. Set Treasury
  console.log("\n3️⃣  Setting treasury...");

  await sendTx(
    `Treasury: ${config.registry.treasury}`,
    registryAddress,
    encodeFunctionData({
      abi: [{ name: "setTreasury", type: "function", inputs: [{ name: "treasury", type: "address" }], outputs: [], stateMutability: "nonpayable" }],
      functionName: "setTreasury",
      args: [config.registry.treasury as `0x${string}`],
    })
  );

  // 4. Whitelist TruthKeeper
  console.log("\n4️⃣  Whitelisting TruthKeeper...");

  await sendTx(
    `TruthKeeper: ${truthKeeperAddress}`,
    registryAddress,
    encodeFunctionData({
      abi: [{ name: "addWhitelistedTruthKeeper", type: "function", inputs: [{ name: "tk", type: "address" }], outputs: [], stateMutability: "nonpayable" }],
      functionName: "addWhitelistedTruthKeeper",
      args: [truthKeeperAddress],
    })
  );

  // 5. Register Resolvers
  console.log("\n5️⃣  Registering resolvers...");

  const resolverAddresses: Record<string, `0x${string}`> = {
    OptimisticResolver: optimisticResolverAddress,
  };
  if (pythResolverAddress) {
    resolverAddresses.PythPriceResolver = pythResolverAddress;
  }

  for (const [name, resolverConfig] of Object.entries(config.resolvers)) {
    const address = resolverAddresses[name];
    if (!address) {
      console.log(`   ⚠️  ${name} not deployed, skipping`);
      continue;
    }

    if (resolverConfig.register) {
      await sendTx(
        `Register ${name}`,
        registryAddress,
        encodeFunctionData({
          abi: [{ name: "registerResolver", type: "function", inputs: [{ name: "resolver", type: "address" }], outputs: [], stateMutability: "nonpayable" }],
          functionName: "registerResolver",
          args: [address],
        })
      );

      // Set trust level if not default
      if (resolverConfig.trust !== "RESOLVER") {
        await sendTx(
          `Set ${name} trust to ${resolverConfig.trust}`,
          registryAddress,
          encodeFunctionData({
            abi: [{ name: "setResolverTrust", type: "function", inputs: [{ name: "resolver", type: "address" }, { name: "trust", type: "uint8" }], outputs: [], stateMutability: "nonpayable" }],
            functionName: "setResolverTrust",
            args: [address, ResolverTrust[resolverConfig.trust]],
          })
        );
      }
    }
  }

  // 6. Allow Resolvers in TruthKeeper
  console.log("\n6️⃣  Allowing resolvers in TruthKeeper...");

  for (const resolverName of config.truthKeeper.allowedResolvers) {
    const address = resolverAddresses[resolverName];
    if (!address) {
      console.log(`   ⚠️  ${resolverName} not deployed, skipping`);
      continue;
    }

    await sendTx(
      `Allow ${resolverName} in TruthKeeper`,
      truthKeeperAddress,
      encodeFunctionData({
        abi: [{ name: "setResolverAllowed", type: "function", inputs: [{ name: "resolver", type: "address" }, { name: "allowed", type: "bool" }], outputs: [], stateMutability: "nonpayable" }],
        functionName: "setResolverAllowed",
        args: [address, true],
      })
    );
  }

  console.log("\n✅ Configuration complete!\n");

  // Print summary
  console.log("📊 Summary:");
  console.log(`   Network:     ${networkName}`);
  console.log(`   Registry:    ${registryAddress}`);
  console.log(`   TruthKeeper: ${truthKeeperAddress}`);
  console.log(`   Treasury:    ${config.registry.treasury}`);
  console.log(`   Resolvers:   ${Object.keys(resolverAddresses).join(", ")}`);
  console.log();
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
