/**
 * Type definitions for the expectations testing framework
 */

import type { Address, Hash, Log } from "viem";

// ============ Base Types ============

export interface StorageCheck<T> {
  getter: () => Promise<T>;
  expected: T;
  label: string;
}

export interface BalanceChange {
  address: Address;
  token: Address | null; // null = native ETH
  delta: bigint;
  label: string;
}

export interface EventExpectation {
  eventName: string;
  args: Record<string, unknown>;
  indexed?: string[]; // which args are indexed
}

// ============ TOC Types (mirrors Solidity enums) ============

export enum TOCState {
  NONE = 0,
  PENDING = 1,
  REJECTED = 2,
  ACTIVE = 3,
  RESOLVING = 4,
  DISPUTED_ROUND_1 = 5,
  DISPUTED_ROUND_2 = 6,
  RESOLVED = 7,
  CANCELLED = 8,
}

export enum AnswerType {
  NONE = 0,
  BOOLEAN = 1,
  NUMERIC = 2,
  GENERIC = 3,
}

export enum DisputeResolution {
  UPHOLD_DISPUTE = 0,
  REJECT_DISPUTE = 1,
  CANCEL_TOC = 2,
  TOO_EARLY = 3,
}

export enum ResolverTrust {
  NONE = 0,
  RESOLVER = 1,
  VERIFIED = 2,
  SYSTEM = 3,
}

export enum AccountabilityTier {
  NONE = 0,
  RESOLVER = 1,
  TK_GUARANTEED = 2,
  SYSTEM = 3,
}

export enum DisputePhase {
  NONE = 0,
  PRE_RESOLUTION = 1,
  POST_RESOLUTION = 2,
}

export enum TKApprovalResponse {
  APPROVE = 0,
  REJECT_SOFT = 1,
  REJECT_HARD = 2,
}

export enum FeeCategory {
  CREATION = 0,
  SLASHING = 1,
}

// ============ Struct Types ============

export interface TOC {
  resolver: Address;
  state: TOCState;
  answerType: AnswerType;
  resolutionTime: bigint;
  disputeWindow: bigint;
  truthKeeperWindow: bigint;
  escalationWindow: bigint;
  postResolutionWindow: bigint;
  disputeDeadline: bigint;
  truthKeeperDeadline: bigint;
  escalationDeadline: bigint;
  postDisputeDeadline: bigint;
  truthKeeper: Address;
  tierAtCreation: AccountabilityTier;
}

export interface DisputeInfo {
  phase: DisputePhase;
  disputer: Address;
  bondToken: Address;
  bondAmount: bigint;
  reason: string;
  evidenceURI: string;
  filedAt: bigint;
  resolvedAt: bigint;
  resultCorrected: boolean;
  proposedResult: `0x${string}`;
  tkDecision: DisputeResolution;
  tkDecidedAt: bigint;
}

export interface ResolutionInfo {
  proposer: Address;
  bondToken: Address;
  bondAmount: bigint;
  proposedResult: `0x${string}`;
}

export interface FeeSplit {
  protocolFee: bigint;
  tkFee: bigint;
  resolverFee: bigint;
}

// ============ Transaction Context ============

export interface TxContext {
  hash: Hash;
  blockNumber: bigint;
  timestamp: bigint;
  logs: Log[];
  from: Address;
  to: Address;
  value: bigint;
}

// ============ Expectation Result ============

export interface ExpectationResult {
  passed: boolean;
  label: string;
  expected?: unknown;
  actual?: unknown;
  error?: string;
}

export interface AggregatedExpectationResult {
  allPassed: boolean;
  results: ExpectationResult[];
  summary: string;
}
