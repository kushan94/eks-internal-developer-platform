'use strict';

// Everything on the page comes from the cluster, so none of it is trusted.
// Elements are built from text nodes only; innerHTML is never used.

const SVG = 'http://www.w3.org/2000/svg';
const ICONS = {
  check: 'M20 6 9 17l-5-5',
  alert: 'M12 9v4M12 17h.01M10.3 3.9 1.8 18a2 2 0 0 0 1.7 3h17a2 2 0 0 0 1.7-3L13.7 3.9a2 2 0 0 0-3.4 0z',
  error: 'M12 22a10 10 0 1 0 0-20 10 10 0 0 0 0 20zM15 9l-6 6M9 9l6 6',
  refresh: 'M21 12a9 9 0 0 1-15.5 6.2L3 16M3 12a9 9 0 0 1 15.5-6.2L21 8M21 3v5h-5M3 21v-5h5',
  spark: 'M12 3l1.9 5.1L19 10l-5.1 1.9L12 17l-1.9-5.1L5 10l5.1-1.9zM19 16l.9 2.1L22 19l-2.1.9L19 22l-.9-2.1L16 19l2.1-.9z',
  server: 'M4 4h16v6H4zM4 14h16v6H4zM8 7h.01M8 17h.01',
  box: 'M21 8 12 3 3 8v8l9 5 9-5zM3 8l9 5 9-5M12 13v8',
  layers: 'M12 2 2 7l10 5 10-5zM2 17l10 5 10-5M2 12l10 5 10-5',
  git: 'M6 3v12M18 9a3 3 0 1 0 0-6 3 3 0 0 0 0 6zM6 21a3 3 0 1 0 0-6 3 3 0 0 0 0 6zM18 9a9 9 0 0 1-9 9',
  bell: 'M18 8a6 6 0 0 0-12 0c0 7-3 9-3 9h18s-3-2-3-9M13.7 21a2 2 0 0 1-3.4 0',
  close: 'M18 6 6 18M6 6l12 12',
};

function icon(name, cls) {
  const svg = document.createElementNS(SVG, 'svg');
  svg.setAttribute('viewBox', '0 0 24 24');
  svg.setAttribute('class', 'icon' + (cls ? ' ' + cls : ''));
  svg.setAttribute('aria-hidden', 'true');
  const p = document.createElementNS(SVG, 'path');
  p.setAttribute('d', ICONS[name]);
  svg.append(p);
  return svg;
}

// h('div', {class: 'x', onclick: fn}, 'text', child) builds an element.
function h(tag, props, ...kids) {
  const el = document.createElement(tag);
  for (const [k, v] of Object.entries(props || {})) {
    if (v == null || v === false) continue;
    if (k.startsWith('on')) el.addEventListener(k.slice(2), v);
    else if (k === 'class') el.className = v;
    else if (k === 'style') Object.assign(el.style, v); // CSSOM, which the CSP allows; style attributes it doesn't
    else el.setAttribute(k, v === true ? '' : v);
  }
  el.append(...kids.flat().filter(k => k != null && k !== false));
  return el;
}

const $ = id => document.getElementById(id);
const TABS = ['overview', 'workloads', 'nodes', 'delivery', 'events'];
const state = { ran: false, overview: null, charts: null, pods: null, events: null, tab: 'overview', drawerNS: null, auto: true, timer: null, abort: null, opener: null };

// ---- Formatting --------------------------------------------------------

const nf = new Intl.NumberFormat(undefined, { maximumFractionDigits: 1 });
const fmtCPU = v => (v >= 10 ? nf.format(v) : v.toFixed(2).replace(/\.?0+$/, '') || '0') + (v === 1 ? ' core' : ' cores');
const fmtBytes = v => v >= 2 ** 30 ? nf.format(v / 2 ** 30) + ' Gi' : nf.format(v / 2 ** 20) + ' Mi';
const fmtCount = v => nf.format(v);
const pct = (a, b) => (b > 0 ? Math.min(100, (a / b) * 100) : 0);

function age(seconds) {
  const s = Math.max(0, Math.round(seconds));
  if (s < 60) return s + 's';
  if (s < 3600) return Math.floor(s / 60) + 'm';
  if (s < 86400) return Math.floor(s / 3600) + 'h ' + Math.floor((s % 3600) / 60) + 'm';
  return Math.floor(s / 86400) + 'd ' + Math.floor((s % 86400) / 3600) + 'h';
}
const ago = iso => age((Date.now() - new Date(iso).getTime()) / 1000) + ' ago';

function tone(p) { return p >= 90 ? 'err' : p >= 70 ? 'warn' : ''; }

const CHIP_OK = /^(Running|Completed|Synced|Healthy|True|Ready)$/;
const CHIP_WARN = /^(NotReady|Restarting|Pending|Progressing|OutOfSync|Terminating|ContainerCreating|\w*Pressure|NetworkUnavailable)$/;
const CHIP_ERR = /(BackOff|Error|Failed|Degraded|Missing|Unschedulable|OOMKilled|Evicted|Invalid|ErrImage|CreateContainer|^False$)/;

