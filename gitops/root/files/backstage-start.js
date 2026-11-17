'use strict';
// Starts Backstage one replica at a time.
//
// Backstage runs its database migrations when it starts. With two replicas
// starting at once against a database that doesn't exist yet (the platform's
// is created every session), both create the same tables, and the race can
// leave a knex migration lock table with two rows. knex can never take its
// lock after that, so a plugin fails to start for good while Backstage's
// liveness check keeps saying it is fine. Nothing restarts the pod.
//
// So each replica takes a Postgres advisory lock before it starts the backend,
// and holds it until the backend is ready, which means its migrations are
// done. The next replica starts then, and finds nothing left to migrate.
//
//   node start.js <command> [args...]
//
// While it waits, it answers the probes itself: liveness is ok and everything
// else is not ready, so Kubernetes doesn't kill a pod that is only waiting. If
// the backend isn't ready within LAUNCHER_STARTUP_TIMEOUT_MS it is stopped and
// this exits, so the pod restarts instead of hanging. If the database can't be
// reached to take the lock, it starts anyway: that is no worse than before.
//
// The lock is released when this process ends, whatever the reason.

const fs = require('fs');
const http = require('http');
const { spawn } = require('child_process');

const env = process.env;
const port = Number(env.LAUNCHER_PORT || 7007);
const readyUrl = env.LAUNCHER_READY_URL || `http://127.0.0.1:${port}/.backstage/health/v1/readiness`;
const startupTimeoutMs = Number(env.LAUNCHER_STARTUP_TIMEOUT_MS || 300000);
const lockKey = Number(env.LAUNCHER_LOCK_KEY || 7007001);
const connectAttempts = Number(env.LAUNCHER_CONNECT_ATTEMPTS || 40);
const connectDelayMs = Number(env.LAUNCHER_CONNECT_DELAY_MS || 3000);
const lockDatabase = env.LAUNCHER_LOCK_DATABASE || 'postgres';
const caPath = env.LAUNCHER_PG_CA || '/app/rds-ca-bundle.pem';
const command = process.argv.slice(2);

const say = (level, message) => console.log(JSON.stringify({ level, service: 'backstage-start', message }));
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

// Answers the probes while this replica waits for its turn.
function placeholder() {
  const server = http.createServer((req, res) => {
    const alive = req.url === '/.backstage/health/v1/liveness';
    res.writeHead(alive ? 200 : 503, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ status: alive ? 'ok' : 'waiting for another replica to finish starting' }));
  });
  server.listen(port, '0.0.0.0');
  return new Promise((resolve) => server.once('listening', () => resolve({
    close: () => new Promise((done) => {
      server.close(() => done());
      if (server.closeAllConnections) server.closeAllConnections();
    }),
  })));
}

function tlsSettings() {
  if (env.LAUNCHER_PG_SSL === 'false') return false;
  // The same CA bundle Backstage uses for RDS, which requires TLS.
  if (fs.existsSync(caPath)) return { ca: fs.readFileSync(caPath) };
  return { rejectUnauthorized: false };
}

// Takes the advisory lock and keeps the connection, which is what holds it.
// Returns null if the database can't be reached after all the attempts.
async function takeLock() {
  const { Client } = require('pg');
  for (let attempt = 1; attempt <= connectAttempts; attempt++) {
    const client = new Client({
      host: env.POSTGRES_HOST,
      port: Number(env.POSTGRES_PORT || 5432),
      user: env.POSTGRES_USER,
      password: env.POSTGRES_PASSWORD,
      database: lockDatabase,
      ssl: tlsSettings(),
      connectionTimeoutMillis: 10000,
    });
    client.on('error', (err) => say('warn', `the connection holding the startup lock failed: ${err.message}`));
    try {
      await client.connect();
      await client.query('select pg_advisory_lock($1)', [lockKey]);
      return client;
    } catch (err) {
      say('warn', `couldn't take the startup lock (attempt ${attempt} of ${connectAttempts}): ${err.message}`);
      await client.end().catch(() => {});
      if (attempt < connectAttempts) await sleep(connectDelayMs);
    }
  }
  return null;
}

function isReady() {
  return new Promise((resolve) => {
    const req = http.get(readyUrl, { timeout: 3000 }, (res) => { res.resume(); resolve(res.statusCode === 200); });
    req.on('error', () => resolve(false));
    req.on('timeout', () => { req.destroy(); resolve(false); });
  });
}

async function main() {
  if (command.length === 0) {
    say('error', 'usage: start.js <command> [args...]');
    process.exit(2);
  }
  let child = null;
  for (const sig of ['SIGTERM', 'SIGINT']) {
    process.on(sig, () => { if (child) child.kill(sig); else process.exit(0); });
  }

  const waiting = await placeholder();
  say('info', 'waiting for the startup lock');
  const lock = await takeLock();
  say(lock ? 'info' : 'warn', lock ? 'took the startup lock, starting the backend' : 'starting the backend without the startup lock');
  const release = async () => { if (lock) await lock.end().catch(() => {}); };
  await waiting.close();

  child = spawn(command[0], command.slice(1), { stdio: 'inherit' });
  let timedOut = false;
  child.on('exit', async (code, signal) => {
    await release();
    if (timedOut) process.exit(1);
    process.exit(code === null ? (signal === 'SIGTERM' ? 0 : 1) : code);
  });

  const deadline = Date.now() + startupTimeoutMs;
  while (child.exitCode === null && child.signalCode === null) {
    if (await isReady()) {
      say('info', 'the backend is ready, releasing the startup lock');
      await release();
      return;
    }
    if (Date.now() > deadline) {
      say('error', `the backend wasn't ready after ${startupTimeoutMs} ms, stopping it so the pod restarts`);
      timedOut = true;
      child.kill('SIGTERM');
      setTimeout(() => child.kill('SIGKILL'), 10000).unref();
      return;
    }
    await sleep(2000);
  }
}

main().catch((err) => { say('error', err.stack || String(err)); process.exit(1); });
