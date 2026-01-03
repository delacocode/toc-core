# TOC Consumer Integration Guide

This guide explains how to integrate TOC (Truth On Chain) into your prediction market or other protocol that needs verifiable truth resolution.

## Quick Start

```solidity
import "./ITOCConsumer.sol";

contract MyMarket {
    ITruthEngine public registry;

    // 1. Create a TOC when opening a market
    function openMarket(bytes calldata payload) external payable returns (uint256 tocId) {
        (, , uint256 fee) = registry.getCreationFee(resolver, templateId);
        // Note: Max window depends on resolver trust (RESOLVER=1 day, VERIFIED=30 days)
        tocId = registry.createTOC{value: fee}(
            resolver,
            templateId,
            payload,
            12 hours,   // disputeWindow (within RESOLVER limit)
            12 hours,   // truthKeeperWindow
            12 hours,   // escalationWindow
            0,          // postResolutionWindow
            truthKeeper
        );
    }

    // 2. Check if market can settle
    function canSettle(uint256 tocId) external view returns (bool) {
        TOC memory toc = registry.getTOC(tocId);
        return toc.state == TOCState.RESOLVED;
    }

    // 3. Read result and settle
    function settle(uint256 tocId) external {
        ExtensiveResult memory res = registry.getExtensiveResult(tocId);
        require(res.isFinalized, "Not finalized");
        bool outcome = TOCResultCodec.decodeBoolean(res.result);
        // ... distribute winnings based on outcome
    }
}
```

---

## TOC Lifecycle

Understanding the TOC state machine helps you know when to allow trading vs. when to settle.

```
                    ┌──────────┐
                    │   NONE   │
                    └────┬─────┘
                         │ createTOC()
                         ▼
                    ┌──────────┐
          ┌─────────│ PENDING  │─────────┐
          │         └────┬─────┘         │
          │ reject()     │ activate()    │
          ▼              ▼               │
    ┌──────────┐   ┌──────────┐          │
    │ REJECTED │   │  ACTIVE  │◄─────────┤ Trading allowed
    └──────────┘   └────┬─────┘          │
                        │ resolveTOC()   │
                        ▼                │
                   ┌───────────┐         │
                   │ RESOLVING │         │ Outcome proposed,
                   └─────┬─────┘         │ dispute window open
            ┌────────────┼────────────┐  │
            │ no dispute │ dispute()  │  │
            ▼            ▼            │  │
      ┌──────────┐ ┌─────────────────┐│  │
      │ RESOLVED │ │ DISPUTED_ROUND_1││  │ TruthKeeper reviewing
      └────┬─────┘ └────────┬────────┘│  │
           │                │         │  │
           │     ┌──────────┴─────┐   │  │
           │     │ TK decides OR  │   │  │
           │     │ escalation     │   │  │
           │     ▼                │   │  │
           │ ┌─────────────────┐  │   │  │
           │ │ DISPUTED_ROUND_2│  │   │  │ Admin reviewing
           │ └────────┬────────┘  │   │  │
           │          │           │   │  │
           │          ▼           │   │  │
           │    ┌──────────┐      │   │  │
           └───►│ RESOLVED │◄─────┘   │  │ Settlement possible
                └────┬─────┘          │  │
                     │                │  │
                     ▼                │  │
                ┌──────────┐          │  │
                │CANCELLED │◄─────────┴──┘ Refund required
                └──────────┘
```

### State Meanings for Your Market

| State | Market Action |
|-------|---------------|
| `PENDING` | Wait for resolver approval |
| `ACTIVE` | Allow trading |
| `RESOLVING` | Outcome proposed, may still change |
| `DISPUTED_ROUND_1` | Under review, wait |
| `DISPUTED_ROUND_2` | Under admin review, wait |
| `RESOLVED` | Safe to settle market |
| `CANCELLED` | Refund all participants |
| `REJECTED` | TOC creation failed |

### When to Settle

