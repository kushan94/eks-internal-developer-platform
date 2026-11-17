'use strict';
// Tests the Backstage launcher (gitops/root/files/backstage-start.js) against a
// real Postgres, with a fake backend that becomes ready after a delay.
// Run it with scripts/test-backstage-start.sh, which starts Postgres.
const { test, after } = require('node:test');
const assert = require('node:assert/strict');
const { spawn } = require('node:child_process');
const fs = require('node:fs');
const http = require('node:http');
const net = require('node:net');
const os = require('node:os');
const path = require('node:path');

const LAUNCHER = path.resolve(__dirname, '../../gitops/root/files/backstage-start.js');
const FAKE = path.resolve(__dirname, 'fake-backend.js');
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const running = new Set();
let keyCounter = Math.floor(Math.random() * 1e6) * 10;

const freePort = () => new Promise((resolve) => {
  const server = net.createServer().listen(0, '127.0.0.1', () => { const { port } = server.address(); server.close(() => resolve(port)); });
});
const get = (port, url) => new Promise((resolve) => {
  http.get({ host: '127.0.0.1', port, path: url, timeout: 2000 }, (res) => { res.resume(); resolve(res.statusCode); }).on('error', () => resolve(0));
});
async function waitFor(fn, ms = 20000) {
  const end = Date.now() + ms;
  while (Date.now() < end) { const v = fn(); if (v) return v; await sleep(100); }
  throw new Error('timed out waiting');
}

// One test's replicas share a log file and a lock key, which is what makes them contend.
function scenario() {
  const log = path.join(fs.mkdtempSync(path.join(os.tmpdir(), 'launcher-')), 'events.log');
  fs.writeFileSync(log, '');
  const key = String(++keyCounter);
  const events = () => fs.readFileSync(log, 'utf8').split('\n').filter(Boolean).map((l) => { const [ts, name, what] = l.split(' '); return { ts: Number(ts), name, what }; });
  const when = (name, what) => (events().find((e) => e.name === name && e.what === what) || {}).ts;
  async function launch(name, extra = {}, args = [process.execPath, FAKE]) {
    const port = await freePort();
    const env = {
      ...process.env, POSTGRES_HOST: '127.0.0.1', POSTGRES_PORT: process.env.TEST_PGPORT, POSTGRES_USER: 'postgres', POSTGRES_PASSWORD: 'test',
      LAUNCHER_PG_SSL: 'false', LAUNCHER_CONNECT_DELAY_MS: '200', LAUNCHER_LOCK_KEY: key, LAUNCHER_PORT: String(port), NAME: name, LOG: log, ...extra,
    };
    // Its own process group, so a test can kill the launcher and its backend together, as a dying container does.
    const proc = spawn(process.execPath, [LAUNCHER, ...args], { env, stdio: ['ignore', 'pipe', 'pipe'], detached: true });
    let output = '';
    proc.stdout.on('data', (d) => { output += d; });
    proc.stderr.on('data', (d) => { output += d; });
    running.add(proc);
    const exited = new Promise((resolve) => proc.on('exit', (code) => { running.delete(proc); proc.stdout.destroy(); proc.stderr.destroy(); resolve(code); }));
    return { proc, port, exited, output: () => output };
  }
  return { launch, when, events };
}
const killGroup = (proc) => { try { process.kill(-proc.pid, 'SIGKILL'); } catch { /* already gone */ } };
after(() => { for (const p of running) killGroup(p); });

test('replicas start one at a time, and the one waiting answers its probes', async () => {
  const s = scenario();
  const a = await s.launch('A', { DELAY_MS: '1500' });
  await waitFor(() => s.when('A', 'started'));
  const b = await s.launch('B', { DELAY_MS: '300' });
  await sleep(1000);
  assert.equal(await get(b.port, '/.backstage/health/v1/liveness'), 200, 'a waiting replica must pass its liveness check');
  assert.equal(await get(b.port, '/.backstage/health/v1/readiness'), 503, 'a waiting replica must not be ready');
  assert.equal(s.when('B', 'started'), undefined, 'B must not start while A is still starting');
  await waitFor(() => s.when('B', 'ready'));
  assert.ok(s.when('B', 'started') >= s.when('A', 'ready'), 'B started before A was ready');
  a.proc.kill('SIGTERM'); b.proc.kill('SIGTERM');
  await Promise.all([a.exited, b.exited]);
});

