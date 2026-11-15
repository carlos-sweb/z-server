# hello-jwt

A standalone consumer example demonstrating **JSON Web Token (JWT) authentication** via the `z_server_jwt` module, featuring the **OAuth Client Credentials flow** (API Key to JWT exchange via `POST /token`) combined with `z_server_auth`.

> **Auth Note**: JWT + API Key dual auth. See [hello-auth](../hello-auth) for API Key only.

---

## Architecture

- **`z_server_jwt`**: Issues and verifies HS256 JWTs with constant-time validation and SQLite/Pogocache-backed `jti` denylist.
- **`z_server_auth`**: Provisions API keys (Client ID / Client Secret credentials) using HMAC-SHA256 with pepper.
- **`POST /token`**: Validates an incoming API Key and exchanges it for a 15-minute signed JWT with matching scopes.
- **`GET /whoami`**: Protected route requiring a valid JWT with the `read:whoami` scope.

---

## Quickstart

### 1. Set secrets in environment

```bash
export Z_SERVER_AUTH_PEPPER=$(openssl rand -hex 32)
export Z_SERVER_JWT_SECRET=$(openssl rand -hex 32)
```

### 2. Build the binary

```bash
zig build -Doptimize=ReleaseFast
```

### 3. Generate an API Key via CLI

```bash
API_KEY=$(./zig-out/bin/hello-jwt create-key --name "ci" --scopes "read:whoami")
echo "Created API Key: $API_KEY"
```

### 4. Start the server

```bash
./zig-out/bin/hello-jwt &
PID=$!
```

### 5. Verify public `/health`

```bash
curl -s http://127.0.0.1:9000/health | jq .
# -> {"ok":true}
```

### 6. Verify unauthenticated `/whoami` fails

```bash
curl -si http://127.0.0.1:9000/whoami | head -3
# -> HTTP/1.1 401 Unauthorized
```

### 7. Exchange API Key for JWT (`POST /token`)

```bash
TOKEN=$(curl -s -X POST http://127.0.0.1:9000/token \
  -H "Authorization: Bearer $API_KEY" | jq -r .token)
echo "JWT Token: $TOKEN"
```

### 8. Access `/whoami` with the issued JWT

```bash
curl -s -H "Authorization: Bearer $TOKEN" http://127.0.0.1:9000/whoami | jq .
# -> {"sub":"ci","scopes":"read:whoami","jti":"..."}
```

### 9. Clean up

```bash
kill $PID
```