```solidity
function canSettle(uint256 tocId) public view returns (bool settleable, string memory reason) {
    TOC memory toc = registry.getTOC(tocId);

    if (toc.state == TOCState.RESOLVED) {
        // Check if post-resolution dispute window has passed (if any)
        if (registry.isFullyFinalized(tocId)) {
            return (true, "Fully finalized");
        }
        return (false, "Post-resolution window still open");
    }

    if (toc.state == TOCState.CANCELLED) {
        return (false, "TOC cancelled - refund required");
    }

    return (false, "Not yet resolved");
}
```

---

## Creating a TOC

### Parameters Explained

```solidity
function createTOC(
    address resolver,           // OptimisticResolver address
    uint32 templateId,          // 1=Arbitrary, 2=Sports, 3=Event (0 is reserved)
    bytes calldata payload,     // Template-specific data (see below)
    uint256 disputeWindow,      // Time to dispute after resolution proposed
    uint256 truthKeeperWindow,  // Time for TK to decide disputes
    uint256 escalationWindow,   // Time to challenge TK decision
    uint256 postResolutionWindow, // Time to dispute after RESOLVED (0 to disable)
    address truthKeeper         // TruthKeeper address for this TOC
) external payable returns (uint256 tocId);
```

### Time Window Limits

**Important:** Maximum window durations are enforced based on resolver trust level:

| Trust Level | Max Window (all 4 windows) |
|-------------|---------------------------|
| `RESOLVER` | 1 day |
| `VERIFIED` | 30 days |
| `SYSTEM` | 30 days |

If you specify a window longer than the max for your resolver's trust level, `createTOC()` will revert with `WindowTooLong(provided, maximum)`.

### Time Window Recommendations

| Use Case | disputeWindow | truthKeeperWindow | escalationWindow | postResolutionWindow |
|----------|---------------|-------------------|------------------|----------------------|
| Sports bets (RESOLVER) | 12 hours | 12 hours | 12 hours | 0 |
| Long-term predictions (VERIFIED) | 3 days | 2 days | 2 days | 7 days |
| High-value markets (VERIFIED) | 7 days | 3 days | 3 days | 14 days |

### Fees

TOC creation requires a fee payment:

```solidity
// Get required fee
(uint256 protocolFee, uint256 resolverFee, uint256 total) =
    registry.getCreationFee(resolver, templateId);

// Create TOC with fee
uint256 tocId = registry.createTOC{value: total}(...);
```

---

## OptimisticResolver Templates

> **Note:** Template 0 is reserved (TEMPLATE_NONE). Valid templates start at 1.

### Template 1: Arbitrary Question (TEMPLATE_ARBITRARY)

For free-form YES/NO questions.

```solidity
ArbitraryPayload memory payload = ArbitraryPayload({
    question: "Will ETH reach $10,000 by end of 2025?",
    description: "Resolves YES if ETH/USD price exceeds $10,000 on any major exchange",
    resolutionSource: "CoinGecko ETH/USD price",
    resolutionTime: 1735689600 // Dec 31, 2025
});

uint256 tocId = registry.createTOC{value: fee}(
    optimisticResolver,
    1, // TEMPLATE_ARBITRARY
    abi.encode(payload),
    12 hours, 12 hours, 12 hours, 0, // Within RESOLVER trust limits
    truthKeeper
);
```

### Template 2: Sports Outcome (TEMPLATE_SPORTS)

For structured sports questions.

```solidity
SportsPayload memory payload = SportsPayload({
    league: "NBA",
    homeTeam: "Lakers",
    awayTeam: "Celtics",
    gameTime: 1703980800,
    questionType: SportQuestionType.WINNER,
    line: 0 // Not used for WINNER type
});

uint256 tocId = registry.createTOC{value: fee}(
    optimisticResolver,
    2, // TEMPLATE_SPORTS
    abi.encode(payload),
    12 hours, 12 hours, 12 hours, 0, // Within RESOLVER trust limits
    truthKeeper
);
```

