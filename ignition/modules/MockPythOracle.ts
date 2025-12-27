import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";

const MockPythOracleModule = buildModule("MockPythOracle", (m) => {
  const mock = m.contract("MockPythOracle");
  return { mock };
});

export default MockPythOracleModule;
