# hello-tls

> **Auth Note**: No auth. See [hello-auth](../hello-auth).

Example consumer project demonstrating `z-server` HTTP core combined with native BearSSL TLS 1.2 termination via the optional `z_server_tls` module.

## Features

- HTTP server provided by `z_server` module on `:9000`.
- Native TLS 1.2 termination provided by `z_server_tls` on `:9443` proxying to `:9000`.
- Demonstrates embedded certificate and private key deployment using `@embedFile`.
- Zero SQLite or Pogocache dependencies.

## Security note

The cert.pem and key.pem files in this directory are self-signed test certificates generated for localhost. They are intentionally committed so the example runs out-of-the-box with @embedFile.

DO NOT use these certificates in production. Generate your own with:
```bash
openssl req -x509 -newkey rsa:2048 -nodes -days 365 -keyout key.pem -out cert.pem -subj "/CN=localhost"
```

## Building & Running

Generating certificates (if needed):
```bash
openssl req -x509 -newkey rsa:2048 -nodes -keyout src/key.pem -out src/cert.pem -days 3650 -subj "/CN=localhost"
```

Compile and run:
```bash
zig build -Doptimize=ReleaseFast
./zig-out/bin/hello-tls
```

## Testing Endpoints

Plaintext HTTP:
```bash
curl -s http://127.0.0.1:9000/
# -> {"service":"hello-tls","secure":false}
```

Encrypted HTTPS (TLS 1.2):
```bash
curl -sk https://127.0.0.1:9443/
# -> {"service":"hello-tls","secure":true,"tls_version":"TLSv1.2"}
```
