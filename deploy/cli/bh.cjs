#!/usr/bin/env node
const { spawnSync } = require('node:child_process');
const { homedir } = require('node:os');
const { isAbsolute, join } = require('node:path');
const pkg = require('./package.json');

const args = process.argv.slice(2);
if (args.length === 1 && ['--version', '-V'].includes(args[0])) {
  console.log(pkg.version);
} else {
  const dataHome = process.env.XDG_DATA_HOME || '';
  const env = {
    ...process.env,
    BAWTHUB_DIR: process.env.BAWTHUB_DIR || join(isAbsolute(dataHome) ? dataHome : join(homedir(), '.local', 'share'), 'bawthub', 'tenant'),
    BAWTHUB_PACKAGED_RELEASE: join(__dirname, 'release'),
  };
  const result = spawnSync('bash', [join(__dirname, 'bh.sh'), ...args], { env, stdio: 'inherit' });
  if (result.error) console.error(`bh: ${result.error.message}`);
  process.exitCode = result.status ?? 1;
}
