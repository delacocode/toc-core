# TOC Core

**Truth On Chain** - Infrastructure for financially-backed truth resolution on-chain.

TOC is a DeFi primitive that sits between data sources and protocols, providing verifiable answers with explicit accountability guarantees.

## Overview

Every answer in TOC comes with a known **accountability tier**:

| Tier | Meaning |
|------|---------|
| **SYSTEM** | Protocol-backed. Maximum security. Suitable for high-value settlements. |
| **TK_GUARANTEED** | TruthKeeper-backed. Balanced risk/reward. Standard production use. |
| **RESOLVER** | Resolver-only. Consumer assumes risk. Experimental or long-tail use. |

Consumers don't guess at trust - they see it explicitly and choose accordingly.

## Key Features

- **Flexible Answer Types** - Boolean, Numeric, or arbitrary bytes
- **Pluggable Resolvers** - Oracles, human judgment, APIs, on-chain state
- **Two-Round Dispute Resolution** - TruthKeeper review + Admin escalation
- **Explicit Accountability** - Tiered trust captured at creation time
- **Bond Economics** - Proposers and disputants stake capital; truth wins

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                        TOCRegistry                           │
│  - TOC lifecycle management (create, resolve, dispute)       │
│  - Bond handling and slashing                                │
│  - Fee collection and distribution                           │
│  - Result storage with accountability snapshots              │
└─────────────────────┬───────────────────────────────────────┘
                      │
        ┌─────────────┼─────────────┐
        ▼             ▼             ▼
┌───────────────┐ ┌───────────────┐ ┌───────────────┐
│ PythResolver  │ │ Optimistic    │ │ Custom        │
│               │ │ Resolver      │ │ Resolver      │
│ - Price feeds │ │ - Human input │ │ - Any logic   │
│ - 15 templates│ │ - YES/NO Qs   │ │               │
└───────────────┘ └───────────────┘ └───────────────┘
        │             │             │
        └─────────────┼─────────────┘
                      ▼
              ┌───────────────┐
              │ TruthKeepers  │
              │               │
              │ - Adjudicate  │
              │ - Validate    │
              └───────────────┘
```

## Contracts

### Core

| Contract | Description |
|----------|-------------|
| `TOCRegistry.sol` | Central registry managing TOC lifecycle, disputes, and results |
| `SimpleTruthKeeper.sol` | Production TruthKeeper with resolver allowlist and time validation |

### Resolvers

| Contract | Description |
|----------|-------------|
| `PythPriceResolverV2.sol` | 15 templates for Pyth oracle price-based questions |
| `OptimisticResolver.sol` | Human-judgment questions (arbitrary, sports, events) |

### Interfaces

| Contract | Description |
|----------|-------------|
| `ITOCRegistry.sol` | Registry interface for consumers |
| `ITOCResolver.sol` | Interface for resolver implementations |
| `ITruthKeeper.sol` | Interface for TruthKeeper implementations |

## Installation

```bash
# Clone the repository
git clone https://github.com/delacocode/toc-core.git
cd toc-core

# Install dependencies
npm install

# Compile contracts
npx hardhat compile
```

## Testing

```bash
# Run all tests
npx hardhat test

# Run with verbose output
npx hardhat test --verbose
```

## Quick Start

```solidity
import "./ITOCRegistry.sol";

contract MyMarket {
    ITOCRegistry public registry;

    function createMarket(bytes calldata payload) external payable returns (uint256 tocId) {
        (, , uint256 fee) = registry.getCreationFee(resolver, templateId);

        // Note: Max window depends on resolver trust (RESOLVER=1 day, VERIFIED=30 days)
        tocId = registry.createTOC{value: fee}(
            resolver,
            1,              // templateId (1=Arbitrary, 2=Sports, 3=Event)
            payload,
            12 hours,       // disputeWindow
            12 hours,       // truthKeeperWindow
            12 hours,       // escalationWindow
            0,              // postResolutionWindow
            truthKeeper
        );
    }

    function settle(uint256 tocId) external {
        ExtensiveResult memory res = registry.getExtensiveResult(tocId);
        require(res.isFinalized, "Not finalized");
        bool outcome = TOCResultCodec.decodeBoolean(res.result);
        // ... distribute winnings
    }
}
```

## TOC Lifecycle

```
NONE → PENDING → ACTIVE → RESOLVING → RESOLVED
         │          │         │
         ▼          ▼         ▼
      REJECTED  CANCELLED  DISPUTED_ROUND_1 → DISPUTED_ROUND_2 → RESOLVED
```

| State | Meaning |
|-------|---------|
| `PENDING` | Awaiting resolver approval |
| `ACTIVE` | Open for resolution proposals |
| `RESOLVING` | Answer proposed, dispute window open |
| `DISPUTED_ROUND_1` | TruthKeeper reviewing |
| `DISPUTED_ROUND_2` | Admin reviewing (escalated) |
| `RESOLVED` | Final answer, safe to settle |
| `CANCELLED` | Voided, refunds required |

## Time Window Limits

Maximum window durations are enforced based on resolver trust level:

| Trust Level | Max Window |
|-------------|------------|
| `RESOLVER` | 1 day |
| `VERIFIED` | 30 days |
| `SYSTEM` | 30 days |

## Documentation

- [Consumer Integration Guide](docs/integration/consumer-guide.md)
- [Architecture Overview](docs/gitbook/architecture/README.md)
- [TOC Lifecycle](docs/gitbook/architecture/toc-lifecycle.md)
- [Dispute Resolution](docs/gitbook/architecture/dispute-resolution.md)

## Security

This codebase has not yet undergone a formal security audit. Use at your own risk.

**Known Considerations:**
- Contract size is at 97% of the 24KB limit
- Owner has significant powers (will transfer to governance contract)
- External dependency on Pyth oracle for price feeds

## License

BUSL-1.1 (Business Source License 1.1)

## Contributing

Contributions are welcome. Please open an issue first to discuss proposed changes.
