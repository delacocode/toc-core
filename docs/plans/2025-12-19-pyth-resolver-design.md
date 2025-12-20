# Pyth Price Resolver Design

## Overview

Professional-grade PythPriceResolver for crypto price-based TOCs. Designed for production launch with comprehensive template coverage.

## Scope

- **Crypto-only** for v1 (24/7 markets, no market hours complexity)
- **15 templates** covering common price prediction scenarios
- **Standardized template IDs** to establish common language across price resolvers

## Template Registry

| ID | Name | Flags | Description |
|----|------|-------|-------------|
| 0 | NONE | - | Reserved/invalid |
| 1 | Snapshot | `isAbove: bool` | Price above/below threshold at deadline |
| 2 | Range | `isInside: bool` | Price inside/outside range at deadline |
| 3 | Reached Target | `isAbove: bool` | Price reached above/below target before deadline |
| 4 | Touched Both | - | Price touched both targets before deadline |
| 5 | Stayed | `isAbove: bool` | Price stayed above/below threshold entire period |
| 6 | Stayed In Range | - | Price stayed within range entire period |
| 7 | Breakout | `isUp: bool` | Price broke out up/down from starting range |
| 8 | Percentage Change | `isUp: bool` | Price moved up/down by X% from start |
| 9 | Percentage Either | - | Price moved X% in either direction |
| 10 | End vs Start | `isHigher: bool` | Deadline price higher/lower than creation price |
| 11 | Asset Compare | `aGreater: bool` | Asset A >/< asset B at deadline |
| 12 | Ratio Threshold | `isAbove: bool` | A/B ratio above/below X at deadline |
| 13 | Spread Threshold | `isAbove: bool` | (A - B) above/below X at deadline |
| 14 | Flip | - | Asset A overtook B before deadline |
| 15 | First to Target | - | Price hit target X before target Y |

## Data Structures

### Common Fields (all templates)

```solidity
bytes32 priceId;    // Pyth price feed ID
uint256 deadline;   // Resolution timestamp
```

### Single-Asset Templates (1-10)

| Template | Payload Fields |
|----------|----------------|
| 1 - Snapshot | `int64 threshold`, `bool isAbove` |
| 2 - Range | `int64 lowerBound`, `int64 upperBound`, `bool isInside` |
| 3 - Reached Target | `int64 target`, `bool isAbove` |
| 4 - Touched Both | `int64 targetA`, `int64 targetB` |
| 5 - Stayed | `int64 threshold`, `bool isAbove`, `uint256 startTime` |
| 6 - Stayed In Range | `int64 lowerBound`, `int64 upperBound`, `uint256 startTime` |
| 7 - Breakout | `int64 rangeStart`, `bool isUp` |
| 8 - Percentage Change | `int64 percentageBps`, `bool isUp`, `int64 referencePrice` |
| 9 - Percentage Either | `int64 percentageBps`, `int64 referencePrice` |
| 10 - End vs Start | `int64 startPrice`, `bool isHigher` |

### Multi-Asset Templates (11-15)

| Template | Payload Fields |
|----------|----------------|
| 11 - Asset Compare | `bytes32 priceIdB`, `bool aGreater` |
| 12 - Ratio Threshold | `bytes32 priceIdB`, `int64 ratio`, `bool isAbove` |
| 13 - Spread Threshold | `bytes32 priceIdB`, `int64 spread`, `bool isAbove` |
| 14 - Flip | `bytes32 priceIdB` |
| 15 - First to Target | `int64 targetA`, `int64 targetB` |

## Price Handling

### Normalization

