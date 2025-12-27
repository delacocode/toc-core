import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";
import TOCRegistryModule from "./TOCRegistry";

const PythPriceResolverModule = buildModule("PythPriceResolver", (m) => {
  const { registry } = m.useModule(TOCRegistryModule);
  const pythAddress = m.getParameter("pythAddress");
  const resolver = m.contract("PythPriceResolver", [pythAddress, registry]);
  return { resolver };
});

export default PythPriceResolverModule;
