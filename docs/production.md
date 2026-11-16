# Production Deployment Checklist

This guide provides operational hardening instructions for running `z-server` in production Linux environments.

## 1. Secrets and Key Management

Never store cryptographic secrets, peppers, or private signing keys in `config.json` or source control.

### Secret Pepper for API Key HMAC
Generate a 64-character (32-byte) hex string:
```bash
export Z_SERVER_AUTH_PEPPER=$(openssl rand -hex 32)
```
- Store this value in your production secrets manager (e.g. AWS Secrets Manager, HashiCorp Vault, systemd credential storage).
- The pepper must never change once API keys are issued; rotating the pepper invalidates all existing issued API keys.

### JWT Signing Secret
Generate a separate 64-character hex secret for signing HS256 tokens:
```bash
export Z_SERVER_JWT_SECRET=$(openssl rand -hex 32)
```

### File Permissions
Restrict configuration file access so only the service user can read it:
```bash
chmod 600 /etc/z-server/config.json
chown zserver:zserver /etc/z-server/config.json
```

## 2. Operating System and Kernel Tuning

### File Descriptor Limits (`nofile`)
High-concurrency servers require more open file descriptors than the Linux default (1024). Configure systemd or `/etc/security/limits.conf`:

```ini
# In systemd service unit:
LimitNOFILE=65535
```

Or verify with:
```bash
ulimit -n 65535
```

### Kernel TCP Tuning (`sysctl`)
Add the following settings to `/etc/sysctl.d/99-zserver.conf`:
```ini
# Increase listen backlog for burst connections
net.core.somaxconn = 4096

# Allow fast recycling of TIME_WAIT sockets
net.ipv4.tcp_tw_reuse = 1

# Expand ephemeral port range
net.ipv4.ip_local_port_range = 1024 65535
```
Apply immediately:
```bash
sysctl --system
```

### Shared Memory for SQLite WAL
SQLite WAL mode creates `-shm` index files that map into shared memory. Ensure `/dev/shm` is mounted with read/write access:
```bash
df -h /dev/shm
```

## 3. Reverse Proxy and TLS Architecture

### Native TLS vs Reverse Proxy
`z-server` embeds BearSSL with hardened TLS 1.2 (ECDHE + ChaCha20-Poly1305 / AES-GCM). It does not require a reverse proxy for TLS termination if HTTP/1.1 is sufficient.

- **Direct Native TLS:** Use native `z_server_tls` for lean deployments with zero extra processes.
- **Reverse Proxy (Caddy / Cloudflare):** Place Caddy or Cloudflare in front if you require HTTP/2, HTTP/3, or automated Let's Encrypt ACME renewal.

### Certificate Storage
- Store private keys in `/etc/ssl/private/` with permissions `600`.
- Never commit TLS certificates or private keys to git repositories.

## 4. SQLite WAL Maintenance and Hot Backups

### Non-blocking Online Backups
Because `z-server` uses WAL mode with `PRAGMA synchronous = NORMAL`, online database backups can be taken safely without interrupting active write transactions.

Create a daily backup cron script:
```bash
#!/usr/bin/env bash
set -euo pipefail
BACKUP_DIR="/var/backups/z-server"
mkdir -p "$BACKUP_DIR"
sqlite3 /var/lib/z-server/app.db ".backup ${BACKUP_DIR}/app-$(date +%F).db"
find "$BACKUP_DIR" -type f -name "app-*.db" -mtime +14 -delete
```

Schedule daily execution at 03:00 AM via cron:
```cron
0 3 * * * /usr/local/bin/backup-z-server.sh
```

### Automatic WAL Checkpointing
`z-server` leaves SQLite's default passive checkpointing active. SQLite automatically checkpoints the WAL file when it reaches 1000 pages (~4 MB). No manual `PRAGMA wal_checkpoint` invocation is needed under normal operation.

## 5. Metrics and Monitoring

Enable the Prometheus endpoint in `config.json` and restrict exposure:

```json
{
  "metrics": {
    "enabled": true,
    "path": "/metrics",
    "require_auth": false,
    "allowed_cidrs": ["10.0.0.0/8", "127.0.0.1/32"]
  }
}
```

### Suggested Prometheus Alert Rules

```yaml
groups:
  - name: zserver_alerts
    rules:
      - alert: HighAuthFailureRate
        expr: rate(auth_failures_total[5m]) > 10
        for: 2m
        labels:
          severity: warning
        annotations:
          summary: "Possible credential stuffing or brute force attack detected"

      - alert: SQLitePoolContention
        expr: rate(sqlite_busy_count_total[5m]) > 1
        for: 1m
        labels:
          severity: critical
        annotations:
          summary: "SQLite connection pool experiencing busy lock contention"

      - alert: HighRateLimitRejection
        expr: rate(ratelimit_rejected_total[5m]) > 50
        for: 2m
        labels:
          severity: warning
        annotations:
          summary: "High volume of rate limited requests"
```

## 6. Rate Limiting Strategy

Protect public endpoints against denial of service and scrape loops:
- Apply strict limits (e.g., 30 requests/minute per client IP) on unauthenticated routes (`/health`, `/token`).
- Apply higher token capacity (e.g., 60-120 requests/minute) on authenticated routes (`/items/*`) keyed by API Key or JWT subject.
- Ensure reverse proxies forward the original client IP in `X-Forwarded-For` or `X-Real-IP`.

## 7. Logging and Data Privacy

In `config.json`, configure:
```json
{
  "logging": {
    "level": "info"
  }
}
```
- Never set `logging.level` to `"debug"` in production environments.
- `z-server` redacts authorization headers automatically. Ensure any custom upstream proxies also sanitize `Authorization` and `X-API-Key` headers before persisting access logs.

## 8. Deployment Strategies

### systemd Service Unit

Create `/etc/systemd/system/z-server.service`:

```ini
[Unit]
Description=z-server high-performance API service
After=network.target

[Service]
Type=simple
User=zserver
Group=zserver
WorkingDirectory=/var/lib/z-server
ExecStart=/usr/local/bin/z-server --config /etc/z-server/config.json
Restart=on-failure
RestartSec=5s

# Security and Sandbox Hardening
LimitNOFILE=65535
ProtectSystem=full
ProtectHome=true
NoNewPrivileges=true
PrivateTmp=true

# Secrets passed via environment
EnvironmentFile=/etc/z-server/environment

[Install]
WantedBy=multi-user.target
```

### Minimal Static Docker Image

Because `z-server` is compiled as a static `x86_64-linux-musl` binary with zero runtime shared libraries, it can run in an empty `scratch` container image (<5 MB total):

```dockerfile
FROM scratch
COPY zig-out/bin/z-server /z-server
COPY certs/ca-certificates.crt /etc/ssl/certs/
EXPOSE 8080 8443
ENTRYPOINT ["/z-server"]
```
This compares favorably to Node.js/Bun runtimes requiring 200+ MB container layers.
