/**
 * Moodle staircase load test (k6).
 *
 * auth_quiz: real session cookies; POST login; POST processattempt writes quiz state like a browser. No dry-run.
 * Flow: / → login → course → quiz → startattempt → processattempt → summary → quiz view.
 *
 * COURSE_PATH, QUIZ_PATH — see env below. THINK_* — set min=max=0 to go fast.
 */

import http from 'k6/http';
import { check, sleep } from 'k6';

const BASE_URL      = __ENV.BASE_URL || 'http://moodle.moodle:80';
const MAX_FAIL_RATE = Number(__ENV.MAX_FAIL_RATE || 0.02);
const MAX_P95_MS    = Number(__ENV.MAX_P95_MS || 2500);
const ABORT_DELAY   = __ENV.ABORT_DELAY || '0s';
const MAX_REDIRECTS = Number(__ENV.MAX_REDIRECTS || 10);
const HTTP_TIMEOUT  = __ENV.HTTP_TIMEOUT || '60s';
const PROFILE       = (__ENV.PROFILE || 'mixed').toLowerCase();
const COURSE_PATH   = __ENV.COURSE_PATH || '/course/view.php?id=2';
const QUIZ_PATH     = __ENV.QUIZ_PATH || '/mod/quiz/view.php?id=1';
const AUTH_USER_PREFIX = __ENV.AUTH_USER_PREFIX || 'user';
const AUTH_USER_START = Number(__ENV.AUTH_USER_START || 1);
const AUTH_USER_COUNT = Number(__ENV.AUTH_USER_COUNT || 100);
const AUTH_USER_PASSWORD = __ENV.AUTH_USER_PASSWORD || '123456';
const QUIZ_DO_SUBMIT = (__ENV.QUIZ_DO_SUBMIT || 'true').toLowerCase() === 'true';
const QUIZ_TEXT_ANSWER = __ENV.QUIZ_TEXT_ANSWER || '2';
const QUIZ_TEXT_ANSWERS_RAW = (__ENV.QUIZ_TEXT_ANSWERS || '2,4,8').trim();

function envThinkMinMax(prefix, defMin, defMax) {
  const mn = Number(__ENV[`${prefix}_MIN_SEC`] ?? defMin);
  const mx = Number(__ENV[`${prefix}_MAX_SEC`] ?? defMax);
  return {
    min: Number.isFinite(mn) ? mn : defMin,
    max: Number.isFinite(mx) ? mx : defMax,
  };
}

function sleepThinkRange(range) {
  let { min, max } = range;
  if (max < min) [min, max] = [max, min];
  if (max <= 0) return;
  const sec = min + Math.random() * (max - min);
  sleep(sec);
}

const THINK_HOME       = envThinkMinMax('THINK_AFTER_HOME', 0, 0.3);
const THINK_LOGIN      = envThinkMinMax('THINK_AFTER_LOGIN', 0.3, 1.5);
const THINK_COURSE     = envThinkMinMax('THINK_AFTER_COURSE', 0.3, 1.5);
const THINK_QUIZ_VIEW   = envThinkMinMax('THINK_AFTER_QUIZ_VIEW', 0.5, 2);
const THINK_BEFORE_SUBMIT = envThinkMinMax('THINK_BEFORE_SUBMIT', 1, 4);
const THINK_AFTER_SUMMARY = envThinkMinMax('THINK_AFTER_SUMMARY', 0.2, 0.8);
const THINK_ITERATION   = envThinkMinMax('THINK_ITERATION', 2, 8);

const usersCsvRaw = (__ENV.LOGIN_USERS_CSV || '').trim();
const AUTH_USERS = usersCsvRaw
  ? usersCsvRaw
      .split('\n')
      .map((line) => line.trim())
      .filter((line) => line && !line.startsWith('#'))
      .map((line) => {
        const parts = line.split(',');
        if (parts.length < 2) return null;
        return { username: parts[0].trim(), password: parts[1].trim() };
      })
      .filter((x) => x && x.username && x.password)
  : [];

function quizAnswerList() {
  if (!QUIZ_TEXT_ANSWERS_RAW) return [QUIZ_TEXT_ANSWER];
  return QUIZ_TEXT_ANSWERS_RAW.split(',').map((s) => s.trim()).filter(Boolean);
}

function getGeneratedAuthUser(vu) {
  if (Number.isNaN(AUTH_USER_COUNT) || AUTH_USER_COUNT <= 0) return null;
  const normalizedStart = Number.isNaN(AUTH_USER_START) ? 1 : AUTH_USER_START;
  const offset = (vu - 1) % AUTH_USER_COUNT;
  const id = normalizedStart + offset;
  const suffix = String(id).padStart(4, '0');
  return { username: `${AUTH_USER_PREFIX}${suffix}`, password: AUTH_USER_PASSWORD };
}

/** Treat all redirects 301–308 as success (older checks sometimes missed 307/308). */
function isOkOrRedirect(status) {
  return status >= 200 && status <= 399;
}

