import hre from "hardhat";

async function main() {
  console.log("Deploying to localhost...\n");

  // 1. Deploy MockPythOracle
  console.log("1. Deploying MockPythOracle...");
  const mockPyth = await hre.viem.deployContract("MockPythOracle");
  console.log(`   MockPythOracle deployed at: ${mockPyth.address}\n`);

  // 2. Deploy TOCRegistry
  console.log("2. Deploying TOCRegistry...");
  const registry = await hre.viem.deployContract("TOCRegistry");
  console.log(`   TOCRegistry deployed at: ${registry.address}\n`);

  // 3. Deploy OptimisticResolver
  console.log("3. Deploying OptimisticResolver...");
  const optimisticResolver = await hre.viem.deployContract("OptimisticResolver", [
    registry.address,
  ]);
  console.log(`   OptimisticResolver deployed at: ${optimisticResolver.address}\n`);

  // 4. Deploy PythPriceResolver
  console.log("4. Deploying PythPriceResolver...");
  const pythResolver = await hre.viem.deployContract("PythPriceResolver", [
    mockPyth.address,
    registry.address,
  ]);
  console.log(`   PythPriceResolver deployed at: ${pythResolver.address}\n`);

  // 5. Deploy SimpleTruthKeeper
  const [deployer] = await hre.viem.getWalletClients();
  console.log("5. Deploying SimpleTruthKeeper...");
  const truthKeeper = await hre.viem.deployContract("SimpleTruthKeeper", [
    registry.address,
    deployer.account.address, // owner
    60, // minDisputeWindow (1 min for testing)
    120, // minTruthKeeperWindow (2 min for testing)
  ]);
  console.log(`   SimpleTruthKeeper deployed at: ${truthKeeper.address}\n`);

  console.log("=".repeat(50));
  console.log("All contracts deployed successfully!");
  console.log("=".repeat(50));
  console.log("\nDeployed Addresses:");
  console.log(`  MockPythOracle:      ${mockPyth.address}`);
  console.log(`  TOCRegistry:         ${registry.address}`);
  console.log(`  OptimisticResolver:  ${optimisticResolver.address}`);
  console.log(`  PythPriceResolver:   ${pythResolver.address}`);
  console.log(`  SimpleTruthKeeper:   ${truthKeeper.address}`);
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
