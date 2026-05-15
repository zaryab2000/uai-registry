#!/usr/bin/env node
import chalk from "chalk";
import { createPublicClient, http, getAddress } from "viem";

// ── Config ──────────────────────────────────────────────

const AGENT_REGISTRY =
  process.env.AGENT_REGISTRY ||
  "0x13499d36729467bd5C6B44725a10a0113cE47178";
const REPUTATION_REGISTRY =
  process.env.REPUTATION_REGISTRY ||
  "0x90B484063622289742516c5dDFdDf1C1A3C2c50C";
const PC_RPC = process.env.PC_RPC;
const AGENT_ID = process.env.AGENT_ID || process.env.CANONICAL_AGENT_ID;

if (!PC_RPC) {
  console.error(chalk.red("ERROR: PC_RPC not set"));
  process.exit(1);
}
if (!AGENT_ID) {
  console.error(chalk.red("ERROR: AGENT_ID or CANONICAL_AGENT_ID not set"));
  process.exit(1);
}

const CHAIN_NAMES = {
  "42101": "Push Chain",
  "11155111": "Ethereum Sepolia",
  "84532": "Base Sepolia",
  "97": "BSC Testnet",
  "1": "Ethereum",
  "8453": "Base",
  "56": "BSC",
};

const chainName = (id) => CHAIN_NAMES[id] || `Chain ${id}`;

const pushChain = {
  id: 42101,
  name: "Push Chain Donut Testnet",
  nativeCurrency: { name: "ETH", symbol: "ETH", decimals: 18 },
  rpcUrls: { default: { http: [PC_RPC] } },
};

const client = createPublicClient({
  chain: pushChain,
  transport: http(PC_RPC),
});

// ── ABIs ────────────────────────────────────────────────

const TAPRegistryAbi = [
  {
    name: "getAgentRecord",
    type: "function",
    stateMutability: "view",
    inputs: [{ name: "agentId", type: "uint256" }],
    outputs: [
      {
        name: "",
        type: "tuple",
        components: [
          { name: "registered", type: "bool" },
          { name: "agentURI", type: "string" },
          { name: "agentCardHash", type: "bytes32" },
          { name: "registeredAt", type: "uint256" },
          { name: "originChainNamespace", type: "string" },
          { name: "originChainId", type: "string" },
          { name: "ownerKey", type: "address" },
          { name: "nativeToPush", type: "bool" },
        ],
      },
    ],
  },
  {
    name: "canonicalOwner",
    type: "function",
    stateMutability: "view",
    inputs: [{ name: "agentId", type: "uint256" }],
    outputs: [{ name: "", type: "address" }],
  },
  {
    name: "getBindings",
    type: "function",
    stateMutability: "view",
    inputs: [{ name: "agentId", type: "uint256" }],
    outputs: [
      {
        name: "",
        type: "tuple[]",
        components: [
          { name: "chainNamespace", type: "string" },
          { name: "chainId", type: "string" },
          { name: "registryAddress", type: "address" },
          { name: "boundAgentId", type: "uint256" },
          { name: "proofType", type: "uint8" },
          { name: "verified", type: "bool" },
          { name: "linkedAt", type: "uint256" },
        ],
      },
    ],
  },
  {
    name: "canonicalOwnerFromBinding",
    type: "function",
    stateMutability: "view",
    inputs: [
      { name: "chainNamespace", type: "string" },
      { name: "chainId", type: "string" },
      { name: "registryAddress", type: "address" },
      { name: "boundAgentId", type: "uint256" },
    ],
    outputs: [
      { name: "canonical", type: "address" },
      { name: "verified", type: "bool" },
    ],
  },
];