function parseStaircasePlan(raw) {
  const fallback = [
    { duration: '15s', target: 10 },
    { duration: '45s', target: 10 },
    { duration: '15s', target: 25 },
    { duration: '45s', target: 25 },
  ];
  if (!raw || String(raw).trim() === '') return fallback;

  const stages = [];
  for (const part of String(raw).split(',')) {
    const [duration, targetRaw] = part.trim().split(':');
    const target = Number(targetRaw);
    if (duration && !Number.isNaN(target) && target >= 0) {
      stages.push({ duration: duration.trim(), target });
    }
  }
  return stages.length > 0 ? stages : fallback;
}

export const options = {
  scenarios: {
    staircase: {
      executor: 'ramping-vus',
      startVUs: 0,
      stages: parseStaircasePlan(__ENV.STAIRCASE_PLAN),
      gracefulRampDown: '0s',
    },
  },
  discardResponseBodies: false,
  thresholds: {
    http_req_failed: [
      { threshold: `rate<=${MAX_FAIL_RATE}`, abortOnFail: true, delayAbortEval: ABORT_DELAY },
    ],
    http_req_duration: [
      { threshold: `p(95)<=${MAX_P95_MS}`, abortOnFail: true, delayAbortEval: ABORT_DELAY },
    ],
  },
};

function probe(path, tag) {
  const res = http.get(`${BASE_URL}${path}`, {
    tags: { name: tag },
    redirects: MAX_REDIRECTS,
    timeout: HTTP_TIMEOUT,
  });
  check(res, {
    [`${tag} status ok`]: (r) => isOkOrRedirect(r.status),
    [`${tag} no timeout`]: (r) => r.status !== 0,
  });
}

function extractLogintoken(body) {
  const m = body.match(/name="logintoken"\s+value="([^"]+)"/i);
  return m ? m[1] : '';
}

function decodeHtml(str) {
  return String(str || '')
    .replace(/&amp;/g, '&')
    .replace(/&quot;/g, '"')
    .replace(/&#039;/g, "'")
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>');
}

function extractHiddenInputs(html) {
  const inputs = {};
  const re = /<input[^>]*type="hidden"[^>]*>/gi;
  let m;
  while ((m = re.exec(html)) !== null) {
    const tag = m[0];
    const name = tag.match(/name="([^"]+)"/i)?.[1];
    const value = decodeHtml(tag.match(/value="([^"]*)"/i)?.[1] || '');
    if (name) inputs[name] = value;
  }
  return inputs;
}

