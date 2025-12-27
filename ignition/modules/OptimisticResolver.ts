import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";
import TOCRegistryModule from "./TOCRegistry";

const OptimisticResolverModule = buildModule("OptimisticResolver", (m) => {
  const { registry } = m.useModule(TOCRegistryModule);
  const resolver = m.contract("OptimisticResolver", [registry]);
  return { resolver };
});

export default OptimisticResolverModule;
