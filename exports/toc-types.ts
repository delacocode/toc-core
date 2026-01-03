/**
 * TOC TypeScript Types
 * Generated from ITOCConsumer.sol - keep in sync with contract types
 */

// ============ Enums ============

/** States a TOC can be in throughout its lifecycle */
export enum TOCState {
  NONE = 0,              // Default/uninitialized
  PENDING = 1,           // Created, awaiting resolver approval
  REJECTED = 2,          // Resolver rejected during creation
  ACTIVE = 3,            // Approved, markets can trade
  RESOLVING = 4,         // Outcome proposed, dispute window open
  DISPUTED_ROUND_1 = 5,  // Dispute raised, TruthKeeper reviewing
  DISPUTED_ROUND_2 = 6,  // TK decision challenged, Admin reviewing
  RESOLVED = 7,          // Final outcome set, immutable
  CANCELLED = 8,         // Admin cancelled, markets should refund
}

/** Types of answers a TOC can have */
export enum AnswerType {
  NONE = 0,      // Default/uninitialized
  BOOLEAN = 1,   // True/False answer
  NUMERIC = 2,   // int256 answer (prices, scores, etc.)
  GENERIC = 3,   // bytes answer (arbitrary data)
}

/** Trust level for resolvers */
export enum ResolverTrust {
  NONE = 0,      // Not registered
  RESOLVER = 1,  // Registered, no system guarantees
  VERIFIED = 2,  // Admin reviewed
  SYSTEM = 3,    // Full system backing
}

/** Accountability tier for a TOC (snapshot at creation) */
export enum AccountabilityTier {
  NONE = 0,           // Default/uninitialized
  RESOLVER = 1,       // No guarantees - creator's risk
  TK_GUARANTEED = 2,  // TruthKeeper guarantees response
  SYSTEM = 3,         // System takes full accountability
}

/** Types of sports questions */
export enum SportQuestionType {
  WINNER = 0,      // Which team wins?
  SPREAD = 1,      // Does home team cover spread?
  OVER_UNDER = 2,  // Is total score over/under line?
}

// ============ Structs ============

/** Core TOC data */
export interface TOC {
  resolver: `0x${string}`;
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
  truthKeeper: `0x${string}`;
  tierAtCreation: AccountabilityTier;
}

/** Result with full resolution context for consumers */
export interface ExtensiveResult {
  answerType: AnswerType;
  result: `0x${string}`;        // ABI-encoded result
  isFinalized: boolean;          // State == RESOLVED
  wasDisputed: boolean;          // Had a dispute filed
  wasCorrected: boolean;         // Dispute upheld, result changed
  resolvedAt: bigint;            // Timestamp of resolution
  tier: AccountabilityTier;      // SYSTEM/TK_GUARANTEED/RESOLVER
  resolverTrust: ResolverTrust;
}

// ============ OptimisticResolver Payloads ============

/** Payload for Template 1: Arbitrary Question */
export interface ArbitraryPayload {
  question: string;
  description: string;
  resolutionSource: string;
  resolutionTime: bigint;
}

/** Payload for Template 2: Sports Outcome */
export interface SportsPayload {
  league: string;
  homeTeam: string;
  awayTeam: string;
  gameTime: bigint;
  questionType: SportQuestionType;
  line: bigint;  // For spread/over-under (scaled 1e18)
}

/** Payload for Template 3: Event Occurrence */
export interface EventPayload {
  eventDescription: string;
  verificationSource: string;
  deadline: bigint;
}

/** Answer payload for resolution proposals */
export interface AnswerPayload {
  answer: boolean;
  justification: string;
}

// ============ PythPriceResolver Payloads ============

/** Payload for Pyth Template 0: Snapshot (Above/Below) */
export interface PythSnapshotPayload {
  priceId: `0x${string}`;  // Pyth price feed ID (bytes32)
  threshold: bigint;        // Price threshold (8 decimals)
  isAbove: boolean;         // true = above, false = below
  deadline: bigint;         // When to check the price
}

/** Payload for Pyth Template 1: Range */
export interface PythRangePayload {
  priceId: `0x${string}`;  // Pyth price feed ID (bytes32)
  lowerBound: bigint;       // Lower price bound (8 decimals)
  upperBound: bigint;       // Upper price bound (8 decimals)
  deadline: bigint;         // When to check the price
}

