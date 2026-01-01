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
