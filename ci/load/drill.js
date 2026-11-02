// SPDX-License-Identifier: AGPL-3.0-only
// Load of ci/scale-drill.sh, from a pod of the release namespace to the server's Service (ClusterIP, no DNS).
// MODE=steady: RATE requests/s for DURATION (a version rollout runs meanwhile).
// MODE=peak: from 10 to RATE requests/s in RAMP, held for DURATION (the HPA must follow).
// The last line of the output is the summary, one JSON object after "DRILL-SUMMARY ".
import http from 'k6/http';
import { check } from 'k6';

const rate = Number(__ENV.RATE || 50);
const duration = __ENV.DURATION || '120s';
const scenario = __ENV.MODE === 'peak'
  ? {
      executor: 'ramping-arrival-rate', startRate: 10, timeUnit: '1s',
      preAllocatedVUs: 50, maxVUs: 400,
      stages: [{ target: rate, duration: __ENV.RAMP || '30s' }, { target: rate, duration }],
    }
  : {
      executor: 'constant-arrival-rate', rate, timeUnit: '1s', duration,
      preAllocatedVUs: 50, maxVUs: 400,
    };

export const options = {
  scenarios: { drill: scenario },
  summaryTrendStats: ['avg', 'med', 'p(95)', 'p(99)', 'max'],
  noConnectionReuse: false,
};

export default function () {
  const res = http.get(`${__ENV.TARGET}/api/v1/instance`, { timeout: '10s' });
  check(res, { 'status 200': (r) => r.status === 200 });
}

export function handleSummary(data) {
  const m = data.metrics;
  const out = {
    requests: m.http_reqs ? m.http_reqs.values.count : 0,
    failed: m.http_req_failed ? m.http_req_failed.values.passes : 0,
    dropped: m.dropped_iterations ? m.dropped_iterations.values.count : 0,
    p95: m.http_req_duration ? m.http_req_duration.values['p(95)'] : null,
    p99: m.http_req_duration ? m.http_req_duration.values['p(99)'] : null,
    max: m.http_req_duration ? m.http_req_duration.values.max : null,
  };
  return { stdout: `DRILL-SUMMARY ${JSON.stringify(out)}\n` };
}