/** Payload for Pyth Template 2: Reached By */
export interface PythReachedByPayload {
  priceId: `0x${string}`;  // Pyth price feed ID (bytes32)
  targetPrice: bigint;      // Target price (8 decimals)
  isAbove: boolean;         // true = must go above, false = must go below
  deadline: bigint;         // Must reach target before this time
}

// ============ Template IDs ============

/** OptimisticResolver template IDs */
export const OPTIMISTIC_TEMPLATE = {
  NONE: 0,
  ARBITRARY: 1,
  SPORTS: 2,
  EVENT: 3,
} as const;

/** PythPriceResolver template IDs */
export const PYTH_TEMPLATE = {
  SNAPSHOT: 0,
  RANGE: 1,
  REACHED_BY: 2,
} as const;

// ============ Pyth Price Feed IDs ============

/** Common Pyth price feed IDs (same across all networks) */
export const PYTH_PRICE_IDS = {
  "BTC/USD": "0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43",
  "ETH/USD": "0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace",
  "SOL/USD": "0xef0d8b6fda2ceba41da15d4095d1da392a0d2f8ed0c6c7bc0f4cfac8c280b56d",
  "USDC/USD": "0xeaa020c61cc479712813461ce153894a96a6c00b21ed0cfc2798d1f9a9e9c94a",
  "USDT/USD": "0x2b89b9dc8fdf9f34709a5b106b472f0f39bb6ca9ce04b0fd7f2e971688e2e53b",
} as const;

// ============ Utility Functions ============

/**
 * Convert USD price to Pyth format (8 decimals)
 * @param usd - Price in USD (e.g., 100000 for $100,000)
 * @returns Price in Pyth int64 format
 */
export function usdToPythPrice(usd: number): bigint {
  return BigInt(Math.round(usd * 1e8));
}

/**
 * Convert Pyth price to USD
 * @param pythPrice - Price in Pyth format
 * @returns Price in USD
 */
export function pythPriceToUsd(pythPrice: bigint): number {
  return Number(pythPrice) / 1e8;
}

/**
 * Decode a boolean result from ABI-encoded bytes
 * @param data - ABI-encoded boolean
 * @returns The decoded boolean
 */
export function decodeBoolean(data: `0x${string}`): boolean {
  // ABI-encoded bool is 32 bytes, last byte is 0x00 or 0x01
  return data.slice(-2) === "01";
}

/**
 * Decode a numeric result from ABI-encoded bytes
 * @param data - ABI-encoded int256
 * @returns The decoded bigint
 */
export function decodeNumeric(data: `0x${string}`): bigint {
  // Remove 0x prefix and parse as hex
  return BigInt(data);
}

/**
 * Check if a TOC state allows trading
 */
export function canTrade(state: TOCState): boolean {
  return state === TOCState.ACTIVE;
}

/**
 * Check if a TOC state means it's settled
 */
export function isSettled(state: TOCState): boolean {
  return state === TOCState.RESOLVED;
}

/**
 * Check if a TOC state means it's cancelled (refund needed)
 */
export function isCancelled(state: TOCState): boolean {
  return state === TOCState.CANCELLED;
}

/**
 * Check if a TOC is in a pending/disputed state
 */
export function isPending(state: TOCState): boolean {
  return (
    state === TOCState.PENDING ||
    state === TOCState.RESOLVING ||
    state === TOCState.DISPUTED_ROUND_1 ||
    state === TOCState.DISPUTED_ROUND_2
  );
}

// ============ ABI Fragments ============

