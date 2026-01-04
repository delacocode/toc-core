/**
 * TOC-Core Contract Exports
 *
 * Central export for ABIs and deployed addresses across all networks.
 */

// Import ABIs
import TruthEngineABI from "./sepolia/abis/TruthEngine.json" with { type: "json" };
import ITruthEngineABI from "./sepolia/abis/ITruthEngine.json" with { type: "json" };
import OptimisticResolverABI from "./sepolia/abis/OptimisticResolver.json" with { type: "json" };
import PythPriceResolverABI from "./sepolia/abis/PythPriceResolver.json" with { type: "json" };
import PythPriceResolverV2ABI from "./sepolia/abis/PythPriceResolverV2.json" with { type: "json" };
import SimpleTruthKeeperABI from "./sepolia/abis/SimpleTruthKeeper.json" with { type: "json" };

// Import addresses
import sepoliaAddresses from "./sepolia/addresses.json" with { type: "json" };

// Export ABIs
export const abis = {
  TruthEngine: TruthEngineABI,
  ITruthEngine: ITruthEngineABI,
  OptimisticResolver: OptimisticResolverABI,
  PythPriceResolver: PythPriceResolverABI,
  PythPriceResolverV2: PythPriceResolverV2ABI,
  SimpleTruthKeeper: SimpleTruthKeeperABI,
} as const;

// Export addresses by network
export const addresses = {
  sepolia: sepoliaAddresses,
} as const;

// Convenience exports
export { TruthEngineABI, ITruthEngineABI, OptimisticResolverABI, PythPriceResolverABI, PythPriceResolverV2ABI, SimpleTruthKeeperABI };
export { sepoliaAddresses };

// Types
export type NetworkName = keyof typeof addresses;
export type ContractName = keyof typeof abis;

// Helper to get addresses for a network
export function getAddresses(network: NetworkName) {
  return addresses[network].contracts;
}

// Helper to get a specific contract address
export function getAddress(network: NetworkName, contract: keyof typeof addresses.sepolia.contracts) {
  return addresses[network].contracts[contract];
}
