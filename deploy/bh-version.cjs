const { spawnSync } = require('node:child_process');
const { existsSync, readFileSync } = require('node:fs');
const { join } = require('node:path');

const repo = 'bawthub/bawthub-cli';
const api = `https://api.github.com/repos/${repo}`;
const services = {
  frontend: ['Web UI', 'TENANT_FRONTEND_IMAGE_REF'],
  app: ['BawtHub API', 'APP_IMAGE_REF'],
  postgres: ['PostgreSQL'],
  redis: ['Redis'],
  'agent-bridge': ['Agent bridge', 'AGENT_BRIDGE_IMAGE_REF'],
  'ops-reconciler': ['Background operations', 'APP_IMAGE_REF'],
  embed: ['Embeddings', 'EMBED_IMAGE'],
  'local-model-bridge': ['Embeddings', 'EMBED_IMAGE'],
  'voice-backend': ['Voice API', 'VOICE_BACKEND_IMAGE_REF'],
  'pocket-tts': ['Speech playback', 'POCKET_IMAGE_REF'],
  'cpu-stt': ['Speech recognition', 'CPU_STT_IMAGE_REF'],
  'playwright-mcp': ['Browser automation', 'PLAYWRIGHT_MCP_IMAGE_REF'],
  crawl4ai: ['Web crawler', 'CRAWL4AI_IMAGE_REF'],
};
const sha = /^[a-f0-9]{40}$/;
const digest = /@sha256:([a-f0-9]{64})$/;
const imageRef = /^(?:sha256:[a-f0-9]{64}|[a-zA-Z0-9][a-zA-Z0-9._:/-]*(?:@sha256:[a-f0-9]{64})?)$/;
const shortHash = id => id.slice(0, 12);

function read(file) {
  try { return readFileSync(file, 'utf8'); }
  catch (err) { if (err.code !== 'ENOENT') throw err; return ''; }
}

