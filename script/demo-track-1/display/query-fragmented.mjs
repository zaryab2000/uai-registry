#!/usr/bin/env node
import chalk from "chalk";
import { createPublicClient, http } from "viem";
import { sepolia } from "viem/chains";

// ── Config ──────────────────────────────────────────────

const ERC8004_IDENTITY =
  process.env.ERC8004_IDENTITY ||
  "0x8004A818BFB912233c491871b3d84c89A494BD9e";

const CHAINS = [
  {
    name: "Ethereum Sepolia",
    chainId: "11155111",
    rpcEnv: "SEPOLIA_RPC",
    rpcDefault: "https://ethereum-sepolia-rpc.publicnode.com",
    agentIdEnv: "BOUND_AGENT_ID_ETH",
    viemChain: sepolia,
  },
  {
    name: "Base Sepolia",
    chainId: "84532",
    rpcEnv: "BASE_SEPOLIA_RPC",
    rpcDefault: "https://sepolia.base.org",
    agentIdEnv: "BOUND_AGENT_ID_BASE",
    viemChain: {
      id: 84532,
      name: "Base Sepolia",
      nativeCurrency: { name: "ETH", symbol: "ETH", decimals: 18 },
      rpcUrls: { default: { http: ["https://sepolia.base.org"] } },
    },
  },
  {
    name: "BSC Testnet",
    chainId: "97",
    rpcEnv: "BSC_TESTNET_RPC",
    rpcDefault: "https://data-seed-prebsc-1-s1.bnbchain.org:8545",
    agentIdEnv: "BOUND_AGENT_ID_BSC",
    viemChain: {
      id: 97,
      name: "BSC Testnet",
      nativeCurrency: { name: "BNB", symbol: "tBNB", decimals: 18 },
      rpcUrls: {
        default: {
          http: ["https://data-seed-prebsc-1-s1.bnbchain.org:8545"],
        },
      },
    },
  },
];

const erc8004Abi = [
  {
    name: "ownerOf",
    type: "function",
    stateMutability: "view",
    inputs: [{ name: "tokenId", type: "uint256" }],
    outputs: [{ name: "", type: "address" }],
  },
  {
    name: "tokenURI",
    type: "function",
    stateMutability: "view",
    inputs: [{ name: "tokenId", type: "uint256" }],
    outputs: [{ name: "", type: "string" }],
  },
];

// ── Rendering helpers ───────────────────────────────────

const W = 68;
const TOP = "╔" + "═".repeat(W - 2) + "╗";
const MID = "╠" + "═".repeat(W - 2) + "╣";
const BOT = "╚" + "═".repeat(W - 2) + "╝";
const boxLine = (s) => "║  " + s.padEnd(W - 4) + "║";
const sTop = (t) => "┌─── " + t + " " + "─".repeat(W - 7 - t.length) + "┐";
const sBot = () => "└" + "─".repeat(W - 2) + "┘";
const sLine = (s) => "│  " + s.padEnd(W - 4) + "│";
const sSep = () => "│  " + "─".repeat(W - 6) + "  │";

const shortAddr = (a) => a.slice(0, 6) + "..." + a.slice(-4);
const shortUri = (uri) =>
  uri.length > 40 ? uri.slice(0, 20) + "..." + uri.slice(-8) : uri;

const kv = (k, v) => `${chalk.dim(k.padEnd(18))}${v}`;

// ── Header ──────────────────────────────────────────────

console.log();
console.log(chalk.bold.red(TOP));
console.log(
  chalk.bold.red(
    boxLine(chalk.bold.white("ERC8004 Agent Full Profile"))
  )
);
console.log(chalk.bold.red(BOT));
console.log();
console.log(chalk.red(sTop("FRAGMENTED IDENTITY")));
console.log(
  sLine(chalk.dim("Same wallet, same agent, same metadata"))
);
console.log(
  sLine(chalk.dim("But 3 chains, 3 different IDs, ZERO link"))
);
console.log(sBot());

