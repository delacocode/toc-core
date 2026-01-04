/**
 * Central ABI exports from compiled artifacts
 *
 * This is the single source of truth for ABIs in tests.
 * ABIs are imported directly from compiled artifacts to ensure type safety
 * and automatic synchronization with contract changes.
 */

// Import ABIs directly from artifacts
import TruthEngineArtifact from "../artifacts/contracts/TruthEngine/TruthEngine.sol/TruthEngine.json" with { type: "json" };
import ITruthEngineArtifact from "../artifacts/contracts/TruthEngine/ITruthEngine.sol/ITruthEngine.json" with { type: "json" };
import OptimisticResolverArtifact from "../artifacts/contracts/resolvers/OptimisticResolver.sol/OptimisticResolver.json" with { type: "json" };
import MockTruthKeeperArtifact from "../artifacts/contracts/mocks/MockTruthKeeper.sol/MockTruthKeeper.json" with { type: "json" };
import SimpleTruthKeeperArtifact from "../artifacts/contracts/SimpleTruthKeeper.sol/SimpleTruthKeeper.json" with { type: "json" };
import PythPriceResolverArtifact from "../artifacts/contracts/resolvers/PythPriceResolver.sol/PythPriceResolver.json" with { type: "json" };
import PythPriceResolverV2Artifact from "../artifacts/contracts/resolvers/PythPriceResolverV2.sol/PythPriceResolverV2.json" with { type: "json" };

// Export ABIs as const for type inference
export const TruthEngineABI = TruthEngineArtifact.abi as const;
export const ITruthEngineABI = ITruthEngineArtifact.abi as const;
export const OptimisticResolverABI = OptimisticResolverArtifact.abi as const;
export const MockTruthKeeperABI = MockTruthKeeperArtifact.abi as const;
export const SimpleTruthKeeperABI = SimpleTruthKeeperArtifact.abi as const;
export const PythPriceResolverABI = PythPriceResolverArtifact.abi as const;
export const PythPriceResolverV2ABI = PythPriceResolverV2Artifact.abi as const;

// Re-export full artifacts if needed
export {
  TruthEngineArtifact,
  ITruthEngineArtifact,
  OptimisticResolverArtifact,
  MockTruthKeeperArtifact,
  SimpleTruthKeeperArtifact,
  PythPriceResolverArtifact,
  PythPriceResolverV2Artifact,
};
