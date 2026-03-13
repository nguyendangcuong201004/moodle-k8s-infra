import http from 'k6/http';
import { check, sleep } from 'k6';

const BASE_URL = __ENV.BASE_URL;

// Peak users for this scenario (target of ramp-up / hold).
const PEAK_VUS = Number(__ENV.TARGET_VUS || 20);

// Ramp-up, hold, ramp-down durations; sum ~2m by default.
const RAMP_UP = __ENV.RAMP_UP || '40s';
const HOLD = __ENV.HOLD || '40s';
const RAMP_DOWN = __ENV.RAMP_DOWN || '40s';

export const options = {
  stages: [
    { duration: RAMP_UP, target: PEAK_VUS },
    { duration: HOLD, target: PEAK_VUS },
    { duration: RAMP_DOWN, target: 0 },
  ],
};

export default function () {
  const home = http.get(`${BASE_URL}/`, { tags: { name: 'home' } });
  check(home, { 'home status 200': (r) => r.status === 200 });

  const login = http.get(`${BASE_URL}/login/index.php`, { tags: { name: 'login' } });
  check(login, { 'login status 200': (r) => r.status === 200 });

  sleep(1);
}