- All prices normalized to **8 decimal USD** (matches Pyth's common format for USD pairs)
- Users specify thresholds in 8 decimal format (e.g., $95,000 = 9500000000000)
- Contract normalizes Pyth prices using exponent before comparison

### Confidence Threshold

- Reject resolution if Pyth confidence > **1% of price**
- Prevents resolution during extreme volatility/uncertainty

```solidity
if (priceData.conf * 100 > uint64(abs(priceData.price))) {
    revert ConfidenceTooWide(priceData.conf, priceData.price);
}
```

## Timing Rules

### Point-in-Time Templates (1, 2, 10, 11, 12, 13)

Price must be published within **1 second** of deadline:

```solidity
if (publishTime < deadline || publishTime > deadline + 1) {
    revert PriceNotNearDeadline(publishTime, deadline);
}
```

### Before-Deadline Templates (3, 4, 14, 15)

Price must be published **before or at** deadline:

```solidity
if (publishTime > deadline) {
    revert PriceAfterDeadline(publishTime, deadline);
}
```

### Period-Based Templates (5, 6, 7, 8, 9)

Require **proof array** at resolution time:

- Resolver submits array of Pyth signed payloads
- Proofs must cover key moments in the period
- Contract validates all proofs meet the condition

For "Stayed" templates (5, 6): All proofs must satisfy condition.
For "Breakout" template (7): At least one proof must show breakout.
For "Percentage" templates (8, 9): Final proof must show target percentage achieved.

### ReachedBy Resolution (Template 3)

- **YES**: Submit proof with `publishTime <= deadline` showing price hit target
- **NO**: After deadline passes, if no valid YES proof submitted, anyone can resolve as NO

## Validation

### Creation-Time

- `priceId` must be non-zero
- `deadline` must be in the future
- `lowerBound < upperBound` for range templates
- `percentageBps > 0` and reasonable (< 100000 = 1000%)
- Multi-asset: `priceIdB != priceId`

### Resolution-Time

- Pyth signature valid (handled by Pyth SDK)
- `publishTime` within tolerance of deadline
- Confidence < 1% of price
- Price exponent normalized to 8 decimals

## Errors

```solidity
error InvalidPriceId();
error DeadlineInPast();
error InvalidBounds();
error InvalidPercentage();
error SamePriceIds();
error DeadlineNotReached();
error PriceNotNearDeadline(uint256 publishTime, uint256 deadline);
error PriceAfterDeadline(uint256 publishTime, uint256 deadline);
error ConfidenceTooWide(uint64 confidence, int64 price);
error InvalidTemplate(uint32 templateId);
error InvalidProofArray();
error ConditionNotMet();
```

## Events

### Creation Events (per template)

```solidity
event SnapshotTOCCreated(
    uint256 indexed tocId,
    bytes32 indexed priceId,
    int64 threshold,
    bool isAbove,
    uint256 deadline
);

event RangeTOCCreated(
    uint256 indexed tocId,
    bytes32 indexed priceId,
    int64 lowerBound,
    int64 upperBound,
    bool isInside,
    uint256 deadline
);

event ReachedTargetTOCCreated(
    uint256 indexed tocId,
    bytes32 indexed priceId,
    int64 target,
    bool isAbove,
    uint256 deadline
);

event TouchedBothTOCCreated(
    uint256 indexed tocId,
    bytes32 indexed priceId,
    int64 targetA,
    int64 targetB,
    uint256 deadline
);

event StayedTOCCreated(
    uint256 indexed tocId,
    bytes32 indexed priceId,
    int64 threshold,
    bool isAbove,
    uint256 startTime,
    uint256 deadline
);

event StayedInRangeTOCCreated(
    uint256 indexed tocId,
    bytes32 indexed priceId,
    int64 lowerBound,
    int64 upperBound,
    uint256 startTime,
    uint256 deadline
);

event BreakoutTOCCreated(
    uint256 indexed tocId,
    bytes32 indexed priceId,
    int64 rangeStart,
    bool isUp,
    uint256 deadline
);

event PercentageChangeTOCCreated(
    uint256 indexed tocId,
    bytes32 indexed priceId,
    int64 percentageBps,
    bool isUp,
    int64 referencePrice,
    uint256 deadline
);

event PercentageEitherTOCCreated(
    uint256 indexed tocId,
    bytes32 indexed priceId,
    int64 percentageBps,
    int64 referencePrice,
    uint256 deadline
);

event EndVsStartTOCCreated(
    uint256 indexed tocId,
    bytes32 indexed priceId,
    int64 startPrice,
    bool isHigher,
    uint256 deadline
);

event AssetCompareTOCCreated(
    uint256 indexed tocId,
    bytes32 indexed priceIdA,
    bytes32 indexed priceIdB,
    bool aGreater,
    uint256 deadline
);

event RatioThresholdTOCCreated(
    uint256 indexed tocId,
    bytes32 indexed priceIdA,
    bytes32 priceIdB,
    int64 ratio,
    bool isAbove,
    uint256 deadline
);

event SpreadThresholdTOCCreated(
    uint256 indexed tocId,
    bytes32 indexed priceIdA,
    bytes32 priceIdB,
    int64 spread,
    bool isAbove,
    uint256 deadline
);

event FlipTOCCreated(
    uint256 indexed tocId,
    bytes32 indexed priceIdA,
    bytes32 indexed priceIdB,
    uint256 deadline
);

event FirstToTargetTOCCreated(
    uint256 indexed tocId,
    bytes32 indexed priceId,
    int64 targetA,
    int64 targetB,
    uint256 deadline
);
```

### Resolution Events

```solidity
event TOCResolved(
    uint256 indexed tocId,
    uint32 indexed templateId,
    bool outcome,
    int64 priceUsed,
    uint256 publishTime
);

event MultiAssetTOCResolved(
    uint256 indexed tocId,
    uint32 indexed templateId,
    bool outcome,
    int64 priceA,
    int64 priceB,
    uint256 publishTime
);
```

## Contract Structure

```solidity
contract PythPriceResolver is ITOCResolver {
    // Constants
    uint32 public constant TEMPLATE_COUNT = 16; // 0-15
    uint64 public constant MAX_CONFIDENCE_PERCENT = 100; // 1% = 100 bps
    uint256 public constant POINT_IN_TIME_TOLERANCE = 1; // 1 second
    int32 public constant PRICE_DECIMALS = 8;

    // Immutables
    IPyth public immutable pyth;
    ITOCRegistry public immutable registry;

    // Storage - unified approach
    mapping(uint256 => uint32) private _tocTemplates;
    mapping(uint256 => bytes) private _tocPayloads;

    // ITOCResolver implementation
    function onTocCreated(...) external returns (TOCState);
    function resolveToc(...) external returns (bytes memory);
    function getTocDetails(...) external view returns (...);
    function getTocQuestion(...) external view returns (string memory);
    function getTemplateCount() external pure returns (uint32);
    function isValidTemplate(uint32) external pure returns (bool);
    function getTemplateAnswerType(uint32) external pure returns (AnswerType);

    // Internal helpers
    function _validatePayload(uint32 templateId, bytes calldata payload) internal view;
    function _normalizePrice(int64 price, int32 expo) internal pure returns (int64);
    function _checkConfidence(uint64 conf, int64 price) internal pure;
    function _verifyTiming(uint32 templateId, uint256 publishTime, uint256 deadline) internal pure;
}
```

## Future Extensions

- **Forex resolver** - Separate contract with market hours handling
- **Commodities resolver** - Separate contract with specific settlement rules
- **Emergency override** - TruthKeeper emergency powers (v2)
- **Configurable confidence** - Per-TOC confidence thresholds
