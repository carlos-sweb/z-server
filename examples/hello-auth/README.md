# hello-auth

Minimal example demonstrating `z_server_auth` integration with `z_server`, `z_server_db`, `z_server_cache`, and `z_server_config`.

## Features Demonstrated

- **Public Endpoint**: `GET /health` is unauthenticated.
- **Protected Endpoint**: `GET /whoami` requires `Authorization: Bearer <key>` with scope `read:whoami`.
- **CLI Subcommand**: Generate API keys directly via `./hello-auth create-key`.

## Building

```bash
zig build -Doptimize=ReleaseFast
```

## Running

1. **Set Pepper**:
   ```bash
   export Z_SERVER_AUTH_PEPPER="0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
   ```

2. **Generate an API Key**:
   ```bash
   ./zig-out/bin/hello-auth create-key --name "test" --scopes "read:whoami" > /tmp/key.txt
   cat /tmp/key.txt
   # Output: zs_live_<random_43_chars>_<crc32_6chars>
   ```

3. **Start the Server**:
   ```bash
   ./zig-out/bin/hello-auth
   ```

4. **Test Endpoints**:
   ```bash
   # Public health check
   curl -s http://127.0.0.1:9000/health | jq .
   # -> {"ok": true}

   # Unauthenticated request (fails with 401)
   curl -si http://127.0.0.1:9000/whoami | head -n 5
   # -> HTTP/1.1 401 Unauthorized
   # -> WWW-Authenticate: Bearer realm="z-server"

   # Authenticated request (succeeds)
   KEY=$(cat /tmp/key.txt)
   curl -s -H "Authorization: Bearer $KEY" http://127.0.0.1:9000/whoami | jq .
   # -> {"key_id": 1, "scopes": "read:whoami", "user_id": "test"}
   ```

5. **Stop the Server**:
   ```bash
   kill $PID   # or Ctrl+C in the foreground terminal
   ```
