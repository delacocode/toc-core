# OptimisticResolver Design

**Date:** 2025-12-07
**Status:** Draft

---

## Overview

The OptimisticResolver enables **human-judgment questions** for prediction markets using an optimistic proposal model. Anyone can propose answers with a bond, and disputes flow through TOCRegistry's TruthKeeper system.

Key difference from UMA: **No cross-chain needed** - all disputes stay on the same L2.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                      OptimisticResolver                              │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  Templates:                                                          │
│    0: Arbitrary Question (free-form YES/NO)                         │
│    1: Sports Outcome                                                │
│    2: Event Occurrence                                              │
│                                                                      │
│  Storage:                                                            │
│    questions[popId] → QuestionData (full question text)             │
│    clarifications[popId] → string[] (creator updates)               │
│                                                                      │
│  Key Functions:                                                      │
│    onPopCreated() → validate & store question                       │
│    resolvePop() → validate proposer's answer                        │
│    addClarification() → creator adds context                        │
│    getPopQuestion() → return formatted question + clarifications    │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
                              │
                              │ calls resolveTOC()
                              ▼
┌─────────────────────────────────────────────────────────────────────┐
│                        TOCRegistry                                   │
│                                                                      │
│  - Receives proposed answer + bond                                  │
│  - Opens dispute window (per-TOC configured)                        │
│  - Disputes → TruthKeeper → Admin                                   │
│  - Handles bond distribution                                        │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

---

## Resolution Flow

### Happy Path (No Dispute)

```
1. TOC Created
   └── User calls TOCRegistry.createTOC(optimisticResolver, template, payload, ...)
   └── OptimisticResolver.onTocCreated() stores question
   └── TOC state: ACTIVE

2. Resolution Proposed
   └── Anyone calls TOCRegistry.resolveTOC(tocId, bondToken, bondAmount, answerPayload)
   └── TOCRegistry calls OptimisticResolver.resolveToc(tocId, caller, answerPayload)
   └── OptimisticResolver validates answer format, returns result
   └── TOCRegistry stores proposal, starts dispute window
   └── TOC state: RESOLVING

3. Dispute Window Passes
   └── Anyone calls TOCRegistry.finalizeTOC(tocId)
   └── TOC state: RESOLVED
   └── Proposer gets bond back
```

### Disputed Path

```
1-2. Same as above...

3. Dispute Filed
   └── Disputer calls TOCRegistry.dispute(tocId, bondToken, bondAmount, reason, ...)
   └── TOC state: DISPUTED_ROUND_1
   └── TruthKeeper reviews

4. TruthKeeper Decision
   └── TK calls TOCRegistry.resolveTruthKeeperDispute(tocId, decision, ...)
   └── If UPHOLD: Result corrected, disputer wins bond
   └── If REJECT: Original stands, proposer keeps bond
   └── If TOO_EARLY: TOC returns to ACTIVE

5. Optional Escalation
   └── If TK decision challenged → DISPUTED_ROUND_2 → Admin decides
```

---

## Templates

### Template 0: Arbitrary Question (YES/NO)

The most flexible template - any human-readable question with YES/NO answer.

**Creation Payload:**
```solidity
struct ArbitraryQuestionPayload {
    string question;           // "Will candidate X win the 2024 election?"
    string description;        // Detailed description and rules
    string resolutionSource;   // "Official election results from AP, Reuters"
    uint256 resolutionTime;    // Timestamp when resolution becomes possible
}
```

**Answer Payload:**
```solidity
struct ArbitraryAnswerPayload {
    bool answer;               // true = YES, false = NO
    string justification;      // Optional: "AP called the race at 11pm EST"
}
```

**Question Format (getPopQuestion):**
```
Q: Will candidate X win the 2024 election?

Description: This market resolves YES if candidate X wins the electoral college...

Resolution Source: Official election results from AP, Reuters

Resolution Time: Nov 15, 2024 00:00 UTC

Clarifications:
- [Nov 1, 2024] If election is contested, wait for official certification
- [Nov 10, 2024] Supreme Court rulings are considered final
```

### Template 1: Sports Outcome

Structured template for sports events.

**Creation Payload:**
```solidity
struct SportsPayload {
    string league;             // "NFL", "NBA", "Premier League"
    string homeTeam;           // "Kansas City Chiefs"
    string awayTeam;           // "San Francisco 49ers"
    uint256 gameTime;          // Scheduled start time
    SportQuestionType qType;   // WINNER, SPREAD, OVER_UNDER
    int256 line;               // For spread/over-under (scaled 1e18)
}

enum SportQuestionType {
    WINNER,      // Which team wins?
    SPREAD,      // Does home team cover spread?
    OVER_UNDER   // Is total score over/under line?
}
```

