/**
 * Tier 1: Base Utility Expectations
 *
 * These are the foundational utilities that all other expectations build upon.
 * They provide:
 * - Storage value verification
 * - Balance change tracking
 * - Event matching
 * - Deep equality comparison
 */

import assert from "node:assert/strict";
import type { Address, Hash, Log, PublicClient, GetContractReturnType } from "viem";
import { parseEventLogs } from "viem";
import type {
  StorageCheck,
  BalanceChange,
  EventExpectation,
  ExpectationResult,
  AggregatedExpectationResult,
  TxContext,
} from "./types.js";

// ============ Storage Verification ============

/**
 * Verify a storage value matches expected
 */
export async function expectStorageValue<T>(
  check: StorageCheck<T>
): Promise<ExpectationResult> {
  try {
    const actual = await check.getter();
    const passed = safeDeepEquals(actual, check.expected);
    return {
      passed,
      label: check.label,
      expected: check.expected,
      actual,
      error: passed ? undefined : `Storage mismatch for ${check.label}`,
    };
  } catch (error) {
    return {
      passed: false,
      label: check.label,
      expected: check.expected,
      error: `Failed to read storage: ${error}`,
    };
  }
}

/**
 * Verify multiple storage values
 */
export async function expectStorageValues(
  checks: StorageCheck<unknown>[]
): Promise<AggregatedExpectationResult> {
  const results = await Promise.all(checks.map(expectStorageValue));
  return aggregateResults(results, "Storage checks");
}

// ============ Balance Verification ============

/**
 * Get native ETH balance
 */
export async function getEthBalance(
  client: PublicClient,
  address: Address
): Promise<bigint> {
  return client.getBalance({ address });
}

/**
 * Get ERC20 balance (requires contract with read.balanceOf)
 */
export async function getErc20Balance(
  tokenContract: GetContractReturnType<readonly unknown[], PublicClient>,
  address: Address
): Promise<bigint> {
  return (tokenContract.read as { balanceOf: (args: [Address]) => Promise<bigint> }).balanceOf([address]);
}

/**
 * Capture balance snapshot for later comparison
 */
export interface BalanceSnapshot {
  address: Address;
  token: Address | null;
  balance: bigint;
}

export async function captureBalances(
  client: PublicClient,
  addresses: Array<{ address: Address; token: Address | null }>
): Promise<BalanceSnapshot[]> {
  return Promise.all(
    addresses.map(async ({ address, token }) => ({
      address,
      token,
      balance: await getEthBalance(client, address), // TODO: Add ERC20 support
    }))
  );
}

/**
 * Verify balance changes between snapshots
 */
export function expectBalanceChanges(
  before: BalanceSnapshot[],
  after: BalanceSnapshot[],
  expected: BalanceChange[]
): AggregatedExpectationResult {
  const results: ExpectationResult[] = expected.map((change) => {
    const beforeSnap = before.find(
      (s) => s.address === change.address && s.token === change.token
    );
    const afterSnap = after.find(
      (s) => s.address === change.address && s.token === change.token
    );

    if (!beforeSnap || !afterSnap) {
      return {
        passed: false,
        label: change.label,
        error: `Missing balance snapshot for ${change.address}`,
      };
    }

    const actualDelta = afterSnap.balance - beforeSnap.balance;
    const passed = actualDelta === change.delta;

    return {
      passed,
      label: change.label,
      expected: change.delta,
      actual: actualDelta,
      error: passed ? undefined : `Balance change mismatch for ${change.label}`,
    };
  });

  return aggregateResults(results, "Balance changes");
}

// ============ Event Verification ============

/**
 * Find events matching a specific name in transaction logs
 */
export function findEvents<TAbi extends readonly unknown[]>(
  logs: Log[],
  abi: TAbi,
  eventName: string
): Log[] {
  try {
    const parsed = parseEventLogs({ abi, logs });
    return parsed.filter((log) => log.eventName === eventName);
  } catch {
    return [];
  }
}

/**
 * Verify an event was emitted with expected args
 */
export function expectEvent<TAbi extends readonly unknown[]>(
  logs: Log[],
  abi: TAbi,
  expectation: EventExpectation
): ExpectationResult {
  const events = findEvents(logs, abi, expectation.eventName);

  if (events.length === 0) {
    return {
      passed: false,
      label: `Event: ${expectation.eventName}`,
      expected: expectation.args,
      error: `Event ${expectation.eventName} not found in logs`,
    };
  }

  // Check if any event matches the expected args
  for (const event of events) {
    const eventArgs = (event as unknown as { args: Record<string, unknown> }).args;
    if (matchEventArgs(eventArgs, expectation.args)) {
      return {
        passed: true,
        label: `Event: ${expectation.eventName}`,
        expected: expectation.args,
        actual: eventArgs,
      };
    }
  }

  return {
    passed: false,
    label: `Event: ${expectation.eventName}`,
    expected: expectation.args,
    actual: (events[0] as unknown as { args: unknown }).args,
    error: `Event ${expectation.eventName} found but args don't match`,
  };
}

