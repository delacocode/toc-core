/**
 * Check and withdraw fees from the TOC Registry
 *
 * Usage: npx hardhat run scripts/check-fees.ts --network <network>
 *
 * Actions:
 *   (default)           - Show all balances
 *   ACTION=withdraw-tk  - Withdraw TruthKeeper fees
 *   ACTION=withdraw-protocol - Withdraw protocol fees (treasury only)
 */

import { formatEther } from "viem";
import {
  getNetwork,
  loadDeployedAddresses,
  getChainConfig,
  createClients,
  getExplorerTxUrl,
} from "./lib/config.js";
import { getRegistryAbi } from "./lib/abis.js";

async function main() {
  const action = process.env.ACTION;
  const network = await getNetwork();
  const { chainId } = getChainConfig(network);
  const addresses = loadDeployedAddresses(chainId);
  const { publicClient, walletClient, account } = createClients(network);
  const abi = getRegistryAbi();

  console.log(`\n💰 Fee & Balance Check on ${network}\n`);
  console.log(`🔑 Account: ${account.address}\n`);

  // Get protocol fee balances
  console.log("📊 Protocol Fee Balances:");

  const creationFees = await publicClient.readContract({
    address: addresses.registry,
    abi,
    functionName: "getProtocolBalance",
    args: [0], // CREATION
  }) as bigint;

  const slashingFees = await publicClient.readContract({
    address: addresses.registry,
    abi,
    functionName: "getProtocolBalance",
    args: [1], // SLASHING
  }) as bigint;

  console.log(`   Creation fees:  ${formatEther(creationFees)} ETH`);
  console.log(`   Slashing fees:  ${formatEther(slashingFees)} ETH`);
  console.log(`   Total:          ${formatEther(creationFees + slashingFees)} ETH`);

  // Get TruthKeeper balance
  console.log("\n📊 TruthKeeper Balances:");

  const tkBalance = await publicClient.readContract({
    address: addresses.registry,
    abi,
    functionName: "getTKBalance",
    args: [addresses.truthKeeper],
  }) as bigint;

  console.log(`   SimpleTruthKeeper (${addresses.truthKeeper.slice(0, 10)}...): ${formatEther(tkBalance)} ETH`);

  // Check if caller is the TruthKeeper (for withdrawal)
  const callerTkBalance = await publicClient.readContract({
    address: addresses.registry,
    abi,
    functionName: "getTKBalance",
    args: [account.address],
  }) as bigint;

  if (callerTkBalance > 0n) {
    console.log(`   Your TK balance: ${formatEther(callerTkBalance)} ETH`);
  }

  // Get treasury address
  const treasury = await publicClient.readContract({
    address: addresses.registry,
    abi,
    functionName: "treasury",
  }) as `0x${string}`;

  console.log(`\n📍 Treasury: ${treasury}`);
  const isTreasury = account.address.toLowerCase() === treasury.toLowerCase();
  console.log(`   You are treasury: ${isTreasury ? "YES ✓" : "NO"}`);

  // Check account ETH balance
  const accountBalance = await publicClient.getBalance({ address: account.address });
  console.log(`\n💳 Your ETH balance: ${formatEther(accountBalance)} ETH`);

  // Handle actions
  if (action === "withdraw-protocol") {
    if (!isTreasury) {
      console.error("\n❌ Only treasury can withdraw protocol fees");
      return;
    }
    if (creationFees + slashingFees === 0n) {
      console.log("\n⚠️  No protocol fees to withdraw");
      return;
    }

    console.log("\n⏳ Withdrawing protocol fees...");
    const hash = await walletClient.writeContract({
      address: addresses.registry,
      abi,
      functionName: "withdrawProtocolFees",
    });
    const receipt = await publicClient.waitForTransactionReceipt({ hash });
    console.log(`✅ Withdrawn! Tx: ${getExplorerTxUrl(network, hash)}`);

  } else if (action === "withdraw-tk") {
    if (callerTkBalance === 0n) {
      console.log("\n⚠️  No TK fees to withdraw for your address");
      return;
    }

    console.log(`\n⏳ Withdrawing TK fees (${formatEther(callerTkBalance)} ETH)...`);
    const hash = await walletClient.writeContract({
      address: addresses.registry,
      abi,
      functionName: "withdrawTKFees",
    });
    const receipt = await publicClient.waitForTransactionReceipt({ hash });
    console.log(`✅ Withdrawn! Tx: ${getExplorerTxUrl(network, hash)}`);

  } else {
    // Just show summary
    console.log("\n💡 Available Actions:");
    if (isTreasury && creationFees + slashingFees > 0n) {
      console.log(`   ACTION=withdraw-protocol npx hardhat run scripts/check-fees.ts --network ${network}`);
    }
    if (callerTkBalance > 0n) {
      console.log(`   ACTION=withdraw-tk npx hardhat run scripts/check-fees.ts --network ${network}`);
    }
    if (!isTreasury && callerTkBalance === 0n) {
      console.log("   (No withdrawable fees for your address)");
    }
  }

  console.log();
}

main().catch(console.error);
