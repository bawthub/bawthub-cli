"use strict";

const { execFile } = require("node:child_process");
const { promisify } = require("node:util");
const run = promisify(execFile);
const docker = async (...args) => (await run("docker", args, { timeout: 7500, maxBuffer: 1024 * 1024 })).stdout.trim();

const groups = {
  Core: { frontend: "Web UI", app: "BawtHub API", postgres: "Database", redis: "Redis", embed: "Embeddings" },
  Agents: { "agent-bridge": "Agent bridge", "ops-reconciler": "Background operations" },
  Voice: { "voice-backend": "Voice API", "cpu-stt": "Speech recognition (CPU)", "pocket-tts": "Text-to-speech (Pocket)" },
  Tools: { "playwright-mcp": "Browser automation", crawl4ai: "Web crawler" },
};
const groupFor = (service) => /^house-h\d+$/.test(service) ? "Agents" :
  Object.keys(groups).find((group) => Object.hasOwn(groups[group], service)) ?? "Other services";
const labelFor = (group, service) => groups[group]?.[service] ??
  (/^house-h\d+$/.test(service) ? `Agent workspace ${service.slice(6)}` : service);
const format = '[{{json .Id}},{{json (index .Config.Labels "com.docker.compose.service")}},{{json .State.Status}},{{if .State.Health}}{{json .State.Health.Status}}{{else}}null{{end}},{{json .State.ExitCode}},{{json (index .HostConfig.PortBindings "3000/tcp")}}]';

const probes = {
  frontend: ["curl", "--noproxy", "*", "-fsS", "--max-time", "5", "http://localhost:3000/api/health"],
  app: ["curl", "--noproxy", "*", "-fsS", "--max-time", "5", "http://localhost:8642/health"],
  "voice-backend": ["python", "-c", "import urllib.request as u; print(u.build_opener(u.ProxyHandler({})).open('http://127.0.0.1/v1/health', timeout=5).read(65536).decode())"],
};
const line = (name, state, detail = "") => `  ${name.padEnd(27)} ${state}${detail ? ` · ${detail}` : ""}`;

async function check([id, service, state, health, exit, ports], hasCpuStt) {
  const r = { service, ports, running: state === "running", status: "Running", detail: "No health check", children: [], attention: false, starting: false };
  const mark = (status, detail = "", attention = false) => Object.assign(r, { status, detail, attention });
  if (state === "created") return mark("Not started");
  if (state === "exited") return exit === 0 ? mark("Stopped") : mark("Exited", `Code ${exit}`, true);
  if (state === "paused") return mark("Paused", "", true);
  if (state === "restarting") return mark("Restarting", "", true);
  if (!r.running) return mark("Unavailable", "", true);
  if (health === "healthy") mark("Healthy", "Docker health check passed");
  if (health === "starting") { mark("Starting", "Waiting for health check"); r.starting = true; }
  if (health === "unhealthy") mark("Unhealthy", "Docker health check failed", true);
  if (!Object.hasOwn(probes, service)) return r;
  let data;
  try {
    data = JSON.parse(await docker("exec", id, ...probes[service]));
    if (!data || typeof data !== "object" || Array.isArray(data) ||
        (service === "frontend" && data.status !== "healthy") ||
        (service === "app" && data.status !== "ok")) throw new Error();
  } catch {
    if (r.starting) return mark("Starting", "Health endpoint not ready yet");
    return mark("Check failed", "Health endpoint did not return a usable response", true);
  }
  if (service !== "voice-backend") {
    if (health === "unhealthy") return mark("Unhealthy", "Endpoint responded; Docker health check is failing", true);
    r.starting = false;
    return mark("Healthy", "Health endpoint passed");
  }

  if (![data.tts_up, data.stt_up, data.llm_up].every((value) => typeof value === "boolean")) {
    return mark("Check failed", "Unexpected voice health response", true);
  }
  const tts = Array.isArray(data.checks) ? data.checks.find((item) => item?.name === "tts") : null;
  const idle = tts?.asleep === true && tts.status === "ok";
  const ttsReady = idle || (data.tts_up && tts?.status !== "degraded" && tts?.status !== "down");
  r.children.push(line("  Speech recognition", data.stt_up ? "Healthy" : hasCpuStt ? "Unavailable" : "Not available"));
  r.children.push(line("  Speech playback", idle ? "Idle" : ttsReady ? "Healthy" : "Unavailable", idle ? "Wakes on use" : ""));
  r.children.push(line("  API connection", data.llm_up ? "Healthy" : "Unavailable"));
  r.starting = false;
  if (!ttsReady || !data.llm_up || (hasCpuStt && !data.stt_up)) return mark("Degraded", "Health endpoint reports a dependency issue", true);
  if (health === "unhealthy") return mark("Unhealthy", "Docker health check failed", true);
  return mark("Healthy", "Health endpoint passed");
}

