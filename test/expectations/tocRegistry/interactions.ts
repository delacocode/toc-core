/**
 * Tier 3: Interaction Expectations for TOCRegistry
 *
 * These compose Tier 2 internal effects into complete interaction verifications.
 * Each function verifies ALL effects of a user-facing operation using the
 * interlacing pattern: effects are verified in execution order.
 */

import type { Address, Log, PublicClient, GetContractReturnType } from "viem";
import {
  aggregateResults,
  assertAllPassed,
  type AggregatedExpectationResult,
  type ExpectationResult,
  TOCState,
  AnswerType,
  AccountabilityTier,
  ResolverTrust,
  DisputePhase,
  DisputeResolution,
} from "../utils/index.js";
import {
  calculateFeeSplit,
  calculateDisputeDeadline,
  expectTocIdIncremented,
  expectTocState,
  expectTocCreatedEvent,
  expectCreationFeesEvent,
  expectResolutionBondEvent,
  expectResolutionProposedEvent,
  expectTocFinalizedEvent,
  expectDisputeBondEvent,
  expectTocDisputedEvent,
  expectPostResolutionDisputeEvent,
  expectDisputeInfoStored,
  expectResolutionInfoStored,
  expectBondReturnEvent,
  expectDisputeResolvedEvent,
  expectResultStored,
  expectProtocolBalanceChanged,
  expectTKBalanceChanged,
} from "./internalEffects.js";

type RegistryContract = GetContractReturnType<readonly unknown[], PublicClient>;

// ============ CreateTOC Interaction ============

export interface CreateTOCParams {
  resolver: Address;
  templateId: number;
  payload: `0x${string}`;
  disputeWindow: number;
  tkWindow: number;
  escalationWindow: number;
  postResolutionWindow: number;
  truthKeeper: Address;
  fee: bigint;
}

export interface CreateTOCExpected {
  expectedTocId: bigint;
  expectedState: TOCState;
  expectedAnswerType: AnswerType;
  expectedTier: AccountabilityTier;
  expectedTrust: ResolverTrust;
  creator: Address;
  tkShareBasisPoints: bigint;
}

export interface CreateTOCContext {
  registry: RegistryContract;
  abi: readonly unknown[];
  logs: Log[];
  params: CreateTOCParams;
  expected: CreateTOCExpected;
  protocolBalanceBefore: bigint;
  tkBalanceBefore: bigint;
}

/**
 * Verify all effects of createTOC in execution order:
 * 1. TOC ID incremented
 * 2. TOC state set to ACTIVE
 * 3. CreationFeesCollected event
 * 4. TOCCreated event
 * 5. Protocol balance increased
 * 6. TK balance increased
 */
export async function expectCreateTOC(
  ctx: CreateTOCContext
): Promise<AggregatedExpectationResult> {
  const results: ExpectationResult[] = [];

  // Calculate fee split
  const feeSplit = calculateFeeSplit(ctx.params.fee, ctx.expected.tkShareBasisPoints);

  // 1. TOC ID incremented
  const idResult = await expectTocIdIncremented({
    registry: ctx.registry,
    expectedNextId: ctx.expected.expectedTocId + 1n,
  });
  results.push(...idResult.results);

  // 2. TOC state set
  const stateResult = await expectTocState({
    registry: ctx.registry,
    tocId: ctx.expected.expectedTocId,
    expectedState: ctx.expected.expectedState,
  });
  results.push(...stateResult.results);

  // 3. CreationFeesCollected event (emitted first)
  results.push(
    expectCreationFeesEvent({
      logs: ctx.logs,
      abi: ctx.abi,
      tocId: ctx.expected.expectedTocId,
      protocolFee: feeSplit.protocolFee,
      tkFee: feeSplit.tkFee,
      resolverFee: 0n,
    })
  );

  // 4. TOCCreated event (emitted second)
  results.push(
    expectTocCreatedEvent({
      logs: ctx.logs,
      abi: ctx.abi,
      tocId: ctx.expected.expectedTocId,
      resolver: ctx.params.resolver,
      trust: ctx.expected.expectedTrust,
      templateId: ctx.params.templateId,
      answerType: ctx.expected.expectedAnswerType,
      initialState: ctx.expected.expectedState,
      truthKeeper: ctx.params.truthKeeper,
      tier: ctx.expected.expectedTier,
    })
  );

  // 5. Protocol balance increased
  const protocolResult = await expectProtocolBalanceChanged({
    registry: ctx.registry,
    category: 0, // CREATION
    expectedDelta: feeSplit.protocolFee,
    balanceBefore: ctx.protocolBalanceBefore,
  });
  results.push(...protocolResult.results);

  // 6. TK balance increased
  const tkResult = await expectTKBalanceChanged({
    registry: ctx.registry,
    truthKeeper: ctx.params.truthKeeper,
    expectedDelta: feeSplit.tkFee,
    balanceBefore: ctx.tkBalanceBefore,
  });
  results.push(...tkResult.results);

  return aggregateResults(results, "createTOC");
}

