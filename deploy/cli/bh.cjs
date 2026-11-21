#!/usr/bin/env node
const { spawnSync } = require('node:child_process');
const { createHash } = require('node:crypto');
const { accessSync, constants, mkdtempSync, realpathSync, rmSync, statSync, writeFileSync } = require('node:fs');
const { homedir, tmpdir } = require('node:os');
const { isAbsolute, join, resolve } = require('node:path');
const pkg = require('./package.json');

const repo = 'bawthub/bawthub-cli';
const args = process.argv.slice(2);

function run(command, argv, env) {
  const result = spawnSync(command, argv, { env, stdio: 'inherit' });
  if (result.error) throw result.error;
  return result.status ?? 1;
}

function isOnlineUpdate() {
  let i = 0;
  const globalOptions = ['--dir', '--manifest', '--context', '--installer'];
  while (globalOptions.includes(args[i])) {
    if (!args[i + 1] || args[i + 1].startsWith('--') || args[i] === '--installer') return false;
    i += 2;
  }
  if (args[i] !== 'update') return false;
  for (i++; i < args.length; i++) {
    if (args[i] === '--verbose') continue;
    if (args[i] !== '--bot-pack' || !args[i + 1] || args[i + 1].startsWith('--')) return false;
    i++;
    try {
      accessSync(args[i + 1], constants.R_OK);
      if (!statSync(args[i + 1]).isFile()) return false;
    } catch { return false; }
  }
  return true;
}

async function get(url, label) {
  const res = await fetch(url, { signal: AbortSignal.timeout(30000) });
  if (!res.ok) throw new Error(`${label}: HTTP ${res.status}`);
  return res;
}

async function updateCli(env) {
  let release;
  try {
    const meta = await get(`https://api.github.com/repos/${repo}/releases/latest`, 'checking the CLI release');
    release = await meta.json();
  } catch (err) {
    console.error(`bh: could not check for a new CLI (${err.message}); using ${pkg.version}.`);
    return undefined;
  }
  const { tag_name: tag, assets } = release;
  const version = /^v(\d{1,6}\.\d{1,6}\.\d{1,6})$/.exec(tag)?.[1];
  if (!version) throw new Error('the latest CLI release does not have a stable version tag');
  const current = pkg.version.split('.').map(Number);
  const diff = version.split('.').map((part, i) => Number(part) - current[i]).find(n => n !== 0);
  if (!(diff > 0)) return undefined;

  // Locate this npm install's prefix, not the default prefix of another Node.
  const prefix = resolve(__dirname, '../../../..');
  const bin = join(prefix, 'bin', 'bh');
  if (__dirname !== join(prefix, 'lib/node_modules/@bawthub/cli') || realpathSync(bin) !== __filename) {
    throw new Error('cannot locate the global npm install; reinstall bh from the official release URL');
  }
  const file = `bawthub-cli-${version}.tgz`;
  const url = `https://github.com/${repo}/releases/download/${tag}/${file}`;
  const asset = assets?.find(a => a.name === file && a.browser_download_url === url);
  if (!/^sha256:[0-9a-f]{64}$/.test(asset?.digest) || !Number.isInteger(asset.size) || asset.size <= 0 || asset.size > 8 * 1024 * 1024) {
    throw new Error('the official CLI archive or its SHA-256 is missing');
  }

  console.error(`Updating BawtHub CLI ${pkg.version} → ${version}…`);
  const res = await get(url, 'downloading the CLI archive');
  const chunks = [];
  let size = 0;
  for await (const chunk of res.body) {
    size += chunk.length;
    if (size > asset.size) throw new Error('the CLI download exceeds the release size');
    chunks.push(chunk);
  }
  const archive = Buffer.concat(chunks, size);
  if (size !== asset.size || `sha256:${createHash('sha256').update(archive).digest('hex')}` !== asset.digest) {
    throw new Error('the CLI download did not match the release checksum');
  }
  const temp = mkdtempSync(join(tmpdir(), 'bawthub-cli-'));
  try {
    const local = join(temp, file);
    writeFileSync(local, archive, { mode: 0o600 });
    const status = run('npm', ['install', '-g', '--prefix', prefix, '--ignore-scripts', '--no-audit', '--no-fund', local], env);
    if (status !== 0) throw new Error('npm could not update the CLI in its current install location');
  } finally {
    rmSync(temp, { recursive: true, force: true });
  }
  return run(process.execPath, [realpathSync(bin), ...args], { ...env, BAWTHUB_CLI_JUST_UPDATED: '1' });
}

async function main() {
  if (args.length === 1 && ['--version', '-V'].includes(args[0])) {
    console.log(pkg.version);
    return 0;
  }
  const env = { ...process.env };
  const alreadyUpdated = env.BAWTHUB_CLI_JUST_UPDATED === '1';
  delete env.BAWTHUB_CLI_JUST_UPDATED;
  delete env.BAWTHUB_CLI_CHECK_UPDATE_TARGET;
  const dataHome = env.XDG_DATA_HOME || '';
  env.BAWTHUB_DIR ||= join(isAbsolute(dataHome) ? dataHome : join(homedir(), '.local', 'share'), 'bawthub', 'tenant');
  env.BAWTHUB_PACKAGED_RELEASE = join(__dirname, 'release');
  const argv = [join(__dirname, 'bh.sh'), ...args];
  if (!alreadyUpdated && isOnlineUpdate()) {
    const checked = run('bash', argv, { ...env, BAWTHUB_CLI_CHECK_UPDATE_TARGET: '1' });
    if (checked !== 0) return checked;
    const status = await updateCli(env);
    if (status !== undefined) return status;
  }
  return run('bash', argv, env);
}

main().then(status => { process.exitCode = status; }).catch(err => {
  console.error(`bh: ${err.message}`);
  process.exitCode = 1;
});
