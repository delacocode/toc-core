/**
 * Payload encoding/decoding utilities for TOC templates
 * Matches the struct definitions in OptimisticResolver.sol
 */

import { encodeAbiParameters, decodeAbiParameters } from "viem";

// Template IDs
export const TEMPLATE = {
  ARBITRARY: 1,
  SPORTS: 2,
  EVENT: 3,
} as const;

// ============================================
// Template 1: Arbitrary Question
// ============================================

export interface ArbitraryPayload {
  question: string;
  description: string;
  resolutionSource: string;
  resolutionTime: bigint;
}

const ARBITRARY_PAYLOAD_TYPE = [
  {
    type: "tuple",
    components: [
      { name: "question", type: "string" },
      { name: "description", type: "string" },
      { name: "resolutionSource", type: "string" },
      { name: "resolutionTime", type: "uint256" },
    ],
  },
] as const;

export function encodeArbitraryPayload(payload: ArbitraryPayload): `0x${string}` {
  return encodeAbiParameters(ARBITRARY_PAYLOAD_TYPE, [payload]);
}

export function decodeArbitraryPayload(data: `0x${string}`): ArbitraryPayload {
  const [decoded] = decodeAbiParameters(ARBITRARY_PAYLOAD_TYPE, data);
  return {
    question: decoded.question,
    description: decoded.description,
    resolutionSource: decoded.resolutionSource,
    resolutionTime: decoded.resolutionTime,
  };
}

// ============================================
// Answer Payload (used for resolution)
// ============================================

export interface AnswerPayload {
  answer: boolean;
  justification: string;
}

const ANSWER_PAYLOAD_TYPE = [
  {
    type: "tuple",
    components: [
      { name: "answer", type: "bool" },
      { name: "justification", type: "string" },
    ],
  },
] as const;

export function encodeAnswerPayload(payload: AnswerPayload): `0x${string}` {
  return encodeAbiParameters(ANSWER_PAYLOAD_TYPE, [payload]);
}

export function decodeAnswerPayload(data: `0x${string}`): AnswerPayload {
  const [decoded] = decodeAbiParameters(ANSWER_PAYLOAD_TYPE, data);
  return {
    answer: decoded.answer,
    justification: decoded.justification,
  };
}

// ============================================
// PythPriceResolver Templates
// ============================================

// Pyth template IDs (from PythPriceResolver.sol)
export const PYTH_TEMPLATE = {
  SNAPSHOT: 0,     // Is price above/below threshold at deadline?
  RANGE: 1,        // Is price within range at deadline?
  REACHED_BY: 2,   // Did price reach target before deadline?
} as const;