**Question types:**
- `WINNER`: Resolves YES if home team wins
- `SPREAD`: Resolves YES if home team covers the spread
- `OVER_UNDER`: Resolves YES if total score exceeds the line

### Template 3: Event Occurrence (TEMPLATE_EVENT)

For "did X happen?" questions.

```solidity
EventPayload memory payload = EventPayload({
    eventDescription: "SpaceX successfully lands Starship on Mars",
    verificationSource: "Official SpaceX announcement",
    deadline: 1893456000 // Jan 1, 2030
});

uint256 tocId = registry.createTOC{value: fee}(
    optimisticResolver,
    3, // TEMPLATE_EVENT
    abi.encode(payload),
    3 days, 2 days, 2 days, 7 days, // Requires VERIFIED trust for these windows
    truthKeeper
);
```

---

## PythPriceResolver Templates

The PythPriceResolver uses Pyth Network oracle data for automated, trustless price resolution. Unlike the OptimisticResolver, Pyth TOCs go directly to ACTIVE state and resolve based on verifiable on-chain price data.

### Template 0: Snapshot (Above/Below)

Is the price above or below a threshold at the deadline?

```solidity
SnapshotPayload memory payload = SnapshotPayload({
    priceId: 0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43, // BTC/USD
    threshold: 10000000000000, // $100,000 in Pyth format (8 decimals)
    isAbove: true,             // Resolves YES if price > threshold
    deadline: 1735689600       // When to check the price
});

uint256 tocId = registry.createTOC{value: fee}(
    pythResolver,
    0, // TEMPLATE_SNAPSHOT
    abi.encode(payload.priceId, payload.threshold, payload.isAbove, payload.deadline),
    5 minutes, 5 minutes, 5 minutes, 0,
    truthKeeper
);
```

### Template 1: Range

Is the price within a range at the deadline?

```solidity
RangePayload memory payload = RangePayload({
    priceId: 0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace, // ETH/USD
    lowerBound: 300000000000,  // $3,000
    upperBound: 400000000000,  // $4,000
    deadline: 1735689600
});

uint256 tocId = registry.createTOC{value: fee}(
    pythResolver,
    1, // TEMPLATE_RANGE
    abi.encode(payload.priceId, payload.lowerBound, payload.upperBound, payload.deadline),
    5 minutes, 5 minutes, 5 minutes, 0,
    truthKeeper
);
```

### Template 2: Reached By

Did the price reach a target before the deadline?

```solidity
ReachedByPayload memory payload = ReachedByPayload({
    priceId: 0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43, // BTC/USD
    targetPrice: 15000000000000, // $150,000
    isAbove: true,               // Must go ABOVE this price
    deadline: 1735689600         // Must reach target BEFORE this time
});

uint256 tocId = registry.createTOC{value: fee}(
    pythResolver,
    2, // TEMPLATE_REACHED_BY
    abi.encode(payload.priceId, payload.targetPrice, payload.isAbove, payload.deadline),
    5 minutes, 5 minutes, 5 minutes, 0,
    truthKeeper
);
```

### Supported Price Feeds

| Asset | Pyth Price ID |
|-------|---------------|
| BTC/USD | `0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43` |
| ETH/USD | `0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace` |
| SOL/USD | `0xef0d8b6fda2ceba41da15d4095d1da392a0d2f8ed0c6c7bc0f4cfac8c280b56d` |
| USDC/USD | `0xeaa020c61cc479712813461ce153894a96a6c00b21ed0cfc2798d1f9a9e9c94a` |
| USDT/USD | `0x2b89b9dc8fdf9f34709a5b106b472f0f39bb6ca9ce04b0fd7f2e971688e2e53b` |

Full list: https://www.pyth.network/developers/price-feed-ids

### Price Format

Pyth uses 8 decimal places. Use these helpers:

```typescript
// Convert USD to Pyth format: $100,000 → 10000000000000
function usdToPythPrice(usd: number): bigint {
    return BigInt(Math.round(usd * 1e8));
}

// Convert Pyth to USD: 10000000000000 → $100,000
function pythPriceToUsd(pythPrice: bigint): number {
    return Number(pythPrice) / 1e8;
}
```

---

## Reading Results

### Simple Result

```solidity
bytes memory result = registry.getResult(tocId);
bool outcome = TOCResultCodec.decodeBoolean(result);
```

### Result with Context

```solidity
ExtensiveResult memory res = registry.getExtensiveResult(tocId);

// Check finalization
require(res.isFinalized, "Not finalized");

// Decode based on answer type
if (res.answerType == AnswerType.BOOLEAN) {
    bool outcome = TOCResultCodec.decodeBoolean(res.result);
} else if (res.answerType == AnswerType.NUMERIC) {
    int256 value = TOCResultCodec.decodeNumeric(res.result);
}

// Check context
if (res.wasCorrected) {
    // Result was changed via dispute - may want to log this
}

// Check accountability
if (res.tier == AccountabilityTier.SYSTEM) {
    // Highest trust level
}
```

### Strict Result (Reverts if Not Finalized)

```solidity
// Reverts if TOC is not fully finalized
ExtensiveResult memory res = registry.getExtensiveResultStrict(tocId);
```

---

## Events to Monitor

### OptimisticResolver Events

```solidity
// Emitted when a TOC is created
event QuestionCreated(
    uint256 indexed tocId,
    uint32 indexed templateId,
    address indexed creator,
    string questionPreview
);

// Emitted when someone proposes a resolution
event ResolutionProposed(
    uint256 indexed tocId,
    address indexed proposer,
    bool answer,
    string justification  // Audit trail for disputes
);
```

The `ResolutionProposed` event is useful for:
- Displaying proposed answers in your UI before finalization
- Logging justifications for transparency and dispute reference
- Monitoring resolution activity across your markets

---

## TruthKeepers

A TruthKeeper (TK) is a contract that validates and approves TOCs, and handles disputes. Every TOC must specify a TruthKeeper.

### SimpleTruthKeeper (Recommended for Launch)

`SimpleTruthKeeper` is the standard TK for initial deployments:

**Features:**
- Resolver allowlist - only approved resolvers get `TK_GUARANTEED` tier
- Time window validation - enforces minimum dispute/TK windows
- Per-resolver overrides - custom minimums for specific resolvers
- Single owner model - can be set to multi-sig

**Approval logic:**
```
IF resolver is on allowlist
   AND disputeWindow >= minimum
   AND truthKeeperWindow >= minimum
THEN → APPROVE (TK_GUARANTEED tier)
ELSE → REJECT_SOFT (RESOLVER tier)
```

### TK Approval Responses

When a TOC is created, the TruthKeeper returns one of:

| Response | Effect | Tier |
|----------|--------|------|
| `APPROVE` | TOC created with TK backing | `TK_GUARANTEED` or `SYSTEM` |
| `REJECT_SOFT` | TOC created without TK backing | `RESOLVER` |
| `REJECT_HARD` | TOC creation reverts | N/A |

### Using SimpleTruthKeeper

```solidity
// Deploy SimpleTruthKeeper
SimpleTruthKeeper tk = new SimpleTruthKeeper(
    registryAddress,    // TruthEngine address
    ownerAddress,       // Who can configure
    1 hours,            // Default min dispute window
    4 hours             // Default min TK window
);

// Allow a resolver
tk.setResolverAllowed(optimisticResolverAddress, true);

// Optional: Set custom minimums for a resolver
tk.setResolverMinWindows(
    optimisticResolverAddress,
    30 minutes,  // Custom min dispute window
    2 hours      // Custom min TK window
);
```

### Which TruthKeeper to Use