// ============ ResolveTOC Interaction ============

export interface ResolveTOCParams {
  tocId: bigint;
  bondToken: Address;
  bondAmount: bigint;
  resolverPayload: `0x${string}`;
}

export interface ResolveTOCExpected {
  expectedState: TOCState;
  expectedResult: `0x${string}`;
  expectedAnswerType: AnswerType;
  proposer: Address;
  disputeWindow: bigint;
  isUndisputable: boolean;
}

export interface ResolveTOCContext {
  registry: RegistryContract;
  abi: readonly unknown[];
  logs: Log[];
  params: ResolveTOCParams;
  expected: ResolveTOCExpected;
  timestamp: bigint;
}

/**
 * Verify all effects of resolveTOC in execution order:
 *
 * For disputable TOC:
 * 1. ResolutionBondDeposited event
 * 2. TOCResolutionProposed event
 * 3. TOC state -> RESOLVING
 * 4. Resolution info stored
 *
 * For undisputable TOC:
 * 1. TOCFinalized event
 * 2. TOC state -> RESOLVED
 * 3. Result stored
 */
export async function expectResolveTOC(
  ctx: ResolveTOCContext
): Promise<AggregatedExpectationResult> {
  const results: ExpectationResult[] = [];

  if (ctx.expected.isUndisputable) {
    // Undisputable path
    // 1. TOCFinalized event
    results.push(
      expectTocFinalizedEvent({
        logs: ctx.logs,
        abi: ctx.abi,
        tocId: ctx.params.tocId,
        answerType: ctx.expected.expectedAnswerType,
      })
    );

    // 2. State -> RESOLVED
    const stateResult = await expectTocState({
      registry: ctx.registry,
      tocId: ctx.params.tocId,
      expectedState: TOCState.RESOLVED,
    });
    results.push(...stateResult.results);

    // 3. Result stored
    const resultStorage = await expectResultStored({
      registry: ctx.registry,
      tocId: ctx.params.tocId,
      expectedResult: ctx.expected.expectedResult,
    });
    results.push(...resultStorage.results);
  } else {
    // Disputable path
    const disputeDeadline = calculateDisputeDeadline(
      ctx.timestamp,
      ctx.expected.disputeWindow
    );

    // 1. ResolutionBondDeposited event
    results.push(
      expectResolutionBondEvent({
        logs: ctx.logs,
        abi: ctx.abi,
        tocId: ctx.params.tocId,
        proposer: ctx.expected.proposer,
        token: ctx.params.bondToken,
        amount: ctx.params.bondAmount,
      })
    );

    // 2. TOCResolutionProposed event
    results.push(
      expectResolutionProposedEvent({
        logs: ctx.logs,
        abi: ctx.abi,
        tocId: ctx.params.tocId,
        proposer: ctx.expected.proposer,
        answerType: ctx.expected.expectedAnswerType,
        disputeDeadline,
      })
    );

    // 3. State -> RESOLVING
    const stateResult = await expectTocState({
      registry: ctx.registry,
      tocId: ctx.params.tocId,
      expectedState: TOCState.RESOLVING,
    });
    results.push(...stateResult.results);

    // 4. Resolution info stored
    const resInfoResult = await expectResolutionInfoStored({
      registry: ctx.registry,
      tocId: ctx.params.tocId,
      expectedProposer: ctx.expected.proposer,
      expectedBondToken: ctx.params.bondToken,
      expectedBondAmount: ctx.params.bondAmount,
      expectedResult: ctx.expected.expectedResult,
    });
    results.push(...resInfoResult.results);
  }

  return aggregateResults(results, "resolveTOC");
}

