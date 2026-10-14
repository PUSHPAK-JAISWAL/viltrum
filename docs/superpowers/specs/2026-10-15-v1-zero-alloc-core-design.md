# Viltrum v1.0: zero-allocation core

| | |
|--|--|
| Status | Approved design, not started |
| Branch | `v1` (`main` stays on 0.13.x for fixes) |
| Date | 2026-10-15 |

## Goal

Beat Axum on HttpArena's HTTP/1.1 profiles **in standard mode** (framework defaults, no tuning flags):
`baseline`, `pipelined`, `limited-conn`, `json-comp`, while `scripts/validate.sh` keeps passing.

Success criteria:

1. HttpArena PR `/benchmark` (64-thread box): viltrum rps > Axum rps on all four profiles.
   Reference (2026-10-14): Axum baseline 1.08M, pipelined 6.47M, limited-conn 0.69M, json-comp 0.27M.
2. `validate.sh` passes every check of the subscribed profiles (today 36/36 incl. byte-offset fragmentation).
3. The framework allocates **zero** GC objects per request on the hot path, enforced by a CI test (see
   "Zero-allocation enforcement").

Breaking the public API is accepted (v1.0). Performance is the only goal of this release; everything else is in
the backlog.

## Why

HttpArena 2026-10-14 (v0.13.0): baseline 595k, pipelined 981k, limited-conn 524k, json-comp 14k, using only
11–23 of 64 cores. `vanilla-epoll`, also written in V with Boehm GC, reaches baseline 3.99M and
pipelined 38.97M on the same box with all cores busy. Its measured lesson (docs/PERF_GAP_ANALYSIS.md in
enghitalo/vanilla): per-request allocation is invisible on a laptop but under Boehm at 64 cores every collection
stops all workers, so allocation rate decides how many cores do useful work. Removing one router allocation took
its pipelined result from 2.4M to 34.9M.

Viltrum today allocates ~20 GC objects per request: method/target/version strings, header key/value strings,
`HeaderMap` and `params` maps (3 allocations each in V), `Request` copies in the router, `Response` with its own
header list, `'${len}'` and `n.str()` strings, the Date string, and `body.bytes()` copies.

## Scope

In v1.0:

- One I/O model: one epoll worker per CPU, Linux only.
- Span-based HTTP/1.1 parser with today's strictness (smuggling rules, chunked bodies, limits).
- `Ctx` API: request views + response writer into the connection's output buffer.
- Compiled router (static table + param segments), middleware chain without per-request closures.
- `viltrum.json` compile-time encoder writing into a buffer.
- gzip middleware on miniz with per-worker state.
- Graceful shutdown (SIGINT/SIGTERM), `max_conns`, read/idle/write timeouts, request counter.

Backlog (removed from v1.0, return later on the new core): TLS/WSS and SIGHUP reload, WebSocket and
upgrade/hijack, static files, form/multipart parsing, `fetch` client, non-Linux backend, `service` module,
offload pool for blocking handlers, `ConnStats` snapshot details and drain timeout. The HttpArena entry drops
`echo-ws` until WebSocket returns.

## Architecture

```
viltrum            App: route registration, middleware, listen
  router/          compiled routes → handler index + param spans
  http1/           framer (CL + chunked), span parser, Ctx, response writer, date cache
  engine/          workers, ConnState table, recv/send loop, pipelining, backpressure, timeouts
  json/            comptime encoder into []u8
  gzip.c.v         miniz deflate with per-worker compressor
```

Each unit has one job and is testable without sockets: the framer and parser take bytes, the router takes a
method and path, the writer appends to a buffer. `engine` is the only module that touches sockets.

## Public API

```v
mut app := viltrum.new()
app.use(viltrum.recover)
app.get('/baseline11', fn (mut c viltrum.Ctx) {
	a := c.query_int('a') or { 0 }
	b := c.query_int('b') or { 0 }
	c.text_int(200, a + b + (c.body_int() or { 0 }))
})
app.get('/json/:count', viltrum.gzip, fn (mut c viltrum.Ctx) {
	n := c.param_int('count') or { 0 }
	c.json(200, Page{ items: items[..n], count: n })
})
app.listen('0.0.0.0:8080')!
```