**Answer Payload:**
```solidity
struct SportsAnswerPayload {
    bool answer;               // Result
    uint256 homeScore;         // Final home score
    uint256 awayScore;         // Final away score
}
```

**Question Format:**
```
Q: NFL - Will Kansas City Chiefs beat San Francisco 49ers?

Game Time: Feb 11, 2024 18:30 UTC
Question Type: WINNER

Resolution: YES if Kansas City wins, NO if San Francisco wins.
            Overtime counts. If game is cancelled, resolves UNKNOWN.
```

### Template 2: Event Occurrence

For verifiable real-world events.

**Creation Payload:**
```solidity
struct EventPayload {
    string event;              // "Fed announces rate cut"
    string description;        // Details about what qualifies
    string verificationSource; // "Federal Reserve official announcement"
    uint256 deadline;          // Must occur by this time
}
```

---

## Storage Design

```solidity
contract OptimisticResolver is ITOCResolver {

    // ============ Storage ============

    /// @notice Core question data for each TOC
    struct QuestionData {
        uint32 templateId;
        address creator;
        uint256 createdAt;
        bytes payload;              // Template-specific creation payload
        string[] clarifications;    // Creator-added clarifications
    }

    /// @notice Mapping from tocId to question data
    mapping(uint256 => QuestionData) private _questions;

    /// @notice Registry reference
    ITOCRegistry public immutable registry;

    // ============ Template Constants ============

    uint32 public constant TEMPLATE_ARBITRARY = 0;
    uint32 public constant TEMPLATE_SPORTS = 1;
    uint32 public constant TEMPLATE_EVENT = 2;
    uint32 public constant TEMPLATE_COUNT = 3;
}
```

---

## Key Functions

### onTocCreated

Called by TOCRegistry when TOC is created.

```solidity
function onTocCreated(
    uint256 tocId,
    uint32 templateId,
    bytes calldata payload
) external onlyRegistry returns (TOCState initialState) {
    // Validate template
    if (templateId >= TEMPLATE_COUNT) {
        revert InvalidTemplate(templateId);
    }

    // Validate payload based on template
    _validatePayload(templateId, payload);

    // Store question data
    _questions[tocId] = QuestionData({
        templateId: templateId,
        creator: tx.origin,  // Original creator, not registry
        createdAt: block.timestamp,
        payload: payload,
        clarifications: new string[](0)
    });

    // All optimistic questions start ACTIVE (no approval needed)
    return TOCState.ACTIVE;
}
```

### resolveToc

Called by TOCRegistry when someone proposes resolution.

```solidity
function resolveToc(
    uint256 tocId,
    address caller,
    bytes calldata answerPayload
) external onlyRegistry returns (bool booleanResult, int256 numericResult, bytes memory genericResult) {
    QuestionData storage q = _questions[tocId];

    // Validate answer format based on template
    _validateAnswer(q.templateId, answerPayload);

    // Decode answer
    if (q.templateId == TEMPLATE_ARBITRARY || q.templateId == TEMPLATE_SPORTS) {
        // Boolean answer
        (bool answer, ) = abi.decode(answerPayload, (bool, string));
        return (answer, 0, "");
    } else if (q.templateId == TEMPLATE_EVENT) {
        (bool occurred, ) = abi.decode(answerPayload, (bool, string));
        return (occurred, 0, "");
    }

    revert InvalidTemplate(q.templateId);
}
```

### addClarification