const TAPReputationRegistryAbi = [
  {
    name: "getReputationScore",
    type: "function",
    stateMutability: "view",
    inputs: [{ name: "agentId", type: "uint256" }],
    outputs: [{ name: "", type: "uint256" }],
  },
  {
    name: "getAggregatedReputation",
    type: "function",
    stateMutability: "view",
    inputs: [{ name: "agentId", type: "uint256" }],
    outputs: [
      {
        name: "",
        type: "tuple",
        components: [
          { name: "totalFeedbackCount", type: "uint64" },
          { name: "weightedAvgValue", type: "int128" },
          { name: "valueDecimals", type: "uint8" },
          { name: "totalPositive", type: "uint64" },
          { name: "totalNegative", type: "uint64" },
          { name: "chainCount", type: "uint16" },
          { name: "lastAggregated", type: "uint64" },
          { name: "reputationScore", type: "uint256" },
        ],
      },
    ],
  },
  {
    name: "getAllChainReputations",
    type: "function",
    stateMutability: "view",
    inputs: [{ name: "agentId", type: "uint256" }],
    outputs: [
      {
        name: "",
        type: "tuple[]",
        components: [
          { name: "chainNamespace", type: "string" },
          { name: "chainId", type: "string" },
          { name: "registryAddress", type: "address" },
          { name: "boundAgentId", type: "uint256" },
          { name: "feedbackCount", type: "uint64" },
          { name: "summaryValue", type: "int128" },
          { name: "valueDecimals", type: "uint8" },
          { name: "positiveCount", type: "uint64" },
          { name: "negativeCount", type: "uint64" },
          { name: "sourceBlockNumber", type: "uint256" },
          { name: "lastUpdated", type: "uint64" },
          { name: "reporter", type: "address" },
        ],
      },
    ],
  },
  {
    name: "getSlashRecords",
    type: "function",
    stateMutability: "view",
    inputs: [{ name: "agentId", type: "uint256" }],
    outputs: [
      {
        name: "",
        type: "tuple[]",
        components: [
          { name: "chainNamespace", type: "string" },
          { name: "chainId", type: "string" },
          { name: "reason", type: "string" },
          { name: "evidenceHash", type: "bytes32" },
          { name: "slashedAt", type: "uint64" },
          { name: "reporter", type: "address" },
          { name: "severityBps", type: "uint256" },
        ],
      },
    ],
  },
  {
    name: "isFresh",
    type: "function",
    stateMutability: "view",
    inputs: [
      { name: "agentId", type: "uint256" },
      { name: "maxAge", type: "uint256" },
    ],
    outputs: [{ name: "", type: "bool" }],
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

const shortAddr = (a) =>
  a.slice(0, 6) + "..." + a.slice(-4);

const shortId = (id) => {
  const s = id.toString();
  return s.length > 20 ? s.slice(0, 10) + "..." + s.slice(-6) : s;
};

const shortUri = (uri) =>
  uri.length > 40
    ? uri.slice(0, 20) + "..." + uri.slice(-8)
    : uri;

const kv = (k, v) => {
  const key = chalk.dim(k.padEnd(18));
  return `${key}${v}`;
};

const progressBar = (pct, width = 20) => {
  const filled = Math.round((pct / 100) * width);
  const empty = width - filled;
  return chalk.green("█".repeat(filled)) + chalk.dim("░".repeat(empty));
};

const CHAIN_COLORS = [
  chalk.hex("#22d3ee"),
  chalk.hex("#a78bfa"),
  chalk.hex("#f59e0b"),
  chalk.hex("#34d399"),
];

const miniBar = (val, max, width = 16, colorIdx = 0) => {
  const filled = Math.round((val / max) * width);
  const empty = width - filled;
  const color = CHAIN_COLORS[colorIdx % CHAIN_COLORS.length];
  return color("█".repeat(filled)) + chalk.dim("░".repeat(empty));
};

// ── Fetch all data ──────────────────────────────────────

const agentId = BigInt(AGENT_ID);

const [record, uea, bindings, score, agg, chains, slashes, fresh1h] =
  await Promise.all([
    client.readContract({
      address: AGENT_REGISTRY,
      abi: TAPRegistryAbi,
      functionName: "getAgentRecord",
      args: [agentId],
    }),
    client.readContract({
      address: AGENT_REGISTRY,
      abi: TAPRegistryAbi,
      functionName: "canonicalOwner",
      args: [agentId],
    }),
    client.readContract({
      address: AGENT_REGISTRY,
      abi: TAPRegistryAbi,
      functionName: "getBindings",
      args: [agentId],
    }),
    client.readContract({
      address: REPUTATION_REGISTRY,
      abi: TAPReputationRegistryAbi,
      functionName: "getReputationScore",
      args: [agentId],
    }),
    client.readContract({
      address: REPUTATION_REGISTRY,
      abi: TAPReputationRegistryAbi,
      functionName: "getAggregatedReputation",
      args: [agentId],
    }),
    client.readContract({
      address: REPUTATION_REGISTRY,
      abi: TAPReputationRegistryAbi,
      functionName: "getAllChainReputations",
      args: [agentId],
    }),
    client.readContract({
      address: REPUTATION_REGISTRY,
      abi: TAPReputationRegistryAbi,
      functionName: "getSlashRecords",
      args: [agentId],
    }),
    client.readContract({
      address: REPUTATION_REGISTRY,
      abi: TAPReputationRegistryAbi,
      functionName: "isFresh",
      args: [agentId, 3600n],
    }),
  ]);

// ── Reverse lookups ─────────────────────────────────────

const reverseLookups = await Promise.all(
  bindings.map((b) =>
    client.readContract({
      address: AGENT_REGISTRY,
      abi: TAPRegistryAbi,
      functionName: "canonicalOwnerFromBinding",
      args: [b.chainNamespace, b.chainId, b.registryAddress, b.boundAgentId],
    })
  )
);

// ── Render ──────────────────────────────────────────────

const scoreBps = Number(score);
const scorePct = (scoreBps / 100).toFixed(2);
const agentName = process.env.AGENT_NAME || "TAP Agent";
const ueaStr = getAddress(uea);

console.log();
console.log(chalk.bold.yellow(TOP));
console.log(
  chalk.bold.yellow(
    boxLine(chalk.bold.white("TAP AGENT FULL PROFILE"))
  )
);
console.log(chalk.bold.yellow(MID));
console.log(
  chalk.bold.yellow(
    boxLine(`🤖 ${chalk.bold.white(agentName)}`)
  )
);
console.log(
  chalk.bold.yellow(
    boxLine(`UEA: ${chalk.cyan(ueaStr)}`)
  )
);
console.log(chalk.bold.yellow(BOT));

// ── 1. Identity ─────────────────────────────────────────

console.log();
console.log(chalk.yellow(sTop("IDENTITY")));
console.log(sLine(kv("Agent ID", chalk.white(shortId(AGENT_ID)))));
console.log(
  sLine(
    kv(
      "Registered",
      record.registered ? chalk.green("✓ true") : chalk.red("✗ false")
    )
  )
);
console.log(
  sLine(
    kv(
      "Native to Push",
      record.nativeToPush ? chalk.green("✓ true") : chalk.dim("false")
    )
  )
);
const origin = `${record.originChainNamespace}:${record.originChainId}`;
const originLabel = chainName(record.originChainId);
console.log(
  sLine(kv("Origin", chalk.white(`${origin} (${originLabel})`)))
);
console.log(sLine(kv("Agent URI", chalk.cyan(shortUri(record.agentURI)))));
console.log(
  sLine(kv("Card Hash", chalk.dim(record.agentCardHash.slice(0, 18) + "...")))
);
const regDate = new Date(Number(record.registeredAt) * 1000);
console.log(
  sLine(kv("Registered At", chalk.dim(regDate.toISOString())))
);
console.log(sBot());

// ── 2. Cross-Chain Bindings ─────────────────────────────

console.log();
console.log(
  chalk.yellow(sTop(`CROSS-CHAIN BINDINGS (${bindings.length})`))
);
console.log(
  sLine(
    `${chalk.dim("Chain".padEnd(22))}${chalk.dim("Agent ID".padEnd(12))}${chalk.dim("Status")}`
  )
);
console.log(sSep());

for (const b of bindings) {
  const name = chainName(b.chainId);
  const caip = `${b.chainNamespace}:${b.chainId}`;
  const label = `${name}`;
  const idStr = b.boundAgentId.toString();
  const verified = b.verified
    ? chalk.green("✓ verified")
    : chalk.red("✗ unverified");
  console.log(
    sLine(`${chalk.white(label.padEnd(22))}${chalk.cyan(idStr.padEnd(12))}${verified}`)
  );
}
console.log(sBot());

// ── 3. Reverse Lookups ──────────────────────────────────

console.log();
console.log(chalk.yellow(sTop("REVERSE LOOKUPS")));
for (let i = 0; i < bindings.length; i++) {
  const b = bindings[i];
  const [canonical, verified] = reverseLookups[i];
  const name = chainName(b.chainId);
  const check = verified ? chalk.green("✓") : chalk.red("✗");
  const canonicalStr = chalk.cyan(shortAddr(getAddress(canonical)));
  console.log(
    sLine(`${check} ${chalk.white(name.padEnd(20))}⟶  ${canonicalStr}`)
  );
}
console.log(
  sLine(
    chalk.dim("All chains resolve to the same canonical UEA")
  )
);
console.log(sBot());

// ── 4. Reputation ───────────────────────────────────────

const scorePctNum = scoreBps / 100;
const totalFeedback = Number(agg.totalFeedbackCount);
const totalPos = Number(agg.totalPositive);
const totalNeg = Number(agg.totalNegative);

let scoreColor = chalk.green;
if (scorePctNum < 40) scoreColor = chalk.red;
else if (scorePctNum < 60) scoreColor = chalk.yellow;

console.log();
console.log(chalk.yellow(sTop("REPUTATION")));
console.log(sLine(""));
console.log(
  sLine(
    `Score: ${progressBar(scorePctNum, 24)}  ${scoreColor.bold(`${scorePct}%`)}`
  )
);
console.log(
  sLine(
    `       ${chalk.dim(`${scoreBps} / 10000 bps`)}`
  )
);
console.log(sLine(""));
console.log(sLine(chalk.dim("Per-Chain Breakdown:")));

for (let ci = 0; ci < chains.length; ci++) {
  const c = chains[ci];
  const name = chainName(c.chainId).padEnd(18);
  const val = Number(c.summaryValue / BigInt(10 ** 18));
  const fb = Number(c.feedbackCount);
  const bar = miniBar(val, 100, 14, ci);
  console.log(
    sLine(
      `${chalk.white(name)}${bar} ${chalk.bold.white(String(val).padStart(3))}/100  ${chalk.dim(`${fb}fb`)}`
    )
  );
}

console.log(sLine(""));
console.log(
  sLine(
    `${chalk.dim("Totals:")} ${chalk.white(totalFeedback)} feedback ${chalk.dim("·")} ${chalk.green(totalPos + "+")} ${chalk.dim("·")} ${chalk.red(totalNeg + "−")}`
  )
);
console.log(
  sLine(
    `${chalk.dim("Chains:")} ${chalk.white(agg.chainCount.toString())} ${chalk.dim("·")} ${chalk.dim("Fresh (<1h):")} ${fresh1h ? chalk.green("✓") : chalk.red("✗")}`
  )
);
console.log(sBot());

// ── 5. Slash History ────────────────────────────────────

console.log();
if (slashes.length === 0) {
  console.log(chalk.yellow(sTop("SLASH HISTORY")));
  console.log(sLine(chalk.green("No slashes recorded ✓")));
  console.log(sBot());
} else {
  let totalPenalty = 0n;
  console.log(
    chalk.yellow(sTop(`SLASH HISTORY (${slashes.length})`))
  );
  for (const s of slashes) {
    const name = chainName(s.chainId);
    const sev = Number(s.severityBps);
    totalPenalty += s.severityBps;
    const date = new Date(Number(s.slashedAt) * 1000);
    console.log(
      sLine(
        `${chalk.red("⚠")} ${chalk.white(name.padEnd(20))}${chalk.red.bold(`-${sev} bps`)}`
      )
    );
    const reasonTrunc =
      s.reason.length > 44 ? s.reason.slice(0, 44) + "…" : s.reason;
    console.log(
      sLine(`  ${chalk.dim(`"${reasonTrunc}"`)}`)
    );
    console.log(
      sLine(`  ${chalk.dim(date.toISOString())}`)
    );
  }
  console.log(sSep());
  console.log(
    sLine(
      `${chalk.dim("Total penalty:")} ${chalk.red.bold(`-${totalPenalty} bps`)}`
    )
  );
  console.log(sBot());
}

console.log();
