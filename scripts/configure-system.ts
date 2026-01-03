import hre from "hardhat";
import { zeroAddress } from "viem";
import fs from "fs";
import path from "path";

// Configuration values (adjust per network)
const CONFIG = {
  sepolia: {
    treasury: "0x0000000000000000000000000000000000000000", // Set before running
    protocolFeeStandard: 10000000000000000n, // 0.01 ETH
    minResolutionBond: 100000000000000000n, // 0.1 ETH
    minDisputeBond: 100000000000000000n, // 0.1 ETH
    minEscalationBond: 50000000000000000n, // 0.05 ETH
    tkShareBasisPoints: 4000n, // 40%
  },
  base: {
    treasury: "0x0000000000000000000000000000000000000000", // Set before running
    protocolFeeStandard: 10000000000000000n, // 0.01 ETH
    minResolutionBond: 1000000000000000000n, // 1 ETH
    minDisputeBond: 1000000000000000000n, // 1 ETH
    minEscalationBond: 500000000000000000n, // 0.5 ETH
    tkShareBasisPoints: 4000n, // 40%
  },
  arbitrum: {
    treasury: "0x0000000000000000000000000000000000000000", // Set before running
    protocolFeeStandard: 10000000000000000n,
    minResolutionBond: 1000000000000000000n,
    minDisputeBond: 1000000000000000000n,
    minEscalationBond: 500000000000000000n,
    tkShareBasisPoints: 4000n,
  },
  polygon: {
    treasury: "0x0000000000000000000000000000000000000000", // Set before running
    protocolFeeStandard: 10000000000000000n,
    minResolutionBond: 1000000000000000000n,
    minDisputeBond: 1000000000000000000n,
    minEscalationBond: 500000000000000000n,
    tkShareBasisPoints: 4000n,
  },
} as const;

// AccountabilityTier enum value for TK_GUARANTEED
const TK_GUARANTEED = 1;

async function main() {
  const network = hre.network.name as keyof typeof CONFIG;

  if (!CONFIG[network]) {
    throw new Error(`No configuration found for network: ${network}`);
  }

  const config = CONFIG[network];

  // Load deployed addresses from Ignition
  const deploymentPath = path.join(
    __dirname,
    "..",
    "ignition",
    "deployments",
    `chain-${hre.network.config.chainId}`,
    "deployed_addresses.json"
  );

  if (!fs.existsSync(deploymentPath)) {
    throw new Error(`Deployment not found at ${deploymentPath}. Run deploy first.`);
  }

  const deployedAddresses = JSON.parse(fs.readFileSync(deploymentPath, "utf-8"));

  console.log(`\nConfiguring TruthEngine on ${network}...`);
  console.log(`Using deployed addresses from: ${deploymentPath}\n`);

  const registry = await hre.viem.getContractAt(
    "TruthEngine",
    deployedAddresses["TruthEngine#TruthEngine"]
  );

  // 1. Set treasury
  console.log("1. Setting treasury...");
  const treasuryTx = await registry.write.setTreasuryAddress([config.treasury]);
  console.log(`   TX: ${treasuryTx}`);

  // 2. Set protocol fees
  console.log("2. Setting protocol fees...");
  const feeTx = await registry.write.setProtocolFeeStandard([config.protocolFeeStandard]);
  console.log(`   TX: ${feeTx}`);

  // 3. Add acceptable bonds (native ETH = zeroAddress)
  console.log("3. Adding acceptable resolution bond...");
  const resBondTx = await registry.write.addAcceptableResolutionBond([
    zeroAddress,
    config.minResolutionBond,
  ]);
  console.log(`   TX: ${resBondTx}`);

  console.log("4. Adding acceptable dispute bond...");
  const disBondTx = await registry.write.addAcceptableDisputeBond([
    zeroAddress,
    config.minDisputeBond,
  ]);
  console.log(`   TX: ${disBondTx}`);

  console.log("5. Adding acceptable escalation bond...");
  const escBondTx = await registry.write.addAcceptableEscalationBond([
    zeroAddress,
    config.minEscalationBond,
  ]);
  console.log(`   TX: ${escBondTx}`);

  // 4. Set TruthKeeper revenue share
  console.log("6. Setting TK share...");
  const tkShareTx = await registry.write.setTKSharePercent([
    TK_GUARANTEED,
    config.tkShareBasisPoints,
  ]);
  console.log(`   TX: ${tkShareTx}`);

  // 5. Whitelist the TruthKeeper
  console.log("7. Whitelisting TruthKeeper...");
  const tkAddr = deployedAddresses["SimpleTruthKeeper#SimpleTruthKeeper"];
  const whitelistTx = await registry.write.addWhitelistedTruthKeeper([tkAddr]);
  console.log(`   TX: ${whitelistTx}`);

  // 6. Register resolvers
  console.log("8. Registering OptimisticResolver...");
  const optAddr = deployedAddresses["OptimisticResolver#OptimisticResolver"];
  const optTx = await registry.write.registerResolver([optAddr]);
  console.log(`   TX: ${optTx}`);

  console.log("9. Registering PythPriceResolver...");
  const pythAddr = deployedAddresses["PythPriceResolver#PythPriceResolver"];
  const pythTx = await registry.write.registerResolver([pythAddr]);
  console.log(`   TX: ${pythTx}`);

  console.log("\nConfiguration complete!");
  console.log("\nDeployed addresses:");
  console.log(`  TruthEngine: ${deployedAddresses["TruthEngine#TruthEngine"]}`);
  console.log(`  OptimisticResolver: ${optAddr}`);
  console.log(`  PythPriceResolver: ${pythAddr}`);
  console.log(`  SimpleTruthKeeper: ${tkAddr}`);
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