/** Minimal ABI for ITruthEngine consumer functions */
export const TRUTH_ENGINE_ABI = [
  {
    name: "createTOC",
    type: "function",
    stateMutability: "payable",
    inputs: [
      { name: "resolver", type: "address" },
      { name: "templateId", type: "uint32" },
      { name: "payload", type: "bytes" },
      { name: "disputeWindow", type: "uint256" },
      { name: "truthKeeperWindow", type: "uint256" },
      { name: "escalationWindow", type: "uint256" },
      { name: "postResolutionWindow", type: "uint256" },
      { name: "truthKeeper", type: "address" },
    ],
    outputs: [{ name: "tocId", type: "uint256" }],
  },
  {
    name: "resolveTOC",
    type: "function",
    stateMutability: "payable",
    inputs: [
      { name: "tocId", type: "uint256" },
      { name: "bondToken", type: "address" },
      { name: "bondAmount", type: "uint256" },
      { name: "payload", type: "bytes" },
    ],
    outputs: [],
  },
  {
    name: "finalizeTOC",
    type: "function",
    stateMutability: "nonpayable",
    inputs: [{ name: "tocId", type: "uint256" }],
    outputs: [],
  },
  {
    name: "getTOC",
    type: "function",
    stateMutability: "view",
    inputs: [{ name: "tocId", type: "uint256" }],
    outputs: [
      {
        name: "",
        type: "tuple",
        components: [
          { name: "resolver", type: "address" },
          { name: "state", type: "uint8" },
          { name: "answerType", type: "uint8" },
          { name: "resolutionTime", type: "uint256" },
          { name: "disputeWindow", type: "uint256" },
          { name: "truthKeeperWindow", type: "uint256" },
          { name: "escalationWindow", type: "uint256" },
          { name: "postResolutionWindow", type: "uint256" },
          { name: "disputeDeadline", type: "uint256" },
          { name: "truthKeeperDeadline", type: "uint256" },
          { name: "escalationDeadline", type: "uint256" },
          { name: "postDisputeDeadline", type: "uint256" },
          { name: "truthKeeper", type: "address" },
          { name: "tierAtCreation", type: "uint8" },
        ],
      },
    ],
  },
  {
    name: "getResult",
    type: "function",
    stateMutability: "view",
    inputs: [{ name: "tocId", type: "uint256" }],
    outputs: [{ name: "result", type: "bytes" }],
  },
  {
    name: "getExtensiveResult",
    type: "function",
    stateMutability: "view",
    inputs: [{ name: "tocId", type: "uint256" }],
    outputs: [
      {
        name: "result",
        type: "tuple",
        components: [
          { name: "answerType", type: "uint8" },
          { name: "result", type: "bytes" },
          { name: "isFinalized", type: "bool" },
          { name: "wasDisputed", type: "bool" },
          { name: "wasCorrected", type: "bool" },
          { name: "resolvedAt", type: "uint256" },
          { name: "tier", type: "uint8" },
          { name: "resolverTrust", type: "uint8" },
        ],
      },
    ],
  },
  {
    name: "getExtensiveResultStrict",
    type: "function",
    stateMutability: "view",
    inputs: [{ name: "tocId", type: "uint256" }],
    outputs: [
      {
        name: "result",
        type: "tuple",
        components: [
          { name: "answerType", type: "uint8" },
          { name: "result", type: "bytes" },
          { name: "isFinalized", type: "bool" },
          { name: "wasDisputed", type: "bool" },
          { name: "wasCorrected", type: "bool" },
          { name: "resolvedAt", type: "uint256" },
          { name: "tier", type: "uint8" },
          { name: "resolverTrust", type: "uint8" },
        ],
      },
    ],
  },
  {
    name: "getTocQuestion",
    type: "function",
    stateMutability: "view",
    inputs: [{ name: "tocId", type: "uint256" }],
    outputs: [{ name: "question", type: "string" }],
  },
  {
    name: "isFullyFinalized",
    type: "function",
    stateMutability: "view",
    inputs: [{ name: "tocId", type: "uint256" }],
    outputs: [{ name: "", type: "bool" }],
  },
  {
    name: "getCreationFee",
    type: "function",
    stateMutability: "view",
    inputs: [
      { name: "resolver", type: "address" },
      { name: "templateId", type: "uint32" },
    ],
    outputs: [
      { name: "protocolFee", type: "uint256" },
      { name: "resolverFee", type: "uint256" },
      { name: "total", type: "uint256" },
    ],
  },
  {
    name: "nextTocId",
    type: "function",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "uint256" }],
  },
] as const;

// ============ Type Exports ============

export type PythAsset = keyof typeof PYTH_PRICE_IDS;
export type OptimisticTemplateId = (typeof OPTIMISTIC_TEMPLATE)[keyof typeof OPTIMISTIC_TEMPLATE];
export type PythTemplateId = (typeof PYTH_TEMPLATE)[keyof typeof PYTH_TEMPLATE];