function statusChip(text, fallback = 'info') {
  const t = String(text || '');
  const c = CHIP_OK.test(t) ? 'ok' : CHIP_WARN.test(t) ? 'warn' : CHIP_ERR.test(t) ? 'err' : fallback;
  return h('span', { class: 'chip ' + c }, t || 'Unknown');
}

// ---- API ---------------------------------------------------------------

async function api(path) {
  const r = await fetch(path, { headers: { Accept: 'application/json' } });
  if (!r.ok) throw new Error((await r.text()).trim() || r.statusText);
  return r.json();
}

// ---- Overview ----------------------------------------------------------

function kpi(iconName, label, value, total, sub, toneName) {
  return h('div', { class: 'kpi' + (toneName ? ' tone-' + toneName : '') },
    h('p', { class: 'label-row' }, icon(iconName), label),
    h('p', { class: 'value' }, value, total != null ? h('small', null, ' / ' + total) : null),
    h('p', { class: 'sub' }, sub || ''));
}

function renderKPIs(o) {
  const t = o.totals;
  const failing = o.namespaces.reduce((n, x) => n + x.failing, 0);
  const warning = o.namespaces.reduce((n, x) => n + x.warning, 0);
  const appProblems = o.problems.filter(p => p.kind === 'Argo CD app');
  $('kpis').replaceChildren(
    kpi('server', 'Nodes ready', t.nodes.good, t.nodes.total, o.version.controlPlane ? 'Kubernetes ' + o.version.controlPlane : '', t.nodes.good < t.nodes.total ? 'err' : 'ok'),
    kpi('box', 'Pods healthy', t.pods.good, t.pods.total, failing + warning ? failing + ' failing · ' + warning + ' warning' : 'All healthy', failing ? 'err' : warning ? 'warn' : 'ok'),
    kpi('layers', 'Deployments available', t.deployments.good, t.deployments.total, t.deployments.total - t.deployments.good ? (t.deployments.total - t.deployments.good) + ' unavailable' : 'All available', t.deployments.good < t.deployments.total ? 'warn' : 'ok'),
    kpi('git', 'Argo CD apps', t.apps.good, t.apps.total, appProblems.length ? appProblems.length + ' need attention' : (t.apps.total ? 'Synced and healthy' : 'None found'), appProblems.some(p => p.severity === 'error') ? 'err' : appProblems.length ? 'warn' : t.apps.total ? 'ok' : ''),
    kpi('bell', 'Warning events', t.warnings, null, 'Kubernetes retains these for about an hour', t.warnings ? 'warn' : 'ok'),
    kpi('refresh', 'Container restarts', t.restarts, null, t.pending ? t.pending + ' pods pending' : 'Since each pod started', t.pending ? 'warn' : ''));
}

function gauge(label, r, fmt, note) {
  const p = pct(r.requested, r.allocatable);
  return h('div', { class: 'gauge' },
    h('div', { class: 'head' }, h('b', null, label), h('span', { class: 'num muted' }, fmt(r.requested) + ' of ' + fmt(r.allocatable) + ' · ' + Math.round(p) + '%')),
    h('div', { class: 'bar ' + tone(p), role: 'img', 'aria-label': label + ' ' + Math.round(p) + '% requested' }, h('span', { style: { width: p + '%' } })),
    note ? h('p', { class: 'muted small' }, note) : null);
}

function renderCapacity(o) {
  const c = o.capacity;
  $('capacity').replaceChildren(
    gauge('CPU', c.cpu, fmtCPU),
    gauge('Memory', c.memory, fmtBytes),
    gauge('Pods', c.pods, fmtCount, 'Requests, not usage. What the scheduler has set aside.'));
  if (o.version.hint) $('capacity').append(h('p', { class: 'version warn small' }, o.version.hint));
}

function renderVersions(o) {
  const v = o.version;
  const nodeVersions = Object.entries(v.nodes || {}).sort();
  $('version').replaceChildren(h('div', { class: 'version' + (v.hint ? ' warn' : '') },
    h('div', { class: 'v' },
      h('span', { class: 'chip info' }, 'Control plane ' + (v.controlPlane || 'unknown')),
      nodeVersions.map(([ver, n]) => h('span', { class: 'chip' }, n + ' node' + (n > 1 ? 's' : '') + ' ' + ver))),
    v.hint ? h('p', { class: 'small', style: { marginTop: '8px' } }, v.hint) : h('p', { class: 'muted small', style: { marginTop: '8px' } }, 'Nodes match the control plane.')));
}

function sparkline(points) {
  const W = 200, H = 56;
  const vals = points.map(p => p[1]);
  const lo = Math.min(...vals), hi = Math.max(...vals);
  const span = hi - lo || 1;
  const t0 = points[0][0], t1 = points[points.length - 1][0] || t0 + 1;
  const xy = ([t, v]) => [((t - t0) / (t1 - t0 || 1)) * W, H - 4 - ((v - lo) / span) * (H - 8)];
  const pts = points.map(xy);
  const svg = document.createElementNS(SVG, 'svg');
  svg.setAttribute('viewBox', `0 0 ${W} ${H}`);
  svg.setAttribute('preserveAspectRatio', 'none');
  svg.setAttribute('role', 'img');
  const area = document.createElementNS(SVG, 'path');
  area.setAttribute('class', 'area');
  area.setAttribute('d', 'M' + pts.map(p => p.join(',')).join('L') + `L${W},${H}L0,${H}Z`);
  const line = document.createElementNS(SVG, 'polyline');
  line.setAttribute('class', 'line');
  line.setAttribute('points', pts.map(p => p.join(',')).join(' '));
  svg.append(area, line);
  return { svg, lo, hi };
}