| Scenario | Recommendation |
|----------|----------------|
| Production launch | `SimpleTruthKeeper` with resolver allowlist |
| Testing | `MockTruthKeeper` (always approves) |
| Custom validation | Implement `ITruthKeeper` interface |

---

## Accountability Tiers

Every TOC has an accountability tier set at creation based on TruthKeeper approval:

| Tier | Meaning | When Assigned |
|------|---------|---------------|
| `SYSTEM` | Maximum protocol backing | TK approved + SYSTEM resolver + whitelisted TK |
| `TK_GUARANTEED` | TruthKeeper stakes reputation | TK approved |
| `RESOLVER` | No guarantees | TK soft-rejected or didn't approve |

Check tier when deciding trust level:

```solidity
ExtensiveResult memory res = registry.getExtensiveResult(tocId);

if (res.tier == AccountabilityTier.SYSTEM) {
    // Highest confidence
} else if (res.tier == AccountabilityTier.TK_GUARANTEED) {
    // TruthKeeper backed
} else {
    // Consumer assumes risk
}
```

---

## Demo: Prediction Market Contract

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "./ITOCConsumer.sol";

/// @title PredictionMarketExample
/// @notice Minimal prediction market using TOC for resolution
/// @dev Starter template - extend with positions, liquidity, etc.
contract PredictionMarketExample {
    ITruthEngine public immutable registry;
    address public immutable resolver;
    address public immutable truthKeeper;

    struct Market {
        uint256 tocId;
        bool settled;
        bool outcome;
    }

    mapping(uint256 => Market) public markets;
    uint256 public nextMarketId;

    event MarketCreated(uint256 indexed marketId, uint256 indexed tocId, string question);
    event MarketSettled(uint256 indexed marketId, bool outcome);

    error MarketNotSettleable(uint256 marketId, TOCState state);
    error MarketAlreadySettled(uint256 marketId);
    error MarketCancelled(uint256 marketId);

    constructor(address _registry, address _resolver, address _truthKeeper) {
        registry = ITruthEngine(_registry);
        resolver = _resolver;
        truthKeeper = _truthKeeper;
    }

    /// @notice Create a new prediction market
    /// @param payload ABI-encoded OptimisticResolver payload
    /// @return marketId The new market ID
    function createMarket(
        uint32 templateId,
        bytes calldata payload
    ) external payable returns (uint256 marketId) {
        // Get required fee
        (, , uint256 fee) = registry.getCreationFee(resolver, templateId);
        require(msg.value >= fee, "Insufficient fee");

        // Create TOC
        // Note: Windows are limited by resolver trust level (RESOLVER = 1 day max)
        uint256 tocId = registry.createTOC{value: fee}(
            resolver,
            templateId,
            payload,
            12 hours,   // disputeWindow (within RESOLVER limit)
            12 hours,   // truthKeeperWindow
            12 hours,   // escalationWindow
            0,          // postResolutionWindow (none for quick settlement)
            truthKeeper
        );

        // Store market
        marketId = nextMarketId++;
        markets[marketId] = Market({
            tocId: tocId,
            settled: false,
            outcome: false
        });

        // Get question for event
        string memory question = registry.getTocQuestion(tocId);
        emit MarketCreated(marketId, tocId, question);

        // Refund excess
        if (msg.value > fee) {
            payable(msg.sender).transfer(msg.value - fee);
        }
    }

    /// @notice Check if a market can be settled
    /// @param marketId The market ID
    /// @return canSettle True if market can be settled
    /// @return state Current TOC state
    function checkMarketStatus(uint256 marketId) external view returns (
        bool canSettle,
        TOCState state
    ) {
        Market storage market = markets[marketId];
        TOC memory toc = registry.getTOC(market.tocId);
        state = toc.state;
        canSettle = (state == TOCState.RESOLVED && !market.settled);
    }

    /// @notice Settle a market using TOC result
    /// @param marketId The market ID
    function settleMarket(uint256 marketId) external {
        Market storage market = markets[marketId];

        if (market.settled) {
            revert MarketAlreadySettled(marketId);
        }

        // Get TOC state
        TOC memory toc = registry.getTOC(market.tocId);

        // Handle cancelled TOC
        if (toc.state == TOCState.CANCELLED) {
            revert MarketCancelled(marketId);
        }

        // Must be resolved
        if (toc.state != TOCState.RESOLVED) {
            revert MarketNotSettleable(marketId, toc.state);
        }

        // Get result
        ExtensiveResult memory res = registry.getExtensiveResult(market.tocId);
        bool outcome = TOCResultCodec.decodeBoolean(res.result);

        // Update market
        market.settled = true;
        market.outcome = outcome;

        emit MarketSettled(marketId, outcome);

        // TODO: Distribute winnings based on outcome
        // - If outcome == true, pay YES holders
        // - If outcome == false, pay NO holders
    }

    /// @notice Get market info
    /// @param marketId The market ID
    function getMarket(uint256 marketId) external view returns (
        uint256 tocId,
        TOCState state,
        bool settled,
        bool outcome,
        string memory question
    ) {
        Market storage market = markets[marketId];
        TOC memory toc = registry.getTOC(market.tocId);

        return (
            market.tocId,
            toc.state,
            market.settled,
            market.outcome,
            registry.getTocQuestion(market.tocId)
        );
    }
}
```

---

## Resolving TOCs

### Resolving OptimisticResolver TOCs

OptimisticResolver requires a two-step process:

```solidity
// Step 1: Propose resolution with bond
AnswerPayload memory answer = AnswerPayload({
    answer: true,  // YES or NO
    justification: "ETH price exceeded $10,000 on Dec 15, 2025 per CoinGecko"
});

