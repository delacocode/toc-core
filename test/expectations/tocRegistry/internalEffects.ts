/**
 * Tier 2: Internal Effects for TOCRegistry
 *
 * These functions verify the internal effects of TOCRegistry operations.
 * Each function verifies ALL effects of a single internal operation:
 * - Storage changes
 * - Events emitted
 * - State transitions
 */

import type { Address, Log, PublicClient, GetContractReturnType } from "viem";
import {
  expectStorageValue,
  expectEvent,
  aggregateResults,
  type StorageCheck,
  type EventExpectation,
  type ExpectationResult,
  type AggregatedExpectationResult,
  TOCState,
  AnswerType,
  AccountabilityTier,
  ResolverTrust,
  DisputePhase,
  DisputeResolution,
  type FeeSplit,
} from "../utils/index.js";

// Type for the registry contract
type RegistryContract = GetContractReturnType<readonly unknown[], PublicClient>;

// ============ Fee Calculation Utilities ============

export function calculateFeeSplit(
  totalFee: bigint,
  tkShareBasisPoints: bigint
): FeeSplit {
  const tkFee = (totalFee * tkShareBasisPoints) / 10000n;
  const protocolFee = totalFee - tkFee;
  return { protocolFee, tkFee, resolverFee: 0n };
}

export function calculateDisputeDeadline(
  resolutionTime: bigint,
  disputeWindow: bigint
): bigint {
  return resolutionTime + disputeWindow;
}

// ============ TOC ID Increment Effect ============

export interface TocIdIncrementContext {
  registry: RegistryContract;
  expectedNextId: bigint;
}

export async function expectTocIdIncremented(
  ctx: TocIdIncrementContext
): Promise<AggregatedExpectationResult> {
  const result = await expectStorageValue({
    getter: () => (ctx.registry.read as { nextTocId: () => Promise<bigint> }).nextTocId(),
    expected: ctx.expectedNextId,
    label: "nextTocId incremented",
  });
  return aggregateResults([result], "TOC ID increment");
}

// ============ TOC State Effect ============

export interface TocStateContext {
  registry: RegistryContract;
  tocId: bigint;
  expectedState: TOCState;
}

export async function expectTocState(
  ctx: TocStateContext
): Promise<AggregatedExpectationResult> {
  const read = ctx.registry.read as { getTOC: (args: [bigint]) => Promise<{ state: number }> };
  const result = await expectStorageValue({
    getter: async () => {
      const toc = await read.getTOC([ctx.tocId]);
      return toc.state;
    },
    expected: ctx.expectedState,
    label: `TOC ${ctx.tocId} state`,
  });
  return aggregateResults([result], "TOC state");
}

// ============ TOC Created Effect ============

export interface TocCreatedContext {
  logs: Log[];
  abi: readonly unknown[];
  tocId: bigint;
  resolver: Address;
  trust: ResolverTrust;
  templateId: number;
  answerType: AnswerType;
  initialState: TOCState;
  truthKeeper: Address;
  tier: AccountabilityTier;
}

export function expectTocCreatedEvent(
  ctx: TocCreatedContext
): ExpectationResult {
  return expectEvent(ctx.logs, ctx.abi, {
    eventName: "TOCCreated",
    args: {
      tocId: ctx.tocId,
      resolver: ctx.resolver,
      trust: ctx.trust,
      templateId: ctx.templateId,
      answerType: ctx.answerType,
      initialState: ctx.initialState,
      truthKeeper: ctx.truthKeeper,
      tier: ctx.tier,
    },
  });
}

// ============ Creation Fees Effect ============

export interface CreationFeesContext {
  logs: Log[];
  abi: readonly unknown[];
  tocId: bigint;
  protocolFee: bigint;
  tkFee: bigint;
  resolverFee: bigint;
}

export function expectCreationFeesEvent(
  ctx: CreationFeesContext
): ExpectationResult {
  return expectEvent(ctx.logs, ctx.abi, {
    eventName: "CreationFeesCollected",
    args: {
      tocId: ctx.tocId,
      protocolFee: ctx.protocolFee,
      tkFee: ctx.tkFee,
      resolverFee: ctx.resolverFee,
    },
  });
}

// ============ Resolution Bond Effect ============

export interface ResolutionBondContext {
  logs: Log[];
  abi: readonly unknown[];
  tocId: bigint;
  proposer: Address;
  token: Address;
  amount: bigint;
}

export function expectResolutionBondEvent(
  ctx: ResolutionBondContext
): ExpectationResult {
  return expectEvent(ctx.logs, ctx.abi, {
    eventName: "ResolutionBondDeposited",
    args: {
      tocId: ctx.tocId,
      proposer: ctx.proposer,
      token: ctx.token,
      amount: ctx.amount,
    },
  });
}

// ============ Resolution Proposed Effect ============

export interface ResolutionProposedContext {
  logs: Log[];
  abi: readonly unknown[];
  tocId: bigint;
  proposer: Address;
  answerType: AnswerType;
  disputeDeadline: bigint;
}

