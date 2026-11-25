"use strict";

// bh chat / bh jobs / bh status --service: talk to the installed tenant's
// llm-bawt API on its loopback port. The API key is read from the app
// container (the operator already controls Docker) and held only in memory.
const { execFile, spawnSync } = require("node:child_process");
const { promisify } = require("node:util");
const readline = require("node:readline");
const run = promisify(execFile);

const ADMISSION = ": llm-bawt-admission ";
const EXTENSION = ": llm-bawt-event ";
const QUEUED = new Set(["chat.completion.queued", "chat.completion.in_flight"]);
const TERMINAL = new Set(["DELIVERED", "FAILED", "CANCELLED", "UNRESOLVED"]);
const tty = process.stdout.isTTY && !process.env.NO_COLOR;
const paint = (code, text) => (tty ? `\x1b[${code}m${text}\x1b[0m` : text);
const dim = (t) => paint("2", t);
const warn = (t) => console.error(paint("33", t));
class UsageError extends Error {}

async function connect(container) {
  const docker = async (...args) => (await run("docker", args, { timeout: 10000, maxBuffer: 1024 * 1024 })).stdout.trim();
  let key;
  try {
    key = await docker("exec", container, "cat", "/run/llm-bawt-api-keys/app/api-key");
  } catch {
    throw new Error("could not read the API key from the app container; is BawtHub running? Try bh status.");
  }
  const binding = (await docker("port", container, "8642/tcp").catch(() => "")).split("\n")[0];
  const port = /:(\d+)$/.exec(binding)?.[1];
  if (!port) throw new Error("the app API port is not published on this host; check bh status.");
  const base = `http://127.0.0.1:${port}`;
  const request = async (method, path, { body, params, headers, timeout = 30000 } = {}) => {
    const url = new URL(path, base);
    for (const [k, v] of Object.entries(params || {})) if (v !== undefined && v !== null) url.searchParams.set(k, String(v));
    const res = await fetch(url, {
      method,
      headers: { "X-LLM-Bawt-Key": key, "Content-Type": "application/json", ...headers },
      body: body === undefined ? undefined : JSON.stringify(body),
      signal: timeout ? AbortSignal.timeout(timeout) : undefined,
    });
    if (!res.ok) {
      const text = (await res.text().catch(() => "")).slice(0, 400);
      let detail = text;
      try { detail = JSON.parse(text).detail ?? text; } catch {}
      throw new Error(`${method} ${url.pathname}: HTTP ${res.status}${detail ? ` ${typeof detail === "string" ? detail : JSON.stringify(detail)}` : ""}`);
    }
    return res;
  };
  const json = async (method, path, opts) => (await request(method, path, opts)).json();
  return { request, json };
}

function parseChat(argv) {
  const o = { words: [], stream: true, plain: false, history: null, timeout: 600 };
  const value = (i, flag) => {
    if (i >= argv.length || argv[i].startsWith("-")) throw new UsageError(`${flag} needs a value`);
    return argv[i];
  };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--") { o.words.push(...argv.slice(i + 1)); break; }
    if (a === "-b" || a === "--bot") o.bot = value(++i, a);
    else if (a === "-m" || a === "--model") o.model = value(++i, a);
    else if (a === "-u" || a === "--user") o.user = value(++i, a);
    else if (a === "-c" || a === "--command") o.command = value(++i, a);
    else if (a === "--plain") o.plain = true;
    else if (a === "--no-stream") o.stream = false;
    else if (a === "--timeout") {
      o.timeout = Number(value(++i, a));
      if (!(o.timeout > 0)) throw new UsageError("--timeout needs a number of seconds");
    } else if (a === "--history") {
      o.history = 10;
      if (/^\d+$/.test(argv[i + 1] || "")) o.history = Number(argv[++i]);
    } else if (a.startsWith("-") && a !== "-") throw new UsageError(`unknown chat option: ${a}`);
    else o.words.push(a);
  }
  return o;
}

