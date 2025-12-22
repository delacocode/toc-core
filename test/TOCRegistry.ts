/**
 * TOCRegistry TypeScript Tests using Expectations Architecture
 *
 * This demonstrates the three-tier expectations pattern:
 * - Tier 1: Base utilities (storage, events, balances)
 * - Tier 2: Internal effects (single effect verification)
 * - Tier 3: Interaction expectations (complete operation verification)
 */

import assert from "node:assert/strict";
import { describe, it, before } from "node:test";
import { network } from "hardhat";
import { parseEther, encodeAbiParameters, zeroAddress, type Address, type Hash } from "viem";
import {
  expectCreateTOC,
  expectResolveTOC,
  expectFinalizeTOC,
  expectDispute,
  assertAllPassed,
  TOCState,
  AnswerType,
  AccountabilityTier,
  ResolverTrust,
  DisputePhase,
} from "./expectations/tocRegistry/index.js";

// ABI for TOCRegistry events (subset needed for testing)
const REGISTRY_ABI = [
  {
    type: "event",
    name: "TOCCreated",
    inputs: [
      { name: "tocId", type: "uint256", indexed: true },
      { name: "resolver", type: "address", indexed: true },
      { name: "trust", type: "uint8", indexed: false },
      { name: "templateId", type: "uint32", indexed: false },
      { name: "answerType", type: "uint8", indexed: false },
      { name: "initialState", type: "uint8", indexed: false },
      { name: "truthKeeper", type: "address", indexed: true },
      { name: "tier", type: "uint8", indexed: false },
    ],
  },
  {
    type: "event",
    name: "CreationFeesCollected",
    inputs: [
      { name: "tocId", type: "uint256", indexed: true },
      { name: "protocolFee", type: "uint256", indexed: false },
      { name: "tkFee", type: "uint256", indexed: false },
      { name: "resolverFee", type: "uint256", indexed: false },
    ],
  },
  {
    type: "event",
    name: "TOCResolutionProposed",
    inputs: [
      { name: "tocId", type: "uint256", indexed: true },
      { name: "proposer", type: "address", indexed: true },
      { name: "answerType", type: "uint8", indexed: false },
      { name: "disputeDeadline", type: "uint256", indexed: false },
    ],
  },
  {
    type: "event",
    name: "ResolutionBondDeposited",
    inputs: [
      { name: "tocId", type: "uint256", indexed: true },
      { name: "proposer", type: "address", indexed: true },
      { name: "token", type: "address", indexed: false },
      { name: "amount", type: "uint256", indexed: false },
    ],
  },
  {
    type: "event",
    name: "TOCFinalized",
    inputs: [
      { name: "tocId", type: "uint256", indexed: true },
      { name: "answerType", type: "uint8", indexed: false },
    ],
  },
  {
    type: "event",
    name: "DisputeBondDeposited",
    inputs: [
      { name: "tocId", type: "uint256", indexed: true },
      { name: "disputer", type: "address", indexed: true },
      { name: "token", type: "address", indexed: false },
      { name: "amount", type: "uint256", indexed: false },
    ],
  },
  {
    type: "event",
    name: "TOCDisputed",
    inputs: [
      { name: "tocId", type: "uint256", indexed: true },
      { name: "disputer", type: "address", indexed: true },
      { name: "reason", type: "string", indexed: false },
    ],
  },
  {
    type: "event",
    name: "PostResolutionDisputeFiled",
    inputs: [
      { name: "tocId", type: "uint256", indexed: true },
      { name: "disputer", type: "address", indexed: true },
      { name: "reason", type: "string", indexed: false },
    ],
  },
  {
    type: "event",
    name: "ResolutionBondReturned",
    inputs: [
      { name: "tocId", type: "uint256", indexed: true },
      { name: "to", type: "address", indexed: true },
      { name: "token", type: "address", indexed: false },
      { name: "amount", type: "uint256", indexed: false },
    ],
  },
] as const;