function renderCharts(c) {
  const box = $('charts');
  if (!c || !c.enabled) {
    box.replaceChildren(h('p', { class: 'empty' }, 'No metrics history. Set PROMETHEUS_URL to chart CPU, memory and restarts here.'));
    return;
  }
  const cards = c.series.filter(s => s.points.length > 1).map(s => {
    const { svg, lo, hi } = sparkline(s.points);
    const last = s.points[s.points.length - 1][1];
    return h('div', { class: 'chart' },
      h('div', { class: 't' }, h('span', { class: 'muted' }, s.title), h('b', null, nf.format(last) + (s.unit || ''))),
      svg,
      h('div', { class: 'range' }, h('span', null, 'low ' + nf.format(lo)), h('span', null, 'high ' + nf.format(hi))));
  });
  box.replaceChildren(...(cards.length ? cards : [h('p', { class: 'empty' }, 'Prometheus returned no data yet.')]));
}

function diagnoseButton(label, target) {
  return h('button', { class: 'btn small', type: 'button', onclick: e => openAssistant(target, e.currentTarget) }, icon('spark'), label || 'Diagnose');
}

function problemTarget(p) {
  const base = { title: p.kind + ' ' + (p.namespace ? p.namespace + '/' : '') + p.name };
  if (p.kind === 'Pod') return { ...base, namespace: p.namespace, pod: p.name, question: `The pod shows ${p.reason}. ${p.detail || ''}`.trim() };
  if (p.kind === 'Argo CD app') return { ...base, namespace: 'argocd', question: `Why is the Argo CD application ${p.name} ${p.reason}? ${p.detail || ''}`.trim() };
  return { ...base, namespace: 'kube-system', question: `The node ${p.name} reports ${p.reason}. ${p.detail || ''}`.trim() };
}

function renderProblems(o) {
  $('problem-count').textContent = o.problems.length;
  if (!o.problems.length) {
    $('problems').replaceChildren(h('p', { class: 'empty' }, 'Nothing needs attention.'));
    return;
  }
  $('problems').replaceChildren(h('ul', { class: 'list' }, o.problems.slice(0, 40).map(p => h('li', { class: 'row-item' },
    icon(p.severity === 'error' ? 'error' : 'alert', 'sev ' + p.severity),
    h('div', { class: 'main' },
      h('div', { class: 'title' }, h('span', { class: 'badge' }, p.kind), h('b', { class: 'mono' }, (p.namespace ? p.namespace + '/' : '') + p.name), statusChip(p.reason)),
      p.detail ? h('p', { class: 'detail', title: p.detail }, p.detail) : null),
    diagnoseButton('Diagnose', problemTarget(p))))));
}

function renderEvents(o) {
  if (!o.events.length) {
    $('events').replaceChildren(h('p', { class: 'empty' }, 'No warning events.'));
    return;
  }
  $('events').replaceChildren(h('ul', { class: 'list' }, o.events.slice(0, 6).map(e => h('li', { class: 'row-item' },
    h('div', { class: 'main' },
      h('div', { class: 'title' }, statusChip(e.reason, 'warn'), h('span', { class: 'mono muted' }, e.namespace + ' · ' + e.object), e.count > 1 ? h('span', { class: 'badge' }, '×' + e.count) : null),
      h('p', { class: 'detail', title: e.message }, e.message)),
    h('span', { class: 'ago' }, ago(e.time))))));
}

function renderNamespaces(o) {
  const q = $('ns-filter').value.trim().toLowerCase();
  const only = $('only-problems').checked;
  const rows = o.namespaces.filter(n => (!q || n.name.toLowerCase().includes(q)) && (!only || n.failing + n.warning > 0));
  if (!rows.length) {
    $('namespaces').replaceChildren(h('p', { class: 'empty' }, 'No namespaces match.'));
    return;
  }
  $('namespaces').replaceChildren(...rows.map(n => {
    const t = n.failing ? 'err' : n.warning ? 'warn' : 'ok';
    return h('button', { class: 'tile tone-' + t, type: 'button', onclick: e => openNamespace(n.name, e.currentTarget) },
      h('span', { class: 'name' }, n.name),
      h('div', { class: 'seg', role: 'img', 'aria-label': `${n.healthy} healthy, ${n.warning} warning, ${n.failing} failing` },
        h('i', { class: 'g', style: { flex: String(n.healthy) } }), h('i', { class: 'w', style: { flex: String(n.warning) } }), h('i', { class: 'e', style: { flex: String(n.failing) } })),
      h('div', { class: 'meta' }, h('span', null, n.pods + (n.pods === 1 ? ' pod' : ' pods') + (n.failing + n.warning ? ' · ' + (n.failing + n.warning) + ' unhealthy' : '')), h('span', null, fmtCPU(n.cpuRequested))),
      h('div', { class: 'meta' }, h('span', null, fmtBytes(n.memoryRequested)), n.restarts ? h('span', null, n.restarts + (n.restarts === 1 ? ' restart' : ' restarts')) : null));
  }));
}