// ── Query each chain ────────────────────────────────────

const results = [];

for (const chain of CHAINS) {
  const rpcUrl = process.env[chain.rpcEnv] || chain.rpcDefault;
  const agentIdStr = process.env[chain.agentIdEnv];

  if (!agentIdStr) {
    console.log();
    console.log(chalk.yellow(sTop(chain.name)));
    console.log(sLine(chalk.red(`⚠ ${chain.agentIdEnv} not set — skipped`)));
    console.log(sBot());
    continue;
  }

  const agentId = BigInt(agentIdStr);
  const client = createPublicClient({
    chain: chain.viemChain,
    transport: http(rpcUrl),
  });

  let owner = "";
  let tokenUri = "";
  let error = null;

  try {
    [owner, tokenUri] = await Promise.all([
      client.readContract({
        address: ERC8004_IDENTITY,
        abi: erc8004Abi,
        functionName: "ownerOf",
        args: [agentId],
      }),
      client.readContract({
        address: ERC8004_IDENTITY,
        abi: erc8004Abi,
        functionName: "tokenURI",
        args: [agentId],
      }),
    ]);
  } catch (e) {
    error = e.message.slice(0, 60);
  }

  results.push({
    chain,
    agentId: agentIdStr,
    owner,
    tokenUri,
    error,
  });

  console.log();
  console.log(chalk.yellow(sTop(`${chain.name} (${chain.chainId})`)));

  if (error) {
    console.log(sLine(chalk.red(`ERROR: ${error}`)));
    console.log(sBot());
    continue;
  }

  console.log(sLine(kv("Agent ID", chalk.cyan.bold(agentIdStr))));
  console.log(sLine(kv("Owner", chalk.white(owner))));
  console.log(sLine(kv("Token URI", chalk.dim(shortUri(tokenUri)))));
  console.log(sSep());
  console.log(sLine(chalk.red.dim("WHAT'S MISSING (no TAP):")));
  console.log(sLine(kv("Cross-chain ID", chalk.red("NONE"))));
  console.log(sLine(kv("Canonical UEA", chalk.red("NONE"))));
  console.log(sLine(kv("Bindings", chalk.red("NONE"))));
  console.log(sLine(kv("Reputation", chalk.red("NONE"))));
  console.log(sLine(kv("Slash History", chalk.red("NONE"))));
  console.log(sBot());
}

// ── Fragmentation Summary ───────────────────────────────

const valid = results.filter((r) => !r.error);

if (valid.length >= 2) {
  console.log();
  console.log(chalk.red(sTop("FRAGMENTATION PROOF")));
  console.log(sLine(""));
  console.log(
    sLine(
      `${chalk.dim("Owner:")} ${chalk.white(valid[0].owner)}`
    )
  );
  console.log(sLine(""));

  const allSame =
    new Set(valid.map((r) => r.owner.toLowerCase())).size === 1;
  console.log(
    sLine(
      `${chalk.dim("Same wallet?")} ${allSame ? chalk.green("✓ YES") : chalk.red("✗ NO")}`
    )
  );

  const allDiffIds =
    new Set(valid.map((r) => r.agentId)).size === valid.length;
  console.log(
    sLine(
      `${chalk.dim("Same agent ID?")} ${allDiffIds ? chalk.red("✗ NO — all different!") : chalk.green("✓ YES")}`
    )
  );
  console.log(sLine(""));

  for (const r of valid) {
    console.log(
      sLine(
        `  ${chalk.white(r.chain.name.padEnd(20))}Agent ID = ${chalk.cyan.bold(r.agentId)}`
      )
    );
  }

  console.log(sLine(""));
  console.log(
    sLine(chalk.red.bold("⚠ No on-chain way to link these identities"))
  );
  console.log(
    sLine(chalk.red.bold("  This is the problem TAP solves."))
  );
  console.log(sBot());
}

console.log();