function extractTextInputNames(html) {
  const names = [];
  const re = /<input[^>]*type=["']text["'][^>]*name=["']([^"']+)["']/gi;
  let m;
  while ((m = re.exec(html)) !== null) {
    names.push(m[1]);
  }
  return names;
}

function pickFirstRadioOrSelect(html) {
  const radio = html.match(/<input[^>]*type="radio"[^>]*name="([^"]+)"[^>]*value="([^"]+)"/i);
  if (radio) return { name: radio[1], value: decodeHtml(radio[2]) };
  const select = html.match(/<select[^>]*name="([^"]+)"[\s\S]*?<option[^>]*value="([^"]+)"/i);
  if (select) return { name: select[1], value: decodeHtml(select[2]) };
  return null;
}

function mergeAnswersIntoForm(html, hiddenBase) {
  const answers = quizAnswerList();
  const textNames = extractTextInputNames(html);
  const out = { ...hiddenBase };
  if (textNames.length > 0) {
    textNames.forEach((name, i) => {
      const v = answers[i] !== undefined ? answers[i] : answers[answers.length - 1] || QUIZ_TEXT_ANSWER;
      out[name] = v;
    });
    return out;
  }
  const radioSel = pickFirstRadioOrSelect(html);
  if (radioSel) {
    out[radioSel.name] = radioSel.value;
    return out;
  }
  return out;
}

function absoluteUrl(maybeRelative) {
  if (!maybeRelative) return '';
  if (maybeRelative.startsWith('http://') || maybeRelative.startsWith('https://')) return maybeRelative;
  if (maybeRelative.startsWith('/')) return `${BASE_URL}${maybeRelative}`;
  return `${BASE_URL}/${maybeRelative}`;
}

function extractFormAction(html) {
  const m = html.match(/<form[^>]*id="responseform"[^>]*action="([^"]+)"/i)
    || html.match(/<form[^>]*action="([^"]*processattempt\.php[^"]*)"/i);
  return m ? absoluteUrl(decodeHtml(m[1])) : absoluteUrl('/mod/quiz/processattempt.php');
}

function extractStartAttemptUrl(html) {
  const m = html.match(/href="([^"]*\/mod\/quiz\/startattempt\.php[^"]*)"/i);
  return m ? absoluteUrl(decodeHtml(m[1])) : '';
}

function cmidFromQuizPath(quizPath) {
  const m = quizPath.match(/[?&]id=(\d+)/);
  return m ? m[1] : '';
}

/** Browser-like path: home → login → course → quiz → attempt → summary → quiz. */
function journeyQuizUser(user) {
  const getOpts = {
    redirects: MAX_REDIRECTS,
    timeout: HTTP_TIMEOUT,
    responseType: 'text',
  };

  const homeRes = http.get(`${BASE_URL}/`, {
    tags: { name: 'home' },
    ...getOpts,
  });
  check(homeRes, {
    'home ok': (r) => isOkOrRedirect(r.status),
  });
  sleepThinkRange(THINK_HOME);

  const loginPage = http.get(`${BASE_URL}/login/index.php`, {
    tags: { name: 'login_page' },
    ...getOpts,
  });
  const token = extractLogintoken(loginPage.body || '');
  check(loginPage, {
    'login_page ok': (r) => isOkOrRedirect(r.status),
    'login_page has token': () => token.length > 0,
  });

  const loginRes = http.post(
    `${BASE_URL}/login/index.php`,
    {
      username: user.username,
      password: user.password,
      logintoken: token,
      anchor: '',
    },
    {
      tags: { name: 'login_submit' },
      redirects: MAX_REDIRECTS,
      timeout: HTTP_TIMEOUT,
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      responseType: 'text',
    }
  );

  check(loginRes, {
    'login_submit ok': (r) => isOkOrRedirect(r.status),
    'login_submit no timeout': (r) => r.status !== 0,
  });

  sleepThinkRange(THINK_LOGIN);

  const courseRes = http.get(`${BASE_URL}${COURSE_PATH}`, {
    tags: { name: 'course_view' },
    ...getOpts,
  });
  check(courseRes, {
    'course_view ok': (r) => isOkOrRedirect(r.status),
  });

  sleepThinkRange(THINK_COURSE);

  const quizRes = http.get(`${BASE_URL}${QUIZ_PATH}`, {
    tags: { name: 'quiz_view' },
    ...getOpts,
  });
  check(quizRes, {
    'quiz_view ok': (r) => isOkOrRedirect(r.status),
    'quiz_view no timeout': (r) => r.status !== 0,
  });

  sleepThinkRange(THINK_QUIZ_VIEW);

  if (!QUIZ_DO_SUBMIT) return;

  const startUrl = extractStartAttemptUrl(quizRes.body || '');
  check(quizRes, {
    'quiz page has startattempt link': () => startUrl.length > 0,
  });
  if (!startUrl) return;

  const attemptPage = http.get(startUrl, {
    tags: { name: 'quiz_attempt' },
    ...getOpts,
  });
  check(attemptPage, {
    'quiz_attempt ok': (r) => isOkOrRedirect(r.status),
  });

  sleepThinkRange(THINK_BEFORE_SUBMIT);

  const hidden = extractHiddenInputs(attemptPage.body || '');
  const merged = mergeAnswersIntoForm(attemptPage.body || '', hidden);
  merged.finishattempt = '1';
  merged.timeup = '0';

  const attemptId = String(merged.attempt || hidden.attempt || '');
  const cmid = cmidFromQuizPath(QUIZ_PATH);

  const processUrl = extractFormAction(attemptPage.body || '');
  const processRes = http.post(processUrl, merged, {
    tags: { name: 'quiz_processattempt' },
    redirects: MAX_REDIRECTS,
    timeout: HTTP_TIMEOUT,
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    responseType: 'text',
  });
  check(processRes, {
    'processattempt ok': (r) => isOkOrRedirect(r.status),
  });

  if (attemptId && cmid) {
    const summaryUrl = `${BASE_URL}/mod/quiz/summary.php?attempt=${attemptId}&cmid=${cmid}`;
    const summaryRes = http.get(summaryUrl, {
      tags: { name: 'quiz_summary' },
      ...getOpts,
    });
    check(summaryRes, {
      'quiz_summary ok': (r) => isOkOrRedirect(r.status),
    });
    sleepThinkRange(THINK_AFTER_SUMMARY);
  }

  const quizAgain = http.get(`${BASE_URL}${QUIZ_PATH}`, {
    tags: { name: 'quiz_view_return' },
    ...getOpts,
  });
  check(quizAgain, {
    'quiz_view_return ok': (r) => isOkOrRedirect(r.status),
  });
}

export default function () {
  if (PROFILE === 'home') {
    probe('/', 'home');
    sleep(1);
  } else if (PROFILE === 'login') {
    probe('/login/index.php', 'login');
    sleep(1);
  } else if (PROFILE === 'auth_quiz') {
    const user =
      AUTH_USERS.length > 0
        ? AUTH_USERS[(__VU - 1) % AUTH_USERS.length]
        : getGeneratedAuthUser(__VU);
    if (!user) {
      probe('/login/index.php', 'login');
      sleepThinkRange(THINK_ITERATION);
      return;
    }
    journeyQuizUser(user);
    sleepThinkRange(THINK_ITERATION);
  } else {
    probe('/', 'home');
    probe('/login/index.php', 'login');
    sleep(1);
  }
}

export function handleSummary(data) {
  return {
    stdout:
      '\n===K6_SUMMARY_BEGIN===\n' +
      JSON.stringify(data) +
      '\n===K6_SUMMARY_END===\n',
  };
}