uint256 bondAmount = 0.01 ether;  // Get actual minimum from registry
registry.resolveTOC{value: bondAmount}(
    tocId,
    address(0),  // ETH for bond
    bondAmount,
    abi.encode(answer)
);
// TOC is now in RESOLVING state

// Step 2: Wait for dispute window, then finalize
// Anyone can call this after the dispute window passes
registry.finalizeTOC(tocId);
// TOC is now RESOLVED
```

**Important:** If disputed during the window, the TOC goes to `DISPUTED_ROUND_1` and the TruthKeeper must resolve it.

### Resolving PythPriceResolver TOCs

Pyth TOCs resolve in a single step using oracle price data:

```solidity
// Fetch price update from Pyth Hermes API (off-chain)
bytes[] memory priceUpdateData = fetchFromHermes(priceId);

// Submit resolution with price proof
registry.resolveTOC{value: bondAmount}(
    tocId,
    address(0),
    bondAmount,
    abi.encode(priceUpdateData)
);
// TOC goes directly to RESOLVED (no dispute window needed)
```

---

## Choosing a Resolver

| Resolver | Best For | Resolution | Trust Model |
|----------|----------|------------|-------------|
| **OptimisticResolver** | Subjective questions, sports, events | Human proposal + dispute | Optimistic with escalation |
| **PythPriceResolver** | Price-based outcomes | Automated via oracle | Trustless (Pyth Network) |

### OptimisticResolver Flow

```
createTOC() → PENDING → [TK approves] → ACTIVE → resolveTOC() → RESOLVING
                                                                    ↓
                              [dispute window] ← ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ┘
                                       ↓
                              [no dispute] → finalizeTOC() → RESOLVED
