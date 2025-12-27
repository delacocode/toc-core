import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";

const TOCRegistryModule = buildModule("TOCRegistry", (m) => {
  const registry = m.contract("TOCRegistry");
  return { registry };
});

export default TOCRegistryModule;
