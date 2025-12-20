# TOC Consumer Integration Guide

This guide explains how to integrate TOC (Truth On Chain) into your prediction market or other protocol that needs verifiable truth resolution.

## Quick Start

```solidity
import "./ITOCConsumer.sol";

contract MyMarket {
    ITOCRegistry public registry;

    // 1. Create a TOC when opening a market
    function openMarket(bytes calldata payload) external payable returns (uint256 tocId) {
        (, , uint256 fee) = registry.getCreationFee(resolver, templateId);
        tocId = registry.createTOC{value: fee}(
            resolver,
            templateId,
            payload,
            1 days,     // disputeWindow
            1 days,     // truthKeeperWindow
            1 days,     // escalationWindow
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
    uint32 templateId,          // 0=Arbitrary, 1=Sports, 2=Event
    bytes calldata payload,     // Template-specific data (see below)
    uint256 disputeWindow,      // Time to dispute after resolution proposed
    uint256 truthKeeperWindow,  // Time for TK to decide disputes
    uint256 escalationWindow,   // Time to challenge TK decision
    uint256 postResolutionWindow, // Time to dispute after RESOLVED (0 to disable)
    address truthKeeper         // TruthKeeper address for this TOC
) external payable returns (uint256 tocId);
```

### Time Window Recommendations

| Use Case | disputeWindow | truthKeeperWindow | escalationWindow | postResolutionWindow |
|----------|---------------|-------------------|------------------|----------------------|
| Sports bets | 1 day | 1 day | 1 day | 0 |
| Long-term predictions | 3 days | 2 days | 2 days | 7 days |
| High-value markets | 7 days | 3 days | 3 days | 14 days |

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

### Template 0: Arbitrary Question

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
    0, // TEMPLATE_ARBITRARY
    abi.encode(payload),
    1 days, 1 days, 1 days, 0,
    truthKeeper
);
```

### Template 1: Sports Outcome

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
    1, // TEMPLATE_SPORTS
    abi.encode(payload),
    1 days, 1 days, 1 days, 0,
    truthKeeper
);
```

**Question types:**
- `WINNER`: Resolves YES if home team wins
- `SPREAD`: Resolves YES if home team covers the spread
- `OVER_UNDER`: Resolves YES if total score exceeds the line

### Template 2: Event Occurrence

For "did X happen?" questions.

```solidity
EventPayload memory payload = EventPayload({
    eventDescription: "SpaceX successfully lands Starship on Mars",
    verificationSource: "Official SpaceX announcement",
    deadline: 1893456000 // Jan 1, 2030
});

uint256 tocId = registry.createTOC{value: fee}(
    optimisticResolver,
    2, // TEMPLATE_EVENT
    abi.encode(payload),
    3 days, 2 days, 2 days, 7 days,
    truthKeeper
);
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
    registryAddress,    // TOCRegistry address
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
    ITOCRegistry public immutable registry;
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
        registry = ITOCRegistry(_registry);
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
        uint256 tocId = registry.createTOC{value: fee}(
            resolver,
            templateId,
            payload,
            1 days,     // disputeWindow
            1 days,     // truthKeeperWindow
            1 days,     // escalationWindow
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

## Next Steps

1. **Copy `ITOCConsumer.sol`** to your project
2. **Deploy contracts:**
   - TOCRegistry (or get existing address)
   - OptimisticResolver (or get existing address)
   - SimpleTruthKeeper (configure with your resolver allowlist)
3. **Configure SimpleTruthKeeper:**
   - Set resolver allowlist: `tk.setResolverAllowed(resolver, true)`
   - Optionally set per-resolver time windows
4. **Create markets** using `createTOC()` with appropriate payloads
5. **Poll state** to determine when markets can settle
6. **Read results** and distribute winnings

For full TOC documentation, see the [GitBook docs](../gitbook/README.md).