// Common Pyth Price Feed IDs
// Full list: https://www.pyth.network/developers/price-feed-ids
// Note: Price feed IDs are the same across all networks (mainnet & testnet)
export const PYTH_PRICE_IDS = {
  // Major Cryptocurrencies
  "BTC/USD": "0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43",
  "ETH/USD": "0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace",
  "SOL/USD": "0xef0d8b6fda2ceba41da15d4095d1da392a0d2f8ed0c6c7bc0f4cfac8c280b56d",
  "XRP/USD": "0xec5d399846a9209f3fe5881d70aae9268c94339ff9817e8d18ff19fa05eea1c8",
  "DOGE/USD": "0xdcef50dd0a4cd2dcc17e45df1676dcb336a11a61c69df7a0299b0150c672d25c",
  "LTC/USD": "0x6e3f3fa8253588df9326580180233eb791e03b443a3ba7a1d892e73874e19a54",
  "BCH/USD": "0x3dd2b63686a450ec7290df3a1e0b583c0481f651351edfa7636f39aed55cf8a3",
  "ZEC/USD": "0xbe9b59d178f0d6a97ab4c343bff2aa69caa1eaae3e9048a65788c529b125bb24",

  // L1 & L2 Tokens
  "AVAX/USD": "0x93da3352f9f1d105fdfe4971cfa80e9dd777bfc5d0f683ebb6e1294b92137bb7",
  "NEAR/USD": "0xc415de8d2eba7db216527dff4b60e8f3a5311c740dadb233e13e12547e226750",
  "ATOM/USD": "0xb00b60f88b03a6a625a8d1c048c3f66653edf217439983d037e7222c4e612819",
  "SUI/USD": "0x23d7315113f5b1d3ba7a83604c44b94d79f4fd69af77f804fc7f920a6dc65744",
  "APT/USD": "0x03ae4db29ed4ae33d323568895aa00337e658e348b37509f5372ae51f0af00d5",
  "SEI/USD": "0x53614f1cb0c031d4af66c04cb9c756234adad0e1cee85303795091499a4084eb",
  "TIA/USD": "0x09f7c1d7dfbb7df2b8fe3d3d87ee94a2259d212da4f30c1f0540d066dfa44723",
  "INJ/USD": "0x7a5bc1d2b56ad029048cd63964b3ad2776eadf812edc1a43a31406cb54bff592",
  "ARB/USD": "0x3fa4252848f9f0a1480be62745a4629d9eb1322aebab8a791e344b3b9c1adcf5",
  "OP/USD": "0x385f64d993f7b77d8182ed5003d97c60aa3361f3cecfe711544d2d59165e9bdf",

  // DeFi Tokens
  "LINK/USD": "0x8ac0c70fff57e9aefdf5edf44b51d62c2d433653cbb2cf5cc06bb115af04d221",
  "UNI/USD": "0x78d185a741d07edb3412b09008b7c5cfb9bbbd7d568bf00ba737b456ba171501",
  "AAVE/USD": "0x2b9ab1e972a281585084148ba1389800799bd4be63b957507db1349314e47445",
  "JUP/USD": "0x0a0408d619e9380abad35060f9192039ed5042fa6f82301d0e48bb52be830996",
  "PYTH/USD": "0x0bbf28e9a841a1cc788f6a361b17ca072d0ea3098a1e5df1c3922d06719579ff",

  // Meme Coins
  "PEPE/USD": "0xd69731a2e74ac1ce884fc3890f7ee324b6deb66147055249568869ed700882e4",
  "WIF/USD": "0x4ca4beeca86f0d164160323817a4e42b10010a724c2217c6ee41b54cd4cc61fc",
  "BONK/USD": "0x72b021217ca3fe68922a19aaf990109cb9d84e9ad004b4d2025ad6f529314419",
  "DEGEN/USD": "0x9c93e4a22c56885af427ac4277437e756e7ec403fbc892f975d497383bb33560",
  "WLD/USD": "0xd6835ad1f773de4a378115eb6824bd0c0e42d84d1c84d9750e853fb6b6c7794a",
  "TOSHI/USD": "0x3450d9fbb8c3cf749578315668e21fabb4cd78dcfda1c1cba698b804bae2db2a",

  // Stablecoins
  "USDC/USD": "0xeaa020c61cc479712813461ce153894a96a6c00b21ed0cfc2798d1f9a9e9c94a",
  "USDT/USD": "0x2b89b9dc8fdf9f34709a5b106b472f0f39bb6ca9ce04b0fd7f2e971688e2e53b",

  // US Equities
  "AAPL/USD": "0x49f6b65cb1de6b10eaf75e7c03ca029c306d0357e91b5311b175084a5ad55688",
  "TSLA/USD": "0x16dad506d7db8da01c87581c87ca897a012a153557d4d578c3b9c9e1bc0632f1",
  "NVDA/USD": "0xb1073854ed24cbc755dc527418f52b7d271f6cc967bbf8d8129112b18860a593",
  "AMZN/USD": "0xb5d0e0fa58a1f8b81498ae670ce93c872d14434b72c364885d4fa1b257cbb07a",
  "GOOGL/USD": "0x5a48c03e9b9cb337801073ed9d166817473697efff0d138874e0f6a33d6d5aa6",
  "MSFT/USD": "0xd0ca23c1cc005e004ccf1db5bf76aeb6a49218f43dac3d4b275e92de12ded4d1",
  "META/USD": "0x78a3e3b8e676a8f73c439f5d749737034b139bbbe899ba5775216fba596607fe",
  "AMD/USD": "0x3622e381dbca2efd1859253763b1adc63f7f9abb8e76da1aa8e638a57ccde93e",
  "COIN/USD": "0xfee33f2a978bf32dd6b662b65ba8083c6773b494f8401194ec1870c640860245",
  "MSTR/USD": "0xe1e80251f5f5184f2195008382538e847fafc36f751896889dd3d1b1f6111f09",
  "GME/USD": "0x6f9cd89ef1b7fd39f667101a91ad578b6c6ace4579d5f7f285a4b06aa4504be6",
  "AMC/USD": "0x5b1703d7eb9dc8662a61556a2ca2f9861747c3fc803e01ba5a8ce35cb50a13a1",
  "SPY/USD": "0x19e09bb805456ada3979a7d1cbb4b6d63babc3a0f8e8a9509f68afa5c4c11cd5",
  "QQQ/USD": "0x9695e2b96ea7b3859da9ed25b7a46a920a776e2fdae19a7bcfdf2b219230452d",

  // Forex
  "EUR/USD": "0xa995d00bb36a63cef7fd2c287dc105fc8f3d93779f062f09551b0af3e81ec30b",
  "GBP/USD": "0x84c2dde9633d93d1bcad84e7dc41c9d56578b7ec52fabedc1f335d673df0a7c1",
  "USD/JPY": "0xef2c98c804ba503c6a707e38be4dfbb16683775f195b091252bf24693042fd52",
  "AUD/USD": "0x67a6f93030420c1c9e3fe37c1ab6b77966af82f995944a9fefce357a22854a80",
  "USD/CAD": "0x3112b03a41c910ed446852aacf67118cb1bec67b2cd0b9a214c58cc0eaa2ecca",
  "USD/CHF": "0x0b1e3297e69f162877b577b0d6a47a0d63b2392bc8499e6540da4187a63e28f8",

  // Precious Metals
  "XAU/USD": "0x765d2ba906dbc32ca17cc11f5310a89e9ee1f6420508c63861f2f8ba4ee34bb2",
  "XAG/USD": "0xf2fb02c32b055c805e7238d628e5e9dadef274376114eb1f012337cabe93871e",
  "XPT/USD": "0x398e4bbc7cbf89d6648c21e08019d878967677753b3096799595c78f805a34e5",
  "XPD/USD": "0x80367e9664197f37d89a07a804dffd2101c479c7c4e8490501bc9d9e1e7f9021",
} as const;