```

- Requires human proposer to submit answer with bond
- Dispute window allows challenges
- Best for questions that need human judgment

### PythPriceResolver Flow

```
createTOC() → ACTIVE → [deadline passes] → resolveTOC() → RESOLVED
```

- Immediately active (no approval needed)
- Resolution uses Pyth price proofs
- Fully automated - no human judgment needed

---

## Integrating PythPriceResolver

### Creating a Pyth-Based Market

```solidity
contract PythMarket {
    ITruthEngine public registry;
    address public pythResolver;
    address public truthKeeper;

    /// @notice Create a price prediction market
    /// @param priceId Pyth price feed ID (e.g., BTC/USD)
    /// @param threshold Price threshold (8 decimals)
    /// @param isAbove True if betting price goes above threshold
    /// @param deadline When to check the price
    function createPriceMarket(
        bytes32 priceId,
        int64 threshold,
        bool isAbove,
        uint256 deadline
    ) external payable returns (uint256 tocId) {
        // Encode snapshot payload
        bytes memory payload = abi.encode(priceId, threshold, isAbove, deadline);

        (, , uint256 fee) = registry.getCreationFee(pythResolver, 0);

        tocId = registry.createTOC{value: fee}(
            pythResolver,
            0,  // TEMPLATE_SNAPSHOT
            payload,
            5 minutes,  // disputeWindow
            5 minutes,  // truthKeeperWindow
            5 minutes,  // escalationWindow
            0,          // postResolutionWindow
            truthKeeper
        );
        // TOC is immediately ACTIVE for Pyth resolver
    }
}
```

### Resolving a Pyth TOC

Resolution requires Pyth price update data from the Hermes API:

```solidity
/// @notice Resolve a Pyth TOC with price data
/// @param tocId The TOC to resolve
/// @param priceUpdateData Encoded price data from Pyth Hermes API
function resolvePythTOC(uint256 tocId, bytes[] calldata priceUpdateData) external {
    // Encode the price update data for the resolver
    bytes memory resolverPayload = abi.encode(priceUpdateData);

    // Resolution bond (may be minimal for Pyth)
    uint256 bondAmount = 0.001 ether;

    registry.resolveTOC{value: bondAmount}(
        tocId,
        address(0), // ETH for bond
        bondAmount,
        resolverPayload
    );
    // TOC goes directly to RESOLVED
}
```

### Off-Chain: Fetching Pyth Price Data

To resolve a Pyth TOC, fetch price updates from the Hermes API:

```typescript
const HERMES_API = "https://hermes.pyth.network";

async function fetchPythUpdateData(priceId: string): Promise<string[]> {
    const cleanId = priceId.replace("0x", "");
    const url = `${HERMES_API}/v2/updates/price/latest?ids[]=${cleanId}&encoding=base64`;

    const response = await fetch(url);
    const data = await response.json();

    // Convert base64 to hex for on-chain use
    return data.binary.data.map((b64: string) =>
        "0x" + Buffer.from(b64, "base64").toString("hex")
    );
}

