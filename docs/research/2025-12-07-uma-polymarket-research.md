# UMA & Polymarket Research: Question/Answer Storage Patterns

**Date:** 2025-12-07
**Purpose:** Research for designing an Optimistic Resolver for POPRegistry

---

## Executive Summary

UMA's Optimistic Oracle and Polymarket provide battle-tested patterns for:
1. **Question encoding** - UTF-8 ancillary data with structured format
2. **Answer values** - Scaled integers (1e18) for YES/NO/UNKNOWN/TOO_EARLY
3. **Bond economics** - Proposer/disputer bonds with split rewards
4. **Dispute flow** - Optimistic verification with escalation path

Key insight: **Questions are stored on-chain as bytes (UTF-8 encoded)**, not IPFS. This is simpler but gas-intensive for long questions.

---

## 1. Question Storage

### UMA's Ancillary Data Format

Questions are encoded as **UTF-8 bytes** with a dictionary structure:

```
q: "Did the temperature exceed 35°C in Manhattan on July 25, 2022?"
p1: 0    // NO
p2: 1    // YES
p3: 0.5  // UNKNOWN/CANNOT BE DETERMINED
p4: -57896044618658097711785492504343953926634992332820282019728.792003956564819968  // TOO EARLY (min int256)
```

**On-chain storage:**
```solidity
// Ancillary data as bytes
bytes public ancillaryData;

// Example encoding
ancillaryData = abi.encodePacked(
    'q: "Will BTC exceed $100k by Dec 31, 2025?",',
    'p1: 0,',    // NO
    'p2: 1,',    // YES
    'p3: 0.5,',  // UNKNOWN
    'p4: -57896044618658097711785492504343953926634992332820282019728.792003956564819968'  // TOO EARLY
);
```

**Limit:** 8,139 bytes max for ancillary data

### Polymarket Approach

Polymarket stores **full question + clarifications on-chain** via UMA adapter:

```solidity
// From UmaCtfAdapter.initialize()
struct QuestionData {
    bytes ancillaryData;      // Full question text + clarifications
    uint256 requestTimestamp;
    address rewardToken;
    uint256 reward;
    uint256 proposalBond;
    uint256 liveness;
}
```

**Question updates:** Polymarket uses a "bulletin board" contract for clarifications:
```
"Updates made by the question creator via the bulletin board on
0x6A5D0222186C0FceA7547534cC13c3CFd9b7b6A4F74 should be considered."
```

---

## 2. Answer Encoding

### YES_OR_NO_QUERY (Binary)

| Value | Meaning | Scaled (1e18) |
|-------|---------|---------------|
| 0 | NO | 0 |
| 1 | YES | 1e18 |
| 0.5 | UNKNOWN/INDETERMINATE | 5e17 |
| min int256 | TOO EARLY | -5.789...e76 |

**When to use each:**
- **p1 (0)**: Question resolved NO/negative
- **p2 (1)**: Question resolved YES/affirmative
- **p3 (0.5)**: At/after resolution time but truly indeterminate
- **p4 (min int256)**: Settlement requested before event occurred

### MULTIPLE_VALUES (Multi-outcome)

For non-binary outcomes, UMA packs up to 7 uint32 values into a single int256:

```
| label1 | label2 | label3 | label4 | label5 | label6 | label7 | unused |
| 32 bits| 32 bits| 32 bits| 32 bits| 32 bits| 32 bits| 32 bits| 32 bits|
```

---

## 3. Bond Economics

### UMA OOV3 Bond Flow

```
Proposer posts bond (e.g., 10,000 USDC)
    │
    ├── No dispute within liveness → Proposer gets bond back
    │
    └── Dispute filed (disputer posts matching 10,000 USDC)
            │
            ├── Proposer wins → Proposer gets 15,000 USDC, Store gets 5,000
            │
            └── Disputer wins → Disputer gets 15,000 USDC, Store gets 5,000
```

**Key parameters:**
- **Minimum bond:** Query via `getMinimumBond(token)` on OOV3
- **Default liveness:** 2 hours
- **Recommended liveness:** 2 hours minimum, longer for high-value

### Polymarket Adapter Bonds

```solidity
function initialize(
    bytes memory ancillaryData,
    address rewardToken,
    uint256 reward,           // Reward for successful proposer
    uint256 proposalBond,     // 0 = use UMA default
    uint256 liveness          // 0 = use UMA default
) external returns (bytes32 questionId);
```

---

## 4. Resolution Flow

### UMA Optimistic Oracle V3 Flow

```
1. ASSERTION
   └── assertTruth(claim, asserter, callback, liveness, currency, bond, identifier)

2. LIVENESS WINDOW (default 2 hours)
   └── Anyone can dispute by posting matching bond

3. SETTLEMENT
   ├── No dispute → settleAssertion() → assertionResolvedCallback(true)
   │
   └── Dispute filed → Escalate to DVM
       │
       └── DVM voting (commit/reveal, 48-72 hours)
           │
           └── assertionResolvedCallback(winner == asserter)
```