// Reverse lookup: price ID -> asset name
export const PYTH_PRICE_NAMES: Record<string, string> = Object.fromEntries(
  Object.entries(PYTH_PRICE_IDS).map(([name, id]) => [id.toLowerCase(), name])
);

// ============================================
// Pyth Template 0: Snapshot (Above/Below)
// ============================================

export interface SnapshotPayload {
  priceId: `0x${string}`;
  threshold: bigint;  // Price in Pyth format (8 decimals, e.g., 100000_00000000 = $100,000)
  isAbove: boolean;   // true = "above", false = "below"
  deadline: bigint;   // Unix timestamp
}

const SNAPSHOT_PAYLOAD_TYPE = [
  { name: "priceId", type: "bytes32" },
  { name: "threshold", type: "int64" },
  { name: "isAbove", type: "bool" },
  { name: "deadline", type: "uint256" },
] as const;

export function encodeSnapshotPayload(payload: SnapshotPayload): `0x${string}` {
  return encodeAbiParameters(SNAPSHOT_PAYLOAD_TYPE, [
    payload.priceId,
    payload.threshold,
    payload.isAbove,
    payload.deadline,
  ]);
}

export function decodeSnapshotPayload(data: `0x${string}`): SnapshotPayload {
  const [priceId, threshold, isAbove, deadline] = decodeAbiParameters(SNAPSHOT_PAYLOAD_TYPE, data);
  return { priceId: priceId as `0x${string}`, threshold, isAbove, deadline };
}

// ============================================
// Pyth Template 1: Range
// ============================================

export interface RangePayload {
  priceId: `0x${string}`;
  lowerBound: bigint;
  upperBound: bigint;
  deadline: bigint;
}

const RANGE_PAYLOAD_TYPE = [
  { name: "priceId", type: "bytes32" },
  { name: "lowerBound", type: "int64" },
  { name: "upperBound", type: "int64" },
  { name: "deadline", type: "uint256" },
] as const;

export function encodeRangePayload(payload: RangePayload): `0x${string}` {
  return encodeAbiParameters(RANGE_PAYLOAD_TYPE, [
    payload.priceId,
    payload.lowerBound,
    payload.upperBound,
    payload.deadline,
  ]);
}

export function decodeRangePayload(data: `0x${string}`): RangePayload {
  const [priceId, lowerBound, upperBound, deadline] = decodeAbiParameters(RANGE_PAYLOAD_TYPE, data);
  return { priceId: priceId as `0x${string}`, lowerBound, upperBound, deadline };
}

// ============================================
// Pyth Template 2: Reached By
// ============================================

export interface ReachedByPayload {
  priceId: `0x${string}`;
  targetPrice: bigint;
  isAbove: boolean;  // true = must go above, false = must go below
  deadline: bigint;
}

const REACHED_BY_PAYLOAD_TYPE = [
  { name: "priceId", type: "bytes32" },
  { name: "targetPrice", type: "int64" },
  { name: "isAbove", type: "bool" },
  { name: "deadline", type: "uint256" },
] as const;

export function encodeReachedByPayload(payload: ReachedByPayload): `0x${string}` {
  return encodeAbiParameters(REACHED_BY_PAYLOAD_TYPE, [
    payload.priceId,
    payload.targetPrice,
    payload.isAbove,
    payload.deadline,
  ]);
}

export function decodeReachedByPayload(data: `0x${string}`): ReachedByPayload {
  const [priceId, targetPrice, isAbove, deadline] = decodeAbiParameters(REACHED_BY_PAYLOAD_TYPE, data);
  return { priceId: priceId as `0x${string}`, targetPrice, isAbove, deadline };
}

// ============================================
// Helper: Convert USD price to Pyth format
// ============================================

/**
 * Convert a human-readable USD price to Pyth's int64 format
 * Pyth uses 8 decimal places, so $100,000 = 100000_00000000
 * @param usdPrice - Price in USD (e.g., 100000 for $100,000)
 * @returns Price in Pyth int64 format
 */
export function usdToPythPrice(usdPrice: number): bigint {
  return BigInt(Math.round(usdPrice * 1e8));
}

/**
 * Convert Pyth's int64 price format to human-readable USD
 * @param pythPrice - Price in Pyth format
 * @returns Price in USD
 */
export function pythPriceToUsd(pythPrice: bigint): number {
  return Number(pythPrice) / 1e8;
}
