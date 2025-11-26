import type { HardhatUserConfig } from "hardhat/config";
import HardhatToolboxViem from "@nomicfoundation/hardhat-toolbox-viem";

const config: HardhatUserConfig = {
  solidity: "0.8.29",
  plugins: [HardhatToolboxViem],
};

export default config;
