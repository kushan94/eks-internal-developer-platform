'use strict';
// A stand-in for the Backstage backend, for testing the launcher. It becomes
// ready DELAY_MS after it starts, and writes what it does to LOG.
const fs = require('fs');
const http = require('http');
const name = process.env.NAME;
const log = (what) => fs.appendFileSync(process.env.LOG, `${Date.now()} ${name} ${what}\n`);
const started = Date.now();
log('started');
let ready = false;
setTimeout(() => { ready = true; log('ready'); }, Number(process.env.DELAY_MS || 0));
http.createServer((req, res) => {
  const ok = req.url === '/.backstage/health/v1/liveness' || ready;
  res.writeHead(ok ? 200 : 503);
  res.end('{}');
}).listen(Number(process.env.LAUNCHER_PORT));
process.on('SIGTERM', () => { log('terminated'); process.exit(0); });
