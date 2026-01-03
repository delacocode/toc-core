import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";
import TruthEngineModule from "./TruthEngine";

const PythPriceResolverModule = buildModule("PythPriceResolver", (m) => {
  const { registry } = m.useModule(TruthEngineModule);
  const pythAddress = m.getParameter("pythAddress");
  const resolver = m.contract("PythPriceResolver", [pythAddress, registry]);
  return { resolver };
});

export default PythPriceResolverModule;