// Helper to encode boolean result
function encodeBooleanResult(value: boolean): `0x${string}` {
  return encodeAbiParameters(
    [{ type: "bool" }],
    [value]
  );
}

// Helper to encode OptimisticResolver ArbitraryPayload (template 0)
// Struct encoding: (string question, string description, string resolutionSource, uint256 resolutionTime)
function encodeArbitraryPayload(
  question: string,
  description: string,
  resolutionSource: string,
  resolutionTime: bigint
): `0x${string}` {
  return encodeAbiParameters(
    [
      {
        type: "tuple",
        components: [
          { name: "question", type: "string" },
          { name: "description", type: "string" },
          { name: "resolutionSource", type: "string" },
          { name: "resolutionTime", type: "uint256" },
        ],
      },
    ],
    [{ question, description, resolutionSource, resolutionTime }]
  );
}

// Helper to encode OptimisticResolver AnswerPayload for resolution
// Struct encoding: (bool answer, string justification)
function encodeAnswerPayload(
  answer: boolean,
  justification: string
): `0x${string}` {
  return encodeAbiParameters(
    [
      {
        type: "tuple",
        components: [
          { name: "answer", type: "bool" },
          { name: "justification", type: "string" },
        ],
      },
    ],
    [{ answer, justification }]
  );
}