function miniBar(r, fmt) {
  const p = pct(r.requested, r.allocatable);
  return h('td', null, h('div', { class: 'bar ' + tone(p) }, h('span', { style: { width: p + '%' } })), h('div', { class: 'cell-sub' }, fmt(r.requested) + ' / ' + fmt(r.allocatable)));
}

function table(el, headers, rows, emptyText) {
  if (!rows.length) { el.replaceChildren(h('caption', { class: 'empty' }, emptyText)); return; }
  el.replaceChildren(h('thead', null, h('tr', null, headers.map(x => h('th', { scope: 'col' }, x)))), h('tbody', null, rows));
}

function renderNodes(o) {
  table($('nodes'), ['Node', 'Zone · type', 'Version', 'CPU requested', 'Memory requested', 'Pods', 'Age', 'Status'],
    o.nodes.map(n => h('tr', null,
      h('td', null, h('div', { class: 'mono' }, n.name), (n.roles || []).length ? h('div', { class: 'cell-sub' }, n.roles.join(', ')) : null),
      h('td', null, h('div', null, n.zone || '—'), h('div', { class: 'cell-sub' }, n.instanceType || '')),
      h('td', { class: 'mono' }, n.version),
      miniBar(n.cpu, fmtCPU), miniBar(n.memory, fmtBytes), miniBar(n.pods, fmtCount),
      h('td', { class: 'num' }, age(n.ageSeconds)),
      h('td', null, n.ready && !(n.conditions || []).length ? statusChip('Ready') : (n.conditions || []).map(c => statusChip(c.split(':')[0]))))),
    'No nodes.');
}

function renderApps(o) {
  table($('apps'), ['Application', 'Sync', 'Health', 'Revision', 'Namespace', 'Message'],
    o.apps.map(a => h('tr', null,
      h('td', { class: 'mono' }, a.name), h('td', null, statusChip(a.sync)), h('td', null, statusChip(a.health)),
      h('td', { class: 'mono' }, a.revision || '—'), h('td', { class: 'mono' }, a.namespace || '—'),
      h('td', { class: 'wrap muted small', title: a.message }, a.message || ''))),
    'No Argo CD applications found.');
}

function renderPods() {
  const l = state.pods;
  if (!l) return;
  const q = $('pod-filter').value.trim().toLowerCase();
  const only = $('pod-only-problems').checked;
  const rows = l.pods.filter(p => (!only || p.severity !== 'ok') &&
    (!q || [p.namespace, p.name, p.status, p.node].some(x => (x || '').toLowerCase().includes(q))));
  $('pod-count').textContent = rows.length;
  $('pods-note').textContent = l.total > l.pods.length ? `Showing the ${l.pods.length} worst of ${l.total} pods. Use a namespace tile for the rest.` : '';
  table($('pods'), ['Pod', 'Status', 'Ready', 'Restarts', 'Node', 'Age', ''],
    rows.slice(0, 200).map(p => h('tr', null,
      h('td', null,
        h('div', { class: 'mono' }, p.name),
        h('div', { class: 'cell-sub' }, h('button', { class: 'link-btn', type: 'button', onclick: e => openNamespace(p.namespace, e.currentTarget) }, p.namespace),
          p.detail ? [' · ', h('span', { class: 'clamp', title: p.detail }, p.detail)] : null)),
      h('td', null, statusChip(p.status)), h('td', { class: 'num' }, p.ready), h('td', { class: 'num' }, p.restarts),
      h('td', { class: 'mono small' }, p.node || '—'), h('td', { class: 'num' }, age(p.ageSeconds)),
      h('td', null, p.severity !== 'ok' ? diagnoseButton('Diagnose', { title: 'Pod ' + p.namespace + '/' + p.name, namespace: p.namespace, pod: p.name, question: `The pod shows ${p.status}. ${p.detail || ''}`.trim() }) : null))),
    'No pods match.');
}

function renderEventsPage() {
  const l = state.events;
  if (!l) return;
  const q = $('ev-filter').value.trim().toLowerCase();
  const rows = l.events.filter(e => !q || [e.namespace, e.object, e.reason, e.message].some(x => (x || '').toLowerCase().includes(q)));
  $('event-count').textContent = rows.length;
  $('events-note').textContent = l.total > l.events.length ? `Showing the newest ${l.events.length} of ${l.total} warnings.` : '';
  const counts = {};
  for (const e of l.events) counts[e.reason] = (counts[e.reason] || 0) + e.count;
  $('ev-reasons').replaceChildren(...Object.entries(counts).sort((a, b) => b[1] - a[1]).slice(0, 8).map(([reason, n]) => {
    const chip = statusChip(reason, 'warn');
    return h('button', { class: chip.className, type: 'button', 'aria-pressed': String(q === reason.toLowerCase()),
      onclick: () => { $('ev-filter').value = q === reason.toLowerCase() ? '' : reason; renderEventsPage(); } }, reason + ' · ' + n);
  }));
  $('events-all').replaceChildren(rows.length ? h('ul', { class: 'list' }, rows.map(e => h('li', { class: 'row-item' },
    h('div', { class: 'main' },
      h('div', { class: 'title' }, statusChip(e.reason, 'warn'), h('span', { class: 'mono muted' }, e.namespace + ' · ' + e.object), e.count > 1 ? h('span', { class: 'badge' }, '×' + e.count) : null),
      h('p', { class: 'detail', title: e.message }, e.message)),
    h('span', { class: 'ago' }, ago(e.time))))) : h('p', { class: 'empty' }, 'No events match.'));
}

