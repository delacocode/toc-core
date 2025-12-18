/**
 * TOCRegistry Expectations
 *
 * Comprehensive testing utilities for verifying TOCRegistry operations.
 * Uses a three-tier architecture:
 *
 * Tier 1 (utils): Base utilities for storage, events, balances
 * Tier 2 (internalEffects): Single internal effect verification
 * Tier 3 (interactions): Complete interaction verification (composes Tier 2)
 *
 * Usage:
 * ```typescript
 * import { expectCreateTOC, assertAllPassed } from "./expectations/tocRegistry";
 *
 * const result = await expectCreateTOC(ctx);
 * assertAllPassed(result);
 * ```
 */

// Re-export everything from internal effects (Tier 2)
export * from "./internalEffects.js";

// Re-export everything from interactions (Tier 3)
export * from "./interactions.js";

// Re-export types from utils
export {
  type StorageCheck,
  type BalanceChange,
  type EventExpectation,
  type ExpectationResult,
  type AggregatedExpectationResult,
  type TxContext,
  type TOC,
  type DisputeInfo,
  type ResolutionInfo,
  type FeeSplit,
} from "../utils/index.js";