test('three replicas start strictly in turn', async () => {
  const s = scenario();
  const all = await Promise.all(['A', 'B', 'C'].map((n) => s.launch(n, { DELAY_MS: '800' })));
  await waitFor(() => ['A', 'B', 'C'].every((n) => s.when(n, 'ready')), 40000);
  const order = s.events().filter((e) => e.what === 'started').sort((x, y) => x.ts - y.ts);
  for (let i = 1; i < order.length; i++) {
    assert.ok(order[i].ts >= s.when(order[i - 1].name, 'ready'), `${order[i].name} started before ${order[i - 1].name} was ready`);
  }
  all.forEach((r) => r.proc.kill('SIGTERM'));
  await Promise.all(all.map((r) => r.exited));
});

test('a backend that never becomes ready is stopped, and the next replica goes ahead', async () => {
  const s = scenario();
  const a = await s.launch('A', { DELAY_MS: '600000', LAUNCHER_STARTUP_TIMEOUT_MS: '3000' });
  await waitFor(() => s.when('A', 'started'));
  const b = await s.launch('B', { DELAY_MS: '300' });
  assert.equal(await a.exited, 1, 'the launcher should exit with an error so the pod restarts');
  assert.ok(s.when('A', 'terminated'), 'the stuck backend should have been stopped');
  assert.match(a.output(), /wasn't ready after 3000 ms/);
  await waitFor(() => s.when('B', 'ready'));
  assert.ok(s.when('B', 'started') >= s.when('A', 'terminated'), 'B started before the stuck backend was gone');
  b.proc.kill('SIGTERM');
  await b.exited;
});

test('a replica that dies while starting releases its turn', async () => {
  const s = scenario();
  const a = await s.launch('A', { DELAY_MS: '600000' });
  await waitFor(() => s.when('A', 'started'));
  const b = await s.launch('B', { DELAY_MS: '300' });
  await sleep(800);
  killGroup(a.proc); // no chance to clean up: the database connection just drops
  await a.exited;
  await waitFor(() => s.when('B', 'ready'));
  b.proc.kill('SIGTERM');
  await b.exited;
});

test('with the database unreachable it starts anyway', async () => {
  const s = scenario();
  const c = await s.launch('C', { POSTGRES_PORT: '1', LAUNCHER_CONNECT_ATTEMPTS: '2', DELAY_MS: '200' });
  await waitFor(() => s.when('C', 'ready'));
  assert.match(c.output(), /without the startup lock/);
  c.proc.kill('SIGTERM');
  await c.exited;
});

test('SIGTERM reaches the backend, and the launcher exits cleanly', async () => {
  const s = scenario();
  const d = await s.launch('D', { DELAY_MS: '200' });
  await waitFor(() => s.when('D', 'ready'));
  d.proc.kill('SIGTERM');
  assert.equal(await d.exited, 0);
  assert.ok(s.when('D', 'terminated'), 'the backend never saw SIGTERM');
});

test('SIGTERM while waiting for the turn exits without starting a backend', async () => {
  const s = scenario();
  const a = await s.launch('A', { DELAY_MS: '600000' });
  await waitFor(() => s.when('A', 'started'));
  const b = await s.launch('B');
  await sleep(1000);
  b.proc.kill('SIGTERM');
  assert.equal(await b.exited, 0);
  assert.equal(s.when('B', 'started'), undefined);
  killGroup(a.proc);
  await a.exited;
});

test('it needs a command', async () => {
  const s = scenario();
  const r = await s.launch('X', {}, []);
  assert.equal(await r.exited, 2);
});

// The file is embedded in a ConfigMap by Helm, and the Backstage chart renders it
// again, so two opening braces in a row would be taken for a template.
test('the launcher contains no double braces for Helm to interpret', () => {
  assert.ok(!fs.readFileSync(LAUNCHER, 'utf8').includes('{{'));
});
