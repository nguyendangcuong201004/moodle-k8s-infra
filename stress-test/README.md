## Moodle Capacity Test (k6)

This folder contains a basic capacity test for Moodle running on any Kubernetes cluster (DigitalOcean, AWS, etc.). The only required input is the public Moodle URL (domain or load balancer address).

## Files

- `k6-moodle.js`: k6 scenario that repeatedly requests:
  - `/`
  - `/login/index.php`
  (used by the main `run-stress-test.sh` at repo root)

## Prerequisites

- `k6`
- `jq`
- Reachable Moodle URL (LoadBalancer DNS/IP)

## Quick Start

1. Mở file `stress-params.env` trong thư mục này và chỉnh các tham số:
   - `START_VUS`, `STEP_VUS`, `MAX_VUS`
   - `TEST_DURATION`, `MAX_P95_MS`, `MAX_FAIL_RATE`, `COOLDOWN_SEC`
2. Đảm bảo file `.env` ở repo root có `MOODLE_WWWROOT` trỏ đến domain Moodle.
3. Chạy:

```bash
cd moodle-k8s-infra/stress-test
./run-stress-test.sh
```

## Optional tuning

Các tham số mặc định nằm trong `stress-params.env`. Chỉ cần sửa file đó rồi chạy `run-stress-test.sh` là đủ. 

### Example: DigitalOcean K8s (DOKS)

```bash
cd moodle-k8s-infra
./run-stress-test.sh
```

### Example: AWS EKS / ALB

```bash
cd moodle-k8s-infra
BASE_URL="https://your-aws-alb-dns.example.com" ./run-stress-test.sh
```

## How to interpret result

- `Estimated max stable capacity`: highest concurrent users that still passed SLA.
- `First failing level`: first user level where failure rate or latency crossed threshold.
- Detailed outputs are stored in `results/`.

## Notes

- This script tests anonymous browsing endpoints only.
- If you need authenticated-user scenarios (real login, course view, quiz submit), extend `k6-moodle.js` with login flow and session handling.

