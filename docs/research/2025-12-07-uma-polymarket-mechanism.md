# UMA & Polymarket: Complete Mechanism Deep Dive

**Date:** 2025-12-07
**Purpose:** Understand how disputes work, especially cross-chain

---

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [Where Things Run](#2-where-things-run)
3. [Cross-Chain Dispute Flow](#3-cross-chain-dispute-flow)
4. [Complete Dispute Timeline](#4-complete-dispute-timeline)
5. [Bond Economics](#5-bond-economics)
6. [Question Storage](#6-question-storage)
7. [Key Differences from POP](#7-key-differences-from-pop)
8. [Sources](#8-sources)

---

## 1. Architecture Overview

### UMA's Three-Layer System

```
┌─────────────────────────────────────────────────────────────────────────┐
│                         APPLICATION LAYER                                │
│  (Polymarket, Across, Sherlock - prediction markets, bridges, etc.)     │
│  Runs on: Polygon, Arbitrum, Optimism, Base                             │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                      OPTIMISTIC ORACLE LAYER                             │
│  OptimisticOracleV2 / OptimisticOracleV3                                │
│  Runs on: Same L2 as application (Polygon, Arbitrum, etc.)              │
│  - Receives proposals                                                    │
│  - Handles liveness period (2 hours default)                            │
│  - Accepts/rejects based on disputes                                    │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
                            (Only if disputed)
                                    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                    DATA VERIFICATION MECHANISM (DVM)                     │
│  Runs on: ETHEREUM MAINNET ONLY                                         │
│  - UMA token holder voting                                              │
│  - Commit/reveal voting phases                                          │
│  - Final arbiter of truth                                               │
└─────────────────────────────────────────────────────────────────────────┘
```

### Polymarket Specific Stack

```
Polymarket UI (Web)
        │
        ▼
┌─────────────────────────────────────────┐
│      Polymarket Contracts (Polygon)      │
│  - CTF (Conditional Token Framework)     │
│  - CLOB (Order Book)                     │
│  - UmaCtfAdapter                         │
└─────────────────────────────────────────┘
        │
        ▼
┌─────────────────────────────────────────┐
│   UMA OptimisticOracle V2 (Polygon)      │
│  - Receives resolution proposals         │
│  - 2-hour liveness window               │
└─────────────────────────────────────────┘
        │
        │ (If disputed - cross-chain!)
        ▼
┌─────────────────────────────────────────┐
│  Oracle Child Tunnel (Polygon)           │
│         │                                │
│         │ Polygon PoS Bridge             │
│         ▼                                │
│  Oracle Root Tunnel (Ethereum)           │
│         │                                │
│         ▼                                │
│  DVM Voting (Ethereum Mainnet)           │
│         │                                │
│         │ (Result relayed back)          │
│         ▼                                │
│  Oracle Root Tunnel → Child Tunnel       │
│         │                                │
│         ▼                                │
│  Resolution finalized on Polygon         │
└─────────────────────────────────────────┘
```

---

## 2. Where Things Run

### By Chain

| Component | Chain | Notes |
|-----------|-------|-------|
| Polymarket trading | Polygon | All bets, positions, USDC |
| UMA OptimisticOracle | Polygon | Proposals, liveness periods |
| Question storage | Polygon | ancillaryData stored on-chain |
| Dispute initiation | Polygon | Post bond on Polygon |
| DVM Voting | **Ethereum Mainnet** | UMA token voting |
| Final resolution | Polygon | Result relayed back |

### Cross-Chain Bridge Contracts

| Contract | Location | Purpose |
|----------|----------|---------|
| OracleSpoke | L2 (Polygon, Arbitrum, etc.) | Receives price requests, relays disputes |
| OracleHub | Ethereum Mainnet | Collects disputes, submits to DVM |
| ChildMessenger | L2 | L2 → Mainnet communication |
| ParentMessenger | Mainnet | Mainnet → L2 communication |
| Oracle Child Tunnel | Polygon | Polygon-specific bridge |
| Oracle Root Tunnel | Mainnet | Polygon-specific bridge |

**Key Insight:** Each L2 has different messenger contracts because each uses different native bridges (Polygon PoS Bridge, Arbitrum Inbox/Outbox, Optimism CrossDomainMessenger).

---

## 3. Cross-Chain Dispute Flow

### Step-by-Step: Polygon → Ethereum → Polygon

```
POLYGON                                          ETHEREUM MAINNET
────────                                         ────────────────

1. Proposal submitted on Polygon
   └── OptimisticOracle receives proposal
   └── 2-hour liveness window starts

2. Dispute filed on Polygon
   └── Disputer posts bond (e.g., $750 USDC)
   └── OptimisticOracle marks as disputed

3. Cross-chain relay begins
   └── Oracle Child Tunnel sends message    ──────►  Oracle Root Tunnel receives
                                                      │
                                                      ▼
4.                                                   OracleHub validates
                                                      │
                                                      ▼
5.                                                   DVM receives price request
                                                      │
                                                      ▼
6.                                                   Commit phase (24-48 hrs)
                                                     UMA holders commit votes
                                                      │
                                                      ▼
7.                                                   Reveal phase
                                                     Votes revealed, tallied
                                                      │
                                                      ▼
8.                                                   DVM resolves dispute
                                                      │
9. Oracle Child Tunnel receives result  ◄──────────  Oracle Root Tunnel relays

10. OptimisticOracle on Polygon finalizes
    └── Market resolved
    └── Bonds distributed
```

### Multi-Sig Fallback

For chains without native messaging bridges, UMA uses a **multi-sig controlled by Risk Labs engineers** to relay disputes. This is acknowledged as a centralization point they're working to decentralize.

---

## 4. Complete Dispute Timeline

### Polymarket Dispute Timeline

| Phase | Duration | What Happens |
|-------|----------|--------------|
| **Proposal** | Instant | Proposer submits outcome + bond (~$750) |
| **Liveness Window** | 2 hours | Anyone can dispute |
| **Dispute Filed** | Instant | Disputer posts matching bond |
| **Debate Period** | 24-48 hours | Discussion in UMA Discord |
| **DVM Voting** | ~48 hours | UMA token holders vote |
| **Resolution** | Instant | Result relayed back to L2 |

**Total time if disputed:** 4-6 days

**If NOT disputed:** 2 hours only

### UMA DVM Voting Schedule

- Votes happen **every other day** (not continuously)
- Always at least 24 hours for discussion before vote
- Commit phase: ~24 hours
- Reveal phase: ~24 hours

---

## 5. Bond Economics

### Standard Polymarket Bonds

| Role | Bond Amount | Notes |
|------|-------------|-------|
| Proposer | ~$750 USDC | Posted to propose resolution |
| Disputer | ~$750 USDC | Must match proposer bond |
| Reward | $5-$100 USDC | Paid to successful proposer |

### Dispute Outcomes

```
┌─────────────────────────────────────────────────────────────────┐
│                     DISPUTE OUTCOMES                             │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  PROPOSER WINS (dispute rejected):                              │
│    - Proposer gets: bond back + 50% of disputer's bond          │
│    - Disputer loses: entire bond                                │
│    - UMA voters: share remaining 50%                            │
│                                                                  │
│  DISPUTER WINS (dispute upheld):                                │
│    - Disputer gets: bond back + 50% of proposer's bond          │
│    - Proposer loses: entire bond                                │
│    - UMA voters: share remaining 50%                            │
│                                                                  │
│  TOO EARLY:                                                      │
│    - Event hasn't happened yet                                  │
│    - Disputer gets: bond back + 50% of proposer's bond          │
│    - Market returns to open state                               │
│                                                                  │
│  UNKNOWN (50-50):                                               │
│    - Question unanswerable                                      │
│    - Market resolves 50-50                                      │
│    - Disputer gets: bond back + 50% of proposer's bond          │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

### Why 50-50 Split?

- **50% to winner:** Incentivizes correct proposals/disputes
- **50% to UMA voters:** Incentivizes participation in DVM voting
- **Minimum bond ensures:** Cost of attack > potential gain

---

## 6. Question Storage

### How Polymarket Stores Questions

**Location:** On-chain on Polygon as `ancillaryData` (bytes)

**Format:** UTF-8 encoded dictionary

```solidity
// Stored on Polygon in UmaCtfAdapter
bytes public ancillaryData = abi.encodePacked(
    'q: "Will Bitcoin exceed $100,000 by December 31, 2025?",',
    'p1: 0,',      // NO
    'p2: 1,',      // YES
    'p3: 0.5,',    // UNKNOWN
    'p4: -57896044618658097711785492504343953926634992332820282019728.792003956564819968,', // TOO EARLY
    'description: "This market resolves YES if...",',
    'resolutionSource: "CoinGecko, CoinMarketCap"'
);
```

**Limit:** 8,139 bytes maximum

### Clarifications/Updates

Polymarket uses a **"Bulletin Board" pattern:**

```
"Updates made by the question creator via the bulletin board on
0x6A5D0222186C0FceA7547534cC13c3CFd9b7b6A4F74 should be considered."
```

This allows question creators to add clarifications without modifying the original question.

### Off-Chain Metadata

Polymarket's **Gamma service** stores (NOT on-chain):
- Market categories/tags
- UI metadata
- Volume statistics
- Historical data

---

## 7. Key Differences from POP

| Aspect | UMA/Polymarket | POP System |
|--------|----------------|------------|
| **Final Arbiter** | DVM (UMA token voting) | Admin/Governance |
| **Dispute Location** | Escalates to Ethereum mainnet | Stays on same chain |
| **Voting Mechanism** | Token-weighted voting | TruthKeeper → Admin |
| **Cross-Chain** | Required for disputes | Not required |
| **Bond Token** | Usually USDC | ETH or ERC20 (configurable) |
| **Liveness Period** | 2 hours default | Per-POP configurable |
| **Two-Round Disputes** | No (direct to DVM) | Yes (TK → Admin) |

### POP's Advantage

POP keeps everything on the same chain:
- No cross-chain messaging complexity
- No mainnet gas costs for disputes
- Faster dispute resolution (no bridge delays)
- No dependency on UMA token holders

### POP's Trade-off

POP relies on trusted TruthKeepers + Admin instead of token voting:
- More centralized final decision
- But: faster, cheaper, simpler

---

## 8. Sources

### Official Documentation

- [Polymarket Resolution Docs](https://docs.polymarket.com/developers/resolution/UMA)
- [Polymarket Dispute Process](https://docs.polymarket.com/polymarket-learn/markets/dispute)
- [UMA Documentation](https://docs.uma.xyz)
- [UMA FAQs](https://docs.uma.xyz/faqs)
- [UMA Network Addresses](https://docs.uma.xyz/resources/network-addresses)

### Technical Specifications

- [Polymarket UMA CTF Adapter (GitHub)](https://github.com/Polymarket/uma-ctf-adapter)
- [UMA Cross-Chain UMIP-144](https://github.com/UMAprotocol/UMIPs/blob/master/UMIPs/umip-144.md)
- [UMA YES_OR_NO_QUERY Guide](https://docs.uma.xyz/verification-guide/yes_or_no)
- [UMA Data Asserter](https://docs.uma.xyz/developers/optimistic-oracle-v3/data-asserter)

### Analysis & Explainers

- [Inside UMA Oracle - RockNBlock](https://rocknblock.io/blog/how-prediction-markets-resolution-works-uma-optimistic-oracle-polymarket)
- [UMA Disputes on Polymarket - PolyNoob](https://polynoob.com/uma-dispute-polymarket/)
- [UMA Scaling to Polygon - Polygon Blog](https://polygon.technology/blog/uma-is-scaling-to-polygon)
- [Polymarket Success on Polygon - CoinDesk](https://www.coindesk.com/tech/2024/10/25/polymarket-is-huge-success-for-polygon-blockchain-everywhere-but-the-bottom-line)
- [How UMA Secures Across Protocol](https://blog.uma.xyz/articles/case-study-how-uma-secures-across-protocol)
- [UMA on Base Launch](https://blog.uma.xyz/articles/umas-optimistic-oracle-has-launched-base)

### Recent Updates

- [UMA Oracle Update - Whitelisted Proposers (The Block)](https://www.theblock.co/post/366507/polymarket-uma-oracle-update)
- [Polymarket + UMA Legacy Docs](https://legacy-docs.polymarket.com/polymarket-+-uma)

---

## Summary

**Key Takeaway:** UMA/Polymarket's system requires cross-chain messaging to Ethereum mainnet for DVM voting when disputes occur. This adds:
- Complexity (bridge contracts, messengers)
- Latency (bridge delays + voting schedule)
- Cost (mainnet gas for DVM)

**POP's approach is simpler:** Keep everything on L2 with TruthKeeper + Admin as arbiters. Trade-off is more centralized trust, but faster/cheaper/simpler.