export function expectResolutionProposedEvent(
  ctx: ResolutionProposedContext
): ExpectationResult {
  return expectEvent(ctx.logs, ctx.abi, {
    eventName: "TOCResolutionProposed",
    args: {
      tocId: ctx.tocId,
      proposer: ctx.proposer,
      answerType: ctx.answerType,
      disputeDeadline: ctx.disputeDeadline,
    },
  });
}

// ============ TOC Finalized Effect ============

export interface TocFinalizedContext {
  logs: Log[];
  abi: readonly unknown[];
  tocId: bigint;
  answerType: AnswerType;
}

export function expectTocFinalizedEvent(
  ctx: TocFinalizedContext
): ExpectationResult {
  return expectEvent(ctx.logs, ctx.abi, {
    eventName: "TOCFinalized",
    args: {
      tocId: ctx.tocId,
      answerType: ctx.answerType,
    },
  });
}

// ============ Dispute Bond Effect ============

export interface DisputeBondContext {
  logs: Log[];
  abi: readonly unknown[];
  tocId: bigint;
  disputer: Address;
  token: Address;
  amount: bigint;
}

export function expectDisputeBondEvent(
  ctx: DisputeBondContext
): ExpectationResult {
  return expectEvent(ctx.logs, ctx.abi, {
    eventName: "DisputeBondDeposited",
    args: {
      tocId: ctx.tocId,
      disputer: ctx.disputer,
      token: ctx.token,
      amount: ctx.amount,
    },
  });
}

// ============ TOC Disputed Effect ============

export interface TocDisputedContext {
  logs: Log[];
  abi: readonly unknown[];
  tocId: bigint;
  disputer: Address;
  reason: string;
}

export function expectTocDisputedEvent(
  ctx: TocDisputedContext
): ExpectationResult {
  return expectEvent(ctx.logs, ctx.abi, {
    eventName: "TOCDisputed",
    args: {
      tocId: ctx.tocId,
      disputer: ctx.disputer,
      reason: ctx.reason,
    },
  });
}

// ============ Post-Resolution Dispute Effect ============

export interface PostResolutionDisputeContext {
  logs: Log[];
  abi: readonly unknown[];
  tocId: bigint;
  disputer: Address;
  reason: string;
}

export function expectPostResolutionDisputeEvent(
  ctx: PostResolutionDisputeContext
): ExpectationResult {
  return expectEvent(ctx.logs, ctx.abi, {
    eventName: "PostResolutionDisputeFiled",
    args: {
      tocId: ctx.tocId,
      disputer: ctx.disputer,
      reason: ctx.reason,
    },
  });
}

// ============ Dispute Info Storage Effect ============

export interface DisputeInfoContext {
  registry: RegistryContract;
  tocId: bigint;
  expectedPhase: DisputePhase;
  expectedDisputer: Address;
  expectedBondToken: Address;
  expectedBondAmount: bigint;
}

export async function expectDisputeInfoStored(
  ctx: DisputeInfoContext
): Promise<AggregatedExpectationResult> {
  const read = ctx.registry.read as {
    getDisputeInfo: (args: [bigint]) => Promise<{
      phase: number;
      disputer: Address;
      bondToken: Address;
      bondAmount: bigint;
    }>;
  };

  const results: ExpectationResult[] = [];

  const disputeInfo = await read.getDisputeInfo([ctx.tocId]);

  results.push({
    passed: disputeInfo.phase === ctx.expectedPhase,
    label: "dispute phase",
    expected: ctx.expectedPhase,
    actual: disputeInfo.phase,
  });

  results.push({
    passed: disputeInfo.disputer.toLowerCase() === ctx.expectedDisputer.toLowerCase(),
    label: "disputer address",
    expected: ctx.expectedDisputer,
    actual: disputeInfo.disputer,
  });

  results.push({
    passed: disputeInfo.bondToken.toLowerCase() === ctx.expectedBondToken.toLowerCase(),
    label: "bond token",
    expected: ctx.expectedBondToken,
    actual: disputeInfo.bondToken,
  });

  results.push({
    passed: disputeInfo.bondAmount === ctx.expectedBondAmount,
    label: "bond amount",
    expected: ctx.expectedBondAmount,
    actual: disputeInfo.bondAmount,
  });

  return aggregateResults(results, "Dispute info storage");
}

// ============ Resolution Info Storage Effect ============

export interface ResolutionInfoContext {
  registry: RegistryContract;
  tocId: bigint;
  expectedProposer: Address;
  expectedBondToken: Address;
  expectedBondAmount: bigint;
  expectedResult: `0x${string}`;
}

