/**
 * List all TOCs and their states
 * Usage: npx hardhat run scripts/list-tocs.ts --network sepolia
 */

import {
  getNetwork,
  loadDeployedAddresses,
  getChainConfig,
  createClients,
} from "./lib/config.js";
import { getRegistryAbi, STATE_NAMES } from "./lib/abis.js";

async function main() {
  const network = await getNetwork();
  const { chainId } = getChainConfig(network);
  const addresses = loadDeployedAddresses(chainId);
  const { publicClient } = createClients(network);
  const abi = getRegistryAbi();

  const nextId = await publicClient.readContract({
    address: addresses.registry,
    abi,
    functionName: "nextTocId",
  }) as bigint;

  const total = Number(nextId) - 1;
  console.log(`\n📊 TOCs on ${network}: ${total}\n`);

  if (total === 0) {
    console.log("   No TOCs created yet.\n");
    return;
  }

  console.log("ID  | State       | Resolver");
  console.log("----|-------------|------------------------------------------");

  let openCount = 0;

  for (let i = 1n; i < nextId; i++) {
    try {
      const toc = await publicClient.readContract({
        address: addresses.registry,
        abi,
        functionName: "getTOC",
        args: [i],
      }) as any;

      const stateName = STATE_NAMES[toc.state] || `UNKNOWN(${toc.state})`;
      const isOpen = toc.state === 3 || toc.state === 4;
      if (isOpen) openCount++;

      const marker = isOpen ? "🟢" : toc.state === 7 ? "✅" : toc.state === 8 ? "❌" : "⚪";
      const resolverShort = toc.resolver.slice(0, 20) + "...";

      console.log(`${marker} ${String(i).padStart(2)} | ${stateName.padEnd(11)} | ${resolverShort}`);
    } catch (e: any) {
      console.log(`❌ ${String(i).padStart(2)} | ERROR       | ${e.shortMessage || e.message}`);
    }
  }

  console.log(`\n🟢 Open TOCs (ACTIVE/RESOLVING): ${openCount}`);
  console.log(`\n💡 Query details: TOC_ID=<id> npx hardhat run scripts/query-toc.ts --network ${network}`);
}

main().catch(console.error);