async function main([project, context, ...ids]) {
  console.log("BawtHub status");
  if (!ids.length) {
    console.log("No services installed. Run bh install.");
  } else {
    const rows = (await docker("inspect", "--type", "container", "--format", format, ...ids)).split("\n").map((row) => JSON.parse(row));
    const seen = new Set(rows.map(([id]) => id));
    if (seen.size !== rows.length || rows.length !== ids.length || ids.some((id) => !seen.has(id)) ||
        rows.some(([, service]) => !/^[a-z0-9][a-z0-9_.-]*$/i.test(service ?? ""))) {
      throw new Error("Docker returned an unexpected service inventory");
    }
    const services = new Set(rows.map((row) => row[1]));
    const dockerHost = process.env.DOCKER_HOST || await docker("context", "inspect", context, "--format", "{{.Endpoints.docker.Host}}").catch(() => "");
    const results = await Promise.all(rows.map((row) => check(row, services.has("cpu-stt"))));
    const missing = ["frontend", "app", "agent-bridge", "redis"].filter((service) => !services.has(service));
    const running = results.filter((r) => r.running).length;
    const issues = results.filter((r) => r.attention || (running > 0 && ["Stopped", "Not started"].includes(r.status))).length + missing.length;
    const starting = results.filter((r) => r.starting).length;
    const overall = issues ? "Needs attention" : starting ? "Starting" : running ? "Running" : "Stopped";
    console.log(`${overall} · ${running}/${results.length} services running${issues ? ` · ${issues} need attention` : ""}`);
    const web = results.find((r) => r.service === "frontend");
    const port = web?.ports?.find((p) => /^\d+$/.test(p.HostPort))?.HostPort;
    if (port) console.log(dockerHost.startsWith("unix://") ? `${web.running ? "Open" : "Configured web address"}: http://localhost:${port}` : `Web port on Docker host: ${port}`);
    for (const service of missing) results.push({ service, status: "Missing", detail: "Run bh install to repair", children: [] });
    for (const group of [...Object.keys(groups), "Other services"]) {
      const items = results.filter((r) => groupFor(r.service) === group)
        .sort((a, b) => (Object.keys(groups[group] ?? {}).indexOf(a.service) + 1 || 100) - (Object.keys(groups[group] ?? {}).indexOf(b.service) + 1 || 100) || a.service.localeCompare(b.service));
      if (!items.length) continue;
      console.log(`\n${group}`);
      for (const r of items) console.log([line(labelFor(group, r.service), r.status, r.detail), ...r.children].join("\n"));
    }
    if (issues) console.log("\nFor details: bh logs <service> (for example, bh logs frontend)");
  }
  console.log(`\nDocker project: ${project} (${context})`);
}

main(process.argv.slice(2)).catch(() => {
  console.error("bh: could not read service state from Docker; check that Docker is running and retry.");
  process.exitCode = 1;
});