// ============ Dispute Interaction ============

export interface DisputeParams {
  tocId: bigint;
  bondToken: Address;
  bondAmount: bigint;
  reason: string;
  evidenceURI: string;
  proposedResult: `0x${string}`;
}

export interface DisputeExpected {
  expectedState: TOCState;
  expectedPhase: DisputePhase;
  disputer: Address;
}

export interface DisputeContext {
  registry: RegistryContract;
  abi: readonly unknown[];
  logs: Log[];
  params: DisputeParams;
  expected: DisputeExpected;
}

/**
 * Verify all effects of dispute in execution order:
 *
 * For pre-resolution dispute:
 * 1. DisputeBondDeposited event
 * 2. TOCDisputed event
 * 3. State -> DISPUTED_ROUND_1
 * 4. Dispute info stored
 *
 * For post-resolution dispute:
 * 1. DisputeBondDeposited event
 * 2. PostResolutionDisputeFiled event
 * 3. State stays RESOLVED
 * 4. Dispute info stored
 */
export async function expectDispute(
  ctx: DisputeContext
): Promise<AggregatedExpectationResult> {
  const results: ExpectationResult[] = [];
  const isPostResolution = ctx.expected.expectedPhase === DisputePhase.POST_RESOLUTION;

  // 1. DisputeBondDeposited event
  results.push(
    expectDisputeBondEvent({
      logs: ctx.logs,
      abi: ctx.abi,
      tocId: ctx.params.tocId,
      disputer: ctx.expected.disputer,
      token: ctx.params.bondToken,
      amount: ctx.params.bondAmount,
    })
  );

  // 2. Dispute event (different for pre vs post)
  if (isPostResolution) {
    results.push(
      expectPostResolutionDisputeEvent({
        logs: ctx.logs,
        abi: ctx.abi,
        tocId: ctx.params.tocId,
        disputer: ctx.expected.disputer,
        reason: ctx.params.reason,
      })
    );
  } else {
    results.push(
      expectTocDisputedEvent({
        logs: ctx.logs,
        abi: ctx.abi,
        tocId: ctx.params.tocId,
        disputer: ctx.expected.disputer,
        reason: ctx.params.reason,
      })
    );
  }

  // 3. State check
  const stateResult = await expectTocState({
    registry: ctx.registry,
    tocId: ctx.params.tocId,
    expectedState: ctx.expected.expectedState,
  });
  results.push(...stateResult.results);

  // 4. Dispute info stored
  const disputeInfoResult = await expectDisputeInfoStored({
    registry: ctx.registry,
    tocId: ctx.params.tocId,
    expectedPhase: ctx.expected.expectedPhase,
    expectedDisputer: ctx.expected.disputer,
    expectedBondToken: ctx.params.bondToken,
    expectedBondAmount: ctx.params.bondAmount,
  });
  results.push(...disputeInfoResult.results);

  return aggregateResults(results, "dispute");
}

// ============ FinalizeTOC Interaction ============

export interface FinalizeTOCExpected {
  tocId: bigint;
  expectedResult: `0x${string}`;
  expectedAnswerType: AnswerType;
  proposer: Address;
  bondToken: Address;
  bondAmount: bigint;
  postResolutionWindow: bigint;
}

