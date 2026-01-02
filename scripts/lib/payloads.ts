/**
 * Payload encoding/decoding utilities for TOC templates
 * Matches the struct definitions in OptimisticResolver.sol
 */

import { encodeAbiParameters, decodeAbiParameters } from "viem";

// Template IDs
export const TEMPLATE = {
  ARBITRARY: 1,
  SPORTS: 2,
  EVENT: 3,
} as const;

// ============================================
// Template 1: Arbitrary Question
// ============================================

export interface ArbitraryPayload {
  question: string;
  description: string;
  resolutionSource: string;
  resolutionTime: bigint;
}

const ARBITRARY_PAYLOAD_TYPE = [
  {
    type: "tuple",
    components: [
      { name: "question", type: "string" },
      { name: "description", type: "string" },
      { name: "resolutionSource", type: "string" },
      { name: "resolutionTime", type: "uint256" },
    ],
  },
] as const;

export function encodeArbitraryPayload(payload: ArbitraryPayload): `0x${string}` {
  return encodeAbiParameters(ARBITRARY_PAYLOAD_TYPE, [payload]);
}

export function decodeArbitraryPayload(data: `0x${string}`): ArbitraryPayload {
  const [decoded] = decodeAbiParameters(ARBITRARY_PAYLOAD_TYPE, data);
  return {
    question: decoded.question,
    description: decoded.description,
    resolutionSource: decoded.resolutionSource,
    resolutionTime: decoded.resolutionTime,
  };
}

// ============================================
// Answer Payload (used for resolution)
// ============================================

export interface AnswerPayload {
  answer: boolean;
  justification: string;
}

const ANSWER_PAYLOAD_TYPE = [
  {
    type: "tuple",
    components: [
      { name: "answer", type: "bool" },
      { name: "justification", type: "string" },
    ],
  },
] as const;

export function encodeAnswerPayload(payload: AnswerPayload): `0x${string}` {
  return encodeAbiParameters(ANSWER_PAYLOAD_TYPE, [payload]);
}

export function decodeAnswerPayload(data: `0x${string}`): AnswerPayload {
  const [decoded] = decodeAbiParameters(ANSWER_PAYLOAD_TYPE, data);
  return {
    answer: decoded.answer,
    justification: decoded.justification,
  };
}

// ============================================
// PythPriceResolver Templates
// ============================================

// Pyth template IDs (from PythPriceResolver.sol)
export const PYTH_TEMPLATE = {
  SNAPSHOT: 0,     // Is price above/below threshold at deadline?
  RANGE: 1,        // Is price within range at deadline?
  REACHED_BY: 2,   // Did price reach target before deadline?
} as const;

// Common Pyth Price Feed IDs
// Full list: https://www.pyth.network/developers/price-feed-ids
// Note: Price feed IDs are the same across all networks (mainnet & testnet)
export const PYTH_PRICE_IDS = {
  "BTC/USD": "0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43",
  "ETH/USD": "0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace",
  "SOL/USD": "0xef0d8b6fda2ceba41da15d4095d1da392a0d2f8ed0c6c7bc0f4cfac8c280b56d",
  "USDC/USD": "0xeaa020c61cc479712813461ce153894a96a6c00b21ed0cfc2798d1f9a9e9c94a",
  "USDT/USD": "0x2b89b9dc8fdf9f34709a5b106b472f0f39bb6ca9ce04b0fd7f2e971688e2e53b",
} as const;

// ============================================
// Pyth Template 0: Snapshot (Above/Below)
// ============================================

export interface SnapshotPayload {
  priceId: `0x${string}`;
  threshold: bigint;  // Price in Pyth format (8 decimals, e.g., 100000_00000000 = $100,000)
  isAbove: boolean;   // true = "above", false = "below"
  deadline: bigint;   // Unix timestamp
}

const SNAPSHOT_PAYLOAD_TYPE = [
  { name: "priceId", type: "bytes32" },
  { name: "threshold", type: "int64" },
  { name: "isAbove", type: "bool" },
  { name: "deadline", type: "uint256" },
] as const;

export function encodeSnapshotPayload(payload: SnapshotPayload): `0x${string}` {
  return encodeAbiParameters(SNAPSHOT_PAYLOAD_TYPE, [
    payload.priceId,
    payload.threshold,
    payload.isAbove,
    payload.deadline,
  ]);
}

export function decodeSnapshotPayload(data: `0x${string}`): SnapshotPayload {
  const [priceId, threshold, isAbove, deadline] = decodeAbiParameters(SNAPSHOT_PAYLOAD_TYPE, data);
  return { priceId: priceId as `0x${string}`, threshold, isAbove, deadline };
}

// ============================================
// Pyth Template 1: Range
// ============================================

export interface RangePayload {
  priceId: `0x${string}`;
  lowerBound: bigint;
  upperBound: bigint;
  deadline: bigint;
}

const RANGE_PAYLOAD_TYPE = [
  { name: "priceId", type: "bytes32" },
  { name: "lowerBound", type: "int64" },
  { name: "upperBound", type: "int64" },
  { name: "deadline", type: "uint256" },
] as const;

export function encodeRangePayload(payload: RangePayload): `0x${string}` {
  return encodeAbiParameters(RANGE_PAYLOAD_TYPE, [
    payload.priceId,
    payload.lowerBound,
    payload.upperBound,
    payload.deadline,
  ]);
}

export function decodeRangePayload(data: `0x${string}`): RangePayload {
  const [priceId, lowerBound, upperBound, deadline] = decodeAbiParameters(RANGE_PAYLOAD_TYPE, data);
  return { priceId: priceId as `0x${string}`, lowerBound, upperBound, deadline };
}

// ============================================
// Pyth Template 2: Reached By
// ============================================

export interface ReachedByPayload {
  priceId: `0x${string}`;
  targetPrice: bigint;
  isAbove: boolean;  // true = must go above, false = must go below
  deadline: bigint;
}

const REACHED_BY_PAYLOAD_TYPE = [
  { name: "priceId", type: "bytes32" },
  { name: "targetPrice", type: "int64" },
  { name: "isAbove", type: "bool" },
  { name: "deadline", type: "uint256" },
] as const;

export function encodeReachedByPayload(payload: ReachedByPayload): `0x${string}` {
  return encodeAbiParameters(REACHED_BY_PAYLOAD_TYPE, [
    payload.priceId,
    payload.targetPrice,
    payload.isAbove,
    payload.deadline,
  ]);
}

export function decodeReachedByPayload(data: `0x${string}`): ReachedByPayload {
  const [priceId, targetPrice, isAbove, deadline] = decodeAbiParameters(REACHED_BY_PAYLOAD_TYPE, data);
  return { priceId: priceId as `0x${string}`, targetPrice, isAbove, deadline };
}

// ============================================
// Helper: Convert USD price to Pyth format
// ============================================

/**
 * Convert a human-readable USD price to Pyth's int64 format
 * Pyth uses 8 decimal places, so $100,000 = 100000_00000000
 * @param usdPrice - Price in USD (e.g., 100000 for $100,000)
 * @returns Price in Pyth int64 format
 */
export function usdToPythPrice(usdPrice: number): bigint {
  return BigInt(Math.round(usdPrice * 1e8));
}

/**
 * Convert Pyth's int64 price format to human-readable USD
 * @param pythPrice - Price in Pyth format
 * @returns Price in USD
 */
export function pythPriceToUsd(pythPrice: bigint): number {
  return Number(pythPrice) / 1e8;
}
