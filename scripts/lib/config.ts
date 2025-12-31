/**
 * Shared configuration loader for deployment scripts
 * Loads config and deployed addresses based on network
 */

import { createPublicClient, createWalletClient, http, type Chain } from "viem";
import { mnemonicToAccount } from "viem/accounts";
import { sepolia, base, bsc, arbitrum, polygon } from "viem/chains";
import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";
import "dotenv/config";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

// Chain configs
const CHAINS: Record<string, { chain: Chain; chainId: number }> = {
  sepolia: { chain: sepolia, chainId: 11155111 },
  base: { chain: base, chainId: 8453 },
  bsc: { chain: bsc, chainId: 56 },
  arbitrum: { chain: arbitrum, chainId: 42161 },
  polygon: { chain: polygon, chainId: 137 },
};

// RPC URL env var names
const RPC_ENV_VARS: Record<string, string> = {
  sepolia: "SEPOLIA_RPC_URL",
  base: "BASE_RPC_URL",
  bsc: "BSC_RPC_URL",
  arbitrum: "ARBITRUM_RPC_URL",
  polygon: "POLYGON_RPC_URL",
};

export interface NetworkConfig {
  network: string;
  chainId: number;
  registry: {
    bonds: {
      resolution: { token: string; minAmount: string };
      dispute: { token: string; minAmount: string };
      escalation: { token: string; minAmount: string };
    };
    fees: {
      protocolFeeStandard: string;
      tkSharePercent: {
        TK_GUARANTEED: number;
        SYSTEM: number;
      };
    };
    treasury: string;
  };
  truthKeeper: {
    owner: string;
    minDisputeWindow: number;
    minTruthKeeperWindow: number;
    allowedResolvers: string[];
  };
  resolvers: Record<string, { register: boolean; trust: string }>;
  pyth: {
    address: string;
  };
}

export interface DeployedAddresses {
  registry: `0x${string}`;
  optimisticResolver: `0x${string}`;
  pythResolver: `0x${string}`;
  truthKeeper: `0x${string}`;
}

let _cachedNetwork: string | null = null;

export async function getNetwork(): Promise<string> {
  if (_cachedNetwork) return _cachedNetwork;

  // Try HARDHAT_NETWORK env var first
  if (process.env.HARDHAT_NETWORK) {
    _cachedNetwork = process.env.HARDHAT_NETWORK;
    return _cachedNetwork;
  }

  // Try Hardhat 3.0 globalOptions
  try {
    const hre = await import("hardhat");
    if (hre.globalOptions?.network) {
      _cachedNetwork = hre.globalOptions.network;
      return _cachedNetwork;
    }
  } catch {
    // Not in Hardhat context
  }

  throw new Error("Network not specified. Use: npx hardhat run <script> --network <network>");
}

export function loadConfig(network: string): NetworkConfig {
  const configPath = path.join(__dirname, `../../ignition/config/${network}.json`);
  if (!fs.existsSync(configPath)) {
    throw new Error(`Config not found: ${configPath}\nCreate config for ${network} first.`);
  }
  return JSON.parse(fs.readFileSync(configPath, "utf-8"));
}

export function loadDeployedAddresses(chainId: number): DeployedAddresses {
  const deployedPath = path.join(__dirname, `../../ignition/deployments/chain-${chainId}/deployed_addresses.json`);
  if (!fs.existsSync(deployedPath)) {
    throw new Error(`Deployment not found: ${deployedPath}\nDeploy to this network first.`);
  }
  const deployed = JSON.parse(fs.readFileSync(deployedPath, "utf-8"));
  return {
    registry: deployed["TOCRegistry#TOCRegistry"] as `0x${string}`,
    optimisticResolver: deployed["OptimisticResolver#OptimisticResolver"] as `0x${string}`,
    pythResolver: deployed["PythPriceResolver#PythPriceResolver"] as `0x${string}`,
    truthKeeper: deployed["SimpleTruthKeeper#SimpleTruthKeeper"] as `0x${string}`,
  };
}

export function getChainConfig(network: string) {
  const chainConfig = CHAINS[network];
  if (!chainConfig) {
    throw new Error(`Unsupported network: ${network}\nSupported: ${Object.keys(CHAINS).join(", ")}`);
  }
  return chainConfig;
}

export function getRpcUrl(network: string): string {
  const envVar = RPC_ENV_VARS[network];
  if (!envVar) {
    throw new Error(`No RPC env var configured for ${network}`);
  }
  const rpcUrl = process.env[envVar];
  if (!rpcUrl) {
    throw new Error(`${envVar} not set in .env`);
  }
  return rpcUrl;
}

export function createClients(network: string) {
  const mnemonic = process.env.MNEMONIC;
  if (!mnemonic) throw new Error("MNEMONIC not set in .env");

  const { chain } = getChainConfig(network);
  const rpcUrl = getRpcUrl(network);
  const account = mnemonicToAccount(mnemonic);

  const publicClient = createPublicClient({
    chain,
    transport: http(rpcUrl),
  });

  const walletClient = createWalletClient({
    account,
    chain,
    transport: http(rpcUrl),
  });

  return { publicClient, walletClient, account };
}

export function getExplorerTxUrl(network: string, hash: string): string {
  const explorers: Record<string, string> = {
    sepolia: "https://sepolia.etherscan.io/tx/",
    base: "https://basescan.org/tx/",
    bsc: "https://bscscan.com/tx/",
    arbitrum: "https://arbiscan.io/tx/",
    polygon: "https://polygonscan.com/tx/",
  };
  return `${explorers[network] || ""}${hash}`;
}
