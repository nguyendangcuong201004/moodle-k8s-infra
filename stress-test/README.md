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
  - `STEP_RAMP`, `STEP_HOLD`
  - `MAX_P95_MS`, `MAX_FAIL_RATE`, `ABORT_DELAY`
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

Default staircase profile currently starts at `50` VUs and increases by `50` each step
(`50 -> 100 -> 150 -> ...`) until `MAX_VUS`.

### Example: AWS EKS / ALB

```bash
cd moodle-k8s-infra
BASE_URL="https://your-aws-alb-dns.example.com" ./run-stress-test.sh
```

## Behavior

- Script chạy **1 lần duy nhất** theo kiểu staircase (tăng tải theo bậc).
- Không có pha giảm user dần (không ramp-down).
- Khi vượt ngưỡng SLA, k6 sẽ **abort ngay lập tức** (không chờ chạy vòng tiếp).

## How to interpret result

- `Status: PASS to MAX_VUS`: chưa vượt ngưỡng tới mức cao nhất đã cấu hình.
- `Status: ABORTED on first threshold breach`: đã chạm giới hạn và dừng ngay.
- Detailed outputs are stored in `results/` (summary + log của một lần chạy).

## Notes

- This script tests anonymous browsing endpoints only.
- If you need authenticated-user scenarios (real login, course view, quiz submit), extend `k6-moodle.js` with login flow and session handling.

