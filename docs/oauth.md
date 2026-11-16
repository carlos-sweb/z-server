# OAuth 2.0 Client Credentials Grant (`POST /auth/token`)

The `z_server_token` module implements the OAuth 2.0 Client Credentials Grant defined in [RFC 6749 §4.4](https://datatracker.ietf.org/doc/html/rfc6749#section-4.4). It allows clients to exchange long-lived API keys for short-lived, signed JWT access tokens (default 900 seconds / 15 minutes).

---

## Architecture & Integration

`z_server_token` orchestrates `z_server_auth` (API key verification) and `z_server_jwt` (HS256 JWT issuance) while remaining cleanly decoupled:

```
+------------------------------------------------------------------------+
| Client Request: POST /auth/token                                      |
| Headers: Authorization: Bearer <api_key> (or X-API-Key)                |
| Body: {"grant_type": "client_credentials", "scope": "..."}             |
+------------------------------------------------------------------------+
                               |
                               v
                     [ Rate Limit by IP ] (30 req/min)
                               |
                               v
               [ Validate API Key (z_server_auth) ]
                               |
                               v
                   [ Rate Limit by API Key ID ] (60 req/min)
                               |
                               v
           [ Validate Downscoping (requested ⊆ granted) ]
                               |
                               v
                 [ Issue HS256 JWT (z_server_jwt) ]
                               |
                               v
+------------------------------------------------------------------------+
| 200 OK                                                                 |
| Cache-Control: no-store, Pragma: no-cache                              |
| {"access_token": "...", "token_type": "Bearer", "expires_in": 900}     |
+------------------------------------------------------------------------+
```

---

## Endpoint Contract

- **Endpoint**: `POST /auth/token` (configurable via `token.endpoint_path`)
- **Authentication**: Accepts API key via:
  1. `Authorization: Bearer <zs_live_... | zs_test_...>`
  2. `X-API-Key: <key>`
  3. JSON body `{"api_key": "<key>", ...}`
- **Request Body (JSON)**:
  - `grant_type` *(string, optional)*: Must be `"client_credentials"`. Defaults to `"client_credentials"` if omitted.
  - `scope` *(string, optional)*: Space- or comma-separated list of scopes to request. Must be a subset of the API key's assigned scopes (downscoping). Defaults to inheriting all scopes of the API key.

---

## RFC 6749 Compliance Notes

1. **Client Credentials Grant (§4.4)**: Authorizes confidential clients directly using client credentials (API keys).
2. **Scope Downscoping (§4.4.2)**: Clients may request a smaller set of permissions than the full set permitted by the API key. If any requested scope exceeds what the key possesses, the server rejects the request with HTTP 400 and `error: invalid_scope`.
3. **No Refresh Tokens (§4.4.3)**: Per RFC 6749 §4.4.3, a refresh token is not emitted for the Client Credentials grant since the client can directly request a new access token using its API key.
4. **Cache Prevention (§5.1)**: Responses include `Cache-Control: no-store` and `Pragma: no-cache` headers.
5. **Standardized Error Format (§5.2)**: Error responses return JSON containing `{"error": "<error_code>"}`.

---

## Rate Limiting Behavior

The token endpoint features built-in dual-tier rate limiting:
- **Per IP**: 30 requests per minute.
- **Per API Key**: 60 requests per minute.

### Implementation:
- **Storage**:
  - When `z_server_cache` (Pogocache) is available, counts are tracked in cache with keys formatted as `ratelimit:<scope>:<id>:<bucket>`.
  - When cache is null, an in-memory `std.AutoHashMap` fallback is used with thread-safe locking and periodic cleanup (entries expired past 60s are purged).
- **Algorithm**: Fixed window with 60-second buckets (`window_s = 60`).
- **Limitation**: As with standard fixed window algorithms, a client may burst up to 2x the limit across the boundary of two consecutive windows (e.g., at second 59 and second 61). For higher precision, global sliding window rate limiting is recommended.

When a client exceeds the limit:
- Status: `429 Too Many Requests`
- Header: `Retry-After: 60`
- Body: `{"error":"rate_limited"}`

---

## Curl Examples

### 1. Successful Token Exchange (200 OK)

```bash
curl -s -X POST http://127.0.0.1:8080/auth/token \
  -H "Authorization: Bearer $KEY" \
  -H "Content-Type: application/json" \
  -d '{"grant_type":"client_credentials"}' | jq .
```

Response:
```json
{
  "access_token": "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...",
  "token_type": "Bearer",
  "expires_in": 900,
  "scope": "items:read items:write"
}
```

### 2. Scope Downscoping (200 OK)

Request a token with only `items:read` when the API key has `items:read items:write`:

```bash
curl -s -X POST http://127.0.0.1:8080/auth/token \
  -H "Authorization: Bearer $KEY" \
  -H "Content-Type: application/json" \
  -d '{"grant_type":"client_credentials", "scope":"items:read"}' | jq .
```

Response:
```json
{
  "access_token": "...",
  "token_type": "Bearer",
  "expires_in": 900,
  "scope": "items:read"
}
```

### 3. Invalid Scope (400 Bad Request)

Requesting scopes not granted to the API key:

```bash
curl -si -X POST http://127.0.0.1:8080/auth/token \
  -H "Authorization: Bearer $KEY" \
  -H "Content-Type: application/json" \
  -d '{"scope":"admin:drop"}'
```

Response:
```http
HTTP/1.1 400 Bad Request
Content-Type: application/json;charset=UTF-8

{"error":"invalid_scope"}
```

### 4. Unsupported Grant Type (400 Bad Request)

```bash
curl -si -X POST http://127.0.0.1:8080/auth/token \
  -H "Authorization: Bearer $KEY" \
  -H "Content-Type: application/json" \
  -d '{"grant_type":"password"}'
```

Response:
```http
HTTP/1.1 400 Bad Request
Content-Type: application/json;charset=UTF-8

{"error":"unsupported_grant_type"}
```

### 5. Missing or Invalid Client Credentials (401 Unauthorized)

```bash
curl -si -X POST http://127.0.0.1:8080/auth/token \
  -d '{}'
```

Response:
```http
HTTP/1.1 401 Unauthorized
WWW-Authenticate: Bearer realm="z-server", error="invalid_client"
Content-Type: application/json;charset=UTF-8

{"error":"invalid_client"}
```

### 6. Rate Limit Exceeded (429 Too Many Requests)

```bash
for i in $(seq 1 35); do
  curl -s -o /dev/null -w "%{http_code}\n" \
    -X POST http://127.0.0.1:8080/auth/token \
    -H "Authorization: Bearer $KEY"
done
```

Response starting from the 31st request:
```http
HTTP/1.1 429 Too Many Requests
Retry-After: 60
Content-Type: application/json;charset=UTF-8

{"error":"rate_limited"}
```

---

## Token Revocation via CLI

To immediately revoke a token before its expiration, extract the `jti` from the token and use the `revoke-jwt` subcommand:

```bash
# Decode JWT payload to get jti
JTI=$(echo "$TOKEN" | cut -d. -f2 | base64 -d 2>/dev/null | jq -r .jti)

# Revoke via CLI
./zig-out/bin/z-server revoke-jwt "$JTI"
# Output: revoked jti: <jti>
```

The `jti` is inserted into SQLite table `revoked_jwt` and cached in Pogocache. Subsequent API calls with this token are rejected with `HTTP 401 Unauthorized`.