/**
 * Verify multiple events were emitted in order
 */
export function expectEventsInOrder<TAbi extends readonly unknown[]>(
  logs: Log[],
  abi: TAbi,
  expectations: EventExpectation[]
): AggregatedExpectationResult {
  const results: ExpectationResult[] = [];
  let logIndex = 0;

  for (const expectation of expectations) {
    let found = false;

    // Search for matching event from current position
    for (let i = logIndex; i < logs.length; i++) {
      const parsed = parseEventLogs({ abi, logs: [logs[i]] });
      if (parsed.length > 0 && parsed[0].eventName === expectation.eventName) {
        const eventArgs = (parsed[0] as unknown as { args: Record<string, unknown> }).args;
        if (matchEventArgs(eventArgs, expectation.args)) {
          found = true;
          logIndex = i + 1;
          results.push({
            passed: true,
            label: `Event: ${expectation.eventName}`,
            expected: expectation.args,
            actual: eventArgs,
          });
          break;
        }
      }
    }

    if (!found) {
      results.push({
        passed: false,
        label: `Event: ${expectation.eventName}`,
        expected: expectation.args,
        error: `Event not found in expected order`,
      });
    }
  }

  return aggregateResults(results, "Events in order");
}

// ============ Deep Equality ============

/**
 * Check if a value looks like an Ethereum address (0x followed by 40 hex chars)
 */
function isAddress(value: unknown): value is string {
  return typeof value === "string" && /^0x[a-fA-F0-9]{40}$/.test(value);
}

/**
 * Safe deep equality comparison handling BigInt, arrays, objects, and addresses
 */
export function safeDeepEquals(a: unknown, b: unknown): boolean {
  // Handle BigInt
  if (typeof a === "bigint" && typeof b === "bigint") {
    return a === b;
  }

  // Handle addresses (case-insensitive comparison)
  if (isAddress(a) && isAddress(b)) {
    return a.toLowerCase() === b.toLowerCase();
  }

  // Handle null/undefined
  if (a === null || b === null || a === undefined || b === undefined) {
    return a === b;
  }

  // Handle arrays
  if (Array.isArray(a) && Array.isArray(b)) {
    if (a.length !== b.length) return false;
    return a.every((val, idx) => safeDeepEquals(val, b[idx]));
  }

  // Handle objects
  if (typeof a === "object" && typeof b === "object") {
    const keysA = Object.keys(a);
    const keysB = Object.keys(b);
    if (keysA.length !== keysB.length) return false;
    return keysA.every((key) =>
      safeDeepEquals(
        (a as Record<string, unknown>)[key],
        (b as Record<string, unknown>)[key]
      )
    );
  }

  // Primitives
  return a === b;
}

/**
 * Match event args with expected (partial match - expected must be subset)
 */
function matchEventArgs(
  actual: Record<string, unknown>,
  expected: Record<string, unknown>
): boolean {
  for (const [key, value] of Object.entries(expected)) {
    if (!safeDeepEquals(actual[key], value)) {
      return false;
    }
  }
  return true;
}

// ============ Result Aggregation ============

/**
 * Aggregate multiple expectation results
 */
export function aggregateResults(
  results: ExpectationResult[],
  label: string
): AggregatedExpectationResult {
  const passed = results.filter((r) => r.passed).length;
  const failed = results.filter((r) => !r.passed).length;
  const allPassed = failed === 0;

  return {
    allPassed,
    results,
    summary: `${label}: ${passed}/${results.length} passed${
      failed > 0 ? `, ${failed} failed` : ""
    }`,
  };
}

/**
 * Stringify value with BigInt support
 */
function stringify(value: unknown): string {
  return JSON.stringify(value, (_, v) =>
    typeof v === "bigint" ? v.toString() + "n" : v
  );
}

/**
 * Assert all expectations passed, throwing detailed error if not
 */
export function assertAllPassed(result: AggregatedExpectationResult): void {
  if (!result.allPassed) {
    const failures = result.results
      .filter((r) => !r.passed)
      .map((r) => `  - ${r.label}: ${r.error}\n    Expected: ${stringify(r.expected)}\n    Actual: ${stringify(r.actual)}`)
      .join("\n");

    assert.fail(`${result.summary}\n\nFailures:\n${failures}`);
  }
}

// ============ Transaction Context Builder ============

/**
 * Build transaction context from receipt
 */
export async function buildTxContext(
  client: PublicClient,
  hash: Hash
): Promise<TxContext> {
  const receipt = await client.getTransactionReceipt({ hash });
  const tx = await client.getTransaction({ hash });
  const block = await client.getBlock({ blockNumber: receipt.blockNumber });

  return {
    hash,
    blockNumber: receipt.blockNumber,
    timestamp: block.timestamp,
    logs: receipt.logs,
    from: tx.from,
    to: tx.to!,
    value: tx.value,
  };
}

// Re-export types
export * from "./types.js";
