# TOC-Core Subgraph Integration Guide

This guide provides comprehensive documentation for integrating the TOC (Truth On Chain) system with subgraph indexing services like The Graph.

## Table of Contents

1. [System Overview](#system-overview)
2. [Contract Architecture](#contract-architecture)
3. [Complete Event Reference](#complete-event-reference)
4. [Entity Schema Design](#entity-schema-design)
5. [Indexing Strategy](#indexing-strategy)
6. [Event Handler Implementation](#event-handler-implementation)
7. [Derived Fields & Aggregations](#derived-fields--aggregations)
8. [Query Examples](#query-examples)
9. [Missing Events Analysis](#missing-events-analysis)

---

## System Overview

TOC-Core is a decentralized oracle and dispute resolution framework implementing:

- **Truth On Chain (TOC)** questions/events with lifecycle management
- **Resolver system** for different data sources (price feeds, human judgment)
- **Two-round dispute resolution** (TruthKeeper + Admin escalation)
- **Bond management** for resolutions and disputes
- **Fee distribution** (protocol, TruthKeeper, resolver)

### Core Flow

```
CREATE TOC -> TK Approval -> ACTIVE -> RESOLUTION PROPOSED -> DISPUTE WINDOW
                                              |
                           [No Dispute]       |        [Dispute Filed]
                                |             v             |
                           RESOLVED    DISPUTED_ROUND_1 ---+
                                              |
                              [TK Decision] --+-- [TK Timeout]
                                    |                  |
                              ESCALATION WINDOW        v
                                    |          DISPUTED_ROUND_2
                              [No Escalation]          |
                                    |            [Admin Resolution]
                                    v                  |
                               RESOLVED <--------------+
```

---

## Contract Architecture

### Deployed Contracts

| Contract | Purpose | Key Events |
|----------|---------|------------|
| `TruthEngine` | Central registry, lifecycle, disputes | TOC lifecycle, bonds, fees |
| `PythPriceResolverV2` | Oracle-based price conditions | Template-specific creation events |
| `OptimisticResolver` | Human judgment questions | Question creation, clarifications |
| `SimpleTruthKeeper` | TK validation logic | Configuration changes |

### Contract Relationships

```
                    TruthEngine (Central Registry)
                           |
          +----------------+----------------+
          |                |                |
    PythPriceResolverV2  OptimisticResolver  SimpleTruthKeeper
          |                |                        |
       Pyth Oracle    Human Judgment          Allowlist/Windows
```

---

## Complete Event Reference

### TruthEngine Events

#### Resolver Management

```graphql
# When a resolver is registered (permissionless)
event ResolverRegistered(
    address indexed resolver,
    ResolverTrust trust,         # RESOLVER (initial level)
    address indexed registeredBy
)

# When admin changes resolver trust level
event ResolverTrustChanged(
    address indexed resolver,
    ResolverTrust oldTrust,      # NONE | RESOLVER | VERIFIED | SYSTEM
    ResolverTrust newTrust
)
```

#### TruthKeeper Registry

```graphql
# TruthKeeper added to system whitelist
event TruthKeeperWhitelisted(address indexed tk)

# TruthKeeper removed from whitelist
event TruthKeeperRemovedFromWhitelist(address indexed tk)

# TK approved a specific TOC
event TruthKeeperApproved(uint256 indexed tocId, address indexed tk)

# TK soft-rejected (TOC proceeds as RESOLVER tier)
event TruthKeeperSoftRejected(uint256 indexed tocId, address indexed tk)
```

#### TOC Lifecycle Events

```graphql
# TOC created with full context - includes creator and all time windows
event TOCCreated(
    uint256 indexed tocId,
    address indexed resolver,
    address indexed creator,
    ResolverTrust trust,
    uint32 templateId,
    AnswerType answerType,       # BOOLEAN | NUMERIC | GENERIC
    TOCState initialState,       # PENDING | ACTIVE
    address truthKeeper,
    AccountabilityTier tier,     # RESOLVER | TK_GUARANTEED | SYSTEM
    uint32 disputeWindow,
    uint32 truthKeeperWindow,
    uint32 escalationWindow,
    uint32 postResolutionWindow
)

# Resolver approved a PENDING TOC
event TOCApproved(uint256 indexed tocId)

# Resolver rejected a PENDING TOC
event TOCRejected(uint256 indexed tocId, string reason)

# Creator transferred ownership
event CreatorTransferred(
    uint256 indexed tocId,
    address indexed previousCreator,
    address indexed newCreator
)
```

#### Resolution Events

```graphql
# Resolution proposed with bond
event TOCResolutionProposed(
    uint256 indexed tocId,
    address indexed proposer,
    AnswerType answerType,
    uint256 disputeDeadline
)

# Resolution accepted (dispute window passed)
event TOCResolved(uint256 indexed tocId, AnswerType answerType)

# TOC fully finalized (no more changes possible)
event TOCFinalized(uint256 indexed tocId, AnswerType answerType)
```

#### Dispute Events

```graphql
# Pre-resolution dispute filed - includes evidence URI
event TOCDisputed(
    uint256 indexed tocId,
    address indexed disputer,
    string reason,
    string evidenceURI
)

# Post-resolution dispute filed - includes evidence and proposed correction
event PostResolutionDisputeFiled(
    uint256 indexed tocId,
    address indexed disputer,
    string reason,
    string evidenceURI,
    bytes proposedResult
)

# Dispute resolved by admin
event DisputeResolved(
    uint256 indexed tocId,
    DisputeResolution resolution,  # UPHOLD_DISPUTE | REJECT_DISPUTE | CANCEL_TOC | TOO_EARLY
    address indexed admin
)

# Post-resolution dispute resolved
event PostResolutionDisputeResolved(
    uint256 indexed tocId,
    bool resultCorrected
)

# TOC cancelled
event TOCCancelled(uint256 indexed tocId, string reason)
```

#### TruthKeeper Dispute Flow

```graphql
# TK resolved Round 1 dispute
event TruthKeeperDisputeResolved(
    uint256 indexed tocId,
    address indexed tk,
    DisputeResolution resolution
)

# TK decision challenged (escalation to Round 2) - includes evidence and proposed correction
event TruthKeeperDecisionChallenged(
    uint256 indexed tocId,
    address indexed challenger,
    string reason,
    string evidenceURI,
    bytes proposedResult
)

# TK failed to respond in time
event TruthKeeperTimedOut(
    uint256 indexed tocId,
    address indexed tk
)

# Admin resolved Round 2 escalation
event EscalationResolved(
    uint256 indexed tocId,
    DisputeResolution resolution,
    address indexed admin
)
```

#### Bond Events

```graphql
# Resolution bond deposited
event ResolutionBondDeposited(
    uint256 indexed tocId,
    address indexed proposer,
    address token,
    uint256 amount
)

# Resolution bond returned
event ResolutionBondReturned(
    uint256 indexed tocId,
    address indexed to,
    address token,
    uint256 amount
)

# Dispute bond deposited
event DisputeBondDeposited(
    uint256 indexed tocId,
    address indexed disputer,
    address token,
    uint256 amount
)

# Dispute bond returned
event DisputeBondReturned(
    uint256 indexed tocId,
    address indexed to,
    address token,
    uint256 amount
)

# Escalation bond deposited
event EscalationBondDeposited(
    uint256 indexed tocId,
    address indexed challenger,
    address token,
    uint256 amount
)

# Escalation bond returned
event EscalationBondReturned(
    uint256 indexed tocId,
    address indexed to,
    address token,
    uint256 amount
)

# Bond slashed (loser's bond)
event BondSlashed(
    uint256 indexed tocId,
    address indexed from,
    address token,
    uint256 amount
)
```

#### Configuration Events

```graphql
# Acceptable bond added to the system
event AcceptableBondAdded(
    string bondType,             # "RESOLUTION" | "DISPUTE" | "ESCALATION"
    address indexed token,
    uint256 minAmount
)

# Default dispute window changed
event DefaultDisputeWindowChanged(
    uint256 oldDuration,
    uint256 newDuration
)
```

#### Fee Events

```graphql
# Treasury address set
event TreasurySet(address indexed treasury)

# Protocol fee configuration updated
event ProtocolFeeUpdated(uint256 minimum, uint256 standard)

# TK share percentage updated
event TKShareUpdated(AccountabilityTier indexed tier, uint256 basisPoints)

# Resolver set their template fee
event ResolverFeeSet(
    address indexed resolver,
    uint32 indexed templateId,
    uint256 amount
)

# Fees collected at TOC creation
event CreationFeesCollected(
    uint256 indexed tocId,
    uint256 protocolFee,
    uint256 tkFee,
    uint256 resolverFee
)

# Fees collected from slashing
event SlashingFeesCollected(
    uint256 indexed tocId,
    uint256 protocolFee,
    uint256 tkFee
)

# Protocol fees withdrawn to treasury
event ProtocolFeesWithdrawn(
    address indexed treasury,
    uint256 creationFees,
    uint256 slashingFees
)

# TK withdrew their accumulated fees
event TKFeesWithdrawn(address indexed tk, uint256 amount)

# Resolver claimed fee for a TOC
event ResolverFeeClaimed(
    address indexed resolver,
    uint256 indexed tocId,
    uint256 amount
)
```

### PythPriceResolverV2 Events

#### Template-Specific Creation Events

```graphql
event SnapshotTOCCreated(
    uint256 indexed tocId,
    bytes32 indexed priceId,
    int64 threshold,
    bool isAbove,
    uint256 deadline
)

event RangeTOCCreated(
    uint256 indexed tocId,
    bytes32 indexed priceId,
    int64 lowerBound,
    int64 upperBound,
    bool isInside,
    uint256 deadline
)

event ReachedTargetTOCCreated(
    uint256 indexed tocId,
    bytes32 indexed priceId,
    int64 target,
    bool isAbove,
    uint256 deadline
)

event TouchedBothTOCCreated(
    uint256 indexed tocId,
    bytes32 indexed priceId,
    int64 targetA,
    int64 targetB,
    uint256 deadline
)

event StayedTOCCreated(
    uint256 indexed tocId,
    bytes32 indexed priceId,
    uint256 startTime,
    uint256 deadline,
    int64 threshold,
    bool isAbove
)

event StayedInRangeTOCCreated(
    uint256 indexed tocId,
    bytes32 indexed priceId,
    uint256 startTime,
    uint256 deadline,
    int64 lowerBound,
    int64 upperBound
)

event BreakoutTOCCreated(
    uint256 indexed tocId,
    bytes32 indexed priceId,
    uint256 deadline,
    uint256 referenceTimestamp,
    int64 referencePrice,
    bool isUp
)

event PercentageChangeTOCCreated(
    uint256 indexed tocId,
    bytes32 indexed priceId,
    uint256 deadline,
    uint256 referenceTimestamp,
    int64 referencePrice,
    uint64 percentageBps,
    bool isUp
)

event PercentageEitherTOCCreated(
    uint256 indexed tocId,
    bytes32 indexed priceId,
    uint256 deadline,
    uint256 referenceTimestamp,
    int64 referencePrice,
    uint64 percentageBps
)

event EndVsStartTOCCreated(
    uint256 indexed tocId,
    bytes32 indexed priceId,
    uint256 deadline,
    uint256 referenceTimestamp,
    int64 referencePrice,
    bool isHigher
)

event AssetCompareTOCCreated(
    uint256 indexed tocId,
    bytes32 indexed priceIdA,
    bytes32 indexed priceIdB,
    uint256 deadline,
    bool aGreater
)

event RatioThresholdTOCCreated(
    uint256 indexed tocId,
    bytes32 indexed priceIdA,
    bytes32 indexed priceIdB,
    uint256 deadline,
    uint64 ratioBps,
    bool isAbove
)

event SpreadThresholdTOCCreated(
    uint256 indexed tocId,
    bytes32 indexed priceIdA,
    bytes32 indexed priceIdB,
    uint256 deadline,
    int64 spreadThreshold,
    bool isAbove
)

event FlipTOCCreated(
    uint256 indexed tocId,
    bytes32 indexed priceIdA,
    bytes32 indexed priceIdB,
    uint256 deadline,
    uint256 referenceTimestamp,
    int64 referencePriceA,
    int64 referencePriceB
)

event FirstToTargetTOCCreated(
    uint256 indexed tocId,
    bytes32 indexed priceId,
    int64 targetA,
    int64 targetB,
    uint256 deadline
)
```

#### Resolution Events

```graphql
# Price TOC resolved with outcome
event TOCResolved(
    uint256 indexed tocId,
    uint32 indexed templateId,
    bool outcome,
    int64 priceUsed,
    uint256 publishTime
)

# Reference price set for templates that need it
event ReferencePriceSet(
    uint256 indexed tocId,
    int64 price,
    uint256 timestamp
)

# Reference prices set for dual-asset templates
event ReferencePricesSet(
    uint256 indexed tocId,
    int64 priceA,
    int64 priceB,
    uint256 timestamp
)
```

### OptimisticResolver Events

```graphql
# Question created
event QuestionCreated(
    uint256 indexed tocId,
    uint32 indexed templateId,
    address indexed creator,
    string questionPreview
)

# Resolution proposed with justification
event ResolutionProposed(
    uint256 indexed tocId,
    address indexed proposer,
    bool answer,
    string justification
)

# Clarification requested by creator
event ClarificationRequested(
    uint256 indexed tocId,
    address indexed creator,
    uint256 clarificationId,
    string text
)

# Clarification accepted
event ClarificationAccepted(
    uint256 indexed tocId,
    uint256 clarificationId
)

# Clarification rejected
event ClarificationRejected(
    uint256 indexed tocId,
    uint256 clarificationId
)
```

### SimpleTruthKeeper Events

```graphql
# Resolver added/removed from allowlist
event ResolverAllowedChanged(
    address indexed resolver,
    bool allowed
)

# Global default windows changed
event DefaultMinWindowsChanged(
    uint32 disputeWindow,
    uint32 tkWindow
)

# Per-resolver window overrides changed
event ResolverMinWindowsChanged(
    address indexed resolver,
    uint32 disputeWindow,
    uint32 tkWindow
)

# Ownership transferred
event OwnershipTransferred(
    address indexed oldOwner,
    address indexed newOwner
)

# Registry address updated
event RegistryUpdated(
    address indexed oldRegistry,
    address indexed newRegistry
)
```

---

## Entity Schema Design

### GraphQL Schema

```graphql
# Enums matching Solidity types
enum TOCState {
  NONE
  PENDING
  REJECTED
  ACTIVE
  RESOLVING
  DISPUTED_ROUND_1
  DISPUTED_ROUND_2
  RESOLVED
  CANCELLED
}

enum AnswerType {
  NONE
  BOOLEAN
  NUMERIC
  GENERIC
}

enum ResolverTrust {
  NONE
  RESOLVER
  VERIFIED
  SYSTEM
}

enum AccountabilityTier {
  NONE
  RESOLVER
  TK_GUARANTEED
  SYSTEM
}

enum DisputeResolution {
  UPHOLD_DISPUTE
  REJECT_DISPUTE
  CANCEL_TOC
  TOO_EARLY
}

enum DisputePhase {
  NONE
  PRE_RESOLUTION
  POST_RESOLUTION
}

# ============ Core Entities ============

type Resolver @entity {
  id: ID!                          # resolver address
  trust: ResolverTrust!
  registeredAt: BigInt!
  registeredBy: Bytes!

  # Aggregates
  totalTOCs: BigInt!
  activeTOCs: BigInt!
  resolvedTOCs: BigInt!
  disputedTOCs: BigInt!

  # Fees
  templateFees: [ResolverTemplateFee!]! @derivedFrom(field: "resolver")
  claimedFees: BigInt!
  unclaimedFees: BigInt!

  # Relations
  tocs: [TOC!]! @derivedFrom(field: "resolver")
}

type ResolverTemplateFee @entity {
  id: ID!                          # resolver-templateId
  resolver: Resolver!
  templateId: Int!
  amount: BigInt!
}

type TruthKeeper @entity {
  id: ID!                          # address
  isWhitelisted: Boolean!

  # Aggregates
  totalTOCsAssigned: BigInt!
  approvedTOCs: BigInt!
  softRejectedTOCs: BigInt!
  disputesResolved: BigInt!
  timeouts: BigInt!

  # Fees
  accumulatedFees: BigInt!
  withdrawnFees: BigInt!

  # Relations
  tocs: [TOC!]! @derivedFrom(field: "truthKeeper")
}

type TOC @entity {
  id: ID!                          # tocId as string
  tocId: BigInt!

  # Core fields
  creator: Bytes!
  resolver: Resolver!
  state: TOCState!
  answerType: AnswerType!
  truthKeeper: TruthKeeper!
  tierAtCreation: AccountabilityTier!
  resolverTrust: ResolverTrust!

  # Template info
  templateId: Int!

  # Time windows (configured)
  disputeWindow: BigInt!
  truthKeeperWindow: BigInt!
  escalationWindow: BigInt!
  postResolutionWindow: BigInt!

  # Computed deadlines
  disputeDeadline: BigInt
  truthKeeperDeadline: BigInt
  escalationDeadline: BigInt
  postDisputeDeadline: BigInt

  # Timestamps
  createdAt: BigInt!
  resolvedAt: BigInt
  finalizedAt: BigInt

  # Result
  result: Bytes
  originalResult: Bytes
  hasCorrectedResult: Boolean!

  # Fees
  protocolFee: BigInt
  tkFee: BigInt
  resolverFee: BigInt

  # Relations
  resolution: Resolution
  dispute: Dispute
  escalation: Escalation
  bonds: [Bond!]! @derivedFrom(field: "toc")
  stateChanges: [TOCStateChange!]! @derivedFrom(field: "toc")

  # Resolver-specific data (polymorphic)
  priceData: PriceCondition
  questionData: Question
}

type Resolution @entity {
  id: ID!                          # tocId
  toc: TOC!
  proposer: Bytes!
  bondToken: Bytes!
  bondAmount: BigInt!
  proposedResult: Bytes!
  proposedAt: BigInt!
}

type Dispute @entity {
  id: ID!                          # tocId
  toc: TOC!
  phase: DisputePhase!
  disputer: Bytes!
  bondToken: Bytes!
  bondAmount: BigInt!
  reason: String!
  evidenceURI: String
  proposedResult: Bytes
  filedAt: BigInt!
  resolvedAt: BigInt
  resolution: DisputeResolution
  resultCorrected: Boolean!

  # TK decision (Round 1)
  tkDecision: DisputeResolution
  tkDecidedAt: BigInt
}

type Escalation @entity {
  id: ID!                          # tocId
  toc: TOC!
  challenger: Bytes!
  bondToken: Bytes!
  bondAmount: BigInt!
  reason: String!
  evidenceURI: String
  proposedResult: Bytes
  filedAt: BigInt!
  resolvedAt: BigInt
  resolution: DisputeResolution
  resolvedBy: Bytes
}

type Bond @entity {
  id: ID!                          # tocId-type-depositor
  toc: TOC!
  bondType: String!                # "RESOLUTION" | "DISPUTE" | "ESCALATION"
  depositor: Bytes!
  token: Bytes!
  amount: BigInt!
  depositedAt: BigInt!
  status: String!                  # "ACTIVE" | "RETURNED" | "SLASHED"
  returnedAt: BigInt
  slashedAt: BigInt
  slashedTo: Bytes
}

type TOCStateChange @entity {
  id: ID!                          # tocId-txHash-logIndex
  toc: TOC!
  fromState: TOCState!
  toState: TOCState!
  timestamp: BigInt!
  blockNumber: BigInt!
  transactionHash: Bytes!
}

# ============ Price Resolver Entities ============

type PriceCondition @entity {
  id: ID!                          # tocId
  toc: TOC!
  templateId: Int!
  templateName: String!
  priceId: Bytes!                  # Primary Pyth price ID
  priceIdB: Bytes                  # Secondary (for dual-asset templates)
  deadline: BigInt!

  # Template-specific parameters (nullable based on template)
  threshold: BigInt
  lowerBound: BigInt
  upperBound: BigInt
  target: BigInt
  targetA: BigInt
  targetB: BigInt
  startTime: BigInt
  isAbove: Boolean
  isInside: Boolean
  isUp: Boolean
  isHigher: Boolean
  aGreater: Boolean
  percentageBps: BigInt
  ratioBps: BigInt
  spreadThreshold: BigInt

  # Reference prices (set later for some templates)
  referencePrice: BigInt
  referencePriceB: BigInt
  referenceTimestamp: BigInt

  # Resolution outcome
  outcome: Boolean
  priceUsed: BigInt
  publishTime: BigInt
}

# ============ Optimistic Resolver Entities ============

type Question @entity {
  id: ID!                          # tocId
  toc: TOC!
  templateId: Int!
  templateName: String!            # "ARBITRARY" | "SPORTS" | "EVENT"
  creator: Bytes!
  createdAt: BigInt!
  questionPreview: String!

  # Clarifications
  clarifications: [Clarification!]! @derivedFrom(field: "question")
  clarificationCount: Int!

  # Resolution
  proposedAnswer: Boolean
  proposedJustification: String
  proposer: Bytes
  proposedAt: BigInt
}

type Clarification @entity {
  id: ID!                          # tocId-clarificationId
  question: Question!
  clarificationId: BigInt!
  text: String!
  requestedBy: Bytes!
  requestedAt: BigInt!
  status: String!                  # "PENDING" | "ACCEPTED" | "REJECTED"
  processedAt: BigInt
}

# ============ Fee Entities ============

type ProtocolFeeConfig @entity {
  id: ID!                          # "config"
  treasury: Bytes
  minimumFee: BigInt!
  standardFee: BigInt!
  tkShareResolver: BigInt!         # Basis points for RESOLVER tier
  tkShareTkGuaranteed: BigInt!     # Basis points for TK_GUARANTEED
  tkShareSystem: BigInt!           # Basis points for SYSTEM
}

type FeeCollection @entity {
  id: ID!                          # tocId-type
  toc: TOC!
  feeType: String!                 # "CREATION" | "SLASHING"
  protocolFee: BigInt!
  tkFee: BigInt!
  resolverFee: BigInt
  collectedAt: BigInt!
}

type FeeWithdrawal @entity {
  id: ID!                          # txHash-logIndex
  withdrawer: Bytes!
  withdrawerType: String!          # "PROTOCOL" | "TRUTH_KEEPER" | "RESOLVER"
  amount: BigInt!
  creationFees: BigInt
  slashingFees: BigInt
  withdrawnAt: BigInt!
  transactionHash: Bytes!
}

# ============ Global Stats ============

type GlobalStats @entity {
  id: ID!                          # "global"
  totalTOCs: BigInt!
  activeTOCs: BigInt!
  resolvedTOCs: BigInt!
  cancelledTOCs: BigInt!
  disputedTOCs: BigInt!
  totalResolvers: BigInt!
  totalTruthKeepers: BigInt!
  totalBondsDeposited: BigInt!
  totalBondsSlashed: BigInt!
  totalProtocolFees: BigInt!
  totalTKFees: BigInt!
  totalResolverFees: BigInt!
}

type DailyStats @entity {
  id: ID!                          # date (YYYY-MM-DD)
  date: String!
  tocsCreated: BigInt!
  tocsResolved: BigInt!
  disputesFiled: BigInt!
  feesCollected: BigInt!
  bondsDeposited: BigInt!
  bondsSlashed: BigInt!
}
```

---

## Indexing Strategy

### Contract Data Sources

```yaml
# subgraph.yaml
specVersion: 0.0.5
schema:
  file: ./schema.graphql
dataSources:
  - kind: ethereum
    name: TruthEngine
    network: mainnet  # or your network
    source:
      address: "0x..."
      abi: TruthEngine
      startBlock: 12345678
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.7
      language: wasm/assemblyscript
      entities:
        - TOC
        - Resolver
        - TruthKeeper
        - Resolution
        - Dispute
        - Escalation
        - Bond
        - GlobalStats
      abis:
        - name: TruthEngine
          file: ./abis/TruthEngine.json
      eventHandlers:
        # Resolver events
        - event: ResolverRegistered(indexed address,uint8,indexed address)
          handler: handleResolverRegistered
        - event: ResolverTrustChanged(indexed address,uint8,uint8)
          handler: handleResolverTrustChanged

        # TruthKeeper events
        - event: TruthKeeperWhitelisted(indexed address)
          handler: handleTruthKeeperWhitelisted
        - event: TruthKeeperRemovedFromWhitelist(indexed address)
          handler: handleTruthKeeperRemovedFromWhitelist
        - event: TruthKeeperApproved(indexed uint256,indexed address)
          handler: handleTruthKeeperApproved
        - event: TruthKeeperSoftRejected(indexed uint256,indexed address)
          handler: handleTruthKeeperSoftRejected

        # TOC lifecycle events
        - event: TOCCreated(indexed uint256,indexed address,uint8,uint32,uint8,uint8,indexed address,uint8)
          handler: handleTOCCreated
        - event: TOCApproved(indexed uint256)
          handler: handleTOCApproved
        - event: TOCRejected(indexed uint256,string)
          handler: handleTOCRejected
        - event: CreatorTransferred(indexed uint256,indexed address,indexed address)
          handler: handleCreatorTransferred

        # Resolution events
        - event: TOCResolutionProposed(indexed uint256,indexed address,uint8,uint256)
          handler: handleTOCResolutionProposed
        - event: TOCResolved(indexed uint256,uint8)
          handler: handleTOCResolved
        - event: TOCFinalized(indexed uint256,uint8)
          handler: handleTOCFinalized

        # Dispute events
        - event: TOCDisputed(indexed uint256,indexed address,string)
          handler: handleTOCDisputed
        - event: PostResolutionDisputeFiled(indexed uint256,indexed address,string)
          handler: handlePostResolutionDisputeFiled
        - event: DisputeResolved(indexed uint256,uint8,indexed address)
          handler: handleDisputeResolved
        - event: PostResolutionDisputeResolved(indexed uint256,bool)
          handler: handlePostResolutionDisputeResolved
        - event: TOCCancelled(indexed uint256,string)
          handler: handleTOCCancelled

        # TK dispute flow
        - event: TruthKeeperDisputeResolved(indexed uint256,indexed address,uint8)
          handler: handleTruthKeeperDisputeResolved
        - event: TruthKeeperDecisionChallenged(indexed uint256,indexed address,string)
          handler: handleTruthKeeperDecisionChallenged
        - event: TruthKeeperTimedOut(indexed uint256,indexed address)
          handler: handleTruthKeeperTimedOut
        - event: EscalationResolved(indexed uint256,uint8,indexed address)
          handler: handleEscalationResolved

        # Bond events
        - event: ResolutionBondDeposited(indexed uint256,indexed address,address,uint256)
          handler: handleResolutionBondDeposited
        - event: ResolutionBondReturned(indexed uint256,indexed address,address,uint256)
          handler: handleResolutionBondReturned
        - event: DisputeBondDeposited(indexed uint256,indexed address,address,uint256)
          handler: handleDisputeBondDeposited
        - event: DisputeBondReturned(indexed uint256,indexed address,address,uint256)
          handler: handleDisputeBondReturned
        - event: EscalationBondDeposited(indexed uint256,indexed address,address,uint256)
          handler: handleEscalationBondDeposited
        - event: EscalationBondReturned(indexed uint256,indexed address,address,uint256)
          handler: handleEscalationBondReturned
        - event: BondSlashed(indexed uint256,indexed address,address,uint256)
          handler: handleBondSlashed

        # Configuration events
        - event: AcceptableBondAdded(string,indexed address,uint256)
          handler: handleAcceptableBondAdded
        - event: DefaultDisputeWindowChanged(uint256,uint256)
          handler: handleDefaultDisputeWindowChanged

        # Fee events
        - event: TreasurySet(indexed address)
          handler: handleTreasurySet
        - event: ProtocolFeeUpdated(uint256,uint256)
          handler: handleProtocolFeeUpdated
        - event: TKShareUpdated(indexed uint8,uint256)
          handler: handleTKShareUpdated
        - event: ResolverFeeSet(indexed address,indexed uint32,uint256)
          handler: handleResolverFeeSet
        - event: CreationFeesCollected(indexed uint256,uint256,uint256,uint256)
          handler: handleCreationFeesCollected
        - event: SlashingFeesCollected(indexed uint256,uint256,uint256)
          handler: handleSlashingFeesCollected
        - event: ProtocolFeesWithdrawn(indexed address,uint256,uint256)
          handler: handleProtocolFeesWithdrawn
        - event: TKFeesWithdrawn(indexed address,uint256)
          handler: handleTKFeesWithdrawn
        - event: ResolverFeeClaimed(indexed address,indexed uint256,uint256)
          handler: handleResolverFeeClaimed
      file: ./src/truth-engine.ts

  - kind: ethereum
    name: PythPriceResolverV2
    network: mainnet
    source:
      address: "0x..."
      abi: PythPriceResolverV2
      startBlock: 12345678
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.7
      language: wasm/assemblyscript
      entities:
        - PriceCondition
      abis:
        - name: PythPriceResolverV2
          file: ./abis/PythPriceResolverV2.json
      eventHandlers:
        - event: SnapshotTOCCreated(indexed uint256,indexed bytes32,int64,bool,uint256)
          handler: handleSnapshotTOCCreated
        - event: RangeTOCCreated(indexed uint256,indexed bytes32,int64,int64,bool,uint256)
          handler: handleRangeTOCCreated
        - event: ReachedTargetTOCCreated(indexed uint256,indexed bytes32,int64,bool,uint256)
          handler: handleReachedTargetTOCCreated
        - event: TouchedBothTOCCreated(indexed uint256,indexed bytes32,int64,int64,uint256)
          handler: handleTouchedBothTOCCreated
        - event: StayedTOCCreated(indexed uint256,indexed bytes32,uint256,uint256,int64,bool)
          handler: handleStayedTOCCreated
        - event: StayedInRangeTOCCreated(indexed uint256,indexed bytes32,uint256,uint256,int64,int64)
          handler: handleStayedInRangeTOCCreated
        - event: BreakoutTOCCreated(indexed uint256,indexed bytes32,uint256,uint256,int64,bool)
          handler: handleBreakoutTOCCreated
        - event: PercentageChangeTOCCreated(indexed uint256,indexed bytes32,uint256,uint256,int64,uint64,bool)
          handler: handlePercentageChangeTOCCreated
        - event: PercentageEitherTOCCreated(indexed uint256,indexed bytes32,uint256,uint256,int64,uint64)
          handler: handlePercentageEitherTOCCreated
        - event: EndVsStartTOCCreated(indexed uint256,indexed bytes32,uint256,uint256,int64,bool)
          handler: handleEndVsStartTOCCreated
        - event: AssetCompareTOCCreated(indexed uint256,indexed bytes32,indexed bytes32,uint256,bool)
          handler: handleAssetCompareTOCCreated
        - event: RatioThresholdTOCCreated(indexed uint256,indexed bytes32,indexed bytes32,uint256,uint64,bool)
          handler: handleRatioThresholdTOCCreated
        - event: SpreadThresholdTOCCreated(indexed uint256,indexed bytes32,indexed bytes32,uint256,int64,bool)
          handler: handleSpreadThresholdTOCCreated
        - event: FlipTOCCreated(indexed uint256,indexed bytes32,indexed bytes32,uint256,uint256,int64,int64)
          handler: handleFlipTOCCreated
        - event: FirstToTargetTOCCreated(indexed uint256,indexed bytes32,int64,int64,uint256)
          handler: handleFirstToTargetTOCCreated
        - event: TOCResolved(indexed uint256,indexed uint32,bool,int64,uint256)
          handler: handlePriceResolverTOCResolved
        - event: ReferencePriceSet(indexed uint256,int64,uint256)
          handler: handleReferencePriceSet
        - event: ReferencePricesSet(indexed uint256,int64,int64,uint256)
          handler: handleReferencePricesSet
      file: ./src/pyth-price-resolver.ts

  - kind: ethereum
    name: OptimisticResolver
    network: mainnet
    source:
      address: "0x..."
      abi: OptimisticResolver
      startBlock: 12345678
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.7
      language: wasm/assemblyscript
      entities:
        - Question
        - Clarification
      abis:
        - name: OptimisticResolver
          file: ./abis/OptimisticResolver.json
      eventHandlers:
        - event: QuestionCreated(indexed uint256,indexed uint32,indexed address,string)
          handler: handleQuestionCreated
        - event: ResolutionProposed(indexed uint256,indexed address,bool,string)
          handler: handleResolutionProposed
        - event: ClarificationRequested(indexed uint256,indexed address,uint256,string)
          handler: handleClarificationRequested
        - event: ClarificationAccepted(indexed uint256,uint256)
          handler: handleClarificationAccepted
        - event: ClarificationRejected(indexed uint256,uint256)
          handler: handleClarificationRejected
      file: ./src/optimistic-resolver.ts

  - kind: ethereum
    name: SimpleTruthKeeper
    network: mainnet
    source:
      address: "0x..."
      abi: SimpleTruthKeeper
      startBlock: 12345678
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.7
      language: wasm/assemblyscript
      entities:
        - TruthKeeper
      abis:
        - name: SimpleTruthKeeper
          file: ./abis/SimpleTruthKeeper.json
      eventHandlers:
        - event: ResolverAllowedChanged(indexed address,bool)
          handler: handleResolverAllowedChanged
        - event: DefaultMinWindowsChanged(uint32,uint32)
          handler: handleDefaultMinWindowsChanged
        - event: ResolverMinWindowsChanged(indexed address,uint32,uint32)
          handler: handleResolverMinWindowsChanged
      file: ./src/simple-truth-keeper.ts
```

---

## Event Handler Implementation

### Example Handler: TOCCreated

```typescript
// src/truth-engine.ts
import { BigInt, Address } from "@graphprotocol/graph-ts"
import { TOCCreated } from "../generated/TruthEngine/TruthEngine"
import { TOC, Resolver, TruthKeeper, GlobalStats, TOCStateChange } from "../generated/schema"

export function handleTOCCreated(event: TOCCreated): void {
  let tocId = event.params.tocId.toString()

  // Create TOC entity
  let toc = new TOC(tocId)
  toc.tocId = event.params.tocId
  toc.resolver = event.params.resolver.toHexString()
  toc.state = stateToString(event.params.initialState)
  toc.answerType = answerTypeToString(event.params.answerType)
  toc.truthKeeper = event.params.truthKeeper.toHexString()
  toc.tierAtCreation = tierToString(event.params.tier)
  toc.resolverTrust = trustToString(event.params.trust)
  toc.templateId = event.params.templateId
  toc.createdAt = event.block.timestamp
  toc.hasCorrectedResult = false

  // Will be populated from contract call or other events
  toc.creator = Address.zero()
  toc.disputeWindow = BigInt.zero()
  toc.truthKeeperWindow = BigInt.zero()
  toc.escalationWindow = BigInt.zero()
  toc.postResolutionWindow = BigInt.zero()

  toc.save()

  // Update resolver stats
  let resolver = Resolver.load(event.params.resolver.toHexString())
  if (resolver) {
    resolver.totalTOCs = resolver.totalTOCs.plus(BigInt.fromI32(1))
    if (toc.state == "ACTIVE") {
      resolver.activeTOCs = resolver.activeTOCs.plus(BigInt.fromI32(1))
    }
    resolver.save()
  }

  // Update TruthKeeper stats
  let tk = TruthKeeper.load(event.params.truthKeeper.toHexString())
  if (tk) {
    tk.totalTOCsAssigned = tk.totalTOCsAssigned.plus(BigInt.fromI32(1))
    tk.save()
  }

  // Update global stats
  let stats = getOrCreateGlobalStats()
  stats.totalTOCs = stats.totalTOCs.plus(BigInt.fromI32(1))
  if (toc.state == "ACTIVE") {
    stats.activeTOCs = stats.activeTOCs.plus(BigInt.fromI32(1))
  }
  stats.save()

  // Create state change record
  let stateChange = new TOCStateChange(
    tocId + "-" + event.transaction.hash.toHexString() + "-" + event.logIndex.toString()
  )
  stateChange.toc = tocId
  stateChange.fromState = "NONE"
  stateChange.toState = toc.state
  stateChange.timestamp = event.block.timestamp
  stateChange.blockNumber = event.block.number
  stateChange.transactionHash = event.transaction.hash
  stateChange.save()
}

function getOrCreateGlobalStats(): GlobalStats {
  let stats = GlobalStats.load("global")
  if (!stats) {
    stats = new GlobalStats("global")
    stats.totalTOCs = BigInt.zero()
    stats.activeTOCs = BigInt.zero()
    stats.resolvedTOCs = BigInt.zero()
    stats.cancelledTOCs = BigInt.zero()
    stats.disputedTOCs = BigInt.zero()
    stats.totalResolvers = BigInt.zero()
    stats.totalTruthKeepers = BigInt.zero()
    stats.totalBondsDeposited = BigInt.zero()
    stats.totalBondsSlashed = BigInt.zero()
    stats.totalProtocolFees = BigInt.zero()
    stats.totalTKFees = BigInt.zero()
    stats.totalResolverFees = BigInt.zero()
  }
  return stats
}

function stateToString(state: i32): string {
  switch (state) {
    case 0: return "NONE"
    case 1: return "PENDING"
    case 2: return "REJECTED"
    case 3: return "ACTIVE"
    case 4: return "RESOLVING"
    case 5: return "DISPUTED_ROUND_1"
    case 6: return "DISPUTED_ROUND_2"
    case 7: return "RESOLVED"
    case 8: return "CANCELLED"
    default: return "NONE"
  }
}
```

---

## Derived Fields & Aggregations

### Daily Statistics

```typescript
function getOrCreateDailyStats(timestamp: BigInt): DailyStats {
  let dayId = timestamp.toI32() / 86400
  let date = new Date(dayId * 86400 * 1000).toISOString().split('T')[0]

  let stats = DailyStats.load(date)
  if (!stats) {
    stats = new DailyStats(date)
    stats.date = date
    stats.tocsCreated = BigInt.zero()
    stats.tocsResolved = BigInt.zero()
    stats.disputesFiled = BigInt.zero()
    stats.feesCollected = BigInt.zero()
    stats.bondsDeposited = BigInt.zero()
    stats.bondsSlashed = BigInt.zero()
  }
  return stats
}
```

### Resolver Performance Metrics

Calculate derived metrics like:
- Dispute rate: `disputedTOCs / totalTOCs`
- Resolution success rate: `resolvedTOCs / totalTOCs`
- Average resolution time: aggregate from TOC timestamps

---

## Query Examples

### Get TOC with Full Details

```graphql
query GetTOC($tocId: ID!) {
  toc(id: $tocId) {
    id
    tocId
    creator
    state
    answerType
    tierAtCreation

    resolver {
      id
      trust
    }

    truthKeeper {
      id
      isWhitelisted
    }

    # Time windows
    disputeWindow
    truthKeeperWindow
    escalationWindow
    postResolutionWindow

    # Deadlines
    disputeDeadline
    truthKeeperDeadline
    escalationDeadline
    postDisputeDeadline

    # Timestamps
    createdAt
    resolvedAt
    finalizedAt

    # Result
    result
    hasCorrectedResult

    # Related entities
    resolution {
      proposer
      bondAmount
      proposedAt
    }

    dispute {
      disputer
      reason
      resolution
      filedAt
    }

    priceData {
      templateName
      priceId
      deadline
      threshold
      outcome
      priceUsed
    }

    questionData {
      questionPreview
      clarificationCount
    }

    bonds {
      bondType
      amount
      status
    }

    stateChanges(orderBy: timestamp, orderDirection: asc) {
      fromState
      toState
      timestamp
    }
  }
}
```

### Get Active TOCs by Resolver

```graphql
query GetActiveTOCs($resolver: String!) {
  tocs(
    where: {
      resolver: $resolver,
      state_in: [ACTIVE, RESOLVING, DISPUTED_ROUND_1, DISPUTED_ROUND_2]
    }
    orderBy: createdAt
    orderDirection: desc
  ) {
    id
    state
    creator
    disputeDeadline
    truthKeeperDeadline
  }
}
```

### Get Disputed TOCs Awaiting Resolution

```graphql
query GetPendingDisputes {
  tocs(
    where: {
      state_in: [DISPUTED_ROUND_1, DISPUTED_ROUND_2]
    }
    orderBy: disputeDeadline
    orderDirection: asc
  ) {
    id
    state
    truthKeeper {
      id
    }
    dispute {
      reason
      filedAt
    }
    truthKeeperDeadline
    escalationDeadline
  }
}
```

### Global Statistics

```graphql
query GetGlobalStats {
  globalStats(id: "global") {
    totalTOCs
    activeTOCs
    resolvedTOCs
    disputedTOCs
    totalBondsDeposited
    totalBondsSlashed
    totalProtocolFees
  }
}
```

### Daily Activity

```graphql
query GetDailyActivity($startDate: String!, $endDate: String!) {
  dailyStats(
    where: { date_gte: $startDate, date_lte: $endDate }
    orderBy: date
    orderDirection: asc
  ) {
    date
    tocsCreated
    tocsResolved
    disputesFiled
    feesCollected
  }
}
```

---

## Event Coverage Analysis

The current event coverage is now **complete** for full subgraph indexing. All bond events and configuration changes are tracked.

### Recently Added Events (Now Available)

The following events have been implemented to complete the coverage:

1. **EscalationBondDeposited** ✅ - Now emitted when escalation bond is deposited
   - Emitted in `challengeTruthKeeperDecision()` after bond transfer

2. **EscalationBondReturned** ✅ - Now emitted when escalation bond is returned
   - Emitted in `resolveEscalation()` when returning bonds

3. **AcceptableBondAdded** ✅ - Now emitted when bond configurations are updated
   - Emitted in `addAcceptableResolutionBond()`, `addAcceptableDisputeBond()`, `addAcceptableEscalationBond()`
   - Includes bondType field ("RESOLUTION", "DISPUTE", or "ESCALATION")

4. **DefaultDisputeWindowChanged** ✅ - Now emitted when default dispute window is updated
   - Emitted in `setDefaultDisputeWindow()` with old and new values

### Optional Future Enhancement

**TOCStateChanged** - A generic state transition event could simplify indexing but adds gas cost per transition. Current approach of inferring state from specific events is more gas-efficient.

### Data Now Fully Available in Events

All critical indexing data is now available directly in events:

| Data | Event | Status |
|------|-------|--------|
| TOC creator | `TOCCreated` | ✅ Available |
| TOC time windows | `TOCCreated` | ✅ Available |
| Dispute evidence URI | `TOCDisputed`, `PostResolutionDisputeFiled` | ✅ Available |
| Escalation evidence URI | `TruthKeeperDecisionChallenged` | ✅ Available |
| Proposed corrections | `PostResolutionDisputeFiled`, `TruthKeeperDecisionChallenged` | ✅ Available |
| Bond configurations | `AcceptableBondAdded` | ✅ Available |
| Resolver fees | `ResolverFeeSet` | ✅ Available |

### Optional Contract Calls

For additional data not critical for indexing:

1. **Resolver template fees by template** - `getResolverFee(resolver, templateId)` for current fee lookup
2. **Full TOC struct** - `getTOC(tocId)` for computed deadlines and other derived data

---

## Best Practices

1. **Index All Events**: Every event should be indexed for complete history
2. **Store Raw + Decoded**: Keep both raw bytes and decoded values
3. **Track State Changes**: Create a separate entity for each state transition
4. **Use Derived Fields**: Calculate aggregates for performance
5. **Handle Reorgs**: Use `blockNumber` for ordering, not just `timestamp`
6. **Version Schema**: Plan for schema migrations as contracts evolve

---

## Deployment Checklist

- [ ] Deploy all contract ABIs
- [ ] Configure correct network and start blocks
- [ ] Verify event signatures match contract ABI
- [ ] Test handlers with historical data
- [ ] Set up alerting for indexing errors
- [ ] Document any off-chain data requirements
