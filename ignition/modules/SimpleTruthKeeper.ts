import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";
import TruthEngineModule from "./TruthEngine";

const SimpleTruthKeeperModule = buildModule("SimpleTruthKeeper", (m) => {
  const { registry } = m.useModule(TruthEngineModule);
  // Default to deployer if no owner specified
  const owner = m.getParameter("truthKeeperOwner", m.getAccount(0));
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