function settings(text) {
  const pairs = new Map();
  for (const line of text.split(/\r?\n/)) {
    const match = /^([A-Z][A-Z0-9_]*)=(.*)$/.exec(line);
    if (match) pairs.set(match[1], match[2].replace(/^(['"])(.*)\1$/, '$2'));
  }
  return pairs;
}

async function get(url, signal, headers) {
  const response = await fetch(url, { signal, headers });
  if (!response.ok) throw new Error(`HTTP ${response.status}`);
  return response;
}

function compareVersions(a, b) {
  return a.split('.').map((v, i) => Number(v) - Number(b.split('.')[i])).find(n => n !== 0) ?? 0;
}

async function checkRelease(checkStack, localCli) {
  const signal = AbortSignal.timeout(5000);
  let cli;
  try {
    const { tag_name: tag, assets } = await (await get(`${api}/releases/latest`, signal)).json();
    const version = /^v(\d{1,6}\.\d{1,6}\.\d{1,6})$/.exec(tag)?.[1];
    if (!version) throw new Error('no stable release tag');
    const file = `bawthub-cli-${version}.tgz`;
    const asset = assets?.find(a => a.name === file && a.browser_download_url === `https://github.com/${repo}/releases/download/${tag}/${file}`);
    if (!/^sha256:[0-9a-f]{64}$/.test(asset?.digest) || !Number.isInteger(asset.size) || asset.size <= 0 || asset.size > 8 * 1024 * 1024) {
      throw new Error('release archive unavailable');
    }
    cli = version;
    if (!checkStack || compareVersions(cli, localCli) < 0) return { cli };
    const commit = (await (await get(`${api}/commits/${tag}`, signal, { Accept: 'application/vnd.github.sha' })).text()).trim();
    if (!sha.test(commit)) throw new Error('invalid release source revision');
    const url = `https://raw.githubusercontent.com/${repo}/${commit}/deploy/tenant.env.example`;
    const pins = settings(await (await get(url, signal)).text());
    if (!digest.test(pins.get('APP_IMAGE_REF') ?? '')) throw new Error('image pins unavailable');
    return { cli, commit, pins };
  } catch {
    return { cli };
  }
}

function inspect(shell, root, manifest, context) {
  const argv = [shell, '--dir', root, '--manifest', manifest];
  if (context) argv.push('--context', context);
  argv.push('_version-inventory');
  const { status, stdout, stderr } = spawnSync('bash', argv, { encoding: 'utf8', timeout: 5000 });
  if (status !== 0) {
    // Show the scoped CLI error, not arbitrary daemon/bootstrap output.
    const reason = stderr?.split('\n').find(line => line.startsWith('bh: '))?.slice(4);
    return { error: reason || 'Docker unavailable or inspection timed out' };
  }
  try {
    const rows = stdout.trim() ? stdout.trim().split('\n').map(line => JSON.parse(line)) : [];
    return { rows };
  } catch {
    return { error: 'Docker did not return a readable service inventory' };
  }
}

function formatImage(ref, id) {
  const pin = digest.exec(ref)?.[1];
  if (pin) return `sha256:${shortHash(pin)}`;
  const build = /^sha256:([a-f0-9]{64})$/.exec(id)?.[1];
  if (!imageRef.test(ref) || ref.startsWith('sha256:') || /^[a-f0-9]{12,64}$/.test(ref)) return build ? `image ${shortHash(build)}` : 'Unknown';
  return build ? `${ref} (${shortHash(build)})` : ref;
}

function imageStatus(ref, key, configured, known, latest, offline) {
  const current = digest.exec(ref)?.[1];
  if (!key) return 'Not tracked by BawtHub releases';
  if (configured.get('IMAGE_SOURCE') === 'local') return 'Local build';
  const config = configured.get(key);
  if (!current) return 'Installed digest unknown';
  if (offline || !latest) return offline ? 'Not checked (offline)' : 'Update check unavailable';
  const want = latest.get(key);
  const next = want && digest.exec(want)?.[1];
  if (!next) return 'No published pin';
  if (current === next) return 'Up to date';
  const label = `sha256:${shortHash(next)}`;
  if (key === 'EMBED_IMAGE') return `Release has ${label} (not auto-updated)`;
  if (!config) return 'No managed pin configured';
  if (config === want) return `Pending apply → ${label}`;
  if (!known.has(`${key}=${config}`)) return `Custom pin (release: ${label})`;
  return `Update available → ${label}`;
}

async function main() {
  const [shell, root, manifest, context, flag] = process.argv.slice(2);
  const packaged = existsSync(join(__dirname, 'package.json'));
  const localCli = require(packaged ? './package.json' : './cli/package.json').version;
  const offline = flag === '--offline';
  const installed = existsSync(manifest);
  const releaseCheck = offline ? Promise.resolve({}) : checkRelease(installed, localCli);
  const inventory = installed ? inspect(shell, root, manifest, context) : {};
  const latest = await releaseCheck;
  const updateUnknown = offline ? 'Not checked (offline)' : 'Update check unavailable';
  const compare = latest.cli ? compareVersions(latest.cli, localCli) : null;
  const cliStatus = compare === null ? updateUnknown : compare > 0 ? `Update available → ${latest.cli}` :
    compare < 0 ? `Ahead of latest release (${latest.cli})` : 'Up to date';

  console.log('BawtHub versions');
  const row = (name, version, status) => console.log(`  ${name.padEnd(24)} ${version.padEnd(26)} ${status}`);
  row('CLI', localCli, cliStatus);
  if (!installed) {
    console.log(`\nNo BawtHub install at ${root}.`);
    return;
  }
  // The source marker belongs to the root, not to every manifest in that root.
  const installedCommit = manifest === join(root, 'deploy', 'tenant.env')
    ? settings(read(join(root, '.bawthub-release'))).get('SOURCE_COMMIT') : undefined;
  const source = sha.test(installedCommit) ? shortHash(installedCommit) : 'Unknown';
  row('Stack files', source, !latest.commit ? updateUnknown : installedCommit === latest.commit ? 'Up to date' : `Latest release: ${shortHash(latest.commit)}`);
  console.log(`\nTenant: ${manifest}`);
  if (inventory.error) {
    console.log(`Service versions unavailable: ${inventory.error}.`);
    return;
  }
  if (!inventory.rows.length) {
    console.log('No service containers installed.');
    return;
  }
  const configured = settings(read(manifest));
  const known = packaged ? new Set(read(join(__dirname, 'release', 'published-pins')).split(/\r?\n/)) :
    new Set(Array.from(settings(read(join(__dirname, 'tenant.env.example'))), ([key, pin]) => `${key}=${pin}`));
  console.log('\n  Component                Installed                  Release status');
  for (const [service, ref, id] of inventory.rows.sort(([a], [b]) => a.localeCompare(b))) {
    if (!/^[a-zA-Z0-9][a-zA-Z0-9_.-]*$/.test(service) || typeof ref !== 'string') continue;
    const [label, key] = /^house-h\d+$/.test(service) ? [`Workspace ${service.slice(6)}`, 'AGENT_BRIDGE_IMAGE_REF'] :
      (Object.hasOwn(services, service) ? services[service] : [service]);
    row(label, formatImage(ref, id), imageStatus(ref, key, configured, known, latest.pins, offline));
  }
}

main().catch(err => {
  console.error(`bh: ${err.message}`);
  process.exitCode = 1;
});