`Ctx` request side (all views into the connection's read buffer):

- `method() Method` (enum), `path() string`, `query() string`, `header(name) ?string` (first field with that
  name), `header_values(name)` (iterator over repeated fields), `param(name) ?string`,
  `query_param(name) ?string`, `body() []u8`, plus `param_int` / `query_int` / `body_int` that parse in place.
- **Lifetime rule:** every string or slice returned is valid only until the handler returns. Keep it with
  `.clone()`. Build with `-d viltrum_debug` to overwrite the read buffer after each request, so code that keeps a
  view reads garbage in tests instead of silently working.

`Ctx` response side (appends to the connection's write buffer):

- `text(status, s string)`, `text_int(status, n i64)`, `json[T](status, value)`,
  `bytes(status, content_type, data)`, `set_header(name, value)`, `no_content(status)`.
- `text_int` writes digits with an in-place formatter, never `str()`.
- Exactly one response per request. A second call is a programming error and panics in debug builds.
- HEAD keeps headers and drops the body. `Date` (when enabled), `Server` (when set) and
  `Content-Length` are written by the framework.

Middleware: `fn (mut c Ctx)`; calling `c.next()` runs the rest of the chain. Global and per-route
chains are flattened into one array per route at registration, and `Ctx` carries the current index, so a request
creates no closures. Built-ins: `recover`, `gzip`, `cors`, `logger`.

Routes: `get/post/put/patch/delete/head/options(pattern, ...middleware, handler)`, `mount(prefix)`. Patterns
keep today's syntax (`:id`, trailing `*rest`).

## Engine

- **Workers:** count = CPUs in the process affinity mask (`sched_getaffinity`), overridable with
  `VILTRUM_WORKERS`. Each worker owns a `SO_REUSEPORT` listener and an epoll instance (level-triggered).
  Workers share nothing on the hot path; the request counter is per worker and summed on read.
- **ConnState:** flat table indexed by fd, plus a free list, per worker. Each connection keeps an 8 KiB read
  buffer and a 16 KiB write buffer for its lifetime. Buffers grow (never per request) up to the limits and shrink
  back to the default size when a connection that grew goes idle, so one large upload does not pin memory.
- **Request cycle:** `recv` into the read buffer → frame (Content-Length or chunked, resumable) → parse spans →
  route → run chain → repeat for every complete message in the buffer → one `send` for the batch → compact
  leftover bytes with `memmove`. A short read skips the extra `recv` (level-triggered epoll reports more).
- **Chunked bodies** are decoded into a per-connection scratch buffer reused across requests.
- **Backpressure:** a worker stops serving further pipelined requests once 1 MiB of output is pending and
  stops reading a connection while its output is pending (`EPOLLOUT` armed). Memory stays bounded at one batch,
  large responses still go out, and a peer that stops reading is closed by `write_timeout`.
- **Connection semantics:** keep-alive by default on HTTP/1.1, `Connection: close` honored after the response,
  HTTP/1.0 closes unless `keep-alive`, `Expect: 100-continue` answered before the body.
- **Errors:** framing or parse errors answer 400 (413/431 for limits) after any earlier pipelined responses, then
  close. A handler panic is caught by `recover` (500 + close), not by the engine.
- **Timeouts:** each worker sweeps its table once per second: header read, body read, idle keep-alive and write
  deadlines, defaults as today (30 s / 30 s / 60 s).
- **Date:** each worker formats the header once per second into a fixed 29-byte buffer.
- **Limits:** `max_header_bytes` 64 KiB, `max_body_bytes` 1 MiB, at most 32 header fields (431), `max_conns`.
- **Shutdown:** SIGINT/SIGTERM stop accepting; open connections finish their current batch and close.

V-specific rules for the hot path (each one measured by vanilla):

- Never slice an array with `a[x..y]` (it allocates or marks aliasing); use an unsafe view helper that sets
  `data`/`len` and clears `.managed`.
- No string interpolation, `str()`, `split`, `to_lower`, `trim`, map literals or `[]T{}` literals. Integers are
  written with an append-digits helper, case-insensitive compares go byte by byte.
- Reused buffers are `noscan` allocations made once per connection.

## Parser

Port today's rules unchanged, operating on spans instead of strings: request line (three tokens, no control
bytes), header names must be tokens, no obs-fold, no bare CR/LF, values without control bytes, duplicate
`Content-Length` / `Host` rejected, TE + CL rejected, only `Transfer-Encoding: chunked` on HTTP/1.1, the
`ChunkScan` walker for chunked framing. A header is `{name_off, name_len, value_off, value_len}` in a fixed array
of 32. Name lookup compares case-insensitively without allocating; repeated fields are never joined into a new
string (`header` returns the first, `header_values` iterates).

## Router

Routes compile at `listen`: static routes go into a table keyed by method and exact path, dynamic routes into a
per-method segment tree. Matching walks the path bytes; params are stored as up to 8 spans in `Ctx`. 404 vs 405
is decided by a second lookup that ignores the method, only on a miss. Paths are normalized as today (trailing
slash, `//`).

## Response writer

Precomputed status lines for every code in use, header names written verbatim, `Content-Length` via the digit
helper. `json[T]` encodes straight into the write buffer when no middleware needs the body; when a body-rewriting
middleware is active (gzip), the body goes into a per-connection scratch buffer first and is moved or compressed
into the write buffer by the middleware.

## JSON encoder

`viltrum.jsonenc.encode_into[T](mut buf []u8, value T)` generated with `$for field in T.fields`. Supports integers,
floats (shortest round-trip via the C formatter into a stack buffer), bools, strings (escaped per RFC 8259),
arrays, nested structs. Field attributes (`@[json: ...]`) are backlog: reading them per call would allocate. This is the framework's standard JSON for
HttpArena's standard mode. Decoding keeps using V's `json` module for now.

## gzip

Per worker: one `tdefl_compressor` allocated with `malloc` at start, `tdefl_init` per response at level 6, output
written through a callback into a per-worker buffer, gzip header and trailer (`mz_crc32`) added around it.
`Accept-Encoding` negotiation (q-values, explicit gzip beats `*`) is reimplemented on spans. Only bodies of
256 bytes or more with compressible content types; `Vary: Accept-Encoding` always set. No caching of output.

## Zero-allocation enforcement

- An in-process harness feeds raw request bytes through framer → parser → router → chain → writer without
  sockets. A CI test runs a warm-up batch, then 10,000 requests of each benchmark shape (GET with query,
  POST Content-Length, POST chunked, pipelined burst, JSON, JSON + gzip) and asserts that the Boehm counters
  (`GC_get_total_bytes`, collection count) do not move. Handler code in the test is allocation-free too.
- A grep-based lint in CI rejects banned calls (interpolation, `str()`, `split`, array slicing) in
  `http1/`, `router/`, `engine/` hot-path files, with an allow list for cold paths.

## Verification

1. Unit tests per module (framer, parser, router, writer, encoder, gzip round trip with an independent decoder).
2. Ported fuzz suite (500k mutations in CI) and the pipelining and smuggling tests, run against the new engine.
3. `validate.sh` from an HttpArena checkout (36/36 minus `echo-ws`).
4. On `semantic` (12-thread bare metal, live services, short runs at times the user picks): `perf stat`
   instructions per request for viltrum and Axum at a fixed rate, not loopback rps.
5. HttpArena PR `/benchmark` for the 64-thread result.

## Migration

- Work on `v1`; `main` keeps 0.13.x. Release as 1.0.0 with a `BREAKING CHANGE` footer.
- Examples kept in v1.0: `hello`, `rest`, `features` (minus backlog features). Others return with their feature.
- Docs: rewrite getting-started, request-response, connection; mark backlog features as "not yet in 1.0".

## Risks

- Users keeping request views past the handler. Mitigation: lifetime rule in names and docs, debug-build
  poisoning.
- V comptime limits in the JSON encoder (generic arrays of structs, options). Mitigation: support the
  HttpArena shapes first, fall back to V `json` for unsupported types with a compile-time notice.
- Boehm still collects whatever user code allocates; the guarantee covers the framework only.
- `semantic` runs live services, so local measurements stay short and scheduled; the 64-thread truth comes from
  HttpArena.
