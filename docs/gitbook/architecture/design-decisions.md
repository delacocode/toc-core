# Design Decisions & Trade-offs

## 1. Address-Based Resolver IDs (vs. Numeric IDs)

**Decision:** Use resolver contract addresses directly instead of registry-assigned numeric IDs.

| Aspect | Address-Based | Numeric IDs |
|--------|---------------|-------------|
| Uniqueness | Globally unique | Registry-scoped |
| Lookup | Direct | Mapping indirection |
| Gas | Slightly higher calldata | Lower calldata |
| Intuition | More intuitive | Less intuitive |

**Rationale:** Simplicity and intuitiveness outweigh minor gas differences.

## 2. Permissionless Resolver Registration

**Decision:** Anyone can register a resolver. Trust level managed separately.

| Aspect | Permissionless | Gated |
|--------|----------------|-------|
| Innovation | Maximum | Limited |
| Security | Consumer must check trust | Registry vouches |
| Spam | Possible (mitigated by trust levels) | Prevented |

**Rationale:** Explicit trust levels let consumers decide. Don't gate innovation.

## 3. Per-POP Time Windows (vs. Global)

**Decision:** Each POP specifies its own dispute/escalation windows.

| Aspect | Per-POP | Global |
|--------|---------|--------|
| Flexibility | High | Low |
| Complexity | Higher | Lower |
| Gas | Slightly higher | Lower |

**Rationale:** Different use cases need different finality speeds. A sports bet can't wait weeks.

## 4. Two-Round Dispute (vs. Single Round)

**Decision:** TruthKeeper first, then admin escalation.

| Aspect | Two-Round | Single |
|--------|-----------|--------|
| Cost | Higher (two bonds) | Lower |
| Accuracy | Higher (two reviews) | Lower |
| Finality | Slower (potential escalation) | Faster |

**Rationale:** High-value decisions need escalation paths. TruthKeeper handles most cases efficiently.

## 5. Immutable Accountability Snapshots

**Decision:** Tier calculated at creation, never changes.

| Aspect | Immutable | Dynamic |
|--------|-----------|---------|
| Predictability | High | Low |
| Flexibility | Lower | Higher |
| Trust | Clear upfront | Can change |

**Rationale:** Consumers need to know what they're getting when they integrate.

## 6. Resolver as Black Box

**Decision:** Registry doesn't know or care how resolvers work internally.

| Aspect | Black Box | Opinionated |
|--------|-----------|-------------|
| Flexibility | Maximum | Limited |
| Safety | Resolver risk | Registry can validate |
| Innovation | Unconstrained | Constrained |

**Rationale:** Trust levels handle safety. Don't limit what resolvers can do.