async function loadTabData() {
  try {
    if (state.tab === 'workloads') { state.pods = await api('/api/pods'); renderPods(); }
    if (state.tab === 'events') { state.events = await api('/api/events'); renderEventsPage(); }
  } catch (e) {
    const target = state.tab === 'workloads' ? $('pods') : $('events-all');
    target.replaceChildren(h('p', { class: 'empty' }, e.message));
  }
}

function setBadge(tab, n, toneName) {
  const el = $('badge-' + tab);
  el.hidden = !n;
  el.textContent = n;
  el.className = 'tab-badge' + (toneName ? ' ' + toneName : '');
}

// The header carries the state of the cluster, so a problem is visible from every tab.
function renderChrome(o) {
  const errors = o.problems.filter(p => p.severity === 'error').length;
  const unhealthyPods = o.namespaces.reduce((n, x) => n + x.failing + x.warning, 0);
  const failingPods = o.namespaces.reduce((n, x) => n + x.failing, 0);
  const nodeProblems = o.problems.filter(p => p.kind === 'Node');
  const appProblems = o.problems.filter(p => p.kind === 'Argo CD app');
  setBadge('overview', o.problems.length, errors ? 'err' : 'warn');
  setBadge('workloads', unhealthyPods, failingPods ? 'err' : 'warn');
  setBadge('nodes', nodeProblems.length + (o.version.hint ? 1 : 0), nodeProblems.some(p => p.severity === 'error') ? 'err' : 'warn');
  setBadge('delivery', appProblems.length, appProblems.some(p => p.severity === 'error') ? 'err' : 'warn');
  setBadge('events', o.totals.warnings, 'warn');
  const pill = $('pill');
  pill.hidden = false;
  pill.className = 'pill ' + (errors ? 'err' : o.problems.length ? 'warn' : '');
  pill.replaceChildren(h('span', { class: 'dot' }), o.problems.length ? o.problems.length + ' need attention' : 'All healthy');
}

function render(o) {
  state.overview = o;
  const unhealthy = o.problems.length;
  $('subtitle').textContent = `${o.version.controlPlane ? 'Kubernetes ' + o.version.controlPlane + ' · ' : ''}${o.totals.nodes.total} nodes · ${o.totals.pods.total} pods · ${o.namespaces.length} namespaces` + (unhealthy ? ` · ${unhealthy} need attention` : '');
  state.unhealthy = unhealthy;
  updateTitle();
  renderChrome(o); renderKPIs(o); renderCapacity(o); renderVersions(o); renderProblems(o); renderEvents(o); renderNamespaces(o); renderNodes(o); renderApps(o);
  $('app').setAttribute('aria-busy', 'false');
  $('updated').textContent = 'Updated ' + new Date(o.generatedAt).toLocaleTimeString();
  const banner = $('banner');
  if (o.errors && o.errors.length) { banner.textContent = 'Some data is missing: ' + o.errors.join('; '); banner.className = 'banner warn'; banner.hidden = false; }
  else { banner.hidden = true; banner.className = 'banner'; }
}

let refreshing = false;
async function refresh() {
  if (refreshing) return;
  refreshing = true;
  const spin = $('refresh-icon');
  spin.classList.add('spin');
  try {
    const [o, c] = await Promise.all([api('/api/overview'), api('/api/charts').catch(() => null)]);
    state.charts = c;
    render(o);
    renderCharts(c);
    loadTabData();
    if (state.drawerNS) loadNamespace(state.drawerNS, false);
  } catch (e) {
    const banner = $('banner');
    banner.className = 'banner';
    banner.textContent = (state.overview ? 'Couldn\'t refresh, showing the last data: ' : '') + e.message;
    banner.hidden = false;
    if (!state.overview) $('subtitle').textContent = 'Can\'t reach the cluster';
  } finally {
    refreshing = false;
    spin.classList.remove('spin');
  }
}

function schedule() {
  clearInterval(state.timer);
  if (state.auto) state.timer = setInterval(() => { if (!document.hidden) refresh(); }, 15000);
}

// ---- Namespace drawer --------------------------------------------------

const scrim = $('scrim');
function showScrim() { scrim.hidden = false; }
function hideScrimIfIdle() { if ($('drawer').hidden && $('assistant').hidden) scrim.hidden = true; }

function openDrawer(el, opener) {
  el.hidden = false; showScrim();
  state.opener = opener || state.opener;
  el.querySelector('button.primary, button').focus();
}
function closeDrawer(el) {
  el.hidden = true; hideScrimIfIdle();
  if (state.opener && document.contains(state.opener) && $('drawer').hidden && $('assistant').hidden) state.opener.focus();
}

