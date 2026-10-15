# Request and response

## Request (`Ctx`)

| Call | Returns |
|------|---------|
| `c.method()` | `Method` enum (`.get`, `.post`, …, `.other`) |
| `c.path()`, `c.query()` | raw path (no query) and raw query string |
| `c.param('id')`, `c.param_int('id')` | route params |
| `c.query_param('q')`, `c.query_int('n')` | first query value, `%XX` and `+` decoded |
| `c.header('name')`, `c.header_values('name')` | first field (any case) / iterator over repeated fields |
| `c.body()`, `c.body_int()` | body bytes (chunked bodies arrive decoded) |
| `c.worker_id()` | index of the worker thread |

Every string and slice above is a view into connection buffers, valid until the handler returns. Clone what
you keep. Build with `-d viltrum_debug` to overwrite request bytes after each request, so a kept view shows up
as garbage in tests.

## Response

`c.text(status, s)`, `c.text_int(status, n)`, `c.json(status, value)`, `c.bytes(status, content_type, data)`,
`c.no_content(status)`. Add headers first with `c.set_header(name, value)` (up to 16) and call `c.close()` first
to close the connection after the response. One response per request; a second call is ignored (it panics in
`-d viltrum_debug` builds).

The framework writes `Content-Length`, `Date` (on by default) and `Server` (if `Options.server_header` is set).
HEAD answers keep `Content-Length` and drop the body.

## Middleware

`recover`, `gzip`, `cors` and `logger` are plain `fn (mut c Ctx)` middleware. V cannot catch panics: a panic exits the process. `recover` only turns a handler that wrote no response into 500 and closes the connection. Run the server under a supervisor (e.g. systemd `Restart=always`).

## Handlers and `-prod`

V 0.5.2 `-prod` builds (with the default Boehm GC) wrap every call statement in a walk over each local struct
or array that holds pointers. Past 32 pointers that walk also takes the GC's global lock, so a handler that
keeps a large array of structs in a local variable and then calls functions serializes all workers. Keep large
data captured by the closure or behind a pointer, and keep handler locals scalar; `benches/httparena/main.v`
shows the shape. The framework's own hot path is checked for this in CI (`scripts/gcpin_check.sh`).