// Use with ethers.js or viem
const priceData = await fetchPythUpdateData(BTC_USD_PRICE_ID);
await registry.resolveTOC(tocId, ETH_ADDRESS, bondAmount,
    ethers.utils.defaultAbiCoder.encode(["bytes[]"], [priceData])
);
```

### Demo: Pyth Price Market Contract

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "./ITOCConsumer.sol";

/// @title PythPriceMarketExample
/// @notice Prediction market for price outcomes using Pyth resolver
contract PythPriceMarketExample {
    ITruthEngine public immutable registry;
    address public immutable pythResolver;
    address public immutable truthKeeper;

    // Pyth price IDs (same across all networks)
    bytes32 public constant BTC_USD = 0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43;
    bytes32 public constant ETH_USD = 0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace;

    struct PriceMarket {
        uint256 tocId;
        bytes32 priceId;
        int64 threshold;
        bool isAbove;
        uint256 deadline;
        bool settled;
        bool outcome;
    }

    mapping(uint256 => PriceMarket) public markets;
    uint256 public nextMarketId;

    event PriceMarketCreated(uint256 indexed marketId, uint256 indexed tocId, bytes32 priceId, int64 threshold);
    event PriceMarketSettled(uint256 indexed marketId, bool outcome);

    constructor(address _registry, address _pythResolver, address _truthKeeper) {
        registry = ITruthEngine(_registry);
        pythResolver = _pythResolver;
        truthKeeper = _truthKeeper;
    }

    /// @notice Create a price prediction market
    /// @param priceId Pyth price feed ID
    /// @param threshold Price threshold (8 decimals, e.g., 100000e8 = $100,000)
    /// @param isAbove True if betting price goes above threshold
    /// @param deadline Unix timestamp when to check the price
    function createPriceMarket(
        bytes32 priceId,
        int64 threshold,
        bool isAbove,
        uint256 deadline
    ) external payable returns (uint256 marketId) {
        require(deadline > block.timestamp, "Deadline must be in future");

        // Encode Pyth snapshot payload
        bytes memory payload = abi.encode(priceId, threshold, isAbove, deadline);

        (, , uint256 fee) = registry.getCreationFee(pythResolver, 0);
        require(msg.value >= fee, "Insufficient fee");

        // Create TOC - goes directly to ACTIVE for Pyth
        uint256 tocId = registry.createTOC{value: fee}(
            pythResolver,
            0,  // TEMPLATE_SNAPSHOT
            payload,
            5 minutes,
            5 minutes,
            5 minutes,
            0,
            truthKeeper
        );

        marketId = nextMarketId++;
        markets[marketId] = PriceMarket({
            tocId: tocId,
            priceId: priceId,
            threshold: threshold,
            isAbove: isAbove,
            deadline: deadline,
            settled: false,
            outcome: false
        });

        emit PriceMarketCreated(marketId, tocId, priceId, threshold);
    }

    /// @notice Resolve a market with Pyth price data (anyone can call after deadline)
    /// @param marketId The market to resolve
    /// @param priceUpdateData Price update from Pyth Hermes API
    function resolveMarket(uint256 marketId, bytes[] calldata priceUpdateData) external payable {
        PriceMarket storage market = markets[marketId];
        require(!market.settled, "Already settled");
        require(block.timestamp >= market.deadline, "Deadline not reached");

        // Encode price data for resolver
        bytes memory resolverPayload = abi.encode(priceUpdateData);

        // Minimal bond for Pyth resolution
        uint256 bondAmount = 0.001 ether;

        registry.resolveTOC{value: bondAmount}(
            market.tocId,
            address(0),
            bondAmount,
            resolverPayload
        );
    }

    /// @notice Settle a market after resolution
    function settleMarket(uint256 marketId) external {
        PriceMarket storage market = markets[marketId];
        require(!market.settled, "Already settled");

        TOC memory toc = registry.getTOC(market.tocId);
        require(toc.state == TOCState.RESOLVED, "Not resolved");

        ExtensiveResult memory res = registry.getExtensiveResult(market.tocId);
        market.outcome = TOCResultCodec.decodeBoolean(res.result);
        market.settled = true;

        emit PriceMarketSettled(marketId, market.outcome);

        // TODO: Distribute winnings based on outcome
    }
}
```

---

## Next Steps

1. **Copy integration files** to your project:
   - `ITOCConsumer.sol` - Solidity interface and types
   - `exports/toc-types.ts` - TypeScript types, ABIs, and utilities
2. **Get deployed addresses** from `exports/toc-addresses.json`:
   ```json
   {
     "networks": {
       "sepolia": {
         "chainId": 11155111,
         "registry": "0x...",
         "optimisticResolver": "0x...",
         "pythResolver": "0x...",
         "truthKeeper": "0x..."
       }
     }
   }
   ```
   Generate fresh exports: `npx hardhat run scripts/export-addresses.ts`
3. **Choose your resolver:**
   - Use OptimisticResolver for human-judgment questions
   - Use PythPriceResolver for automated price resolution
4. **Create markets** using `createTOC()` with appropriate payloads
5. **Poll state** to determine when markets can settle
6. **Read results** using `getExtensiveResult()` and `TOCResultCodec`

For full TOC documentation, see the [GitBook docs](../gitbook/README.md).