function openNamespace(name, opener) {
  state.drawerNS = name;
  history.replaceState(null, '', routeHash(state.tab, name));
  $('drawer-title').textContent = name;
  $('drawer-body').replaceChildren(h('p', { class: 'empty' }, 'Loading…'));
  const btn = $('drawer-diagnose');
  btn.replaceChildren(icon('spark'), 'Diagnose namespace');
  btn.onclick = e => openAssistant({ title: 'Namespace ' + name, namespace: name, question: '' }, e.currentTarget);
  openDrawer($('drawer'), opener);
  loadNamespace(name, true);
}

async function loadNamespace(name, first) {
  try {
    const d = await api('/api/namespaces/' + encodeURIComponent(name));
    if (state.drawerNS !== name) return;
    renderNamespaceDetail(d);
  } catch (e) {
    if (first) $('drawer-body').replaceChildren(h('p', { class: 'empty' }, e.message));
  }
}

function renderNamespaceDetail(d) {
  const sections = [];
  if (d.webservices.length) {
    sections.push(h('h3', null, 'WebServices'), h('div', { class: 'table-wrap' }, h('table', null,
      h('tbody', null, d.webservices.map(w => h('tr', null,
        h('td', { class: 'mono' }, w.name), h('td', null, statusChip(w.ready === 'True' ? 'Ready' : w.ready === 'False' ? 'NotReady' : 'Pending')),
        h('td', { class: 'wrap muted small' }, w.message || '')))))));
  }
  if (d.deployments.length) {
    sections.push(h('h3', null, 'Deployments'), h('div', { class: 'table-wrap' }, h('table', null,
      h('tbody', null, d.deployments.map(x => h('tr', null,
        h('td', { class: 'mono' }, x.name),
        h('td', null, statusChip(x.available >= x.desired ? 'Healthy' : 'Progressing')),
        h('td', { class: 'num' }, x.available + ' of ' + x.desired + ' available')))))));
  }
  sections.push(h('h3', null, 'Pods', h('span', { class: 'count' }, d.pods.length)));
  sections.push(d.pods.length ? h('div', { class: 'table-wrap' }, h('table', null,
    h('thead', null, h('tr', null, ['Pod', 'Status', 'Ready', 'Restarts', 'Node', 'Age', ''].map(x => h('th', { scope: 'col' }, x)))),
    h('tbody', null, d.pods.map(p => h('tr', null,
      h('td', null, h('div', { class: 'mono' }, p.name), p.detail ? h('div', { class: 'cell-sub clamp', title: p.detail }, p.detail) : null),
      h('td', null, statusChip(p.status)), h('td', { class: 'num' }, p.ready), h('td', { class: 'num' }, p.restarts),
      h('td', { class: 'mono small' }, p.node || '—'), h('td', { class: 'num' }, age(p.ageSeconds)),
      h('td', null, p.severity !== 'ok' ? diagnoseButton('Diagnose', { title: 'Pod ' + d.name + '/' + p.name, namespace: d.name, pod: p.name, question: `The pod shows ${p.status}. ${p.detail || ''}`.trim() }) : null)))))) : h('p', { class: 'empty' }, 'No pods.'));
  sections.push(h('h3', null, 'Warnings'));
  sections.push(d.events.length ? h('ul', { class: 'list' }, d.events.map(e => h('li', { class: 'row-item' },
    h('div', { class: 'main' }, h('div', { class: 'title' }, statusChip(e.reason, 'warn'), h('span', { class: 'mono muted' }, e.object), e.count > 1 ? h('span', { class: 'badge' }, '×' + e.count) : null), h('p', { class: 'detail', title: e.message }, e.message)),
    h('span', { class: 'ago' }, ago(e.time))))) : h('p', { class: 'empty' }, 'No warnings.'));
  $('drawer-body').replaceChildren(...sections);
}

// ---- Assistant ---------------------------------------------------------

let target = null;

function openAssistant(t, opener) {
  stopRun();
  target = t;
  $('assistant-title').textContent = t.title;
  $('question').value = t.question || '';
  $('timeline').replaceChildren();
  const ans = $('answer'); ans.replaceChildren(); ans.className = 'answer';
  $('usage').textContent = '';
  $('note').hidden = true;
  state.ran = false;
  loadBudget();
  const run = $('run'); run.replaceChildren(icon('spark'), 'Run diagnosis'); run.disabled = false;
  openDrawer($('assistant'), opener);
  $('question').focus();
}

function argsText(input) {
  try { return Object.entries(input || {}).filter(([, v]) => v !== '' && v != null).map(([k, v]) => k + '=' + v).join(' '); } catch { return ''; }
}

async function* sse(resp) {
  const reader = resp.body.getReader();
  const dec = new TextDecoder();
  let buf = '';
  for (;;) {
    const { value, done } = await reader.read();
    if (done) return;
    buf += dec.decode(value, { stream: true });
    let i;
    while ((i = buf.indexOf('\n\n')) >= 0) {
      const frame = buf.slice(0, i); buf = buf.slice(i + 2);
      let ev = 'message', data = '';
      for (const line of frame.split('\n')) {
        if (line.startsWith('event: ')) ev = line.slice(7); else if (line.startsWith('data: ')) data += line.slice(6);
      }
      if (data) yield [ev, JSON.parse(data)];
    }
  }
}

