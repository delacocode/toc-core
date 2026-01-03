import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";

const TruthEngineModule = buildModule("TruthEngine", (m) => {
  const registry = m.contract("TruthEngine");
  return { registry };
});

export default TruthEngineModule;
