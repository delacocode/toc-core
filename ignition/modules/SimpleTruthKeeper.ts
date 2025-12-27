import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";
import TOCRegistryModule from "./TOCRegistry";

const SimpleTruthKeeperModule = buildModule("SimpleTruthKeeper", (m) => {
  const { registry } = m.useModule(TOCRegistryModule);
  const owner = m.getParameter("truthKeeperOwner");
  const minDisputeWindow = m.getParameter("minDisputeWindow", 3600);
  const minTKWindow = m.getParameter("minTruthKeeperWindow", 86400);

  const truthKeeper = m.contract("SimpleTruthKeeper", [
    registry,
    owner,
    minDisputeWindow,
    minTKWindow,
  ]);
  return { truthKeeper };
});

export default SimpleTruthKeeperModule;