Allows question creator to add clarifications (like Polymarket's bulletin board).

```solidity
function addClarification(uint256 tocId, string calldata clarification) external {
    QuestionData storage q = _questions[tocId];

    // Only creator can add clarifications
    if (msg.sender != q.creator) {
        revert OnlyCreator(msg.sender, q.creator);
    }

    // Can only clarify before resolution
    TOC memory toc = registry.getTOC(tocId);
    if (toc.state != TOCState.ACTIVE && toc.state != TOCState.PENDING) {
        revert CannotClarifyAfterResolution(toc.state);
    }

    // Add clarification with timestamp
    string memory timestamped = string(abi.encodePacked(
        "[", _formatTimestamp(block.timestamp), "] ",
        clarification
    ));
    q.clarifications.push(timestamped);

    emit ClarificationAdded(tocId, msg.sender, clarification);
}
```

### getTocQuestion

Returns formatted question with all clarifications.

```solidity
function getTocQuestion(uint256 tocId) external view returns (string memory question) {
    QuestionData storage q = _questions[tocId];

    if (q.templateId == TEMPLATE_ARBITRARY) {
        return _formatArbitraryQuestion(tocId, q);
    } else if (q.templateId == TEMPLATE_SPORTS) {
        return _formatSportsQuestion(tocId, q);
    } else if (q.templateId == TEMPLATE_EVENT) {
        return _formatEventQuestion(tocId, q);
    }

    return "Unknown template";
}

function _formatArbitraryQuestion(
    uint256 tocId,
    QuestionData storage q
) internal view returns (string memory) {
    ArbitraryQuestionPayload memory p = abi.decode(q.payload, (ArbitraryQuestionPayload));

    // Build question string
    string memory result = string(abi.encodePacked(
        "Q: ", p.question, "\n\n",
        "Description: ", p.description, "\n\n",
        "Resolution Source: ", p.resolutionSource, "\n\n",
        "Resolution Time: ", _formatTimestamp(p.resolutionTime)
    ));

    // Add clarifications if any
    if (q.clarifications.length > 0) {
        result = string(abi.encodePacked(result, "\n\nClarifications:"));
        for (uint i = 0; i < q.clarifications.length; i++) {
            result = string(abi.encodePacked(result, "\n- ", q.clarifications[i]));
        }
    }

    return result;
}
```

---

## Events

```solidity
event QuestionCreated(
    uint256 indexed tocId,
    uint32 templateId,
    address indexed creator,
    string question
);

event ClarificationAdded(
    uint256 indexed tocId,
    address indexed creator,
    string clarification
);
```

---

## Error Definitions

```solidity
error InvalidTemplate(uint32 templateId);
error InvalidPayload();
error InvalidAnswer();
error OnlyRegistry();
error OnlyCreator(address caller, address creator);
error CannotClarifyAfterResolution(TOCState state);
error QuestionTooLong(uint256 length, uint256 max);
error ResolutionTimeInPast(uint256 resolutionTime, uint256 current);
```

---

## Gas Considerations

### Question Storage Costs (L2 estimates)

| Question Length | Storage Cost (Arbitrum) |
|-----------------|------------------------|
| 100 chars | ~$0.01 |
| 500 chars | ~$0.03 |
| 1000 chars | ~$0.05 |
| 5000 chars | ~$0.20 |

**Recommendation:** Set max question length to 8KB (matching UMA's limit).

```solidity
uint256 public constant MAX_QUESTION_LENGTH = 8192; // 8KB
```

---

## Comparison with PythPriceResolver

| Aspect | PythPriceResolver | OptimisticResolver |
|--------|-------------------|-------------------|
| Data Source | Pyth oracle (automated) | Human judgment |
| Resolution | Deterministic (price data) | Optimistic (anyone proposes) |
| Question Format | Structured (price/threshold) | Free-form text |
| Disputes | Rare (oracle is source of truth) | Expected (human judgment) |
| Gas Cost | Low (minimal storage) | Higher (stores full question) |

---

## Security Considerations

1. **Question Manipulation:** Creator clarifications could change meaning
   - Mitigation: Clarifications are timestamped, TruthKeepers can reject manipulative clarifications

2. **Spam Questions:** Anyone can create TOCs with nonsense
   - Mitigation: TOCRegistry's bond requirements apply

3. **Ambiguous Questions:** Poorly worded questions cause disputes
   - Mitigation: Templates encourage structured questions, clarifications allowed

4. **Resolution Time Gaming:** Setting past resolution times
   - Mitigation: Validate resolutionTime > block.timestamp in onTocCreated

---

## Implementation Plan

1. **Phase 1: Core Contract**
   - Implement OptimisticResolver with Template 0 (Arbitrary)
   - Basic question storage and retrieval
   - Integration with TOCRegistry

2. **Phase 2: Clarifications**
   - Add clarification system
   - Timestamp formatting

3. **Phase 3: Additional Templates**
   - Template 1: Sports
   - Template 2: Events

4. **Phase 4: Testing**
   - Unit tests for all templates
   - Integration tests with TOCRegistry
   - Dispute flow tests

---

## Open Questions

1. **Should we limit who can resolve?** Current design: anyone with bond. Alternative: only whitelisted or creator+whitelisted.

2. **Should clarifications be editable?** Current: append-only. Alternative: allow editing within time window.

3. **Numeric answers?** Current: all templates return boolean. Could add NUMERIC template for scored outcomes.

---

## Files to Create

```
contracts/
└── resolvers/
    └── OptimisticResolver.sol

contracts/test/
└── OptimisticResolver.t.sol
```
