import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";
import TOCRegistryModule from "./TOCRegistry";
import OptimisticResolverModule from "./OptimisticResolver";
import PythPriceResolverModule from "./PythPriceResolver";
import SimpleTruthKeeperModule from "./SimpleTruthKeeper";

const TOCSystemModule = buildModule("TOCSystem", (m) => {
  const { registry } = m.useModule(TOCRegistryModule);
  const { resolver: optimisticResolver } = m.useModule(OptimisticResolverModule);
  const { resolver: pythResolver } = m.useModule(PythPriceResolverModule);
  const { truthKeeper } = m.useModule(SimpleTruthKeeperModule);

  return { registry, optimisticResolver, pythResolver, truthKeeper };
});

export default TOCSystemModule;
