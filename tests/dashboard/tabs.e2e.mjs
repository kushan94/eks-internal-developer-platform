import puppeteer from 'puppeteer-core';
// Browser tests for the dashboard. Start it first with scripts/dashboard-demo.sh.
//   CHROME  path to Chrome or Chromium (default: Chrome on macOS)
//   BASE    where the dashboard is (default: the demo's address)
//   SHOTS   a folder to save screenshots in (default: none)
const CHROME = process.env.CHROME || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const BASE = process.env.BASE || 'http://localhost:18080/';
const out = process.env.SHOTS || '';
const shot = (p, name, opts = {}) => out ? p.screenshot({ path: `${out}/${name}.png`, ...opts }) : null;
const wait = ms => new Promise(r => setTimeout(r, ms));
let failures = 0;
const check = (name, ok, extra = '') => { console.log((ok ? 'PASS ' : 'FAIL ') + name + (ok ? '' : '  ' + extra)); if (!ok) failures++; };

const browser = await puppeteer.launch({ executablePath: CHROME, headless: 'new', args: ['--hide-scrollbars'] });
async function open(url, scheme = 'light', w = 1440, h = 900) {
  const p = await browser.newPage();
  await p.setViewport({ width: w, height: h });
  await p.emulateMediaFeatures([{ name: 'prefers-color-scheme', value: scheme }]);
  p.errors = [];
  p.on('pageerror', e => p.errors.push('pageerror: ' + e.message));
  p.on('console', m => { if (m.type() === 'error') p.errors.push('console: ' + m.text()); });
  await p.goto(url, { waitUntil: 'networkidle0' });
  await wait(400);
  return p;
}
const visible = p => p.evaluate(() => [...document.querySelectorAll('[role=tabpanel]')].filter(x => !x.hidden).map(x => x.id));
const selected = p => p.evaluate(() => [...document.querySelectorAll('[role=tab]')].filter(x => x.getAttribute('aria-selected') === 'true').map(x => x.id));

// Every tab, by URL
for (const tab of ['overview', 'workloads', 'nodes', 'delivery', 'events']) {
  const p = await open(BASE + '#/' + tab);
  check(`#/${tab} shows only its panel`, JSON.stringify(await visible(p)) === JSON.stringify(['panel-' + tab]), JSON.stringify(await visible(p)));
  check(`#/${tab} selects its tab`, JSON.stringify(await selected(p)) === JSON.stringify(['tab-' + tab]));
  check(`#/${tab} has no console errors`, p.errors.length === 0, p.errors.join('\n'));
  await shot(p, `tab-${tab}`, { fullPage: true });
  await p.close();
}

// The default and an unknown route are Overview
let p = await open(BASE);
check('no hash shows Overview', JSON.stringify(await visible(p)) === '["panel-overview"]');
await p.goto(BASE + '#/nonsense'); await wait(300);
check('an unknown route shows Overview', JSON.stringify(await visible(p)) === '["panel-overview"]');

// Badges and the header pill are there on every tab
await p.goto(BASE + '#/nodes'); await wait(300);
const chrome = await p.evaluate(() => ({ pill: document.getElementById('pill').textContent, overview: document.getElementById('badge-overview').textContent, workloads: document.getElementById('badge-workloads').textContent, events: document.getElementById('badge-events').textContent, pillVisible: !document.getElementById('pill').hidden }));
check('the attention pill is visible on the Nodes tab', chrome.pillVisible && /need attention/.test(chrome.pill), JSON.stringify(chrome));
check('tab badges carry counts', +chrome.overview > 0 && +chrome.workloads > 0 && +chrome.events > 0, JSON.stringify(chrome));

// Clicking a tab changes the address, and Back returns
await p.click('#tab-events'); await wait(500);
check('clicking Events updates the address', (await p.evaluate(() => location.hash)) === '#/events');
check('clicking Events shows its panel', JSON.stringify(await visible(p)) === '["panel-events"]');
await p.goBack(); await wait(400);
check('Back returns to the previous tab', JSON.stringify(await visible(p)) === '["panel-nodes"]', JSON.stringify(await visible(p)));

// Keyboard: arrows move between tabs, and only the selected tab is in the tab order
await p.focus('#tab-nodes');
await p.keyboard.press('ArrowRight'); await wait(300);
check('ArrowRight moves to Delivery', JSON.stringify(await selected(p)) === '["tab-delivery"]', JSON.stringify(await selected(p)));
check('focus follows', await p.evaluate(() => document.activeElement.id) === 'tab-delivery');
await p.keyboard.press('End'); await wait(300);
check('End moves to Events', JSON.stringify(await selected(p)) === '["tab-events"]');
await p.keyboard.press('ArrowRight'); await wait(300);
check('ArrowRight wraps to Overview', JSON.stringify(await selected(p)) === '["tab-overview"]');
check('only the selected tab has tabindex 0', await p.evaluate(() => [...document.querySelectorAll('[role=tab]')].filter(x => x.tabIndex === 0).length) === 1);
await p.close();