const money = v => '$' + v.toFixed(v < 0.1 ? 3 : 2);

const STOP_NOTES = {
  budget: 'The assistant reached its token budget and answered with what it had found so far. Treat this as partial.',
  max_turns: 'The assistant reached its limit on steps and answered with what it had found so far. Treat this as partial.',
  max_tokens: 'The answer was cut off by its length limit.',
  refusal: 'The model declined to answer this request.',
};

function showOutcome(data, seconds) {
  state.cached = !!data.cached;
  const tools = `${data.steps.length} tool call${data.steps.length === 1 ? '' : 's'}`;
  $('usage').textContent = data.cached
    ? `Answer from ${ago(data.cachedAt)} · no new cost · ${tools}`
    : `${tools} · ${fmtCount(data.inputTokens)} tokens in, ${fmtCount(data.outputTokens)} out · about ${money(data.costUSD)}${data.costKnown ? '' : ' (price of this model not known)'} · ${seconds}s`;
  const note = $('note');
  const text = data.cached ? 'This is a recent answer to the same question. Run a fresh diagnosis if things have changed.' : STOP_NOTES[data.stopped];
  note.hidden = !text;
  note.textContent = text || '';
  note.className = 'note' + (data.cached ? ' info' : '');
}

async function loadBudget() {
  const el = $('budget');
  try {
    const u = await api('/api/usage');
    const cap = u.capUSD > 0 ? ` of ${money(u.capUSD)}` : '';
    el.textContent = `Today: ${money(u.spentUSD)}${cap} · ${u.diagnoses} diagnos${u.diagnoses === 1 ? 'is' : 'es'} · ${u.hourlyUsed} of ${u.hourlyLimit} allowed this hour`;
  } catch { el.textContent = ''; }
}

function stopRun() { if (state.abort) { state.abort.abort(); state.abort = null; } }

function setRunning(on) {
  $('run').hidden = on; $('stop').hidden = !on; $('question').disabled = on;
}

async function runDiagnosis() {
  const timeline = $('timeline'), ans = $('answer');
  timeline.replaceChildren(); ans.replaceChildren(); ans.className = 'answer'; $('usage').textContent = ''; $('note').hidden = true;
  state.cached = false;
  setRunning(true);
  state.abort = new AbortController();
  let current = null;
  const started = Date.now();
  const add = (cls, ...kids) => { const li = h('li', { class: cls }, ...kids); timeline.append(li); return li; };
  try {
    const resp = await fetch('/api/diagnose/stream', {
      method: 'POST', headers: { 'Content-Type': 'application/json' }, signal: state.abort.signal,
      body: JSON.stringify({ namespace: target.namespace, pod: target.pod || '', service: target.service || '', question: $('question').value.trim(), fresh: state.ran }),
    });
    if (!resp.ok) throw new Error((await resp.text()).trim());
    for await (const [ev, data] of sse(resp)) {
      if (ev === 'turn') { if (current) current.remove(); current = add('thinking', h('span', null, data.turn === 1 ? 'Reading the situation…' : 'Thinking about what it found…')); }
      else if (ev === 'tool') { if (current) current.remove(); current = add('running', h('b', { class: 'mono' }, data.tool), h('span', { class: 'args' }, argsText(data.input))); }
      else if (ev === 'step') { if (current) { current.className = data.failed ? 'failed' : ''; current.append(h('span', { class: 'muted small' }, data.failed ? 'failed' : fmtCount(data.bytes) + ' bytes')); current = null; } }
      else if (ev === 'done') {
        if (current) current.remove();
        if (data.answer) { ans.className = 'answer filled'; ans.replaceChildren(...markdown(data.answer)); }
        else { ans.className = 'answer filled error'; ans.textContent = 'No answer (' + (data.stopped || 'unknown') + ').'; }
        showOutcome(data, Math.round((Date.now() - started) / 1000));
      } else if (ev === 'failed') { if (current) current.remove(); ans.className = 'answer filled error'; ans.textContent = data.error; }
    }
  } catch (e) {
    if (current) current.remove();
    if (e.name !== 'AbortError') { ans.className = 'answer filled error'; ans.textContent = e.message; }
    else $('usage').textContent = 'Stopped.';
  } finally {
    state.abort = null; setRunning(false);
    state.ran = true;
    $('run').replaceChildren(icon('spark'), state.cached ? 'Run a fresh diagnosis' : 'Run again');
    loadBudget();
  }
}