export interface FinalizeTOCContext {
  registry: RegistryContract;
  abi: readonly unknown[];
  logs: Log[];
  expected: FinalizeTOCExpected;
}

/**
 * Verify all effects of finalizeTOC in execution order:
 * 1. TOCFinalized event
 * 2. State -> RESOLVED
 * 3. Result stored
 * 4. ResolutionBondReturned event (only if postResolutionWindow == 0)
 */
export async function expectFinalizeTOC(
  ctx: FinalizeTOCContext
): Promise<AggregatedExpectationResult> {
  const results: ExpectationResult[] = [];

  // 1. TOCFinalized event
  results.push(
    expectTocFinalizedEvent({
      logs: ctx.logs,
      abi: ctx.abi,
      tocId: ctx.expected.tocId,
      answerType: ctx.expected.expectedAnswerType,
    })
  );

  // 2. State -> RESOLVED
  const stateResult = await expectTocState({
    registry: ctx.registry,
    tocId: ctx.expected.tocId,
    expectedState: TOCState.RESOLVED,
  });
  results.push(...stateResult.results);

  // 3. Result stored
  const resultStorage = await expectResultStored({
    registry: ctx.registry,
    tocId: ctx.expected.tocId,
    expectedResult: ctx.expected.expectedResult,
  });
  results.push(...resultStorage.results);

  // 4. Bond returned (only if postResolutionWindow == 0)
  if (ctx.expected.postResolutionWindow === 0n) {
    results.push(
      expectBondReturnEvent({
        logs: ctx.logs,
        abi: ctx.abi,
        tocId: ctx.expected.tocId,
        to: ctx.expected.proposer,
        token: ctx.expected.bondToken,
        amount: ctx.expected.bondAmount,
        bondType: "resolution",
      })
    );
  }

  return aggregateResults(results, "finalizeTOC");
}

// ============ ResolveDispute Interaction ============

export interface ResolveDisputeParams {
  tocId: bigint;
  resolution: DisputeResolution;
  correctedResult: `0x${string}`;
}

export interface ResolveDisputeExpected {
  expectedState: TOCState;
  admin: Address;
  resultCorrected: boolean;
}

export interface ResolveDisputeContext {
  registry: RegistryContract;
  abi: readonly unknown[];
  logs: Log[];
  params: ResolveDisputeParams;
  expected: ResolveDisputeExpected;
}

/**
 * Verify all effects of resolveDispute in execution order:
 * 1. DisputeResolved event
 * 2. State -> expected (RESOLVED or CANCELLED)
 * 3. Result stored (if corrected)
 */
export async function expectResolveDispute(
  ctx: ResolveDisputeContext
): Promise<AggregatedExpectationResult> {
  const results: ExpectationResult[] = [];

  // 1. DisputeResolved event
  results.push(
    expectDisputeResolvedEvent({
      logs: ctx.logs,
      abi: ctx.abi,
      tocId: ctx.params.tocId,
      resolution: ctx.params.resolution,
      admin: ctx.expected.admin,
    })
  );

  // 2. State check
  const stateResult = await expectTocState({
    registry: ctx.registry,
    tocId: ctx.params.tocId,
    expectedState: ctx.expected.expectedState,
  });
  results.push(...stateResult.results);

  // 3. Result stored if corrected
  if (ctx.expected.resultCorrected) {
    const resultStorage = await expectResultStored({
      registry: ctx.registry,
      tocId: ctx.params.tocId,
      expectedResult: ctx.params.correctedResult,
    });
    results.push(...resultStorage.results);
  }

  return aggregateResults(results, "resolveDispute");
}

// ============ Convenience Export ============

export {
  aggregateResults,
  assertAllPassed,
  calculateFeeSplit,
  calculateDisputeDeadline,
  TOCState,
  AnswerType,
  AccountabilityTier,
  ResolverTrust,
  DisputePhase,
  DisputeResolution,
};