const CHAT_USAGE = [
  "Usage: bh chat [-b BOT] [-m MODEL] [-u USER] [--plain] [--no-stream] [-c CMD] [MESSAGE...]",
  "       bh chat [-b BOT] [-u USER] --history [N]",
  "",
  "  With a message, asks once and prints the reply. Without one, reads a piped",
  "  message from stdin, or starts an interactive chat in a terminal (Ctrl-D or",
  "  /exit to leave). Each message continues the bot's ongoing conversation, the",
  "  same thread you see in the web app.",
  "  -c CMD        run CMD and include its output with the message",
  "  --history [N] print the last N messages (default 10)",
  "  --timeout S   how long to wait for a queued reply (default 600)",
].join("\n");

async function waitForReply(api, receipt, o) {
  const id = receipt.delivery_id;
  if (!id || !receipt.user_message_id) throw new Error("the queued receipt has no delivery id");
  const deadline = Date.now() + o.timeout * 1000;
  for (;;) {
    const reply = await api.json("GET", `/v1/inter-bot-deliveries/${encodeURIComponent(id)}/reply`, {
      params: { bot_id: receipt.bot_id || o.bot, user_id: receipt.user_id || o.user, user_message_id: receipt.user_message_id },
    });
    if (reply.delivery_id !== id) throw new Error("the reply changed delivery identity");
    if (TERMINAL.has(reply.status)) return reply;
    if (Date.now() >= deadline) return null;
    await new Promise((r) => setTimeout(r, 1000));
  }
}

async function showTools(api, reply, receipt, o) {
  if (o.plain || !reply.turn_id) return;
  try {
    const { events = [] } = await api.json("GET", "/v1/tool-calls", {
      params: { message_id: reply.user_message_id || receipt.user_message_id, bot_id: receipt.bot_id || o.bot, user_id: receipt.user_id || o.user },
    });
    for (const event of events) {
      if (event.turn_id !== reply.turn_id) continue;
      for (const call of event.tool_calls || []) console.log(dim(`⚙ ${call.name || call.tool || "tool"}`));
    }
  } catch {}
}

async function resolveQueued(api, receipt, o) {
  const ref = receipt.delivery_id || receipt.turn_id || "unknown";
  if (receipt.object === "chat.completion.in_flight") {
    warn(`Turn ${ref} was already accepted; check its reply in the web app.`);
    return false;
  }
  if (!o.plain) console.error(dim("Queued; waiting for the reply…"));
  const reply = await waitForReply(api, receipt, o);
  if (!reply) { warn(`Request ${ref} was accepted; its reply is still pending. It will appear in the web app.`); return false; }
  if (reply.status !== "DELIVERED" || typeof reply.response_text !== "string") {
    warn(`Request ${ref} ended with status ${reply.status}.`);
    return false;
  }
  await showTools(api, reply, receipt, o);
  process.stdout.write(reply.response_text.replace(/\n*$/, "\n"));
  return true;
}

