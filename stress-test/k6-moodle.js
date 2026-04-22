import http from 'k6/http';
import { check, sleep } from 'k6';

const BASE_URL = __ENV.BASE_URL;
const MAX_FAIL_RATE = Number(__ENV.MAX_FAIL_RATE || 0.02);
const MAX_P95_MS = Number(__ENV.MAX_P95_MS || 2000);
const ABORT_DELAY = __ENV.ABORT_DELAY || '0s';
const MAX_REDIRECTS = Number(__ENV.MAX_REDIRECTS || 5);
const HTTP_TIMEOUT = __ENV.HTTP_TIMEOUT || '12s';
const HOST_MAP = __ENV.HOST_MAP || '';

function isOkOrRedirect(status) {
  return status === 200 || status === 301 || status === 302 || status === 303;
}

function parseStaircasePlan(rawPlan) {
  const fallback = [
    { duration: '10s', target: 50 },
    { duration: '45s', target: 50 },
    { duration: '10s', target: 100 },
    { duration: '45s', target: 100 },
  ];

  if (!rawPlan || String(rawPlan).trim() === '') {
    return fallback;
  }

  const stages = [];
  for (const part of String(rawPlan).split(',')) {
    const item = part.trim();
    if (!item) continue;

    const fields = item.split(':');
    if (fields.length !== 2) {
      continue;
    }

    const duration = fields[0].trim();
    const target = Number(fields[1].trim());
    if (!duration || Number.isNaN(target) || target < 0) {
      continue;
    }
    stages.push({ duration, target });
  }

  return stages.length > 0 ? stages : fallback;
}

function parseHostsMap(rawMap) {
  const hosts = {};
  if (!rawMap || String(rawMap).trim() === '') {
    return hosts;
  }

  for (const part of String(rawMap).split(',')) {
    const item = part.trim();
    if (!item) continue;

    const fields = item.split('=');
    if (fields.length !== 2) continue;

    const host = fields[0].trim();
    const ip = fields[1].trim();
    if (!host || !ip) continue;
    hosts[host] = ip;
  }
  return hosts;
}

const STAGES = parseStaircasePlan(__ENV.STAIRCASE_PLAN);
const HOSTS = parseHostsMap(HOST_MAP);

export const options = {
  scenarios: {
    staircase: {
      executor: 'ramping-vus',
      startVUs: 0,
      stages: STAGES,
      gracefulRampDown: '0s',
    },
  },
  hosts: HOSTS,
  thresholds: {
    http_req_failed: [
      { threshold: `rate<=${MAX_FAIL_RATE}`, abortOnFail: true, delayAbortEval: ABORT_DELAY },
    ],
    http_req_duration: [
      { threshold: `p(95)<=${MAX_P95_MS}`, abortOnFail: true, delayAbortEval: ABORT_DELAY },
    ],
  },
};

export default function () {
  const reqParams = {
    tags: { name: 'home' },
    redirects: MAX_REDIRECTS,
    timeout: HTTP_TIMEOUT,
  };
  const home = http.get(`${BASE_URL}/`, reqParams);
  check(home, {
    'home status 2xx/3xx': (r) => isOkOrRedirect(r.status),
    'home no redirect loop': (r) => r.status !== 0,
  });

  const login = http.get(`${BASE_URL}/login/index.php`, {
    tags: { name: 'login' },
    redirects: MAX_REDIRECTS,
    timeout: HTTP_TIMEOUT,
  });
  check(login, {
    'login status 2xx/3xx': (r) => isOkOrRedirect(r.status),
    'login no redirect loop': (r) => r.status !== 0,
  });

  sleep(1);
}