### Polymarket's Two-Round Dispute

```
1. INITIALIZE
   └── UmaCtfAdapter stores question, requests price from OO

2. PROPOSE
   └── Anyone posts proposalBond + proposed outcome

3. LIVENESS (~2 hours)
   │
   ├── No dispute → CTFAdapter resolves market
   │
   └── First dispute → Market RESETS (new OO request)
       │
       └── Second dispute → Escalate to DVM (48-72 hours)
```

**Why reset on first dispute?** "Ensures obviously incorrect disputes do not slow down resolution"

---

## 5. Callback Interface

### UMA OOV3 Callback

```solidity
interface OptimisticOracleV3CallbackRecipient {
    function assertionResolvedCallback(
        bytes32 assertionId,
        bool assertedTruthfully
    ) external;

    function assertionDisputedCallback(
        bytes32 assertionId
    ) external;
}
```

### Data Asserter Pattern

```solidity
contract DataAsserter is OptimisticOracleV3CallbackRecipient {
    struct DataAssertion {
        bytes32 dataId;
        bytes32 data;
        address asserter;
        bool resolved;
    }

    mapping(bytes32 => DataAssertion) public assertionsData;

    function assertionResolvedCallback(
        bytes32 assertionId,
        bool assertedTruthfully
    ) public {
        require(msg.sender == address(oo));

        if (assertedTruthfully) {
            assertionsData[assertionId].resolved = true;
            emit DataAssertionResolved(...);
        } else {
            // Disputed and lost - delete assertion
            delete assertionsData[assertionId];
        }
    }
}
```

---

## 6. Key Design Decisions for Our Optimistic Resolver

### What We Can Learn

| UMA/Polymarket Pattern | Apply to POP? | Notes |
|------------------------|---------------|-------|
| UTF-8 bytes for questions | ✅ | Simple, on-chain, verifiable |
| 8KB question limit | ✅ | Reasonable for most use cases |
| Scaled int256 answers | ⚠️ | We already have BOOLEAN/NUMERIC/GENERIC |
| 2-hour default liveness | ✅ | Good starting point |
| Bond split (50% winner, 50% protocol) | ⚠️ | We use TruthKeeper system |
| Reset on first dispute | ❌ | Our TK system handles this differently |
| DVM for final arbitration | ❌ | We use Admin escalation |

### Our Architecture Difference

**UMA:** Proposer → OO → Dispute → DVM (token-weighted voting)

**POP:** Proposer → Resolver → POPRegistry → TruthKeeper → Admin

We already have a robust dispute system. The Optimistic Resolver should:
1. Accept proposals with bonds
2. Validate question format
3. Call `POPRegistry.resolvePOP()` to submit outcome
4. Let POPRegistry's dispute mechanism handle challenges

### Proposed Question Format

```solidity
// Template 0: Arbitrary text question (like UMA YES_OR_NO_QUERY)
struct ArbitraryQuestion {
    string question;        // Human-readable question text
    string clarifications;  // Additional context/rules
    uint256 resolutionTime; // When question can be resolved
    AnswerType answerType;  // BOOLEAN, NUMERIC, or GENERIC
}

// Template 1: Sports outcome
struct SportsQuestion {
    string league;          // "NFL", "NBA", "MLB"
    string homeTeam;
    string awayTeam;
    uint256 gameTime;
    QuestionType qType;     // WINNER, SPREAD, TOTAL
}

// Template 2: Price threshold (alternative to Pyth)
struct PriceQuestion {
    string asset;           // "BTC", "ETH"
    string comparison;      // "above", "below", "between"
    int256 threshold;
    uint256 deadline;
}
```

---

## 7. Open Questions for Design

1. **Bond token:** ETH only or ERC20 support?
2. **Minimum bond:** Fixed or per-question configurable?
3. **Proposer whitelist:** Fast path for trusted proposers (lower bond, shorter liveness)?
4. **Question updates:** Allow clarifications via bulletin board pattern?
5. **Answer disputes:** Who can dispute - anyone or bond holders?

---

## Sources

- [Polymarket Resolution Docs](https://docs.polymarket.com/developers/resolution/UMA)
- [UMA Documentation](https://docs.uma.xyz)
- [Polymarket UMA CTF Adapter](https://github.com/Polymarket/uma-ctf-adapter)
- [UMA YES_OR_NO_QUERY Guide](https://docs.uma.xyz/verification-guide/yes_or_no)
- [UMA Data Asserter](https://docs.uma.xyz/developers/optimistic-oracle-v3/data-asserter)
- [Inside UMA Oracle - RockNBlock](https://rocknblock.io/blog/how-prediction-markets-resolution-works-uma-optimistic-oracle-polymarket)
