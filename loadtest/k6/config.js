// Load-test knobs. CLI/env from run.sh override the defaults.
//
// Think times are short so k6 can hit 0 dropped iterations: arrival is capped
// at vuShare / (think.mean + 1s HTTP budget). 500 RPS in the previous cutre
// run was a (server + client + think) ceiling, not the server's.

export const defaults = {
  users: 10000,
  durationSec: 300,
  rampUpSec: 60,
  maxVus: 200,
  baseUrl: 'http://127.0.0.1:8080',
  maxItemsPerUser: 50,
};

export const profiles = {
  lurker: {
    weight: 0.4,
    think: { min: 8, max: 30, mean: 15, sigma: 4 },
    ops: [
      { op: 'list', p: 0.8 },
      { op: 'get', p: 0.15 },
      { op: 'health', p: 0.05 },
    ],
  },
  casual: {
    weight: 0.35,
    think: { min: 2, max: 6, mean: 3.5, sigma: 1 },
    ops: [
      { op: 'list', p: 0.5 },
      { op: 'get', p: 0.3 },
      { op: 'post', p: 0.15 },
      { op: 'put', p: 0.04 },
      { op: 'del', p: 0.01 },
    ],
  },
  power: {
    weight: 0.2,
    think: { min: 0.5, max: 2, mean: 1, sigma: 0.3 },
    ops: [
      { op: 'list', p: 0.3 },
      { op: 'get', p: 0.3 },
      { op: 'post', p: 0.25 },
      { op: 'put', p: 0.12 },
      { op: 'del', p: 0.03 },
    ],
  },
  editor: {
    weight: 0.05,
    think: { min: 1, max: 4, mean: 2, sigma: 0.8 },
    ops: [
      { op: 'list', p: 0.2 },
      { op: 'get', p: 0.2 },
      { op: 'post', p: 0.1 },
      { op: 'put', p: 0.3 },
      { op: 'del', p: 0.2 },
    ],
  },
};

export const profileOrder = ['lurker', 'casual', 'power', 'editor'];

export function envNumber(name, fallback) {
  const raw = __ENV[name];
  if (raw === undefined || raw === '') return fallback;
  const n = Number(raw);
  return Number.isFinite(n) ? n : fallback;
}

export function envString(name, fallback) {
  const raw = __ENV[name];
  return raw === undefined || raw === '' ? fallback : raw;
}

export function parseDurationSec(raw, fallback) {
  if (raw === undefined || raw === '') return fallback;
  const m = String(raw).trim().match(/^([0-9]+(?:\.[0-9]+)?)(ms|s|m|h)?$/);
  if (!m) return fallback;
  const n = Number(m[1]);
  switch (m[2] || 's') {
    case 'ms':
      return n / 1000;
    case 's':
      return n;
    case 'm':
      return n * 60;
    case 'h':
      return n * 3600;
    default:
      return fallback;
  }
}

export function loadConfig() {
  return {
    users: Math.max(1, Math.floor(envNumber('USERS', defaults.users))),
    durationSec: Math.max(1, parseDurationSec(__ENV.DURATION, defaults.durationSec)),
    rampUpSec: Math.max(0, parseDurationSec(__ENV.RAMP_UP, defaults.rampUpSec)),
    maxVus: Math.max(4, Math.floor(envNumber('MAX_VUS', defaults.maxVus))),
    baseUrl: envString('BASE_URL', defaults.baseUrl).replace(/\/$/, ''),
    maxItemsPerUser: defaults.maxItemsPerUser,
  };
}

/** Integer VU shares that sum to maxVus. */
export function splitVus(maxVus) {
  const shares = {};
  let left = maxVus;
  for (let i = 0; i < profileOrder.length; i++) {
    const name = profileOrder[i];
    if (i === profileOrder.length - 1) {
      shares[name] = Math.max(1, left);
    } else {
      const n = Math.max(1, Math.floor(maxVus * profiles[name].weight));
      shares[name] = n;
      left -= n;
    }
  }
  return shares;
}

/** Identity ranges: lurker 0..nL-1, casual next, … covering [0, users). */
export function identityRanges(users) {
  const ranges = {};
  let start = 0;
  for (let i = 0; i < profileOrder.length; i++) {
    const name = profileOrder[i];
    const n =
      i === profileOrder.length - 1
        ? Math.max(0, users - start)
        : Math.max(1, Math.floor(users * profiles[name].weight));
    ranges[name] = { start, count: n };
    start += n;
  }
  return ranges;
}

/**
 * Arrival rate (iterations/s). Cap leaves 1s of HTTP budget per VU so k6
 * does not drop iterations when sleep(think) + request overlap.
 */
export function arrivalRate(users, profileName, vuShare) {
  const p = profiles[profileName];
  const desired = (users * p.weight) / p.think.mean;
  const cap = vuShare / p.think.mean;
  return Math.max(0.1, Math.min(desired, cap));
}

/** Box–Muller gaussian, clipped to [min, max]. */
export function gaussThink(think) {
  let u = 0;
  let v = 0;
  while (u === 0) u = Math.random();
  while (v === 0) v = Math.random();
  const z = Math.sqrt(-2 * Math.log(u)) * Math.cos(2 * Math.PI * v);
  const x = think.mean + z * think.sigma;
  if (x < think.min) return think.min;
  if (x > think.max) return think.max;
  return x;
}

export function pickOp(profileName) {
  const ops = profiles[profileName].ops;
  let r = Math.random();
  for (const row of ops) {
    r -= row.p;
    if (r <= 0) return row.op;
  }
  return ops[ops.length - 1].op;
}
