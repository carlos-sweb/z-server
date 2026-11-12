import http from 'k6/http';
import { check, sleep } from 'k6';
import { Counter, Trend } from 'k6/metrics';
import exec from 'k6/execution';
import {
  arrivalRate,
  gaussThink,
  identityRanges,
  loadConfig,
  pickOp,
  profiles,
  profileOrder,
  splitVus,
} from './config.js';

const cfg = loadConfig();
const vuShares = splitVus(cfg.maxVus);
const ranges = identityRanges(cfg.users);

const holdSec = Math.max(1, cfg.durationSec - cfg.rampUpSec);

function scenarioSpec(name) {
  const rate = Math.max(1, Math.ceil(arrivalRate(cfg.users, name, vuShares[name])));
  const vus = vuShares[name];
  return {
    executor: 'ramping-arrival-rate',
    exec: name,
    timeUnit: '1s',
    startRate: 0,
    preAllocatedVUs: vus,
    maxVUs: vus,
    gracefulStop: '15s',
    tags: { profile: name },
    stages: [
      { duration: `${cfg.rampUpSec}s`, target: rate },
      { duration: `${holdSec}s`, target: rate },
    ],
  };
}

export const options = {
  insecureSkipTLSVerify: true,
  discardResponseBodies: false,
  summaryTrendStats: ['min', 'avg', 'med', 'p(90)', 'p(95)', 'p(99)', 'p(99.9)', 'max', 'count'],
  thresholds: {
    // Realistic for a 16-conn SQLite pool on localhost. Failures are reported,
    // not aborted — the 5 min run must finish so analysis.md can show the dip.
    'http_req_failed': [{ threshold: 'rate<0.05', abortOnFail: false }],
    'dur_list': [{ threshold: 'p(99)<100', abortOnFail: false }],
    'dur_get': [{ threshold: 'p(99)<100', abortOnFail: false }],
    'dur_health': [{ threshold: 'p(99)<100', abortOnFail: false }],
    'dur_post': [{ threshold: 'p(99)<500', abortOnFail: false }],
    'dur_put': [{ threshold: 'p(99)<500', abortOnFail: false }],
    'dur_delete': [{ threshold: 'p(99)<500', abortOnFail: false }],
    checks: [{ threshold: 'rate>0.95', abortOnFail: false }],
  },
  scenarios: {
    lurker: scenarioSpec('lurker'),
    casual: scenarioSpec('casual'),
    power: scenarioSpec('power'),
    editor: scenarioSpec('editor'),
  },
};

http.setResponseCallback(http.expectedStatuses({ min: 200, max: 299 }, 404));

const durHealth = new Trend('dur_health', true);
const durList = new Trend('dur_list', true);
const durGet = new Trend('dur_get', true);
const durPost = new Trend('dur_post', true);
const durPut = new Trend('dur_put', true);
const durDelete = new Trend('dur_delete', true);
const cacheHits = new Counter('cache_hits');
const cacheMisses = new Counter('cache_misses');
const status503 = new Counter('status_503');
const statusErr = new Counter('status_err');

const trends = {
  health: durHealth,
  list: durList,
  get: durGet,
  post: durPost,
  put: durPut,
  del: durDelete,
};

// Per-VU state (survives iterations of this VU, not shared).
const vu = {
  ready: false,
  users: null,
  rr: 0,
};

function headers() {
  return { 'Content-Type': 'application/json', Accept: 'application/json' };
}

function ownIdentities(profileName) {
  const range = ranges[profileName];
  const nVus = vuShares[profileName];
  const slot = (exec.vu.idInInstance - 1) % nVus;
  const ids = [];
  for (let i = slot; i < range.count; i += nVus) {
    ids.push(range.start + i);
  }
  if (ids.length === 0 && range.count > 0) ids.push(range.start);
  return ids;
}

function ensureVu(profileName) {
  if (vu.ready) return;
  const ids = ownIdentities(profileName);
  vu.users = ids.map((id) => ({
    id,
    items: [],
    seq: 0,
    bootstrapped: false,
    cleaned: false,
  }));
  vu.ready = true;
}

function nextUser(profileName) {
  ensureVu(profileName);
  const u = vu.users[vu.rr % vu.users.length];
  vu.rr += 1;
  return u;
}

function taskName(user) {
  user.seq += 1;
  return `todo/${user.id}/${user.seq}`;
}

function taskPayload(user, extra) {
  const due = 1735689600 + (user.id % 86400);
  const body = {
    done: false,
    priority: (user.id % 3) + 1,
    tags: ['loadtest', `u${user.id % 17}`],
    due_date: due,
    notes: `user ${user.id}`,
  };
  if (extra) {
    for (const k of Object.keys(extra)) body[k] = extra[k];
  }
  return body;
}

function record(res, op) {
  trends[op].add(res.timings.duration);
  if (res.status === 503) {
    status503.add(1);
    statusErr.add(1);
  } else if (res.status === 0 || res.status >= 400) {
    if (res.status !== 404) statusErr.add(1);
  }
  if (op === 'get') {
    const x = res.headers['X-Cache'] || res.headers['x-cache'] || '';
    if (x === 'HIT') cacheHits.add(1);
    else if (x === 'MISS') cacheMisses.add(1);
  }
}

function bootstrap(user) {
  const n = 1 + Math.floor(Math.random() * 3);
  for (let i = 0; i < n; i++) postItem(user);
  user.bootstrapped = true;
}

