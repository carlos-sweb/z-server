# Metrics with `z_server_metrics`

`z_server_metrics` provides Prometheus-compatible application observability for `z-server` and downstream applications. It exposes metrics in the standard **Prometheus Text 0.0.4** exposition format, prevents label cardinality explosion via per-handler pattern wrapping, and collects atomic counters across core modules without locks in the request hot path.

## 11 Core Metrics

| Metric | Type | Labels | Description |
|---|---|---|---|
| `http_requests_total` | Counter | `method`, `path`, `status` | Total HTTP requests processed (status grouped by `2xx`, `3xx`, `4xx`, `5xx`, `other`) |
| `http_request_duration_seconds` | Histogram | `method`, `path`, `le` | Request duration in seconds (buckets: 1ms, 5ms, 10ms, 25ms, 50ms, 100ms, 250ms, 500ms, 1s, 2.5s, 5s, `+Inf`), plus `_sum` and `_count` |
| `http_requests_in_flight` | Gauge | — | Current number of concurrent HTTP requests being processed |
| `sqlite_busy_count_total` | Counter | — | Total count of `SQLITE_BUSY` and `SQLITE_BUSY_TIMEOUT` events |
| `sqlite_query_duration_seconds` | Histogram | `query_type` | Duration of SQLite queries by type (`select`, `insert`, `update`, `delete`) |
| `cache_hits_total` | Counter | — | Total cache hits in Pogocache |
| `cache_misses_total` | Counter | — | Total cache misses in Pogocache |
| `auth_failures_total` | Counter | `reason` | Authentication failures (`missing`, `invalid_key`, `expired`, `revoked`) |
| `jwt_validations_total` | Counter | `result` | JWT token validation outcomes (`valid`, `invalid_sig`, `expired`, `denylist`) |
| `ratelimit_rejected_total` | Counter | `policy` | Rate-limited requests (HTTP 429) grouped by policy (`ip`, `key`, `global`) |
| `process_start_time_seconds` | Gauge | — | Process start timestamp in Unix epoch seconds |
| `process_uptime_seconds` | Gauge | — | Process uptime in seconds |

> [!NOTE]
> If an optional module (`db`, `cache`, `auth`, `jwt`, `ratelimit`) is not enabled in the application, its corresponding metrics are omitted from `/metrics`.

## Route Wrapping (`wrap`)

To avoid cardinality explosion from dynamic URL path parameters (e.g., `/items/12345` vs `/items/98765`), `z_server_metrics` uses per-handler wrapping with explicit route patterns:

```zig
const z_metrics = @import("z_server_metrics");

// Freestanding handlers:
.{
    .method = .GET,
    .path = "/health",
    .handler = z_metrics.wrap("/health", healthHandler),
}

// Parametric route patterns:
.{
    .method = .GET,
    .path = "/items/:id",
    .handler = z_metrics.wrap("/items/:id", getItemHandler),
}
```

The route pattern `/items/:id` is registered once and all requests map to that metric label without string allocations during request processing.

## `/metrics` Endpoint Output Example

```text
# HELP http_requests_total Total HTTP requests processed
# TYPE http_requests_total counter
http_requests_total{method="GET",path="/health",status="2xx"} 5

# HELP http_request_duration_seconds HTTP request latency histogram
# TYPE http_request_duration_seconds histogram
http_request_duration_seconds_bucket{method="GET",path="/health",le="0.001"} 5
http_request_duration_seconds_bucket{method="GET",path="/health",le="0.005"} 5
...
http_request_duration_seconds_bucket{method="GET",path="/health",le="+Inf"} 5
http_request_duration_seconds_sum{method="GET",path="/health"} 0.000320
http_request_duration_seconds_count{method="GET",path="/health"} 5

# HELP http_requests_in_flight Current number of HTTP requests being processed
# TYPE http_requests_in_flight gauge
http_requests_in_flight 0

# HELP process_start_time_seconds Start time of the process since Unix epoch in seconds
# TYPE process_start_time_seconds gauge
process_start_time_seconds 1794793600

# HELP process_uptime_seconds Number of seconds since process start
# TYPE process_uptime_seconds gauge
process_uptime_seconds 42
```

## Configuration (`config.json`)

To enable Prometheus metrics in `z-server`:

```json
{
  "$schema_version": 2,
  "server": {
    "bind": "127.0.0.1:8080"
  },
  "metrics": {
    "enabled": true,
    "path": "/metrics",
    "require_auth": false,
    "allowed_cidrs": [
      "127.0.0.1/32",
      "10.0.0.0/8"
    ]
  }
}
```

- `enabled`: Activates route registration and registry wiring. When `false`, `/metrics` returns 404.
- `path`: Custom endpoint path (default: `"/metrics"`).
- `require_auth`: If `true`, requires Bearer token authentication with scope `metrics:read`.
- `allowed_cidrs`: Optional IPv4 CIDR allowlist. If non-empty, requests from unauthorized IPs receive HTTP 403 Forbidden.

## Prometheus Scrape Configuration

Add the scrape target to your `prometheus.yml`:

```yaml
scrape_configs:
  - job_name: "z-server"
    scrape_interval: 15s
    static_configs:
      - targets: ["127.0.0.1:8080"]
    metrics_path: "/metrics"
```
