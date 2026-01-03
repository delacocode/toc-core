import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";
import TruthEngineModule from "./TruthEngine";

const OptimisticResolverModule = buildModule("OptimisticResolver", (m) => {
  const { registry } = m.useModule(TruthEngineModule);
  const resolver = m.contract("OptimisticResolver", [registry]);
  return { resolver };
});

export default OptimisticResolverModule;