export async function expectResolutionInfoStored(
  ctx: ResolutionInfoContext
): Promise<AggregatedExpectationResult> {
  const read = ctx.registry.read as {
    getResolutionInfo: (args: [bigint]) => Promise<{
      proposer: Address;
      bondToken: Address;
      bondAmount: bigint;
      proposedResult: `0x${string}`;
    }>;
  };

  const results: ExpectationResult[] = [];
  const resInfo = await read.getResolutionInfo([ctx.tocId]);

  results.push({
    passed: resInfo.proposer.toLowerCase() === ctx.expectedProposer.toLowerCase(),
    label: "resolution proposer",
    expected: ctx.expectedProposer,
    actual: resInfo.proposer,
  });

  results.push({
    passed: resInfo.bondToken.toLowerCase() === ctx.expectedBondToken.toLowerCase(),
    label: "resolution bond token",
    expected: ctx.expectedBondToken,
    actual: resInfo.bondToken,
  });

  results.push({
    passed: resInfo.bondAmount === ctx.expectedBondAmount,
    label: "resolution bond amount",
    expected: ctx.expectedBondAmount,
    actual: resInfo.bondAmount,
  });

  results.push({
    passed: resInfo.proposedResult.toLowerCase() === ctx.expectedResult.toLowerCase(),
    label: "proposed result",
    expected: ctx.expectedResult,
    actual: resInfo.proposedResult,
  });

  return aggregateResults(results, "Resolution info storage");
}

// ============ Bond Return Effect ============

export interface BondReturnContext {
  logs: Log[];
  abi: readonly unknown[];
  tocId: bigint;
  to: Address;
  token: Address;
  amount: bigint;
  bondType: "resolution" | "dispute";
}

export function expectBondReturnEvent(
  ctx: BondReturnContext
): ExpectationResult {
  const eventName =
    ctx.bondType === "resolution"
      ? "ResolutionBondReturned"
      : "DisputeBondReturned";

  return expectEvent(ctx.logs, ctx.abi, {
    eventName,
    args: {
      tocId: ctx.tocId,
      to: ctx.to,
      token: ctx.token,
      amount: ctx.amount,
    },
  });
}

// ============ Dispute Resolution Effect ============

export interface DisputeResolutionContext {
  logs: Log[];
  abi: readonly unknown[];
  tocId: bigint;
  resolution: DisputeResolution;
  admin: Address;
}

export function expectDisputeResolvedEvent(
  ctx: DisputeResolutionContext
): ExpectationResult {
  return expectEvent(ctx.logs, ctx.abi, {
    eventName: "DisputeResolved",
    args: {
      tocId: ctx.tocId,
      resolution: ctx.resolution,
      admin: ctx.admin,
    },
  });
}

// ============ Result Storage Effect ============

export interface ResultStorageContext {
  registry: RegistryContract;
  tocId: bigint;
  expectedResult: `0x${string}`;
}

export async function expectResultStored(
  ctx: ResultStorageContext
): Promise<AggregatedExpectationResult> {
  const read = ctx.registry.read as {
    getResult: (args: [bigint]) => Promise<`0x${string}`>;
  };

  const result = await expectStorageValue({
    getter: () => read.getResult([ctx.tocId]),
    expected: ctx.expectedResult,
    label: `TOC ${ctx.tocId} result`,
  });

  return aggregateResults([result], "Result storage");
}

// ============ Protocol Balance Effect ============

export interface ProtocolBalanceContext {
  registry: RegistryContract;
  category: 0 | 1; // FeeCategory enum
  expectedDelta: bigint;
  balanceBefore: bigint;
}

export async function expectProtocolBalanceChanged(
  ctx: ProtocolBalanceContext
): Promise<AggregatedExpectationResult> {
  const read = ctx.registry.read as {
    getProtocolBalance: (args: [number]) => Promise<bigint>;
  };

  const balanceAfter = await read.getProtocolBalance([ctx.category]);
  const actualDelta = balanceAfter - ctx.balanceBefore;

  const result: ExpectationResult = {
    passed: actualDelta === ctx.expectedDelta,
    label: `Protocol balance change (category ${ctx.category})`,
    expected: ctx.expectedDelta,
    actual: actualDelta,
  };

  return aggregateResults([result], "Protocol balance");
}

// ============ TK Balance Effect ============

export interface TKBalanceContext {
  registry: RegistryContract;
  truthKeeper: Address;
  expectedDelta: bigint;
  balanceBefore: bigint;
}

export async function expectTKBalanceChanged(
  ctx: TKBalanceContext
): Promise<AggregatedExpectationResult> {
  const read = ctx.registry.read as {
    getTKBalance: (args: [Address]) => Promise<bigint>;
  };

  const balanceAfter = await read.getTKBalance([ctx.truthKeeper]);
  const actualDelta = balanceAfter - ctx.balanceBefore;

  const result: ExpectationResult = {
    passed: actualDelta === ctx.expectedDelta,
    label: `TK balance change for ${ctx.truthKeeper}`,
    expected: ctx.expectedDelta,
    actual: actualDelta,
  };

  return aggregateResults([result], "TK balance");
}