// A small markdown reader for the model's answer: headings, lists, fenced
// code, bold and inline code. It builds elements, never HTML.
function inline(text) {
  const out = [];
  const re = /(\*\*[^*]+\*\*|`[^`]+`)/g;
  let last = 0, m;
  while ((m = re.exec(text))) {
    if (m.index > last) out.push(text.slice(last, m.index));
    out.push(m[0].startsWith('**') ? h('b', null, m[0].slice(2, -2)) : h('code', null, m[0].slice(1, -1)));
    last = m.index + m[0].length;
  }
  if (last < text.length) out.push(text.slice(last));
  return out;
}

function markdown(src) {
  const out = [];
  const lines = src.replace(/\r/g, '').split('\n');
  for (let i = 0; i < lines.length;) {
    const line = lines[i];
    if (/^```/.test(line)) {
      const code = []; i++;
      while (i < lines.length && !/^```/.test(lines[i])) code.push(lines[i++]);
      i++; out.push(h('pre', null, h('code', null, code.join('\n')))); continue;
    }
    const head = /^#{1,4}\s+(.*)/.exec(line);
    if (head) { out.push(h('h4', null, inline(head[1]))); i++; continue; }
    if (/^\s*([-*]|\d+\.)\s+/.test(line)) {
      const ordered = /^\s*\d+\./.test(line), items = [];
      while (i < lines.length && /^\s*([-*]|\d+\.)\s+/.test(lines[i])) items.push(h('li', null, inline(lines[i++].replace(/^\s*([-*]|\d+\.)\s+/, ''))));
      out.push(h(ordered ? 'ol' : 'ul', null, items)); continue;
    }
    if (!line.trim()) { i++; continue; }
    const para = [];
    while (i < lines.length && lines[i].trim() && !/^(```|#{1,4}\s|\s*([-*]|\d+\.)\s+)/.test(lines[i])) para.push(lines[i++]);
    out.push(h('p', null, inline(para.join(' '))));
  }
  return out;
}

// ---- Tabs and routing --------------------------------------------------
// The address says where you are: #/nodes, or #/workloads?ns=shop for a
// namespace open on top. Links to either can be shared.

function routeHash(tab, ns) { return '#/' + tab + (ns ? '?ns=' + encodeURIComponent(ns) : ''); }

function parseRoute() {
  const legacy = /^#ns=(.+)$/.exec(location.hash);
  if (legacy) return { tab: 'workloads', ns: decodeURIComponent(legacy[1]) };
  const m = /^#\/([a-z]+)(?:\?ns=(.+))?$/.exec(location.hash);
  return { tab: m && TABS.includes(m[1]) ? m[1] : 'overview', ns: m && m[2] ? decodeURIComponent(m[2]) : null };
}

function showTab(tab) {
  state.tab = tab;
  for (const t of TABS) {
    const selected = t === tab;
    const button = $('tab-' + t);
    button.setAttribute('aria-selected', String(selected));
    button.tabIndex = selected ? 0 : -1;
    $('panel-' + t).hidden = !selected;
  }
  updateTitle();
}

function updateTitle() {
  document.title = (state.unhealthy ? `(${state.unhealthy}) ` : '') + 'Cluster dashboard · ' + state.tab[0].toUpperCase() + state.tab.slice(1);
}

function applyRoute() {
  const { tab, ns } = parseRoute();
  showTab(tab);
  loadTabData();
  if (ns && state.drawerNS !== ns) openNamespace(ns);
  else if (!ns && state.drawerNS) { $('drawer-close').click(); }
}

function initTabs() {
  const buttons = TABS.map(t => $('tab-' + t));
  buttons.forEach((b, i) => {
    b.addEventListener('click', () => { location.hash = routeHash(b.dataset.tab); });
    b.addEventListener('keydown', e => {
      const next = { ArrowRight: (i + 1) % buttons.length, ArrowLeft: (i + buttons.length - 1) % buttons.length, Home: 0, End: buttons.length - 1 }[e.key];
      if (next == null) return;
      e.preventDefault();
      buttons[next].focus();
      location.hash = routeHash(buttons[next].dataset.tab);
    });
  });
  window.addEventListener('hashchange', applyRoute);
}

// ---- Start -------------------------------------------------------------

function init() {
  const spinner = document.createElementNS(SVG, 'path');
  spinner.setAttribute('d', ICONS.refresh);
  $('refresh-icon').append(spinner);
  $('drawer-close').append(icon('close')); $('assistant-close').append(icon('close'));
  $('refresh').addEventListener('click', refresh);
  $('auto').addEventListener('change', e => { state.auto = e.target.checked; schedule(); });
  $('ns-filter').addEventListener('input', () => state.overview && renderNamespaces(state.overview));
  $('only-problems').addEventListener('change', () => state.overview && renderNamespaces(state.overview));
  $('pod-filter').addEventListener('input', renderPods);
  $('pod-only-problems').addEventListener('change', renderPods);
  $('ev-filter').addEventListener('input', renderEventsPage);
  $('drawer-close').addEventListener('click', () => { state.drawerNS = null; history.replaceState(null, '', routeHash(state.tab)); closeDrawer($('drawer')); });
  $('assistant-close').addEventListener('click', () => { stopRun(); closeDrawer($('assistant')); });
  $('run').addEventListener('click', runDiagnosis);
  $('stop').addEventListener('click', stopRun);
  $('question').addEventListener('keydown', e => { if (e.key === 'Enter' && (e.metaKey || e.ctrlKey)) runDiagnosis(); });
  scrim.addEventListener('click', () => ($('assistant').hidden ? $('drawer-close') : $('assistant-close')).click());
  document.addEventListener('keydown', e => {
    if (e.key !== 'Escape') return;
    if (!$('assistant').hidden) $('assistant-close').click(); else if (!$('drawer').hidden) $('drawer-close').click();
  });
  initTabs();
  const first = parseRoute();
  showTab(first.tab);
  refresh();
  schedule();
  if (first.ns) openNamespace(first.ns);
}

init();