async function ask(api, message, o) {
  const body = { messages: [{ role: "user", content: message }], stream: o.stream };
  if (o.bot) body.bot_id = o.bot;
  if (o.model) body.model = o.model;
  if (o.user) body.user = o.user;
  if (!o.stream) {
    const data = await api.json("POST", "/v1/chat/completions", { body, timeout: o.timeout * 1000 });
    if (QUEUED.has(data?.object)) return resolveQueued(api, data, o);
    const text = data?.choices?.[0]?.message?.content;
    if (typeof text !== "string") { warn("The service returned no reply text."); return false; }
    process.stdout.write(text.replace(/\n*$/, "\n"));
    return true;
  }
  const res = await api.request("POST", "/v1/chat/completions", {
    body,
    timeout: 0,
    headers: { "X-LLM-Bawt-Extension-Events": "comment", "X-LLM-Bawt-Admission-Events": "comment" },
  });
  const decoder = new TextDecoder();
  let buffer = "", wrote = false, admitted = null, endsWithNewline = true, done = false;
  const out = (text) => { process.stdout.write(text); wrote = true; endsWithNewline = text.endsWith("\n"); };
  const handle = async (line) => {
    if (line.startsWith(ADMISSION.trim())) {
      try {
        const receipt = JSON.parse(line.slice(ADMISSION.trim().length));
        if (QUEUED.has(receipt?.object)) admitted = receipt;
      } catch {}
      return;
    }
    if (line.startsWith(EXTENSION)) line = "data: " + line.slice(EXTENSION.length);
    if (!line.startsWith("data: ")) return;
    const data = line.slice(6);
    if (data === "[DONE]") { done = true; return; }
    let chunk;
    try { chunk = JSON.parse(data); } catch { return; }
    if (!chunk || typeof chunk !== "object") return;
    if (QUEUED.has(chunk.object)) { admitted = chunk; return; }
    if (chunk.error && typeof chunk.error === "object") throw new Error(chunk.error.message || "the reply stream failed");
    if (chunk.object === "service.warning") { for (const w of chunk.warnings || []) warn(String(w)); return; }
    const delta = chunk.choices?.[0]?.delta || {};
    for (const call of delta.tool_calls || []) {
      if (!o.plain) { if (!endsWithNewline) out("\n"); out(dim(`⚙ ${call.function?.name || "tool"}`) + "\n"); }
    }
    if (delta.content) out(delta.content);
  };
  for await (const part of res.body) {
    buffer += decoder.decode(part, { stream: true });
    let nl;
    while ((nl = buffer.indexOf("\n")) >= 0) {
      const line = buffer.slice(0, nl).trim();
      buffer = buffer.slice(nl + 1);
      if (line) await handle(line);
      if (done) break;
    }
    if (done) break;
  }
  if (wrote && !endsWithNewline) process.stdout.write("\n");
  if (wrote) return true;
  // An admitted turn that streamed nothing: wait for its recorded reply
  // instead of resubmitting the message.
  if (admitted) return resolveQueued(api, admitted, o);
  warn("The service returned an empty reply; check bh logs app.");
  return false;
}

async function history(api, o) {
  const data = await api.json("GET", "/v1/history", { params: { bot_id: o.bot, user_id: o.user, limit: o.history } });
  for (const m of data.messages || []) {
    const when = m.timestamp ? new Date(m.timestamp * 1000).toLocaleString() : "";
    const who = m.role === "user" ? (m.author?.display_name || m.author?.entity_id || "you") : (m.author?.display_name || m.author?.entity_id || o.bot || "bot");
    console.log(o.plain ? `${who}: ${m.content}` : `${paint("1", who)} ${dim(when)}\n${m.content}\n`);
  }
}

function withCommand(message, o) {
  if (!o.command) return message;
  const r = spawnSync("sh", ["-c", o.command], { encoding: "utf8", maxBuffer: 4 * 1024 * 1024 });
  const output = `${r.stdout || ""}${r.stderr || ""}`.trim();
  return `${message ? message + "\n\n" : ""}Output of \`${o.command}\`:\n\`\`\`\n${output}\n\`\`\``;
}

async function readStdin() {
  let s = "";
  for await (const c of process.stdin) s += c;
  return s.trim();
}

// Without -u, use the installation's only person; several need a choice.
async function resolveUser(api, o) {
  if (o.user) return;
  const { profiles = [] } = await api.json("GET", "/v1/profiles", { params: { entity_type: "user" } });
  const people = profiles.filter((p) => p.entity_type === "user" && !p.is_service).map((p) => p.entity_id);
  if (people.length === 1) o.user = people[0];
  else if (people.length > 1) throw new UsageError(`choose who you are with -u (${people.join(", ")})`);
}

