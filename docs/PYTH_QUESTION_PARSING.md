# Parsing PythPriceResolver Question Strings

The `getTocQuestion()` function returns a raw string that needs parsing to extract human-readable values.

## Question Formats by Template

### Template 0: Snapshot (Above/Below)
```
Will price be above 320000000000 at timestamp 1736103600?
Will price be below 9000000000000 at timestamp 1736190000?
```

**Regex:** `Will price be (above|below) (-?\d+) at timestamp (\d+)\?`

### Template 1: Range
```
Will price be between 300000000000 and 350000000000 at timestamp 1736103600?
```

**Regex:** `Will price be between (-?\d+) and (-?\d+) at timestamp (\d+)\?`

### Template 2: Reached By
```
Will price reach above 400000000000 by timestamp 1736103600?
```

**Regex:** `Will price reach (above|below) (-?\d+) by timestamp (\d+)\?`

## Parsing Values

### Price (int64, 8 decimals)
```typescript
function formatPrice(raw: string): string {
  const price = Number(raw) / 1e8;
  return price.toLocaleString("en-US", {
    style: "currency",
    currency: "USD",
    maximumFractionDigits: 0
  });
}

// "320000000000" → "$3,200"
// "9000000000000" → "$90,000"
```

### Timestamp (Unix seconds)
```typescript
function formatTime(timestamp: string): string {
  return new Date(Number(timestamp) * 1000).toLocaleString();
}

// "1736103600" → "1/5/2026, 7:00:00 PM"
```

## Getting the Asset Name

The question string does NOT include the asset. To get it, call `getTocDetails()` and decode the `priceId`:

```typescript
const [templateId, payload] = await resolver.getTocDetails(tocId);

// Decode payload (for Snapshot template)
const decoded = decodeAbiParameters(
  [
    { name: "priceId", type: "bytes32" },
    { name: "threshold", type: "int64" },
    { name: "isAbove", type: "bool" },
    { name: "deadline", type: "uint256" },
  ],
  payload
);

// Import from toc-core exports (54+ supported assets)
import { PYTH_PRICE_NAMES } from "toc-core/exports/toc-types";

const asset = PYTH_PRICE_NAMES[decoded[0].toLowerCase()]; // "ETH/USD"
```

## Complete Example

```typescript
import { decodeAbiParameters } from "viem";
import { PYTH_PRICE_NAMES } from "toc-core/exports/toc-types";

async function formatPythToc(tocId: bigint, resolver: any) {
  // Get question and details
  const question = await resolver.getTocQuestion(tocId);
  const [templateId, payload] = await resolver.getTocDetails(tocId);

  // Parse question
  const match = question.match(/Will price be (above|below) (-?\d+) at timestamp (\d+)\?/);
  if (!match) return question;

  const [, direction, rawPrice, timestamp] = match;

  // Decode payload for asset
  const decoded = decodeAbiParameters(
    [
      { name: "priceId", type: "bytes32" },
      { name: "threshold", type: "int64" },
      { name: "isAbove", type: "bool" },
      { name: "deadline", type: "uint256" },
    ],
    payload
  );

  const asset = PYTH_PRICE_NAMES[decoded[0].toLowerCase()] || "Unknown";
  const price = (Number(rawPrice) / 1e8).toLocaleString("en-US", {
    style: "currency", currency: "USD", maximumFractionDigits: 0
  });
  const time = new Date(Number(timestamp) * 1000).toLocaleString();

  return `Will ${asset} be ${direction} ${price} at ${time}?`;
  // "Will ETH/USD be above $3,200 at 1/5/2026, 7:00:00 PM?"
}
```

## Payload Structures by Template

| Template | Payload ABI |
|----------|-------------|
| 0 (Snapshot) | `(bytes32 priceId, int64 threshold, bool isAbove, uint256 deadline)` |
| 1 (Range) | `(bytes32 priceId, int64 lowerBound, int64 upperBound, uint256 deadline)` |
| 2 (ReachedBy) | `(bytes32 priceId, int64 targetPrice, bool isAbove, uint256 deadline)` |