// Workloads: pods list and filters
p = await open(BASE + '#/workloads');
const all = await p.evaluate(() => document.querySelectorAll('#pods tbody tr').length);
check('the pods table lists pods from every namespace', all >= 20, String(all));
await p.evaluate(() => { const c = document.getElementById('pod-only-problems'); c.click(); });
await wait(200);
const bad = await p.evaluate(() => document.querySelectorAll('#pods tbody tr').length);
check('"Only unhealthy" narrows the pods', bad > 0 && bad < all, `${bad} of ${all}`);
await p.type('#pod-filter', 'fault-oom'); await wait(200);
check('the pod filter matches the namespace', await p.evaluate(() => document.querySelectorAll('#pods tbody tr').length) === 1);
await shot(p, 'workloads-filtered');
await p.close();

// Events: reason chips filter the list
p = await open(BASE + '#/events');
const n0 = await p.evaluate(() => document.querySelectorAll('#events-all li').length);
await p.evaluate(() => document.querySelector('#ev-reasons button').click()); await wait(200);
const n1 = await p.evaluate(() => document.querySelectorAll('#events-all li').length);
check('a reason chip filters the events', n1 > 0 && n1 <= n0, `${n1} of ${n0}`);
check('the chip shows as pressed', await p.evaluate(() => document.querySelector('#ev-reasons button').getAttribute('aria-pressed')) === 'true');
await p.close();

// Deep links to a namespace, new and legacy
for (const url of [BASE + '#/workloads?ns=fault-oom', BASE + '#ns=fault-oom']) {
  p = await open(url);
  check(`${url.slice(BASE.length)} opens the drawer`, await p.evaluate(() => !document.getElementById('drawer').hidden && document.getElementById('drawer-title').textContent === 'fault-oom'));
  check(`${url.slice(BASE.length)} lands on Workloads`, JSON.stringify(await visible(p)) === '["panel-workloads"]');
  await p.keyboard.press('Escape'); await wait(300);
  check('Escape closes the drawer and keeps the tab in the address', await p.evaluate(() => document.getElementById('drawer').hidden && location.hash === '#/workloads'), await p.evaluate(() => location.hash));
  await p.close();
}
// Opening a drawer from the Overview keeps you on Overview
p = await open(BASE + '#/overview');
await p.evaluate(() => document.querySelector('#problems .btn').click()); await wait(300);
check('Diagnose opens the assistant from Overview', await p.evaluate(() => !document.getElementById('assistant').hidden));
await p.close();

// The assistant, with its streaming response stubbed so no model is called
const sse = (...evs) => evs.map(([e, d]) => `event: ${e}\ndata: ${JSON.stringify(d)}\n\n`).join('');
const STREAM = sse(
  ['turn', { turn: 1 }],
  ['tool', { tool: 'list_pods', input: { namespace: 'fault-oom' } }],
  ['step', { tool: 'list_pods', input: {}, bytes: 612 }],
  ['tool', { tool: 'get_pod_logs', input: { namespace: 'fault-oom', previous: true } }],
  ['step', { tool: 'get_pod_logs', input: {}, bytes: 0, failed: true }],
  ['done', { answer: '## Cause\nThe container is **OOMKilled**.\n\n- `list_pods`: exit code 137\n\n```yaml\nmemory: 256Mi\n```\n\n<img src=x onerror=window.__pwned=1>', steps: [1, 2], inputTokens: 5210, outputTokens: 640 }],
);
p = await open(BASE + '#/overview');
await p.setRequestInterception(true);
let sent = null;
p.on('request', r => {
  if (r.url().endsWith('/api/diagnose/stream')) { sent = JSON.parse(r.postData()); r.respond({ status: 200, contentType: 'text/event-stream', body: STREAM }); } else r.continue();
});
await p.evaluate(() => document.querySelector('#problems .btn').click()); await wait(300);
check('the assistant waits for Run before calling anything', sent === null);
await p.click('#run'); await wait(800);
check('Run sends the target and the question', sent && sent.namespace && typeof sent.question === 'string', JSON.stringify(sent));
check('every tool call shows in the timeline, failed ones marked', await p.evaluate(() => document.querySelectorAll('#timeline li').length === 2 && document.querySelectorAll('#timeline li.failed').length === 1));
check('the answer is rendered as headings, lists and code', await p.evaluate(() => !!document.querySelector('#answer h4') && !!document.querySelector('#answer li') && !!document.querySelector('#answer pre')));
check('HTML in the answer is shown as text and never runs', await p.evaluate(() => !document.querySelector('#answer img') && !window.__pwned && document.getElementById('answer').textContent.includes('<img')));
check('the usage line shows tool calls and tokens', await p.evaluate(() => /2 tool calls · 5,210 tokens in, 640 out/.test(document.getElementById('usage').textContent)), await p.evaluate(() => document.getElementById('usage').textContent));
await shot(p, 'assistant');
await p.close();

// Dark and phone
p = await open(BASE + '#/nodes', 'dark'); await shot(p, 'dark-nodes', { fullPage: true }); check('dark has no console errors', p.errors.length === 0, p.errors.join('\n')); await p.close();
p = await open(BASE + '#/workloads', 'light', 390, 844);
check('phone width has no horizontal overflow', await p.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth) === 0);
check('the tab bar scrolls instead of wrapping', await p.evaluate(() => document.querySelector('.tabs').scrollWidth >= document.querySelector('.tabs').clientWidth));
await shot(p, 'mobile-workloads'); check('phone has no console errors', p.errors.length === 0, p.errors.join('\n')); await p.close();

await browser.close();
console.log(failures ? `${failures} FAILED` : 'ALL PASSED');
process.exit(failures ? 1 : 0);