async function chat(api, argv) {
  const o = parseChat(argv);
  await resolveUser(api, o);
  if (o.history !== null) { await history(api, o); return 0; }
  let message = o.words.join(" ").trim();
  if (!message && !process.stdin.isTTY) message = await readStdin();
  if (message || o.command) return (await ask(api, withCommand(message, o), o)) ? 0 : 1;
  const rl = readline.createInterface({ input: process.stdin, output: process.stdout, prompt: paint("36", "› ") });
  console.log(dim(`Chatting with ${o.bot || "the default bot"}. Ctrl-D or /exit to leave.`));
  rl.prompt();
  for await (const line of rl) {
    const text = line.trim();
    if (text === "/exit" || text === "/quit") break;
    if (text) {
      rl.pause();
      try { await ask(api, text, o); } catch (err) { warn(`bh: ${err.message}`); }
      rl.resume();
    }
    rl.prompt();
  }
  rl.close();
  return 0;
}

const when = (v) => (v ? new Date(v).toLocaleString() : "—");

async function jobs(api, argv) {
  const [sub, arg] = argv;
  if (sub === "run") {
    if (!arg || argv.length !== 2) throw new UsageError("usage: bh jobs run JOB_TYPE");
    const r = await api.json("POST", `/v1/jobs/${encodeURIComponent(arg)}/trigger`);
    console.log(r.message || (r.success ? `Triggered ${arg}; the scheduler runs it on its next check.` : JSON.stringify(r)));
    return r.success === false ? 1 : 0;
  }
  if (sub !== undefined && sub !== "runs") throw new UsageError("usage: bh jobs [runs [N] | run JOB_TYPE]");
  if (sub === undefined) {
    const { jobs: list = [] } = await api.json("GET", "/v1/jobs");
    console.log(paint("1", "Scheduled jobs"));
    for (const j of list) {
      console.log(`  ${(j.enabled ? "✓" : "✗")} ${String(j.job_type).padEnd(24)} ${String(j.bot_id ?? "").padEnd(12)} last ${when(j.last_run_at)} · next ${when(j.next_run_at)}${j.last_status ? ` · ${j.last_status}` : ""}`);
    }
    if (!list.length) console.log("  none");
  }
  const limit = sub === "runs" && /^\d+$/.test(arg || "") ? Number(arg) : 10;
  const { runs = [] } = await api.json("GET", "/v1/jobs/runs", { params: { limit } });
  console.log(paint("1", "Recent runs"));
  for (const r of runs) {
    const ms = r.duration_ms != null ? `${(r.duration_ms / 1000).toFixed(1)} s` : "";
    console.log(`  ${when(r.started_at)}  ${String(r.job_type ?? "").padEnd(24)} ${String(r.bot_id ?? "").padEnd(12)} ${r.status ?? ""} ${ms}${r.error_message ? ` · ${String(r.error_message).slice(0, 80)}` : ""}`);
  }
  if (!runs.length) console.log("  none");
  return 0;
}

async function serviceStatus(api) {
  const s = await api.json("GET", "/v1/status");
  const scalar = (v) => v === null || ["string", "number", "boolean"].includes(typeof v);
  for (const [section, value] of Object.entries(s)) {
    if (!value || typeof value !== "object") continue;
    console.log(paint("1", section[0].toUpperCase() + section.slice(1)));
    for (const [k, v] of Object.entries(value)) if (scalar(v)) console.log(`  ${k.replace(/_/g, " ").padEnd(26)} ${v ?? "—"}`);
  }
  return 0;
}

async function main() {
  const [command, container, ...argv] = process.argv.slice(2);
  if (command === "chat" && (argv.includes("-h") || argv.includes("--help"))) { console.log(CHAT_USAGE); return 0; }
  if (!container) throw new Error("BawtHub's app service is not running; start it with bh start.");
  const api = await connect(container);
  if (command === "chat") return chat(api, argv);
  if (command === "jobs") return jobs(api, argv);
  if (command === "service-status") return serviceStatus(api);
  throw new UsageError(`unknown command: ${command}`);
}

main().then((code) => { process.exitCode = code; }).catch((err) => {
  console.error(`bh: ${err.message}`);
  if (err instanceof UsageError && process.argv[2] === "chat") console.error(CHAT_USAGE);
  process.exitCode = err instanceof UsageError ? 2 : 1;
});