describe("TOCRegistry with Expectations", async function () {
  const { viem } = await network.connect();
  const publicClient = await viem.getPublicClient();
  const [deployer, user1] = await viem.getWalletClients();

  // Constants
  const MIN_RESOLUTION_BOND = parseEther("0.1");
  const MIN_DISPUTE_BOND = parseEther("0.05");
  const MIN_ESCALATION_BOND = parseEther("0.15");
  const PROTOCOL_FEE = parseEther("0.001");
  const DEFAULT_DISPUTE_WINDOW = 12n * 60n * 60n; // 12 hours (within 1-day limit for RESOLVER trust)
  const DEFAULT_TK_WINDOW = 12n * 60n * 60n;
  const DEFAULT_ESCALATION_WINDOW = 12n * 60n * 60n;
  const DEFAULT_POST_RESOLUTION_WINDOW = 12n * 60n * 60n;
  const TK_SHARE_BASIS_POINTS = 4000n; // 40%

  // Contracts
  let registry: Awaited<ReturnType<typeof viem.deployContract>>;
  let resolver: Awaited<ReturnType<typeof viem.deployContract>>;
  let truthKeeper: Awaited<ReturnType<typeof viem.deployContract>>;

  before(async () => {
    // Deploy TOCRegistry
    registry = await viem.deployContract("TOCRegistry");

    // Deploy OptimisticResolver (real resolver)
    resolver = await viem.deployContract("OptimisticResolver", [registry.address]);

    // Deploy MockTruthKeeper (TruthKeeper is an interface, needs mock implementation)
    truthKeeper = await viem.deployContract("MockTruthKeeper", [registry.address]);

    // Configure registry
    await registry.write.addAcceptableResolutionBond([zeroAddress, MIN_RESOLUTION_BOND]);
    await registry.write.addAcceptableDisputeBond([zeroAddress, MIN_DISPUTE_BOND]);
    await registry.write.addAcceptableEscalationBond([zeroAddress, MIN_ESCALATION_BOND]);
    await registry.write.addWhitelistedTruthKeeper([truthKeeper.address]);
    await registry.write.setProtocolFeeStandard([PROTOCOL_FEE]);
    await registry.write.setTKSharePercent([AccountabilityTier.TK_GUARANTEED, TK_SHARE_BASIS_POINTS]);
    await registry.write.setTKSharePercent([AccountabilityTier.SYSTEM, 6000n]);
    await registry.write.registerResolver([resolver.address]);
  });

  describe("TOC Creation", () => {
    it("should create TOC with full effect verification", async () => {
      // Use proper ArbitraryPayload format for OptimisticResolver template 1 (TEMPLATE_ARBITRARY)
      const futureTime = BigInt(Math.floor(Date.now() / 1000) + 86400 * 30); // 30 days from now
      const payload = encodeArbitraryPayload(
        "Will BTC hit $100k?",
        "Bitcoin price reaching $100,000 USD",
        "CoinGecko",
        futureTime
      );

      // Capture state before
      const protocolBalanceBefore = await registry.read.getProtocolBalance([0]); // CREATION category
      const tkBalanceBefore = await registry.read.getTKBalance([truthKeeper.address]);

      // Execute createTOC
      const hash = await registry.write.createTOC(
        [
          resolver.address,
          1, // templateId (TEMPLATE_ARBITRARY)
          payload,
          DEFAULT_DISPUTE_WINDOW,
          DEFAULT_TK_WINDOW,
          DEFAULT_ESCALATION_WINDOW,
          DEFAULT_POST_RESOLUTION_WINDOW,
          truthKeeper.address,
        ],
        { value: PROTOCOL_FEE }
      );

      // Get receipt and logs
      const receipt = await publicClient.getTransactionReceipt({ hash });
      const block = await publicClient.getBlock({ blockNumber: receipt.blockNumber });

      // Verify all effects using expectCreateTOC
      const result = await expectCreateTOC({
        registry: registry as unknown as Parameters<typeof expectCreateTOC>[0]["registry"],
        abi: REGISTRY_ABI,
        logs: receipt.logs,
        params: {
          resolver: resolver.address,
          templateId: 1,
          payload: payload as `0x${string}`,
          disputeWindow: Number(DEFAULT_DISPUTE_WINDOW),
          tkWindow: Number(DEFAULT_TK_WINDOW),
          escalationWindow: Number(DEFAULT_ESCALATION_WINDOW),
          postResolutionWindow: Number(DEFAULT_POST_RESOLUTION_WINDOW),
          truthKeeper: truthKeeper.address,
          fee: PROTOCOL_FEE,
        },
        expected: {
          expectedTocId: 1n,
          expectedState: TOCState.ACTIVE,
          expectedAnswerType: AnswerType.BOOLEAN,
          expectedTier: AccountabilityTier.TK_GUARANTEED,
          expectedTrust: ResolverTrust.RESOLVER,
          creator: deployer.account.address,
          tkShareBasisPoints: TK_SHARE_BASIS_POINTS,
        },
        protocolBalanceBefore: protocolBalanceBefore as bigint,
        tkBalanceBefore: tkBalanceBefore as bigint,
      });

      // Assert all expectations passed
      assertAllPassed(result);
      console.log(`  ✓ ${result.summary}`);
    });
  });

  describe("TOC Resolution", () => {
    it("should resolve disputable TOC with full effect verification", async () => {
      // First create a TOC
      const futureTime = BigInt(Math.floor(Date.now() / 1000) + 86400 * 30);
      const payload = encodeArbitraryPayload("Test resolution", "Test description", "Test source", futureTime);
      await registry.write.createTOC(
        [
          resolver.address,
          1, // TEMPLATE_ARBITRARY
          payload,
          DEFAULT_DISPUTE_WINDOW,
          DEFAULT_TK_WINDOW,
          DEFAULT_ESCALATION_WINDOW,
          DEFAULT_POST_RESOLUTION_WINDOW,
          truthKeeper.address,
        ],
        { value: PROTOCOL_FEE }
      );

      const tocId = (await registry.read.nextTocId()) as bigint - 1n;
      const expectedResult = encodeBooleanResult(true);
      const answerPayload = encodeAnswerPayload(true, "BTC did reach $100k");

      // Execute resolveTOC
      const hash = await registry.write.resolveTOC(
        [tocId, zeroAddress, MIN_RESOLUTION_BOND, answerPayload],
        { value: MIN_RESOLUTION_BOND }
      );

      const receipt = await publicClient.getTransactionReceipt({ hash });
      const block = await publicClient.getBlock({ blockNumber: receipt.blockNumber });

      // Verify all effects
      const result = await expectResolveTOC({
        registry: registry as unknown as Parameters<typeof expectResolveTOC>[0]["registry"],
        abi: REGISTRY_ABI,
        logs: receipt.logs,
        params: {
          tocId,
          bondToken: zeroAddress,
          bondAmount: MIN_RESOLUTION_BOND,
          resolverPayload: answerPayload,
        },
        expected: {
          expectedState: TOCState.RESOLVING,
          expectedResult,
          expectedAnswerType: AnswerType.BOOLEAN,
          proposer: deployer.account.address,
          disputeWindow: DEFAULT_DISPUTE_WINDOW,
          isUndisputable: false,
        },
        timestamp: block.timestamp,
      });

      assertAllPassed(result);
      console.log(`  ✓ ${result.summary}`);
    });

    it("should resolve undisputable TOC directly to RESOLVED", async () => {
      // Create undisputable TOC (all windows = 0)
      const futureTime = BigInt(Math.floor(Date.now() / 1000) + 86400 * 30);
      const payload = encodeArbitraryPayload("Undisputable test", "Test description", "Test source", futureTime);
      await registry.write.createTOC(
        [
          resolver.address,
          1, // TEMPLATE_ARBITRARY
          payload,
          0n, // disputeWindow
          0n, // tkWindow
          0n, // escalationWindow
          0n, // postResolutionWindow
          truthKeeper.address,
        ],
        { value: PROTOCOL_FEE }
      );

      const tocId = (await registry.read.nextTocId()) as bigint - 1n;
      const expectedResult = encodeBooleanResult(true);
      const answerPayload = encodeAnswerPayload(true, "Test passed");

      // Execute resolveTOC
      const hash = await registry.write.resolveTOC(
        [tocId, zeroAddress, 0n, answerPayload],
        { value: 0n }
      );

      const receipt = await publicClient.getTransactionReceipt({ hash });
      const block = await publicClient.getBlock({ blockNumber: receipt.blockNumber });

      // Verify undisputable path
      const result = await expectResolveTOC({
        registry: registry as unknown as Parameters<typeof expectResolveTOC>[0]["registry"],
        abi: REGISTRY_ABI,
        logs: receipt.logs,
        params: {
          tocId,
          bondToken: zeroAddress,
          bondAmount: 0n,
          resolverPayload: answerPayload,
        },
        expected: {
          expectedState: TOCState.RESOLVED,
          expectedResult,
          expectedAnswerType: AnswerType.BOOLEAN,
          proposer: deployer.account.address,
          disputeWindow: 0n,
          isUndisputable: true,
        },
        timestamp: block.timestamp,
      });

      assertAllPassed(result);
      console.log(`  ✓ ${result.summary}`);
    });
  });

  describe("Full Lifecycle", () => {
    it("should complete full lifecycle: create -> resolve -> finalize", async () => {
      // 1. Create TOC
      const futureTime = BigInt(Math.floor(Date.now() / 1000) + 86400 * 30);
      const payload = encodeArbitraryPayload("Full lifecycle test", "Test description", "Test source", futureTime);
      const protocolBalanceBefore = await registry.read.getProtocolBalance([0]) as bigint;
      const tkBalanceBefore = await registry.read.getTKBalance([truthKeeper.address]) as bigint;

      const createHash = await registry.write.createTOC(
        [
          resolver.address,
          1, // TEMPLATE_ARBITRARY
          payload,
          DEFAULT_DISPUTE_WINDOW,
          DEFAULT_TK_WINDOW,
          DEFAULT_ESCALATION_WINDOW,
          DEFAULT_POST_RESOLUTION_WINDOW,
          truthKeeper.address,
        ],
        { value: PROTOCOL_FEE }
      );

      const createReceipt = await publicClient.getTransactionReceipt({ hash: createHash });
      const tocId = (await registry.read.nextTocId()) as bigint - 1n;

      const createResult = await expectCreateTOC({
        registry: registry as unknown as Parameters<typeof expectCreateTOC>[0]["registry"],
        abi: REGISTRY_ABI,
        logs: createReceipt.logs,
        params: {
          resolver: resolver.address,
          templateId: 1,
          payload: payload as `0x${string}`,
          disputeWindow: Number(DEFAULT_DISPUTE_WINDOW),
          tkWindow: Number(DEFAULT_TK_WINDOW),
          escalationWindow: Number(DEFAULT_ESCALATION_WINDOW),
          postResolutionWindow: Number(DEFAULT_POST_RESOLUTION_WINDOW),
          truthKeeper: truthKeeper.address,
          fee: PROTOCOL_FEE,
        },
        expected: {
          expectedTocId: tocId,
          expectedState: TOCState.ACTIVE,
          expectedAnswerType: AnswerType.BOOLEAN,
          expectedTier: AccountabilityTier.TK_GUARANTEED,
          expectedTrust: ResolverTrust.RESOLVER,
          creator: deployer.account.address,
          tkShareBasisPoints: TK_SHARE_BASIS_POINTS,
        },
        protocolBalanceBefore,
        tkBalanceBefore,
      });
      assertAllPassed(createResult);
      console.log(`  ✓ Create: ${createResult.summary}`);

      // 2. Resolve TOC
      const expectedResult = encodeBooleanResult(true);
      const answerPayload = encodeAnswerPayload(true, "Lifecycle test resolution");
      const resolveHash = await registry.write.resolveTOC(
        [tocId, zeroAddress, MIN_RESOLUTION_BOND, answerPayload],
        { value: MIN_RESOLUTION_BOND }
      );

      const resolveReceipt = await publicClient.getTransactionReceipt({ hash: resolveHash });
      const resolveBlock = await publicClient.getBlock({ blockNumber: resolveReceipt.blockNumber });

      const resolveResult = await expectResolveTOC({
        registry: registry as unknown as Parameters<typeof expectResolveTOC>[0]["registry"],
        abi: REGISTRY_ABI,
        logs: resolveReceipt.logs,
        params: {
          tocId,
          bondToken: zeroAddress,
          bondAmount: MIN_RESOLUTION_BOND,
          resolverPayload: answerPayload,
        },
        expected: {
          expectedState: TOCState.RESOLVING,
          expectedResult,
          expectedAnswerType: AnswerType.BOOLEAN,
          proposer: deployer.account.address,
          disputeWindow: DEFAULT_DISPUTE_WINDOW,
          isUndisputable: false,
        },
        timestamp: resolveBlock.timestamp,
      });
      assertAllPassed(resolveResult);
      console.log(`  ✓ Resolve: ${resolveResult.summary}`);

      // 3. Time travel past dispute window
      await publicClient.request({
        method: "evm_increaseTime" as "evm_mine",
        params: [Number(DEFAULT_DISPUTE_WINDOW) + 1],
      } as any);
      await publicClient.request({
        method: "evm_mine",
        params: [],
      } as any);

      // 4. Finalize TOC
      const finalizeHash = await registry.write.finalizeTOC([tocId]);
      const finalizeReceipt = await publicClient.getTransactionReceipt({ hash: finalizeHash });

      const finalizeResult = await expectFinalizeTOC({
        registry: registry as unknown as Parameters<typeof expectFinalizeTOC>[0]["registry"],
        abi: REGISTRY_ABI,
        logs: finalizeReceipt.logs,
        expected: {
          tocId,
          expectedResult,
          expectedAnswerType: AnswerType.BOOLEAN,
          proposer: deployer.account.address,
          bondToken: zeroAddress,
          bondAmount: MIN_RESOLUTION_BOND,
          postResolutionWindow: DEFAULT_POST_RESOLUTION_WINDOW,
        },
      });
      assertAllPassed(finalizeResult);
      console.log(`  ✓ Finalize: ${finalizeResult.summary}`);

      // 5. Verify final state
      const toc = await registry.read.getTOC([tocId]) as { state: number };
      assert.equal(toc.state, TOCState.RESOLVED, "Final state should be RESOLVED");
      console.log("  ✓ Final state verified: RESOLVED");
    });
  });
});
