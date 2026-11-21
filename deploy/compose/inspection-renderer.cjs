// Private tenant renderer. The frontend sends a fixed snapshot's escaped HTML,
// never URLs, cookies or commands. Run with network_mode: none; the only IPC
// is the socket volume mounted in this worker and the tenant frontend.
const { chmodSync, lstatSync, unlinkSync } = require('node:fs');
const { createServer } = require('node:http');
const { chromium } = require('/app/node_modules/playwright');

const socket = '/run/bawthub-inspection/render.sock';
const sizes = { phone: { width: 375, height: 844 }, desktop: { width: 1280, height: 900 } };
const maxRequest = 128 * 1024;
const maxImage = 2 * 1024 * 1024;
let busy = false;

async function render(request, response) {
  if (request.method === 'GET' && request.url === '/ready') {
    response.writeHead(204).end();
    return;
  }
  if (request.method !== 'POST' || request.url !== '/render' || request.headers['content-type'] !== 'application/json') {
    response.writeHead(404).end();
    return;
  }
  if (busy) {
    response.writeHead(503).end();
    return;
  }
  busy = true;
  let browser;
  const deadline = AbortSignal.timeout(16_000);
  const closeBrowser = () => { if (browser) void browser.close().catch(() => {}); };
  deadline.addEventListener('abort', closeBrowser, { once: true });
  try {
    const chunks = [];
    let bytes = 0;
    for await (const chunk of request) {
      bytes += chunk.length;
      if (bytes > maxRequest) {
        response.writeHead(413).end();
        return;
      }
      chunks.push(chunk);
    }
    const body = JSON.parse(Buffer.concat(chunks).toString('utf8'));
    const { html, viewport: name } = body ?? {};
    if (typeof html !== 'string' || (name !== 'phone' && name !== 'desktop')) {
      response.writeHead(400).end();
      return;
    }
    deadline.throwIfAborted();
    browser = await chromium.launch({ channel: 'chromium', headless: true, timeout: 5000 });
    deadline.throwIfAborted();
    const context = await browser.newContext({
      viewport: sizes[name], isMobile: name === 'phone', hasTouch: name === 'phone',
      javaScriptEnabled: false, serviceWorkers: 'block',
    });
    let unexpectedRequest = false;
    await context.route('**/*', (route) => {
      unexpectedRequest = true;
      return route.abort();
    });
    const page = await context.newPage();
    await page.setContent(html, { timeout: 5000 });
    const image = await page.screenshot({ timeout: 5000, animations: 'disabled' });
    // A completed response means this context is closed and another request
    // can start; otherwise sequential callers can race the busy flag.
    await browser.close();
    browser = undefined;
    deadline.throwIfAborted();
    if (unexpectedRequest || image.length > maxImage) {
      response.writeHead(422).end();
      return;
    }
    response.writeHead(200, { 'Content-Type': 'image/png', 'Content-Length': image.length }).end(image);
  } catch {
    // No URLs, markup, stdout from Chromium or exception details on this lane.
    if (!response.headersSent) response.writeHead(502).end();
  } finally {
    deadline.removeEventListener('abort', closeBrowser);
    if (browser) await browser.close().catch(() => {});
    busy = false;
  }
}

process.umask(0o077);
// Only the dedicated worker writes in this directory. Remove its stale socket
// from a prior container; don't follow a symlink or clobber a regular file.
const prior = lstatSync(socket, { throwIfNoEntry: false });
if (prior?.isSocket()) unlinkSync(socket);
const server = createServer({ requestTimeout: 5000, headersTimeout: 3000, connectionsCheckingInterval: 1000 }, (request, response) => {
  // One request per connection; the dedicated frontend is the only client.
  response.setHeader('Connection', 'close');
  void render(request, response);
});
server.listen(socket, () => chmodSync(socket, 0o600));
