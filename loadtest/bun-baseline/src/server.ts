import { Database } from "bun:sqlite";
import { isMainThread, parentPort, workerData, Worker } from "node:worker_threads";
import { readFileSync, readdirSync, mkdirSync } from "node:fs";

const PORT = Number(process.env.PORT ?? 8080);
const HOST = process.env.HOST ?? "0.0.0.0";
const DB_PATH = process.env.DB_PATH ?? "data/app.db";
const NUM_WORKERS = Number(process.env.BUN_WORKERS ?? 16);
const MAX_BODY = 64 * 1024;
const MAX_VALUE_BYTES = 32 * 1024;
const CACHE_TTL_MS = 60_000;
const BUSY_DELAYS_MS = [2, 5, 10, 20, 50];

if (isMainThread) {
  mkdirSync("data", { recursive: true });
  const initDb = new Database(DB_PATH, { create: true });
  initDb.exec("PRAGMA journal_mode = WAL;");
  initDb.exec("PRAGMA synchronous = NORMAL;");
  initDb.exec("PRAGMA busy_timeout = 5000;");
  initDb.exec("PRAGMA foreign_keys = ON;");
  initDb.exec(`
    CREATE TABLE IF NOT EXISTS items(
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      name TEXT NOT NULL,
      payload TEXT NOT NULL,
      created_at INTEGER NOT NULL DEFAULT (unixepoch()),
      updated_at INTEGER NOT NULL DEFAULT (unixepoch())
    );
  `);
  initDb.close();

  const sab = new SharedArrayBuffer(4);
  const workers: Worker[] = [];

  for (let i = 0; i < NUM_WORKERS; i++) {
    const w = new Worker(import.meta.filename, {
      workerData: { id: i, sab, port: PORT, host: HOST, dbPath: DB_PATH },
    });
    workers.push(w);
    w.on("message", (msg) => {
      if (msg?.type === "invalidate" || msg?.type === "set") {
        for (const other of workers) {
          if (other !== w) other.postMessage(msg);
        }
      }
    });
  }

  console.log(`bun-baseline main process started with ${NUM_WORKERS} workers on ${HOST}:${PORT}`);

  const shutdown = () => {
    for (const w of workers) w.terminate();
    process.exit(0);
  };
  process.on("SIGTERM", shutdown);
  process.on("SIGINT", shutdown);
} else {
  const { id: workerId, sab, port, host, dbPath } = workerData as {
    id: number;
    sab: SharedArrayBuffer;
    port: number;
    host: string;
    dbPath: string;
  };
  const busyCounter = new Int32Array(sab);

  const db = new Database(dbPath);
  db.exec("PRAGMA journal_mode = WAL;");
  db.exec("PRAGMA synchronous = NORMAL;");
  db.exec("PRAGMA busy_timeout = 5000;");
  db.exec("PRAGMA foreign_keys = ON;");

  const qList = db.query(
    "SELECT id, name, created_at FROM items ORDER BY id DESC LIMIT 100;",
  );
  const qGet = db.query(
    "SELECT id, name, payload, created_at, updated_at FROM items WHERE id = ?;",
  );
  const qInsert = db.query("INSERT INTO items (name, payload) VALUES (?, ?);");
  const qUpdate = db.query(
    "UPDATE items SET name = ?, payload = ?, updated_at = unixepoch() WHERE id = ?;",
  );
  const qDelete = db.query("DELETE FROM items WHERE id = ?;");

  type CacheEntry = { value: string; expiresAt: number };
  const cache = new Map<string, CacheEntry>();

  parentPort?.on("message", (msg) => {
    if (msg?.type === "invalidate" && typeof msg.key === "string") {
      cache.delete(msg.key);
    } else if (msg?.type === "set" && typeof msg.key === "string" && typeof msg.value === "string") {
      cache.set(msg.key, { value: msg.value, expiresAt: msg.expiresAt ?? (Date.now() + CACHE_TTL_MS) });
    }
  });

  function cacheGet(key: string): string | null {
    const e = cache.get(key);
    if (!e) return null;
    if (Date.now() > e.expiresAt) {
      cache.delete(key);
      return null;
    }
    return e.value;
  }

  function cacheSet(key: string, value: string): void {
    if (value.length > MAX_VALUE_BYTES) return;
    const expiresAt = Date.now() + CACHE_TTL_MS;
    cache.set(key, { value, expiresAt });
    parentPort?.postMessage({ type: "set", key, value, expiresAt });
  }

  function cacheDel(key: string): void {
    cache.delete(key);
    parentPort?.postMessage({ type: "invalidate", key });
  }

  function isBusy(err: unknown): boolean {
    const msg = err instanceof Error ? err.message : String(err);
    const code = (err as { code?: string })?.code ?? "";
    return (
      code.includes("BUSY") ||
      msg.includes("database is locked") ||
      msg.includes("SQLITE_BUSY")
    );
  }

  function withRetry<T>(fn: () => T): T {
    let last: unknown;
    for (let i = 0; i <= BUSY_DELAYS_MS.length; i++) {
      try {
        return fn();
      } catch (err) {
        if (isBusy(err)) Atomics.add(busyCounter, 0, 1);
        last = err;
        if (!isBusy(err) || i === BUSY_DELAYS_MS.length) throw err;
        Bun.sleepSync(BUSY_DELAYS_MS[i]!);
      }
    }
    throw last;
  }

  function json(data: unknown, status = 200, extra?: HeadersInit): Response {
    return new Response(JSON.stringify(data), {
      status,
      headers: { "Content-Type": "application/json", ...extra },
    });
  }

  function busy(): Response {
    return json({ error: "busy" }, 503, { "Retry-After": "1" });
  }

  async function readBody(req: Request): Promise<string | null> {
    const len = Number(req.headers.get("content-length") ?? "0");
    if (len > MAX_BODY) return null;
    const buf = await req.arrayBuffer();
    if (buf.byteLength > MAX_BODY) return null;
    return new TextDecoder().decode(buf);
  }

  function parseItemBody(raw: string): { name: string; payload: string } | null {
    try {
      const v = JSON.parse(raw);
      if (!v || typeof v !== "object" || typeof v.name !== "string") return null;
      if (!v.payload || typeof v.payload !== "object" || Array.isArray(v.payload)) {
        return null;
      }
      return { name: v.name, payload: JSON.stringify(v.payload) };
    } catch {
      return null;
    }
  }

  function parseId(pathname: string): number | null {
    const m = /^\/items\/(\d+)$/.exec(pathname);
    if (!m) return null;
    const id = Number(m[1]);
    if (!Number.isInteger(id) || id < 0) return null;
    return id;
  }

  function getIoBytes(): { read_bytes: number; write_bytes: number } {
    try {
      const text = readFileSync("/proc/self/io", "utf8");
      let read_bytes = 0;
      let write_bytes = 0;
      for (const line of text.split("\n")) {
        if (line.startsWith("read_bytes:")) {
          read_bytes = Number(line.slice(11).trim()) || 0;
        } else if (line.startsWith("write_bytes:")) {
          write_bytes = Number(line.slice(12).trim()) || 0;
        }
      }
      return { read_bytes, write_bytes };
    } catch (e) {
      console.error("io read failed:", e);
      return { read_bytes: 0, write_bytes: 0 };
    }
  }

  function getFdCount(): number {
    try {
      return readdirSync("/proc/self/fd").length;
    } catch {
      return 0;
    }
  }

  function handleHealth(): Response {
    const io = getIoBytes();
    return json({
      ok: true,
      version: "bun-baseline-v1",
      db: "ok",
      cache: "ok",
      sqlite_busy_count: Atomics.load(busyCounter, 0),
      io_read_bytes: io.read_bytes,
      io_write_bytes: io.write_bytes,
      fd_count: getFdCount(),
    });
  }

  function handleList(): Response {
    try {
      const rows = withRetry(() => qList.all());
      return json(rows);
    } catch (err) {
      if (isBusy(err)) return busy();
      throw err;
    }
  }

  function handleGet(id: number): Response {
    const key = `item:${id}`;
    const hit = cacheGet(key);
    if (hit) {
      return new Response(hit, {
        headers: { "Content-Type": "application/json", "X-Cache": "HIT" },
      });
    }
    try {
      const row = withRetry(() => qGet.get(id)) as
        | { id: number; name: string; payload: string; created_at: number; updated_at: number }
        | null;
      if (!row) return json({ error: "not found" }, 404);
      let payload: unknown = row.payload;
      try {
        payload = JSON.parse(row.payload);
      } catch {
        /* keep string */
      }
      const body = JSON.stringify({
        id: row.id,
        name: row.name,
        payload,
        created_at: row.created_at,
        updated_at: row.updated_at,
      });
      cacheSet(key, body);
      return new Response(body, {
        headers: { "Content-Type": "application/json", "X-Cache": "MISS" },
      });
    } catch (err) {
      if (isBusy(err)) return busy();
      throw err;
    }
  }

  function handleCreate(name: string, payload: string): Response {
    try {
      const id = withRetry(() => {
        const info = qInsert.run(name, payload);
        return Number(info.lastInsertRowid);
      });
      return json({ id }, 201);
    } catch (err) {
      if (isBusy(err)) return busy();
      throw err;
    }
  }

  function handlePut(id: number, name: string, payload: string): Response {
    try {
      const changed = withRetry(() => qUpdate.run(name, payload, id).changes);
      if (changed === 0) return json({ error: "not found" }, 404);
      cacheDel(`item:${id}`);

      const row = withRetry(() => qGet.get(id)) as
        | { id: number; name: string; payload: string; created_at: number; updated_at: number }
        | null;
      if (!row) return json({ error: "not found" }, 404);
      let p: unknown = row.payload;
      try {
        p = JSON.parse(row.payload);
      } catch {
        /* keep string */
      }
      return json({
        id: row.id,
        name: row.name,
        payload: p,
        created_at: row.created_at,
        updated_at: row.updated_at,
      });
    } catch (err) {
      if (isBusy(err)) return busy();
      throw err;
    }
  }

  function handleDelete(id: number): Response {
    try {
      const changed = withRetry(() => qDelete.run(id).changes);
      if (changed === 0) return json({ error: "not found" }, 404);
      cacheDel(`item:${id}`);
      return new Response(null, { status: 204 });
    } catch (err) {
      if (isBusy(err)) return busy();
      throw err;
    }
  }

  Bun.serve({
    hostname: host,
    port: port,
    reusePort: true,
    idleTimeout: 30,
    async fetch(req) {
      const url = new URL(req.url);
      const path = url.pathname;
      try {
        if (req.method === "GET" && path === "/health") return handleHealth();
        if (req.method === "GET" && path === "/") return json({ ok: true });
        if (req.method === "GET" && path === "/items") return handleList();
        if (req.method === "GET" && path.startsWith("/items/")) {
          const id = parseId(path);
          if (id === null) return json({ error: "invalid id" }, 400);
          return handleGet(id);
        }
        if (req.method === "POST" && path === "/items") {
          const raw = await readBody(req);
          if (raw === null) return json({ error: "invalid json" }, 400);
          const parsed = parseItemBody(raw);
          if (!parsed) return json({ error: "invalid json" }, 400);
          return handleCreate(parsed.name, parsed.payload);
        }
        if (req.method === "PUT" && path.startsWith("/items/")) {
          const id = parseId(path);
          if (id === null) return json({ error: "invalid id" }, 400);
          const raw = await readBody(req);
          if (raw === null) return json({ error: "invalid json" }, 400);
          const parsed = parseItemBody(raw);
          if (!parsed) return json({ error: "invalid json" }, 400);
          return handlePut(id, parsed.name, parsed.payload);
        }
        if (req.method === "DELETE" && path.startsWith("/items/")) {
          const id = parseId(path);
          if (id === null) return json({ error: "invalid id" }, 400);
          return handleDelete(id);
        }
        return json({ error: "not found" }, 404);
      } catch (err) {
        if (isBusy(err)) return busy();
        return json({ error: "internal" }, 500);
      }
    },
  });
}
