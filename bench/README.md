# Benchmarks

## Install oha (Fedora)

```bash
sudo dnf install oha
```

If the package is missing, download the release binary:

```bash
curl -fsSL -o bench/oha https://github.com/hatoo/oha/releases/download/v1.16.0/oha-linux-amd64
chmod +x bench/oha
```

wrk alternative: `sudo dnf install wrk` (the scripts use oha).

## Run

From the repository root, with nothing else bound to `:8080`:

```bash
./bench/run.sh
./bench/valgrind.sh
```

`run.sh` writes `bench/results.md`. `valgrind.sh` writes `bench/valgrind.log`.

## Scenarios

1. GET `/items/:id` HIT — small item, warmed cache, 1000 req, c=50
2. GET `/items/:id` MISS — 40 KiB payload (above `MAX_VALUE_BYTES`), 1000 req, c=50
3. POST `/items` — 500 req, c=50
4. GET `/items` list — 1000 req, c=50