function maybeCleanup(user) {
  if (user.cleaned) return false;
  if (exec.scenario.progress < 0.95) return false;
  user.cleaned = true;
  if (user.items.length > 0) delItem(user);
  return true;
}

function postItem(user) {
  if (user.items.length >= cfg.maxItemsPerUser) return putItem(user);
  const payload = JSON.stringify({ name: taskName(user), payload: taskPayload(user) });
  const res = http.post(`${cfg.baseUrl}/items`, payload, {
    headers: headers(),
    tags: { name: 'POST /items', endpoint: 'POST /items' },
  });
  record(res, 'post');
  const ok = check(res, {
    'POST 201 or 503': (r) => r.status === 201 || r.status === 503,
  });
  if (ok && res.status === 201) {
    try {
      const body = res.json();
      if (body && body.id !== undefined) user.items.push(Number(body.id));
    } catch (e) {
      // ignore parse errors; counted via checks/status
    }
  }
  return res;
}

function listItems() {
  const res = http.get(`${cfg.baseUrl}/items`, {
    headers: headers(),
    tags: { name: 'GET /items', endpoint: 'GET /items' },
  });
  record(res, 'list');
  check(res, {
    'GET /items 200 or 503': (r) => r.status === 200 || r.status === 503,
  });
  return res;
}

function getItem(user) {
  if (user.items.length === 0) return listItems();
  const id = user.items[Math.floor(Math.random() * user.items.length)];
  const res = http.get(`${cfg.baseUrl}/items/${id}`, {
    headers: headers(),
    tags: { name: 'GET /items/:id', endpoint: 'GET /items/:id' },
  });
  record(res, 'get');
  check(res, {
    'GET :id 200/404/503': (r) => r.status === 200 || r.status === 404 || r.status === 503,
  });
  // One named check per header value (only the matching name is recorded, so
  // the other does not fail). analyze.sh reads these from k6-summary.json.
  const xcache = res.headers['X-Cache'] || res.headers['x-cache'] || '';
  if (xcache === 'HIT') check(res, { 'X-Cache HIT': () => true });
  else if (xcache === 'MISS') check(res, { 'X-Cache MISS': () => true });
  return res;
}

function putItem(user) {
  if (user.items.length === 0) return postItem(user);
  const id = user.items[Math.floor(Math.random() * user.items.length)];
  const payload = JSON.stringify({
    name: taskName(user),
    payload: taskPayload(user, { done: Math.random() < 0.5 }),
  });
  const res = http.put(`${cfg.baseUrl}/items/${id}`, payload, {
    headers: headers(),
    tags: { name: 'PUT /items/:id', endpoint: 'PUT /items/:id' },
  });
  record(res, 'put');
  check(res, {
    'PUT 200/404/503': (r) => r.status === 200 || r.status === 404 || r.status === 503,
  });
  return res;
}

function delItem(user) {
  if (user.items.length === 0) return postItem(user);
  const idx = Math.floor(Math.random() * user.items.length);
  const id = user.items[idx];
  const res = http.del(`${cfg.baseUrl}/items/${id}`, null, {
    headers: headers(),
    tags: { name: 'DELETE /items/:id', endpoint: 'DELETE /items/:id' },
  });
  record(res, 'del');
  check(res, {
    'DELETE 204/404/503': (r) => r.status === 204 || r.status === 404 || r.status === 503,
  });
  if (res.status === 204 || res.status === 404) {
    user.items.splice(idx, 1);
  }
  return res;
}

function health() {
  const res = http.get(`${cfg.baseUrl}/health`, {
    headers: headers(),
    tags: { name: 'GET /health', endpoint: 'GET /health' },
  });
  record(res, 'health');
  check(res, {
    'GET /health 200 or 503': (r) => r.status === 200 || r.status === 503,
  });
  return res;
}

function act(profileName) {
  const user = nextUser(profileName);
  if (!user.bootstrapped) bootstrap(user);
  if (maybeCleanup(user)) {
    sleep(gaussThink(profiles[profileName].think));
    return;
  }
  let op = pickOp(profileName);
  if (op === 'post' && user.items.length >= cfg.maxItemsPerUser) {
    op = Math.random() < 0.5 ? 'put' : 'del';
  }
  switch (op) {
    case 'list':
      listItems();
      break;
    case 'get':
      getItem(user);
      break;
    case 'post':
      postItem(user);
      break;
    case 'put':
      putItem(user);
      break;
    case 'del':
      delItem(user);
      if (exec.scenario.progress < 0.95) postItem(user);
      break;
    case 'health':
      health();
      break;
    default:
      listItems();
  }
  sleep(gaussThink(profiles[profileName].think));
}

export function lurker() {
  act('lurker');
}
export function casual() {
  act('casual');
}
export function power() {
  act('power');
}
export function editor() {
  act('editor');
}

export function setup() {
  const res = http.get(`${cfg.baseUrl}/health`);
  if (res.status !== 200) {
    throw new Error(`z-server not healthy at ${cfg.baseUrl}/health (status ${res.status})`);
  }
  return {
    users: cfg.users,
    durationSec: cfg.durationSec,
    maxVus: cfg.maxVus,
    vuShares,
    rates: Object.fromEntries(
      profileOrder.map((n) => [n, arrivalRate(cfg.users, n, vuShares[n])]),
    ),
  };
}
