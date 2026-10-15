# Viltrum v1.0 zero-allocation core Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rebuild viltrum's HTTP/1.1 stack so the framework allocates nothing per request and scales across all cores, to beat Axum on HttpArena in standard mode.

**Architecture:** One epoll worker per CPU with its own `SO_REUSEPORT` listener; every connection keeps reusable read/write buffers; the parser yields spans into the read buffer; handlers receive a `Ctx` that writes the response straight into the connection's write buffer. A socket-free `Worker.process` drives framing → parsing → routing → handlers, which is what the zero-allocation test exercises.

**Tech Stack:** V 0.5.2 (release zip, as in CI), Boehm GC (V default), Linux epoll, miniz from `@VEXEROOT/thirdparty/zip`.

**Spec:** `docs/superpowers/specs/2026-10-15-v1-zero-alloc-core-design.md`

## Global Constraints

- Branch `v1`. Do not touch `main`. Do not push, tag or release without the user's approval.
- V 0.5.2 release (`https://github.com/vlang/v/releases/download/0.5.2/v_linux.zip`); local V lives in WSL at `~/v`, the repo is symlinked as `~/.vmodules/viltrum`.
- Linux only (epoll). Non-Linux backend is backlog.
- Hot-path code (`http1/`, `router/` match path, `jsonenc/`, `engine/process.v`, `engine/worker_linux.c.v`) must not use: string interpolation, `.str()`, `split`, `to_lower`/`to_upper`, `trim*`, `bytestr()`, array slicing `a[x..y]`, map or array literals. Use `view`, `str_view`, `append_*`, `eq_ci`, `lower`. Cold paths (startup, errors that close the connection, tests) may allocate; mark them `// cold:` where a reader could doubt it.
- Framework allocates zero GC bytes per request, measured with `gc_heap_usage().total_bytes` (wrapped as `http1.allocated_bytes()`).
- Limits and defaults (spec): `max_header_bytes` 64 KiB, `max_body_bytes` 1 MiB, at most 32 header fields (431), read/write timeout 30 s, idle 60 s, read buffer 8 KiB, write buffer 16 KiB, pending output cap 1 MiB, listen backlog 4096.
- Parser strictness is unchanged from v0.13: token header names, no obs-fold, no bare CR/LF, no control bytes in values, duplicate `Content-Length`/`Host` rejected, TE+CL rejected, only `Transfer-Encoding: chunked` on HTTP/1.1, chunk size ≤ 8 hex digits, chunk line ≤ 4096 bytes, trailers ≤ 8192 bytes.
- Run commands from PowerShell as `wsl -e bash <script>`; inline `wsl -e bash -c "..."` breaks on `$`, quotes and `|` — write a script file in the session scratchpad instead.
- Format check: `v fmt` on an LF copy of each changed file must produce no diff (git checks files out with CRLF on Windows).
- Commits use Conventional Commits; the final merge to `main` carries `BREAKING CHANGE:`.

## Spec deltas (decided while planning)

- Middleware is `fn (mut c Ctx)` and continues with `c.next()` (Gin/Echo style) instead of `fn (mut c Ctx, next Next)`. Same zero-closure property, simpler type. Update the spec in Task 1.
- The JSON encoder module is `viltrum.jsonenc` (a module named `json` would clash with V's `json` in user code). `@[json: ...]` attributes move to the backlog: reading `field.attrs` at runtime would allocate per field.
- Query and form values are percent-decoded into a per-request scratch buffer (no GC allocation); the returned string is valid until the handler returns, like every other request view.

## Review Focus

1. A handler that returns without responding: the client must still get a response (500) and the connection must stay in sync. Test in Task 10.
2. A response larger than the write buffer (multi-MB JSON): must be sent completely across partial writes, with later pipelined responses after it. Test in Task 11.
3. A client that pipelines but never reads responses: memory must stay bounded (processing pauses at 1 MiB pending, reading pauses while output is pending) and the connection is closed by `write_timeout`. Test in Task 11.
4. A slow client trickling header bytes forever (slowloris): `read_timeout` closes it. Test in Task 11.
5. Percent-encoded and `+` query values, and a decoded value used after another decode in the same handler: both must stay correct. Test in Task 7.

## File map

| File | Responsibility | Task |
|------|----------------|------|
| `http1/bytes.v` | `view`, `str_view`, `append_*`, `lower`, `eq_ci`, `is_tchar`, `parse_i64`, `allocated_bytes` | 2 |
| `http1/frame.v` | `Limits`, `HttpError`, `Span`, `Frame`, `frame()`, `header_value()` | 3 |
| `http1/chunked.v` | `ChunkScan`, `scan_chunked()`, `decode_chunked()` | 3 |
| `http1/parse.v` | `Method`, `Field`, `Head`, `parse_head()` | 4 |
| `http1/writer.v` | `reason()`, `write_status_line()`, `write_header()`, `body_allowed()` | 5 |
| `http1/date.v` | `DateCache` | 5 |
| `jsonenc/encode.v` | `encode_into[T]()` | 6 |
| `http1/ctx.v` | `Ctx`, `Handler`, request accessors, response writers, `next()` | 7 |
| `router/router.v` | `Router`, `Match`, `add()`, `find()` | 8 |
| `http1/gzip.c.v` | `Deflater`, `accepts_gzip()`, `compressible()`, `gzip_middleware()` | 9 |
| `engine/options.v` | `Options`, `Stop` | 10 |
| `engine/process.v` | `Conn`, `Worker`, `new_worker()`, `Worker.process()` | 10 |
| `engine/worker_linux.c.v` | epoll loop, accept, recv/send, backpressure, timeouts | 11 |
| `engine/serve_linux.c.v` | `serve()`: listeners, worker count, signals, threads | 11 |
| `viltrum.v` | `App`, `Group`, routing API, `listen`, built-in middleware | 12 |
| `examples/{hello,rest,features}/main.v` | examples on the new API | 12 |
| `scripts/hotpath_lint.sh`, `.github/workflows/ci.yml` | CI | 13 |
| `benches/httparena/*` | standard-mode entry | 13 |

Test files sit next to their modules (`*_test.v`). Old code is available as `git show main:<path>` for porting.

---

### Task 1: Strip the tree to the v1 scope

**Files:**
- Delete: `http/`, `engine/` (all current files), `router/router.v`, `router/router_test.v`, `ws/`, `staticf/`, `service/`, `gzip.c.v`, `tests/recover_test.v`, `tests/gzip_test.v`, `examples/client`, `examples/https_hello`, `examples/upgrade_echo`, `examples/upload`, `examples/ws_echo`, `examples/wss_echo`, `examples/hello`, `examples/rest`, `examples/features` (the last three come back in Task 12)
- Replace: `viltrum.v`
- Modify: `.github/workflows/ci.yml`, `docs/superpowers/specs/2026-10-15-v1-zero-alloc-core-design.md`

**Interfaces:**
- Consumes: nothing
- Produces: an empty `module viltrum` with `pub const version = '1.0.0-dev'`; later tasks add modules next to it

- [ ] **Step 1: Delete the old stack**

```bash
cd /c/Users/tunay/Documents/GitHub/viltrum
git rm -r -q http engine router ws staticf service gzip.c.v tests examples/client examples/https_hello \
  examples/upgrade_echo examples/upload examples/ws_echo examples/wss_echo examples/hello examples/rest examples/features
```

- [ ] **Step 2: Replace `viltrum.v` with a stub**

```v
module viltrum

// The v1.0 core is being rebuilt. See
// docs/superpowers/specs/2026-10-15-v1-zero-alloc-core-design.md.

pub const version = '1.0.0-dev'
```

- [ ] **Step 3: Point CI at the new modules**

Replace the `Unit tests`, `Parser fuzz`, `Build examples`, `Build WS load client` and `WS soak` steps of `.github/workflows/ci.yml` with:

```yaml
      - name: Unit tests
        run: |
          for d in http1 router jsonenc engine; do
            if [ -d "$d" ]; then v test "$d/"; fi
          done

      - name: Parser fuzz (500k mutations)
        run: if [ -f http1/fuzz_test.v ]; then VILTRUM_FUZZ_ITERS=500000 v test http1/fuzz_test.v; fi
```

- [ ] **Step 4: Record the spec deltas**

In the spec's "Public API" section replace the middleware paragraph's first sentence with:

```markdown
Middleware: `fn (mut c Ctx)`; calling `c.next()` runs the rest of the chain.
```

In the "JSON encoder" section replace the first sentence with:

```markdown
`viltrum.jsonenc.encode_into[T](mut buf []u8, value T)` generated with `$for field in T.fields`.
```

and replace `and `@[json: 'name']` / `@[json: '-']`.` with `. Field attributes (`@[json: ...]`) are backlog: reading them per call would allocate.`

- [ ] **Step 5: Verify the stub builds and commit**

Run (scratchpad script `t1.sh`):

```bash
export PATH=$HOME/v:$PATH
cd /mnt/c/Users/tunay/Documents/GitHub/viltrum
v -check viltrum.v && echo BUILD_OK
```

Expected: `BUILD_OK`.

```bash
git add -A
git commit -q -m "refactor!: strip the tree to the v1 core scope

TLS, WebSocket, static files, forms, the fetch client and the service
module move to the backlog; the HTTP stack is rebuilt in the next commits."
```

---

### Task 2: Byte helpers and the allocation probe

**Files:**
- Create: `http1/bytes.v`
- Test: `http1/bytes_test.v`

**Interfaces:**
- Consumes: nothing
- Produces:
  - `pub fn view(buf []u8, start int, len int) []u8`
  - `pub fn str_view(buf []u8, start int, len int) string`
  - `pub fn append_str(mut out []u8, s string)`
  - `pub fn append_bytes(mut out []u8, b []u8)`
  - `pub fn append_int(mut out []u8, n i64)`
  - `pub fn lower(c u8) u8`
  - `pub fn eq_ci(s string, lower_lit string) bool`
  - `pub fn is_tchar(c u8) bool`
  - `pub fn parse_i64(s string) ?i64`
  - `pub fn allocated_bytes() u64`

- [ ] **Step 1: Write the failing test**

`http1/bytes_test.v`:

```v
module http1

fn test_append_int_matches_str() {
	mut out := []u8{cap: 64}
	for n in [i64(0), 7, -7, 10, 99, 100, 1234567890, -9223372036854775807 - 1, 9223372036854775807] {
		unsafe {
			out.len = 0
		}
		append_int(mut out, n)
		assert out.bytestr() == n.str()
	}
}

fn test_views_share_memory() {
	buf := 'GET /abc HTTP/1.1'.bytes()
	v := view(buf, 4, 4)
	assert v.bytestr() == '/abc'
	assert unsafe { &u8(v.data) } == unsafe { &u8(buf.data) + 4 }
	s := str_view(buf, 4, 4)
	assert s == '/abc'
	assert s.str == unsafe { &u8(buf.data) + 4 }
	assert str_view(buf, 0, 0) == ''
}

fn test_case_and_tokens() {
	assert eq_ci('Content-Length', 'content-length')
	assert !eq_ci('Content-Lengt', 'content-length')
	assert lower(`A`) == `a` && lower(`z`) == `z` && lower(`-`) == `-`
	for c in "!#$%&'*+-.^_`|~09azAZ".bytes() {
		assert is_tchar(c)
	}
	for c in ' \t"(),/:;<=>?@[\\]{}\x7f\x00'.bytes() {
		assert !is_tchar(c)
	}
}

fn test_parse_i64() {
	assert parse_i64('42')? == 42
	assert parse_i64(' -17 ')? == -17
	assert parse_i64('+5')? == 5
	assert parse_i64('20\r\n')? == 20
	for bad in ['', ' ', '-', '1x', '0x10', '1234567890123456789'] {
		if _ := parse_i64(bad) {
			assert false, bad
		}
	}
}

fn test_helpers_allocate_nothing() {
	buf := 'GET /abc HTTP/1.1'.bytes()
	mut out := []u8{cap: 4096}
	before := allocated_bytes()
	for i in 0 .. 10000 {
		unsafe {
			out.len = 0
		}
		append_str(mut out, str_view(buf, 0, 3))
		append_bytes(mut out, view(buf, 4, 4))
		append_int(mut out, i64(i))
		_ = eq_ci(str_view(buf, 9, 8), 'http/1.1')
		_ = parse_i64(str_view(buf, 5, 3)) or { 0 }
	}
	assert allocated_bytes() - before == 0
}
```

- [ ] **Step 2: Run it and see it fail**

Scratchpad script `t2.sh`:

```bash
export PATH=$HOME/v:$PATH
cd /mnt/c/Users/tunay/Documents/GitHub/viltrum
v test http1/ 2>&1 | grep -E 'FAIL|Summary|error' | head
```

Expected: compile error, `unknown function: view` (or similar).

- [ ] **Step 3: Implement `http1/bytes.v`**

```v
module http1

// Byte helpers for the request hot path. None of them allocates: views share the
// caller's buffer, appends write into capacity the caller owns.

// view returns buf[start..start+len] without copying and without V's slice
// bookkeeping (array.slice marks the parent and costs ~20% of a plaintext request).
// The view does not own its memory: it is valid while buf is neither freed nor moved.
@[inline]
pub fn view(buf []u8, start int, len int) []u8 {
	mut v := unsafe { buf }
	unsafe {
		v.data = &u8(buf.data) + start
		v.len = len
		v.cap = len
		v.flags.clear(.managed)
	}
	return v
}

// str_view is view as a string. It is not NUL-terminated; clone it to keep it.
@[inline]
pub fn str_view(buf []u8, start int, len int) string {
	if len <= 0 {
		return ''
	}
	return unsafe { tos(&u8(buf.data) + start, len) }
}

@[inline]
pub fn append_str(mut out []u8, s string) {
	if s.len > 0 {
		unsafe { out.push_many(s.str, s.len) }
	}
}

@[inline]
pub fn append_bytes(mut out []u8, b []u8) {
	if b.len > 0 {
		unsafe { out.push_many(b.data, b.len) }
	}
}

// append_int writes n in decimal (n.str() would allocate).
pub fn append_int(mut out []u8, n i64) {
	if n == 0 {
		out << `0`
		return
	}
	mut tmp := [20]u8{}
	mut i := 20
	neg := n < 0
	mut v := if neg { u64(-(n + 1)) + 1 } else { u64(n) }
	for v > 0 {
		i--
		tmp[i] = u8(`0` + v % 10)
		v /= 10
	}
	if neg {
		out << `-`
	}
	unsafe { out.push_many(&tmp[i], 20 - i) }
}

@[inline]
pub fn lower(c u8) u8 {
	return if c >= `A` && c <= `Z` { c + 32 } else { c }
}

// eq_ci compares s with an ASCII-lowercase literal, ignoring the case of s.
pub fn eq_ci(s string, lower_lit string) bool {
	if s.len != lower_lit.len {
		return false
	}
	for i in 0 .. s.len {
		if lower(s[i]) != lower_lit[i] {
			return false
		}
	}
	return true
}

// is_tchar reports whether c may appear in an RFC 9110 token.
pub fn is_tchar(c u8) bool {
	if (c >= `a` && c <= `z`) || (c >= `A` && c <= `Z`) || (c >= `0` && c <= `9`) {
		return true
	}
	return match c {
		`!`, `#`, `$`, `%`, `&`, `'`, `*`, `+`, `-`, `.`, `^`, `_`, `\``, `|`, `~` { true }
		else { false }
	}
}

// parse_i64 parses an optionally signed decimal, ignoring surrounding whitespace.
// At most 18 digits, so it can never overflow.
pub fn parse_i64(s string) ?i64 {
	mut i := 0
	mut j := s.len
	for i < j && (s[i] == ` ` || s[i] == `\t`) {
		i++
	}
	for j > i && (s[j - 1] == ` ` || s[j - 1] == `\t` || s[j - 1] == `\r` || s[j - 1] == `\n`) {
		j--
	}
	if i == j {
		return none
	}
	mut neg := false
	if s[i] == `-` || s[i] == `+` {
		neg = s[i] == `-`
		i++
		if i == j {
			return none
		}
	}
	if j - i > 18 {
		return none
	}
	mut n := i64(0)
	for k in i .. j {
		c := s[k]
		if c < `0` || c > `9` {
			return none
		}
		n = n * 10 + i64(c - `0`)
	}
	return if neg { -n } else { n }
}

// allocated_bytes is the GC's running total of allocated bytes. Tests diff it
// around a batch of requests to prove the hot path allocates nothing.
pub fn allocated_bytes() u64 {
	return u64(gc_heap_usage().total_bytes)
}
```

- [ ] **Step 4: Run the tests**

Run `t2.sh`. Expected: `Summary for all V _test.v files: 1 passed, 1 total.`

- [ ] **Step 5: Format check and commit**

Scratchpad script `fmt.sh` (reused by every task; pass the files as arguments):

```bash
export PATH=$HOME/v:$PATH
cd /mnt/c/Users/tunay/Documents/GitHub/viltrum
for f in "$@"; do
  sed 's/\r$//' "$f" > /tmp/fmt_in.v
  v fmt /tmp/fmt_in.v > /tmp/fmt_out.v
  diff -q /tmp/fmt_in.v /tmp/fmt_out.v >/dev/null && echo "fmt ok $f" || { echo "fmt DIFF $f"; diff /tmp/fmt_in.v /tmp/fmt_out.v | head -20; }
done
```

Run `wsl -e bash <scratchpad>/fmt.sh http1/bytes.v http1/bytes_test.v`; fix any diff by hand, then:

```bash
git add http1/bytes.v http1/bytes_test.v
git commit -q -m "feat(http1): allocation-free byte helpers and GC probe"
```

---
### Task 3: Message framing (Content-Length and chunked)

**Files:**
- Create: `http1/frame.v`, `http1/chunked.v`
- Test: `http1/frame_test.v`

**Interfaces:**
- Consumes (Task 2): `view`, `str_view`, `lower`, `eq_ci`, `is_tchar`, `allocated_bytes`
- Produces:
  - `pub struct Limits { max_header_bytes int = 65536; max_body_bytes int = 1048576; max_headers int = 32 }`
  - `pub struct HttpError { status int; reason string }` implementing `IError` (`msg()` = reason, `code()` = status)
  - `fn refuse(status int, reason string) IError` (module-private, used by Tasks 4 and 7)
  - `pub struct Span { start int = -1; len int }`, `pub fn (s Span) found() bool`
  - `pub struct Frame { scanned int; head_end int; content_length int; chunked bool; chunk ChunkScan; expect_continue bool; continue_sent bool }`, `pub fn (mut f Frame) reset()`
  - `pub fn frame(buf []u8, mut f Frame, lim Limits) !int` — message length, or -1 when more bytes are needed
  - `pub fn header_value(head []u8, name_lower string) Span`
  - `pub struct ChunkScan`, `pub fn ChunkScan.new(body_start int) ChunkScan`
  - `pub fn scan_chunked(buf []u8, mut st ChunkScan, max_body int) !bool`
  - `pub fn decode_chunked(buf []u8, start int, mut out []u8)`

- [ ] **Step 1: Write the failing test**

`http1/frame_test.v`:

```v
module http1

const chunked_req = 'POST /c HTTP/1.1\r\nHost: x\r\ntransfer-encoding: Chunked\r\n\r\n' +
	'4;name=val\r\nWiki\r\n5 \r\npedia\r\nE\r\n in\r\n\r\nchunks.\r\n0\r\nX-Trailer: 1\r\n\r\n'

fn frame_all(raw string) !int {
	mut f := Frame{}
	return frame(raw.bytes(), mut f, Limits{})
}

fn status_of(raw string) int {
	frame_all(raw) or { return err.code() }
	return 0
}

fn test_content_length_framing() {
	get := 'GET / HTTP/1.1\r\nHost: x\r\n\r\n'
	assert frame_all(get + 'GET')! == get.len
	post := 'POST / HTTP/1.1\r\nContent-Length: 5\r\n\r\nhello'
	assert frame_all(post + 'GET / HTTP/1.1')! == post.len
	assert frame_all('POST / HTTP/1.1\r\nContent-Length: 5\r\n\r\nhel')! == -1
	assert frame_all('GET / HTTP/1.1\r\nHost: x\r\n')! == -1
	lower_cl := 'POST / HTTP/1.1\r\ncontent-length:  2 \r\n\r\n20'
	assert frame_all(lower_cl)! == lower_cl.len
}

fn test_framing_errors_carry_status() {
	assert status_of('POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\nContent-Length: 5\r\n\r\nhello') == 400
	assert status_of('POST / HTTP/1.1\r\nTransfer-Encoding: gzip\r\n\r\n') == 400
	assert status_of('POST / HTTP/1.1\r\nTransfer-Encoding: chunked, chunked\r\n\r\n0\r\n\r\n') == 400
	for cl in ['abc', '+5', '-1', '5, 5', '4294967301', '99999999999999999999', ''] {
		assert status_of('POST / HTTP/1.1\r\nContent-Length: ${cl}\r\n\r\nhello') == 400, cl
	}
	assert status_of('POST / HTTP/1.1\r\nContent-Length: 2000000\r\n\r\n') == 413
	big := 'GET / HTTP/1.1\r\nX: ' + 'a'.repeat(70000)
	assert status_of(big) == 431
	assert status_of(big + '\r\n\r\n') == 431
}

fn test_chunk_errors_carry_status() {
	head := 'POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n'
	for body in ['0x5\r\nhello\r\n0\r\n\r\n', '-5\r\nhello\r\n0\r\n\r\n',
		'000000005\r\nhello\r\n0\r\n\r\n', '5\r\nhelloX0\r\n\r\n', '5\nhello\r\n0\r\n\r\n',
		'5 x\r\nhello\r\n0\r\n\r\n', '0\r\nBad Trailer\r\n\r\n'] {
		assert status_of(head + body) == 400, body
	}
	assert status_of(head + 'ffffff\r\n') == 413
	assert status_of(head + '0\r\nX: ' + 'a'.repeat(9000) + '\r\n\r\n') == 431
	assert status_of(head + '5;' + 'e'.repeat(5000)) == 400
}

fn test_expect_continue_is_flagged_once_head_is_complete() {
	mut f := Frame{}
	raw := 'POST / HTTP/1.1\r\nExpect: 100-Continue\r\nContent-Length: 2\r\n\r\n'.bytes()
	assert frame(raw, mut f, Limits{})! == -1
	assert f.expect_continue
}

// Feeding one byte at a time must end exactly at the message end, never earlier.
fn test_frame_resumes_byte_by_byte() {
	post := 'POST /p HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\nhello'
	for msg in [chunked_req, post] {
		raw := (msg + 'GET /next HTTP/1.1\r\n\r\n').bytes()
		mut f := Frame{}
		mut done := false
		for n in 1 .. raw.len + 1 {
			got := frame(view(raw, 0, n), mut f, Limits{})!
			if got >= 0 {
				assert n == msg.len
				assert got == msg.len
				done = true
				break
			}
		}
		assert done
	}
}

fn test_decode_chunked() {
	raw := chunked_req.bytes()
	mut f := Frame{}
	assert frame(raw, mut f, Limits{})! == raw.len
	assert f.chunked
	mut out := []u8{}
	decode_chunked(raw, f.head_end, mut out)
	assert out.bytestr() == 'Wikipedia in\r\n\r\nchunks.'
}

fn test_header_value_skips_request_line_and_trims() {
	head := 'GET /content-length: HTTP/1.1\r\nHost:  a.b \r\nX-Y:\r\n\r\n'.bytes()
	h := header_value(head, 'host')
	assert str_view(head, h.start, h.len) == 'a.b'
	assert !header_value(head, 'content-length').found()
	e := header_value(head, 'x-y')
	assert e.found() && e.len == 0
}

fn test_framing_allocates_nothing() {
	get := 'GET /plaintext HTTP/1.1\r\nHost: x\r\nAccept: */*\r\n\r\n'.bytes()
	post := chunked_req.bytes()
	mut out := []u8{cap: 256}
	before := allocated_bytes()
	for _ in 0 .. 10000 {
		mut f := Frame{}
		_ = frame(get, mut f, Limits{}) or { -2 }
		mut g := Frame{}
		_ = frame(post, mut g, Limits{}) or { -2 }
		unsafe {
			out.len = 0
		}
		decode_chunked(post, g.head_end, mut out)
	}
	assert allocated_bytes() - before == 0
}
```

- [ ] **Step 2: Run it and see it fail**

Run `t2.sh` (it tests all of `http1/`). Expected: compile error on `Frame` / `frame`.

- [ ] **Step 3: Implement `http1/frame.v`**

```v
module http1

// Framing: find where the message at the front of a buffer ends, so pipelined
// requests can be served from one read. Content-Length and chunked only; anything
// a front proxy could read differently is refused (request smuggling).

pub struct Limits {
pub:
	max_header_bytes int = 64 * 1024
	max_body_bytes   int = 1024 * 1024
	max_headers      int = 32
}

// HttpError is a request the engine refuses: it answers `status` and closes.
pub struct HttpError {
	Error
pub:
	status int
	reason string
}

pub fn (e HttpError) msg() string {
	return e.reason
}

pub fn (e HttpError) code() int {
	return e.status
}

// cold: errors close the connection, so boxing them is off the hot path.
fn refuse(status int, reason string) IError {
	return IError(HttpError{
		status: status
		reason: reason
	})
}

// Span is a byte range of a buffer; start < 0 means absent.
pub struct Span {
pub:
	start int = -1
	len   int
}

pub fn (s Span) found() bool {
	return s.start >= 0
}

// Frame is the resumable framing state of the message at the front of a buffer.
pub struct Frame {
pub mut:
	scanned         int // the header terminator search resumes here
	head_end        int // index just past CRLFCRLF; 0 until the head is complete
	content_length  int
	chunked         bool
	chunk           ChunkScan
	expect_continue bool
	continue_sent   bool
}

pub fn (mut f Frame) reset() {
	f = Frame{}
}

// frame returns the length of the complete message at the front of buf, or -1 when
// more bytes are needed. f must be reset between messages. Errors are HttpError.
pub fn frame(buf []u8, mut f Frame, lim Limits) !int {
	if f.head_end == 0 {
		end := find_head_end(buf, f.scanned)
		if end < 0 {
			if buf.len > lim.max_header_bytes {
				return refuse(431, 'headers too large')
			}
			f.scanned = if buf.len > 3 { buf.len - 3 } else { 0 }
			return -1
		}
		if end > lim.max_header_bytes {
			return refuse(431, 'headers too large')
		}
		f.head_end = end
		head := view(buf, 0, end)
		te := header_value(head, 'transfer-encoding')
		cl := header_value(head, 'content-length')
		if te.found() && cl.found() {
			return refuse(400, 'transfer-encoding and content-length conflict')
		}
		if te.found() {
			if !eq_ci(str_view(head, te.start, te.len), 'chunked') {
				return refuse(400, 'transfer-encoding not supported')
			}
			f.chunked = true
			f.chunk = ChunkScan.new(end)
		} else if cl.found() {
			n := parse_content_length(view(head, cl.start, cl.len)) or {
				return refuse(400, 'bad content-length')
			}
			if n > lim.max_body_bytes {
				return refuse(413, 'payload too large')
			}
			f.content_length = n
		}
		ex := header_value(head, 'expect')
		f.expect_continue = ex.found() && eq_ci(str_view(head, ex.start, ex.len), '100-continue')
	}
	if f.chunked {
		if !scan_chunked(buf, mut f.chunk, lim.max_body_bytes)! {
			return -1
		}
		return f.chunk.pos
	}
	total := f.head_end + f.content_length
	if buf.len < total {
		return -1
	}
	return total
}

// find_head_end returns the index just past the first CRLFCRLF at or after from, or -1.
fn find_head_end(buf []u8, from int) int {
	mut i := from
	for i + 3 < buf.len {
		if buf[i] == `\r` && buf[i + 1] == `\n` && buf[i + 2] == `\r` && buf[i + 3] == `\n` {
			return i + 4
		}
		i++
	}
	return -1
}

// header_value finds the first field named name_lower (ASCII lowercase) in a
// request head and returns its value with OWS trimmed. The request line is skipped,
// lines are split on CRLF only (the parser rejects bare CR/LF later).
pub fn header_value(head []u8, name_lower string) Span {
	mut i := 0
	for i + 1 < head.len && !(head[i] == `\r` && head[i + 1] == `\n`) {
		i++
	}
	i += 2
	for i + 1 < head.len {
		mut j := i
		for j + 1 < head.len && !(head[j] == `\r` && head[j + 1] == `\n`) {
			j++
		}
		if j == i {
			break
		}
		if j - i > name_lower.len && head[i + name_lower.len] == `:` {
			mut ok := true
			for k in 0 .. name_lower.len {
				if lower(head[i + k]) != name_lower[k] {
					ok = false
					break
				}
			}
			if ok {
				mut s := i + name_lower.len + 1
				mut e := j
				for s < e && (head[s] == ` ` || head[s] == `\t`) {
					s++
				}
				for e > s && (head[e - 1] == ` ` || head[e - 1] == `\t`) {
					e--
				}
				return Span{
					start: s
					len:   e - s
				}
			}
		}
		i = j + 2
	}
	return Span{}
}

// parse_content_length accepts 1*DIGIT only (RFC 9112 §6.3): no sign, list or overflow.
fn parse_content_length(b []u8) ?int {
	if b.len == 0 || b.len > 10 {
		return none
	}
	mut n := i64(0)
	for c in b {
		if c < `0` || c > `9` {
			return none
		}
		n = n * 10 + i64(c - `0`)
	}
	if n > max_i32 {
		return none
	}
	return int(n)
}
```

- [ ] **Step 4: Implement `http1/chunked.v`**

Ported from `git show main:http/chunked.v` with three changes: errors carry a status, the scan no longer decodes (`decode_chunked` does, after framing accepted the body), and trailer checks use indexes instead of slices.

```v
module http1

// Chunked request bodies (RFC 9112 §7.1). frame() accepts a chunked body with
// scan_chunked; the engine then copies its data out with decode_chunked. Both walk
// the same bytes, so they cannot disagree on where the message ends.

const max_chunk_size_digits = 8 // 0xffffffff; the body limit cuts in long before
const max_chunk_trailer_bytes = 8192
const max_chunk_line_bytes = 4096 // size line including extensions

// ChunkScan is resumable framing state. pos is an offset into the buffer passed to
// scan_chunked and only moves past complete units, so a client sending one byte at
// a time costs one pass over the body, not one pass per read.
pub struct ChunkScan {
pub mut:
	pos int
mut:
	total         int
	in_trailers   bool
	trailer_bytes int
}

pub fn ChunkScan.new(body_start int) ChunkScan {
	return ChunkScan{
		pos: body_start
	}
}

// scan_chunked advances st over buf and returns true once the whole chunked body
// (last chunk, trailers and the final CRLF) is in buf; st.pos is then the message
// end. It returns false when more bytes are needed.
pub fn scan_chunked(buf []u8, mut st ChunkScan, max_body int) !bool {
	for !st.in_trailers {
		mut i := st.pos
		mut size := i64(0)
		mut digits := 0
		for i < buf.len {
			v := hex_value(buf[i])
			if v < 0 {
				break
			}
			digits++
			if digits > max_chunk_size_digits {
				return refuse(400, 'bad chunk size')
			}
			size = size * 16 + i64(v)
			i++
		}
		if i >= buf.len {
			return false
		}
		if digits == 0 {
			return refuse(400, 'bad chunk size')
		}
		for i < buf.len && (buf[i] == ` ` || buf[i] == `\t`) {
			i++
		}
		if i >= buf.len {
			if buf.len - st.pos > max_chunk_line_bytes {
				return refuse(400, 'chunk line too long')
			}
			return false
		}
		if buf[i] != `\r` && buf[i] != `;` {
			return refuse(400, 'bad chunk size')
		}
		i = chunk_line_end(buf, i)!
		if i < 0 {
			if buf.len - st.pos > max_chunk_line_bytes {
				return refuse(400, 'chunk line too long')
			}
			return false
		}
		if size == 0 {
			st.pos = i
			st.in_trailers = true
			break
		}
		if i64(st.total) + size > i64(max_body) {
			return refuse(413, 'payload too large')
		}
		n := int(size)
		if buf.len < i + n + 2 {
			return false
		}
		if buf[i + n] != `\r` || buf[i + n + 1] != `\n` {
			return refuse(400, 'bad chunk data')
		}
		st.total += n
		st.pos = i + n + 2
	}
	// trailer-section: field lines until an empty line. Trailers are dropped.
	for {
		start := st.pos
		i := chunk_line_end(buf, start)!
		if i < 0 {
			if buf.len - start > max_chunk_trailer_bytes {
				return refuse(431, 'chunk trailers too large')
			}
			return false
		}
		st.pos = i
		if i == start + 2 {
			return true
		}
		st.trailer_bytes += i - start
		if st.trailer_bytes > max_chunk_trailer_bytes {
			return refuse(431, 'chunk trailers too large')
		}
		mut colon := start
		for colon < i - 2 && buf[colon] != `:` {
			colon++
		}
		if colon == start || colon >= i - 2 {
			return refuse(400, 'bad chunk trailer')
		}
		for k in start .. colon {
			if !is_tchar(buf[k]) {
				return refuse(400, 'bad chunk trailer')
			}
		}
	}
	return false
}

// decode_chunked appends the data of a chunked body that scan_chunked accepted to
// out. The syntax is not re-checked.
pub fn decode_chunked(buf []u8, start int, mut out []u8) {
	mut i := start
	for {
		mut size := 0
		for i < buf.len {
			v := hex_value(buf[i])
			if v < 0 {
				break
			}
			size = size * 16 + v
			i++
		}
		for i < buf.len && buf[i] != `\n` {
			i++
		}
		i++
		if size == 0 || i + size > buf.len {
			return
		}
		unsafe { out.push_many(&u8(buf.data) + i, size) }
		i += size + 2
	}
}

// chunk_line_end returns the offset just past the CRLF that ends the line at from,
// -1 when buf ends first, or an error for a bare CR/LF or another control byte.
fn chunk_line_end(buf []u8, from int) !int {
	mut i := from
	for i < buf.len {
		c := buf[i]
		if c == `\r` {
			if i + 1 >= buf.len {
				return -1
			}
			if buf[i + 1] != `\n` {
				return refuse(400, 'bare cr')
			}
			return i + 2
		}
		if (c < 0x20 && c != `\t`) || c == 0x7f {
			return refuse(400, 'control byte in chunk line')
		}
		i++
	}
	return -1
}

fn hex_value(c u8) int {
	return match true {
		c >= `0` && c <= `9` { int(c - `0`) }
		c >= `a` && c <= `f` { int(c - `a`) + 10 }
		c >= `A` && c <= `F` { int(c - `A`) + 10 }
		else { -1 }
	}
}
```

- [ ] **Step 5: Run the tests**

Run `t2.sh`. Expected: `2 passed, 2 total` (bytes_test, frame_test).

- [ ] **Step 6: Format check and commit**

```bash
# wsl -e bash <scratchpad>/fmt.sh http1/frame.v http1/chunked.v http1/frame_test.v
git add http1/frame.v http1/chunked.v http1/frame_test.v
git commit -q -m "feat(http1): resumable Content-Length and chunked framing"
```

---

### Task 4: Span-based request head parser and fuzz suite

**Files:**
- Create: `http1/parse.v`
- Test: `http1/parse_test.v`, `http1/fuzz_test.v`

**Interfaces:**
- Consumes: Task 2 helpers; Task 3 `Span`, `Frame`, `frame`, `Limits`, `refuse`
- Produces:
  - `pub enum Method { get head post put delete patch options connect trace other }`
  - `pub fn method_of(s string) Method`
  - `pub const max_fields = 32`
  - `pub struct Field { name Span; value Span }`
  - `pub struct Head { method Method; method_raw Span; target Span; path Span; query Span; minor int; fields [32]Field; nfields int; keep_alive bool; host_seen bool; chunked bool }` (all `pub mut`)
  - `pub fn parse_head(buf []u8, head_end int, mut h Head) !`
  - `fn eq_ci_span(buf []u8, a Span, b string) bool` (module-private, used by Tasks 7 and 9)
  - `fn has_prefix_ci(s string, lower_lit string) bool` (module-private)

- [ ] **Step 1: Write the failing tests**

`http1/parse_test.v`:

```v
module http1

fn parse_msg(raw string) !Head {
	buf := raw.bytes()
	mut f := Frame{}
	n := frame(buf, mut f, Limits{})!
	if n < 0 {
		return error('incomplete')
	}
	mut h := Head{}
	parse_head(buf, f.head_end, mut h)!
	return h
}

fn span_str(raw string, s Span) string {
	return raw.bytes()[s.start..s.start + s.len].bytestr()
}

fn test_request_line() {
	raw := 'GET /hi/there?x=1&y=2 HTTP/1.1\r\nHost: localhost\r\nUser-Agent: t\r\n\r\n'
	h := parse_msg(raw)!
	assert h.method == .get
	assert span_str(raw, h.path) == '/hi/there'
	assert span_str(raw, h.query) == 'x=1&y=2'
	assert h.minor == 1
	assert h.nfields == 2
	assert span_str(raw, h.fields[1].name) == 'User-Agent'
	assert span_str(raw, h.fields[1].value) == 't'
	assert h.host_seen && h.keep_alive
}

fn test_targets() {
	abs := 'GET http://example.com/a/b?q=1 HTTP/1.1\r\nHost: x\r\n\r\n'
	h := parse_msg(abs)!
	assert span_str(abs, h.path) == '/a/b'
	assert span_str(abs, h.query) == 'q=1'
	bare := 'GET HTTPS://example.com HTTP/1.1\r\nHost: x\r\n\r\n'
	hb := parse_msg(bare)!
	assert hb.path.len == 0 && hb.query.len == 0
	star := 'OPTIONS * HTTP/1.1\r\nHost: x\r\n\r\n'
	hs := parse_msg(star)!
	assert hs.method == .options && span_str(star, hs.path) == '*'
	assert parse_msg('GET /x HTTP/1.1\r\nHost: x\r\n\r\n')!.query.len == 0
	assert method_of('PATCH') == .patch && method_of('get') == .other && method_of('PURGE') == .other
}

fn test_keep_alive_rules() {
	assert parse_msg('GET / HTTP/1.1\r\nHost: x\r\n\r\n')!.keep_alive
	assert !parse_msg('GET / HTTP/1.1\r\nHost: x\r\nConnection: Close\r\n\r\n')!.keep_alive
	assert !parse_msg('GET / HTTP/1.0\r\n\r\n')!.keep_alive
	assert parse_msg('GET / HTTP/1.0\r\nConnection: Keep-Alive\r\n\r\n')!.keep_alive
	assert parse_msg('GET / HTTP/1.1\r\nHost: x\r\nConnection: keep-alive, Upgrade\r\n\r\n')!.keep_alive
	assert !parse_msg('GET / HTTP/1.1\r\nHost: x\r\nConnection: upgrade,close\r\n\r\n')!.keep_alive
}

fn test_unsupported_version_is_505() {
	parse_msg('GET / HTTP/2.0\r\n\r\n') or {
		assert err.code() == 505
		return
	}
	assert false, 'HTTP/2.0 accepted'
}

fn test_too_many_fields_is_431() {
	mut raw := 'GET / HTTP/1.1\r\nHost: x\r\n'
	for i in 0 .. 32 {
		raw += 'X-${i}: v\r\n'
	}
	parse_msg(raw + '\r\n') or {
		assert err.code() == 431
		return
	}
	assert false, '33 fields accepted'
}

fn test_parse_allocates_nothing() {
	buf := 'GET /baseline11?a=13&b=42 HTTP/1.1\r\nHost: localhost\r\nUser-Agent: wrk\r\nAccept: */*\r\nConnection: keep-alive\r\n\r\n'.bytes()
	mut f := Frame{}
	n := frame(buf, mut f, Limits{})!
	assert n == buf.len
	mut h := Head{}
	before := allocated_bytes()
	for _ in 0 .. 10000 {
		parse_head(buf, f.head_end, mut h) or { panic(err) }
	}
	assert allocated_bytes() - before == 0
}
```

`http1/fuzz_test.v` (ported from `git show main:http/fuzz_test.v`: same idea, seeds now include a chunked body, entry point is frame + parse):

```v
module http1

import os
import rand

fn frame_and_parse(b []u8) !Head {
	mut f := Frame{}
	n := frame(b, mut f, Limits{})!
	if n < 0 {
		return error('incomplete')
	}
	mut h := Head{}
	parse_head(b, f.head_end, mut h)!
	return h
}

// Framing a front proxy might read differently than we do. Every case must be
// refused (the engine answers 4xx and closes), never silently "fixed".
fn test_rejects_ambiguous_framing() {
	bad := [
		'POST / HTTP/1.1\r\nHost: x\r\nContent-Length : 5\r\n\r\nhello',
		'POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\nContent-Length: 6\r\n\r\nhelloo',
		'POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\nContent-Length: 5\r\n\r\nhello',
		'POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 5, 5\r\n\r\nhello',
		'POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 5abc\r\n\r\nhello',
		'POST / HTTP/1.1\r\nHost: x\r\nContent-Length: +5\r\n\r\nhello',
		'POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 0x5\r\n\r\nhello',
		'POST / HTTP/1.1\r\nHost: x\r\nContent-Length: \r\n\r\n',
		'POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 4294967301\r\n\r\nhello',
		'POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 99999999999999999999999\r\n\r\nhello',
		'GET / HTTP/1.1\r\nHost: x\r\n folded: value\r\n\r\n',
		'GET / HTTP/1.1\r\nHost: x\r\nX: a\nContent-Length: 5\r\n\r\nhello',
		'GET / HTTP/1.1\r\nHost: x\r\nX: a\rb\r\n\r\n',
		'GET / HTTP/1.1\r\nHost: x\r\nX: a\x00b\r\n\r\n',
		'GET / HTTP/1.1\r\nHost: a\r\nHost: b\r\n\r\n',
		'GET / HTTP/1.1\r\nHost: x\r\nX(y): z\r\n\r\n',
		'GET / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding : chunked\r\n\r\n',
		'GET /a\nb HTTP/1.1\r\nHost: x\r\n\r\n',
		'POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: gzip, chunked\r\n\r\n0\r\n\r\n',
		'POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked, chunked\r\n\r\n0\r\n\r\n',
		'POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n',
		'POST / HTTP/1.0\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n',
		'POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n0x5\r\nhello\r\n0\r\n\r\n',
		'POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n-5\r\nhello\r\n0\r\n\r\n',
		'POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n000000005\r\nhello\r\n0\r\n\r\n',
		'POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhelloX0\r\n\r\n',
		'POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n5\nhello\r\n0\r\n\r\n',
		'POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n5 x\x00\r\nhello\r\n0\r\n\r\n',
		'POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhel',
		'POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n0\r\nBad Trailer\r\n\r\n',
		'POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n',
		' GET / HTTP/1.1\r\nHost: x\r\n\r\n',
		'GET  / HTTP/1.1\r\nHost: x\r\n\r\n',
		'GET / HTTP/1.1 \r\nHost: x\r\n\r\n',
		'G(T / HTTP/1.1\r\nHost: x\r\n\r\n',
		'GET foo HTTP/1.1\r\nHost: x\r\n\r\n',
	]
	for raw in bad {
		if _ := frame_and_parse(raw.bytes()) {
			assert false, 'accepted: ${raw.replace('\r', '\\r').replace('\n', '\\n')}'
		}
	}
}

fn test_accepts_well_formed_edges() {
	ok := [
		'GET / HTTP/1.1\r\nHost: x\r\nX-Tab:\tv\t\r\n\r\n',
		'POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 0\r\n\r\n',
		'POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 005\r\n\r\nhello',
		"GET / HTTP/1.1\r\nHost: x\r\nX-Ok!#$%&'*+-.^_`|~: v\r\n\r\n",
		'GET / HTTP/1.1\r\nHost: x\r\nX-Utf8: caf\xc3\xa9\r\n\r\n',
		'GET / HTTP/1.1\r\nHost: x\r\nX-Empty:\r\n\r\n',
	]
	for raw in ok {
		frame_and_parse(raw.bytes()) or { assert false, '${raw}: ${err.msg()}' }
	}
}

const fuzz_seeds = [
	'GET /hi/tunay?x=1 HTTP/1.1\r\nHost: localhost\r\nUser-Agent: t\r\n\r\n',
	'POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\nhello',
	'OPTIONS * HTTP/1.1\r\nHost: x\r\n\r\n',
	'GET http://x/a/../b?q HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n',
	'POST /c HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n4;ext=1\r\nWiki\r\n5\r\npedia\r\n0\r\nX-T: 1\r\n\r\n',
]

const fuzz_tokens = [':', ' ', '\t', '\r', '\n', '\r\n', '\r\n\r\n', '\x00', '\xff', ',',
	'Content-Length: ', 'Transfer-Encoding: ', 'Host: ', 'Connection: close', '%', '?', '/../',
	'-1', '4294967296', 'HTTP/1.1', 'HTTP/1.0', ';', '0\r\n\r\n']

// Random mutations over seed requests. Invariants: no panic (V aborts on OOB), and
// every span of an accepted head lies inside the buffer.
fn test_fuzz_parse() {
	iters := os.getenv_opt('VILTRUM_FUZZ_ITERS') or { '20000' }.int()
	rand.seed([u32(0x5eed), 0x1])
	for _ in 0 .. iters {
		mut b := fuzz_seeds[rand.intn(fuzz_seeds.len) or { 0 }].bytes()
		for _ in 0 .. 1 + (rand.intn(4) or { 0 }) {
			b = mutate(b)
		}
		h := frame_and_parse(b) or { continue }
		assert h.nfields <= max_fields
		assert h.path.start + h.path.len <= b.len
		assert h.query.start + h.query.len <= b.len
		for k in 0 .. h.nfields {
			f := h.fields[k]
			assert f.name.len > 0 && f.name.start + f.name.len <= b.len
			assert f.value.start + f.value.len <= b.len
		}
	}
}

fn mutate(b []u8) []u8 {
	mut out := b.clone()
	pos := if out.len == 0 { 0 } else { rand.intn(out.len) or { 0 } }
	op := rand.intn(5) or { 0 }
	match op {
		0 {
			if out.len > 0 {
				out[pos] = u8(rand.intn(256) or { 0 })
			}
		}
		1 {
			if out.len > 0 {
				out.delete(pos)
			}
		}
		2 {
			out.insert(pos, fuzz_tokens[rand.intn(fuzz_tokens.len) or { 0 }].bytes())
		}
		3 {
			end := pos + (rand.intn(16) or { 0 })
			out = out[..pos].clone()
			out << b[if end < b.len { end } else { b.len }..]
		}
		else {
			out = out[..pos].clone()
		}
	}
	return out
}
```

- [ ] **Step 2: Run them and see them fail**

Run `t2.sh`. Expected: compile error on `Head` / `parse_head`.

- [ ] **Step 3: Implement `http1/parse.v`**

```v
module http1

// Request head parser. It validates the head and records spans into the message
// buffer; nothing is copied. The rules are the v0.13 ones: a front proxy and we
// must never disagree about a request (smuggling), so ambiguity is refused.

pub enum Method {
	get
	head
	post
	put
	delete
	patch
	options
	connect
	trace
	other
}

pub fn method_of(s string) Method {
	return match s {
		'GET' { .get }
		'HEAD' { .head }
		'POST' { .post }
		'PUT' { .put }
		'DELETE' { .delete }
		'PATCH' { .patch }
		'OPTIONS' { .options }
		'CONNECT' { .connect }
		'TRACE' { .trace }
		else { .other }
	}
}

pub const max_fields = 32

pub struct Field {
pub:
	name  Span
	value Span
}

// Head is a parsed request head. Every Span indexes the message buffer.
pub struct Head {
pub mut:
	method     Method
	method_raw Span
	target     Span
	path       Span // len 0 means "/" (absolute-form target without a path)
	query      Span
	minor      int // the x of HTTP/1.x
	fields     [max_fields]Field
	nfields    int
	keep_alive bool
	host_seen  bool
	chunked    bool
}

// parse_head validates and indexes buf[0..head_end] (head_end is just past CRLFCRLF,
// as found by frame). Errors are HttpError.
pub fn parse_head(buf []u8, head_end int, mut h Head) ! {
	h.nfields = 0
	h.host_seen = false
	h.chunked = false
	mut conn_close := false
	mut conn_keep := false
	le := line_end(buf, 0, head_end)!
	parse_request_line(buf, le, mut h)!
	mut p := le + 2
	for p < head_end - 2 {
		e := line_end(buf, p, head_end)!
		if buf[p] == ` ` || buf[p] == `\t` {
			return refuse(400, 'obs-fold')
		}
		mut colon := p
		for colon < e && buf[colon] != `:` {
			colon++
		}
		if colon == e {
			return refuse(400, 'bad header line')
		}
		if colon == p {
			return refuse(400, 'empty header name')
		}
		for k in p .. colon {
			if !is_tchar(buf[k]) {
				return refuse(400, 'bad header name')
			}
		}
		mut vs := colon + 1
		mut ve := e
		for vs < ve && (buf[vs] == ` ` || buf[vs] == `\t`) {
			vs++
		}
		for ve > vs && (buf[ve - 1] == ` ` || buf[ve - 1] == `\t`) {
			ve--
		}
		for k in vs .. ve {
			c := buf[k]
			if (c < 0x20 && c != `\t`) || c == 0x7f {
				return refuse(400, 'bad header value')
			}
		}
		if h.nfields == max_fields {
			return refuse(431, 'too many header fields')
		}
		name := Span{
			start: p
			len:   colon - p
		}
		value := Span{
			start: vs
			len:   ve - vs
		}
		nm := str_view(buf, name.start, name.len)
		if eq_ci(nm, 'content-length') || eq_ci(nm, 'host') {
			for k in 0 .. h.nfields {
				if eq_ci_span(buf, h.fields[k].name, nm) {
					return refuse(400, 'duplicate framing header')
				}
			}
			if eq_ci(nm, 'host') {
				h.host_seen = true
			}
		} else if eq_ci(nm, 'transfer-encoding') {
			if h.chunked {
				return refuse(400, 'duplicate transfer-encoding')
			}
			h.chunked = true
		} else if eq_ci(nm, 'connection') {
			scan_connection(buf, value, mut conn_close, mut conn_keep)
		}
		h.fields[h.nfields] = Field{
			name:  name
			value: value
		}
		h.nfields++
		p = e + 2
	}
	if h.chunked && h.minor == 0 {
		return refuse(400, 'transfer-encoding on HTTP/1.0')
	}
	h.keep_alive = if h.minor == 1 { !conn_close } else { conn_keep && !conn_close }
}

fn parse_request_line(buf []u8, le int, mut h Head) ! {
	mut sp1 := -1
	mut sp2 := -1
	for k in 0 .. le {
		c := buf[k]
		if c < 0x20 || c == 0x7f {
			return refuse(400, 'bad request line')
		}
		if c == ` ` {
			if sp1 < 0 {
				sp1 = k
			} else if sp2 < 0 {
				sp2 = k
			} else {
				return refuse(400, 'bad request line')
			}
		}
	}
	if sp1 <= 0 || sp2 < 0 || sp2 == sp1 + 1 || sp2 == le - 1 {
		return refuse(400, 'bad request line')
	}
	for k in 0 .. sp1 {
		if !is_tchar(buf[k]) {
			return refuse(400, 'bad method')
		}
	}
	h.method_raw = Span{
		start: 0
		len:   sp1
	}
	h.method = method_of(str_view(buf, 0, sp1))
	ver := str_view(buf, sp2 + 1, le - sp2 - 1)
	if ver == 'HTTP/1.1' {
		h.minor = 1
	} else if ver == 'HTTP/1.0' {
		h.minor = 0
	} else if has_prefix_ci(ver, 'http/') {
		return refuse(505, 'http version not supported')
	} else {
		return refuse(400, 'bad version')
	}
	ts := sp1 + 1
	h.target = Span{
		start: ts
		len:   sp2 - ts
	}
	if sp2 - ts == 1 && buf[ts] == `*` {
		h.path = Span{
			start: ts
			len:   1
		}
		h.query = Span{
			start: sp2
			len:   0
		}
		return
	}
	mut ps := ts
	if buf[ts] != `/` {
		t := str_view(buf, ts, sp2 - ts)
		skip := if has_prefix_ci(t, 'http://') {
			7
		} else if has_prefix_ci(t, 'https://') {
			8
		} else {
			return refuse(400, 'bad request target')
		}
		ps = ts + skip
		for ps < sp2 && buf[ps] != `/` && buf[ps] != `?` {
			ps++
		}
	}
	mut q := ps
	for q < sp2 && buf[q] != `?` {
		q++
	}
	h.path = Span{
		start: ps
		len:   q - ps
	}
	h.query = if q < sp2 {
		Span{
			start: q + 1
			len:   sp2 - q - 1
		}
	} else {
		Span{
			start: sp2
			len:   0
		}
	}
}

// line_end returns the index of the CR ending the line that starts at from. A bare
// CR or LF, or no CRLF before limit, is an error.
fn line_end(buf []u8, from int, limit int) !int {
	mut i := from
	for i < limit {
		c := buf[i]
		if c == `\n` {
			return refuse(400, 'bare lf')
		}
		if c == `\r` {
			if i + 1 >= limit || buf[i + 1] != `\n` {
				return refuse(400, 'bare cr')
			}
			return i
		}
		i++
	}
	return refuse(400, 'unterminated line')
}

// scan_connection reads the comma-separated tokens of a Connection value.
fn scan_connection(buf []u8, v Span, mut close_ bool, mut keep bool) {
	end := v.start + v.len
	mut i := v.start
	for i < end {
		for i < end && (buf[i] == ` ` || buf[i] == `\t` || buf[i] == `,`) {
			i++
		}
		s := i
		for i < end && buf[i] != `,` {
			i++
		}
		mut e := i
		for e > s && (buf[e - 1] == ` ` || buf[e - 1] == `\t`) {
			e--
		}
		tok := str_view(buf, s, e - s)
		if eq_ci(tok, 'close') {
			close_ = true
		} else if eq_ci(tok, 'keep-alive') {
			keep = true
		}
	}
}

// eq_ci_span compares the bytes of a with b, ignoring ASCII case on both sides.
fn eq_ci_span(buf []u8, a Span, b string) bool {
	if a.len != b.len {
		return false
	}
	for k in 0 .. a.len {
		if lower(buf[a.start + k]) != lower(b[k]) {
			return false
		}
	}
	return true
}

fn has_prefix_ci(s string, lower_lit string) bool {
	if s.len < lower_lit.len {
		return false
	}
	for k in 0 .. lower_lit.len {
		if lower(s[k]) != lower_lit[k] {
			return false
		}
	}
	return true
}
```

- [ ] **Step 4: Run the tests and the long fuzz**

Run `t2.sh`. Expected: `4 passed, 4 total`.
Then scratchpad `fuzz.sh`:

```bash
export PATH=$HOME/v:$PATH
cd /mnt/c/Users/tunay/Documents/GitHub/viltrum
VILTRUM_FUZZ_ITERS=500000 v test http1/fuzz_test.v 2>&1 | grep -E 'FAIL|Summary|>'
```

Expected: `1 passed, 1 total`.

- [ ] **Step 5: Format check and commit**

```bash
# wsl -e bash <scratchpad>/fmt.sh http1/parse.v http1/parse_test.v http1/fuzz_test.v
git add http1/parse.v http1/parse_test.v http1/fuzz_test.v
git commit -q -m "feat(http1): span-based request head parser with the v0.13 strictness"
```

---

### Task 5: Response writer primitives and the Date cache

**Files:**
- Create: `http1/writer.v`, `http1/date.v`
- Test: `http1/writer_test.v`

**Interfaces:**
- Consumes: Task 2 `append_str`, `append_int`, `allocated_bytes`
- Produces:
  - `pub fn reason(status int) string`
  - `pub fn write_status_line(mut out []u8, status int)`
  - `pub fn write_header(mut out []u8, name string, value string)`
  - `pub fn body_allowed(status int) bool` (false for 1xx, 204, 304)
  - `pub struct DateCache`, `pub fn (mut d DateCache) write(mut out []u8)` — appends `Date: <IMF-fixdate>\r\n`

- [ ] **Step 1: Write the failing test**

`http1/writer_test.v`:

```v
module http1

import time

fn test_status_line_and_headers() {
	mut out := []u8{}
	write_status_line(mut out, 200)
	write_header(mut out, 'Content-Type', 'text/plain')
	assert out.bytestr() == 'HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n'
	unsafe {
		out.len = 0
	}
	write_status_line(mut out, 599)
	assert out.bytestr() == 'HTTP/1.1 599 Unknown\r\n'
	assert reason(404) == 'Not Found' && reason(413) == 'Content Too Large'
	assert !body_allowed(204) && !body_allowed(304) && !body_allowed(100) && body_allowed(200)
}

fn test_date_matches_time_formatting() {
	mut d := DateCache{}
	mut ts := i64(0)
	for ts < 4102444800 {
		d.format(time.unix(ts))
		want := time.unix(ts).custom_format('ddd, DD MMM YYYY HH:mm:ss') + ' GMT'
		assert d.text[..].bytestr() == want, ts.str()
		ts += 839_999
	}
}

fn test_date_write_allocates_nothing() {
	mut d := DateCache{}
	mut out := []u8{cap: 4096}
	d.write(mut out)
	assert out.bytestr().starts_with('Date: ') && out.len == 37
	before := allocated_bytes()
	for _ in 0 .. 10000 {
		unsafe {
			out.len = 0
		}
		d.write(mut out)
		write_status_line(mut out, 200)
		write_header(mut out, 'Server', 'viltrum')
	}
	assert allocated_bytes() - before == 0
}
```

- [ ] **Step 2: Run it and see it fail**

Run `t2.sh`. Expected: compile error on `write_status_line`.

- [ ] **Step 3: Implement `http1/writer.v`**

```v
module http1

pub const crlf = '\r\n'

// reason is the reason phrase for a status code (RFC 9110 names).
pub fn reason(status int) string {
	return match status {
		100 { 'Continue' }
		101 { 'Switching Protocols' }
		200 { 'OK' }
		201 { 'Created' }
		202 { 'Accepted' }
		204 { 'No Content' }
		206 { 'Partial Content' }
		301 { 'Moved Permanently' }
		302 { 'Found' }
		303 { 'See Other' }
		304 { 'Not Modified' }
		307 { 'Temporary Redirect' }
		308 { 'Permanent Redirect' }
		400 { 'Bad Request' }
		401 { 'Unauthorized' }
		403 { 'Forbidden' }
		404 { 'Not Found' }
		405 { 'Method Not Allowed' }
		406 { 'Not Acceptable' }
		408 { 'Request Timeout' }
		409 { 'Conflict' }
		410 { 'Gone' }
		411 { 'Length Required' }
		412 { 'Precondition Failed' }
		413 { 'Content Too Large' }
		414 { 'URI Too Long' }
		415 { 'Unsupported Media Type' }
		416 { 'Range Not Satisfiable' }
		417 { 'Expectation Failed' }
		422 { 'Unprocessable Content' }
		426 { 'Upgrade Required' }
		428 { 'Precondition Required' }
		429 { 'Too Many Requests' }
		431 { 'Request Header Fields Too Large' }
		500 { 'Internal Server Error' }
		501 { 'Not Implemented' }
		502 { 'Bad Gateway' }
		503 { 'Service Unavailable' }
		504 { 'Gateway Timeout' }
		505 { 'HTTP Version Not Supported' }
		else { 'Unknown' }
	}
}

pub fn write_status_line(mut out []u8, status int) {
	append_str(mut out, 'HTTP/1.1 ')
	append_int(mut out, status)
	out << ` `
	append_str(mut out, reason(status))
	append_str(mut out, crlf)
}

pub fn write_header(mut out []u8, name string, value string) {
	append_str(mut out, name)
	append_str(mut out, ': ')
	append_str(mut out, value)
	append_str(mut out, crlf)
}

// body_allowed is false for statuses that must not carry a body or a Content-Length.
pub fn body_allowed(status int) bool {
	return status >= 200 && status != 204 && status != 304
}
```

- [ ] **Step 4: Implement `http1/date.v`**

```v
module http1

import time

fn C.time(t voidptr) i64

const day_names = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun']
const month_names = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov',
	'Dec']

// DateCache holds the IMF-fixdate for the current second. A worker owns one, so
// the header is formatted at most once per second per worker.
pub struct DateCache {
mut:
	sec  i64 = -1
	text [29]u8
}

// write appends `Date: <IMF-fixdate>\r\n`.
pub fn (mut d DateCache) write(mut out []u8) {
	now := C.time(unsafe { nil })
	if now != d.sec {
		d.sec = now
		d.format(time.unix(now))
	}
	append_str(mut out, 'Date: ')
	unsafe { out.push_many(&d.text[0], 29) }
	append_str(mut out, crlf)
}

// format writes "Sun, 06 Nov 1994 08:49:37 GMT" into text.
fn (mut d DateCache) format(t time.Time) {
	mut i := d.put_str(0, day_names[t.day_of_week() - 1])
	i = d.put_str(i, ', ')
	i = d.put2(i, t.day)
	d.text[i] = ` `
	i = d.put_str(i + 1, month_names[t.month - 1])
	d.text[i] = ` `
	i = d.put2(i + 1, t.year / 100)
	i = d.put2(i, t.year % 100)
	d.text[i] = ` `
	i = d.put2(i + 1, t.hour)
	d.text[i] = `:`
	i = d.put2(i + 1, t.minute)
	d.text[i] = `:`
	i = d.put2(i + 1, t.second)
	d.put_str(i, ' GMT')
}

fn (mut d DateCache) put_str(i int, s string) int {
	for k in 0 .. s.len {
		d.text[i + k] = s[k]
	}
	return i + s.len
}

fn (mut d DateCache) put2(i int, n int) int {
	d.text[i] = u8(`0` + n / 10)
	d.text[i + 1] = u8(`0` + n % 10)
	return i + 2
}
```

- [ ] **Step 5: Run the tests**

Run `t2.sh`. Expected: `5 passed, 5 total`.

- [ ] **Step 6: Format check and commit**

```bash
# wsl -e bash <scratchpad>/fmt.sh http1/writer.v http1/date.v http1/writer_test.v
git add http1/writer.v http1/date.v http1/writer_test.v
git commit -q -m "feat(http1): response writer primitives and a per-second Date cache"
```

---

### Task 6: Allocation-free JSON encoder

**Files:**
- Create: `jsonenc/encode.v`
- Test: `jsonenc/encode_test.v`

**Interfaces:**
- Consumes: nothing (standalone module: `http1` will import it, so it must not import `http1`)
- Produces: `pub fn encode_into[T](mut out []u8, val T)` — appends compact JSON (no spaces) for integers, floats, bools, strings, arrays and structs (fields in declaration order, by field name). Unsupported types are a compile error.

- [ ] **Step 1: Write the failing test**

`jsonenc/encode_test.v`:

```v
module jsonenc

import json
import math

struct Rating {
	score int
	count int
}

struct Item {
	id       int
	name     string
	category string
	price    int
	quantity int
	active   bool
	tags     []string
	rating   Rating
	total    i64
}

struct Page {
	items []Item
	count int
}

fn enc[T](v T) string {
	mut out := []u8{}
	encode_into(mut out, v)
	return out.bytestr()
}

fn sample() Page {
	a := Item{
		id:       1
		name:     'Alpha Widget'
		category: 'electronics'
		price:    328
		quantity: 15
		active:   true
		tags:     ['sale', 'new']
		rating:   Rating{
			score: 48
			count: 53
		}
		total:    4920
	}
	b := Item{
		id:       2
		name:     'Pro Valve'
		category: 'tools'
		price:    347
		quantity: 95
		rating:   Rating{
			score: 15
			count: 259
		}
		total:    32965
	}
	return Page{
		items: [a, b]
		count: 2
	}
}

fn test_matches_vlib_json_for_plain_data() {
	p := sample()
	assert enc(p) == json.encode(p)
	assert enc([1, 2, 3]) == '[1,2,3]'
	assert enc([]int{}) == '[]'
	assert enc(true) == 'true'
	assert enc(u64(18446744073709551615)) == '18446744073709551615'
	assert enc(i64(-9223372036854775807 - 1)) == '-9223372036854775808'
}

fn test_strings_are_escaped() {
	assert enc('plain') == '"plain"'
	assert enc('q"b\\s/') == '"q\\"b\\\\s/"'
	assert enc('a\nb\rc\td\x08e\x0cf') == '"a\\nb\\rc\\td\\be\\ff"'
	assert enc('\x01\x1f') == '"\\u0001\\u001f"'
	assert enc('café') == '"café"'
}

fn test_floats_round_trip() {
	for f in [0.0, 1.5, -2.25, 0.1, 1e300, 123456.789] {
		assert enc(f).f64() == f, f.str()
	}
	assert enc(math.nan()) == 'null'
	assert enc(math.inf(1)) == 'null'
}

fn test_encoding_allocates_nothing() {
	p := sample()
	mut out := []u8{cap: 4096}
	encode_into(mut out, p)
	before := u64(gc_heap_usage().total_bytes)
	for _ in 0 .. 10000 {
		unsafe {
			out.len = 0
		}
		encode_into(mut out, p)
		encode_into(mut out, 3.25)
	}
	assert u64(gc_heap_usage().total_bytes) - before == 0
}
```

- [ ] **Step 2: Run it and see it fail**

Scratchpad `t6.sh`:

```bash
export PATH=$HOME/v:$PATH
cd /mnt/c/Users/tunay/Documents/GitHub/viltrum
v test jsonenc/ 2>&1 | grep -E 'FAIL|Summary|error|>' | head
```

Expected: compile error, `unknown function: encode_into`.

- [ ] **Step 3: Implement `jsonenc/encode.v`**

```v
module jsonenc

import math

// encode_into appends the JSON encoding of val to out without allocating. It is
// generated per type at compile time, so there is no reflection at run time.
pub fn encode_into[T](mut out []u8, val T) {
	$if T.unaliased_typ is string {
		write_string(mut out, string(val))
	} $else $if T.unaliased_typ is bool {
		if bool(val) {
			push(mut out, 'true')
		} else {
			push(mut out, 'false')
		}
	} $else $if T.unaliased_typ is u64 {
		write_u64(mut out, u64(val))
	} $else $if T.unaliased_typ is $int {
		write_i64(mut out, i64(val))
	} $else $if T.unaliased_typ is $float {
		write_f64(mut out, f64(val))
	} $else $if T.unaliased_typ is $array {
		out << `[`
		for i, item in val {
			if i > 0 {
				out << `,`
			}
			encode_into(mut out, item)
		}
		out << `]`
	} $else $if T.unaliased_typ is $struct {
		out << `{`
		mut first := true
		$for field in T.fields {
			if !first {
				out << `,`
			}
			first = false
			out << `"`
			push(mut out, field.name)
			out << `"`
			out << `:`
			encode_into(mut out, val.$(field.name))
		}
		out << `}`
	} $else {
		$compile_error('viltrum.jsonenc: unsupported type')
	}
}

@[inline]
fn push(mut out []u8, s string) {
	if s.len > 0 {
		unsafe { out.push_many(s.str, s.len) }
	}
}

const hex_digits = '0123456789abcdef'

// write_string escapes per RFC 8259: quote, backslash and control bytes. UTF-8
// passes through unchanged.
fn write_string(mut out []u8, s string) {
	out << `"`
	mut run := 0
	for i in 0 .. s.len {
		c := s[i]
		if c >= 0x20 && c != `"` && c != `\\` {
			continue
		}
		unsafe { out.push_many(s.str + run, i - run) }
		run = i + 1
		out << `\\`
		match c {
			`"` { out << `"` }
			`\\` { out << `\\` }
			`\n` { out << `n` }
			`\r` { out << `r` }
			`\t` { out << `t` }
			0x08 { out << `b` }
			0x0c { out << `f` }
			else {
				push(mut out, 'u00')
				out << hex_digits[c >> 4]
				out << hex_digits[c & 0xf]
			}
		}
	}
	unsafe { out.push_many(s.str + run, s.len - run) }
	out << `"`
}

fn write_u64(mut out []u8, n u64) {
	if n == 0 {
		out << `0`
		return
	}
	mut tmp := [20]u8{}
	mut i := 20
	mut v := n
	for v > 0 {
		i--
		tmp[i] = u8(`0` + v % 10)
		v /= 10
	}
	unsafe { out.push_many(&tmp[i], 20 - i) }
}

fn write_i64(mut out []u8, n i64) {
	if n < 0 {
		out << `-`
		write_u64(mut out, u64(-(n + 1)) + 1)
		return
	}
	write_u64(mut out, u64(n))
}

// write_f64 prints the shortest-safe %.17g form; NaN and infinities are null.
fn write_f64(mut out []u8, f f64) {
	if math.is_nan(f) || math.is_inf(f, 0) {
		push(mut out, 'null')
		return
	}
	mut tmp := [32]u8{}
	n := C.snprintf(&char(&tmp[0]), 32, c'%.17g', f)
	unsafe { out.push_many(&tmp[0], n) }
}
```

- [ ] **Step 4: Run the tests**

Run `t6.sh`. Expected: `1 passed, 1 total`. If `json.encode(p)` differs only in field formatting, print both strings and compare; V's `json` emits the same compact form for ints, bools, strings and nested arrays.

- [ ] **Step 5: Format check and commit**

```bash
# wsl -e bash <scratchpad>/fmt.sh jsonenc/encode.v jsonenc/encode_test.v
git add jsonenc
git commit -q -m "feat(jsonenc): compile-time JSON encoder that writes into a buffer"
```

---

### Task 7: Ctx — request views, response writer, middleware chain

**Files:**
- Create: `http1/ctx.v`, `http1/testing.v`
- Test: `http1/ctx_test.v`

**Interfaces:**
- Consumes: Task 2 helpers; Task 3 `Span`, `Frame`, `frame`, `Limits`, `decode_chunked`, `hex_value`; Task 4 `Head`, `Method`, `parse_head`, `eq_ci_span`; Task 5 writer + `DateCache`; Task 6 `jsonenc.encode_into`
- Produces:
  - `pub type Handler = fn (mut c Ctx)`
  - `pub const ct_text = 'text/plain; charset=utf-8'`, `pub const ct_json = 'application/json'`
  - `pub struct Ctx` with `pub mut` fields: `buf []u8`, `head Head`, `body_bytes []u8`, `param_names []string`, `params [8]Span` (absolute offsets into `buf`), `nparams int`, `status int`, `close_after bool`, `responded bool`, `capture bool`, `cap_type string`, `chain []Handler`, `idx int`, `worker int`, `out []u8`, `send_date bool = true`, `server string`, `date DateCache`
  - `pub fn Ctx.new() Ctx`
  - Engine side: `pub fn (mut c Ctx) begin(msg []u8)`, `pub fn (mut c Ctx) set_body(b []u8)`, `pub fn (mut c Ctx) set_chunked_body(start int)`
  - Request: `method() Method`, `path() string`, `query() string`, `header(name string) ?string`, `header_values(name string) HeaderValues` (`next() ?string`), `param(name string) ?string`, `param_int(name string) ?i64`, `query_param(name string) ?string` (mut), `query_int(name string) ?i64` (mut), `body() []u8`, `body_int() ?i64`, `worker_id() int`
  - Response: `text(status int, s string)`, `text_int(status int, n i64)`, `json[T](status int, val T)`, `bytes(status int, content_type string, data []u8)`, `no_content(status int)`, `set_header(name string, value string)`, `close()`, `captured_body() []u8`, `send_captured(body []u8, content_encoding string)`, `has_header(name string) bool` (response headers set so far)
  - Chain: `next()`
  - `pub fn test_ctx(raw string) !Ctx` — a Ctx for one raw request, response in `c.out`, Date off

- [ ] **Step 1: Write the failing test**

`http1/ctx_test.v`:

```v
module http1

struct Msg {
	message string
}

fn out_of(c Ctx) string {
	return c.out.bytestr()
}

fn test_request_accessors() {
	mut c := test_ctx('POST /u/42/files?name=a%20b&flag&x=1+2&k%65y=v HTTP/1.1\r\nHost: h\r\nX-A: 1\r\nx-a: 2\r\nContent-Length: 3\r\n\r\n 7 ')!
	assert c.method() == .post
	assert c.path() == '/u/42/files'
	assert c.query() == 'name=a%20b&flag&x=1+2&k%65y=v'
	assert c.header('host')? == 'h'
	assert c.header('X-A')? == '1'
	mut it := c.header_values('x-a')
	mut vals := []string{}
	for {
		v := it.next() or { break }
		vals << v
	}
	assert vals == ['1', '2']
	assert c.query_param('name')? == 'a b'
	assert c.query_param('flag')? == ''
	assert c.query_param('x')? == '1 2'
	assert c.query_param('key')? == 'v'
	if _ := c.query_param('missing') {
		assert false
	}
	if _ := c.header('nope') {
		assert false
	}
	assert c.body_int()? == 7
	assert c.body().bytestr() == ' 7 '
	assert test_ctx('GET HTTP://h HTTP/1.1\r\nHost: h\r\n\r\n')!.path() == '/'
}

fn test_params() {
	mut c := test_ctx('GET /u/42 HTTP/1.1\r\nHost: h\r\n\r\n')!
	c.param_names = ['id']
	c.params[0] = Span{
		start: c.head.path.start + 3
		len:   2
	}
	c.nparams = 1
	assert c.param('id')? == '42'
	assert c.param_int('id')? == 42
	if _ := c.param('other') {
		assert false
	}
}

// Review Focus 5: a decoded value stays correct after later decodes, even when the
// decode buffer has to grow.
fn test_decoded_values_survive_later_decodes() {
	long := '%41'.repeat(3000)
	mut c := test_ctx('GET /?a=%C3%A9t%C3%A9&b=${long} HTTP/1.1\r\nHost: h\r\n\r\n')!
	a := c.query_param('a')?
	b := c.query_param('b')?
	assert a == 'été'
	assert b == 'A'.repeat(3000)
	assert a == 'été'
	assert c.query_param('a')? == 'été'
}

fn test_chunked_body() {
	c := test_ctx('POST / HTTP/1.1\r\nHost: h\r\nTransfer-Encoding: chunked\r\n\r\n2\r\n20\r\n0\r\n\r\n')!
	assert c.body_int()? == 20
}

fn test_text_response() {
	mut c := test_ctx('GET / HTTP/1.1\r\nHost: h\r\n\r\n')!
	c.text(200, 'hi')
	assert out_of(c) == 'HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: 2\r\n\r\nhi'
	assert c.status == 200 && c.responded
	c.text(500, 'again')
	assert out_of(c).ends_with('\r\n\r\nhi')
}

fn test_head_keeps_length_drops_body() {
	mut c := test_ctx('HEAD / HTTP/1.1\r\nHost: h\r\n\r\n')!
	c.text(200, 'hi')
	assert out_of(c).ends_with('Content-Length: 2\r\n\r\n')
}

fn test_connection_headers() {
	mut a := test_ctx('GET / HTTP/1.0\r\nConnection: keep-alive\r\n\r\n')!
	a.text(200, 'x')
	assert out_of(a).contains('Connection: keep-alive\r\n')
	mut b := test_ctx('GET / HTTP/1.1\r\nHost: h\r\nConnection: close\r\n\r\n')!
	b.text(200, 'x')
	assert out_of(b).contains('Connection: close\r\n') && b.close_after
	mut d := test_ctx('GET / HTTP/1.1\r\nHost: h\r\n\r\n')!
	d.close()
	d.text(200, 'x')
	assert out_of(d).contains('Connection: close\r\n') && d.close_after
	mut e := test_ctx('GET / HTTP/1.1\r\nHost: h\r\n\r\n')!
	e.text(200, 'x')
	assert !out_of(e).contains('Connection:')
}

fn test_extra_headers_date_and_server() {
	mut c := test_ctx('GET / HTTP/1.1\r\nHost: h\r\n\r\n')!
	c.send_date = true
	c.server = 'viltrum'
	c.set_header('X-Id', '7')
	assert c.has_header('x-id') && !c.has_header('vary')
	c.no_content(204)
	s := out_of(c)
	assert s.starts_with('HTTP/1.1 204 No Content\r\nX-Id: 7\r\nDate: ')
	assert s.ends_with(' GMT\r\nServer: viltrum\r\n\r\n')
	assert !s.contains('Content-Length')
}

fn test_text_int_json_bytes() {
	mut a := test_ctx('GET / HTTP/1.1\r\nHost: h\r\n\r\n')!
	a.text_int(200, -42)
	assert out_of(a).ends_with('Content-Length: 3\r\n\r\n-42')
	mut b := test_ctx('GET / HTTP/1.1\r\nHost: h\r\n\r\n')!
	b.json(200, Msg{ message: 'Hello, World!' })
	assert out_of(b) == 'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 27\r\n\r\n{"message":"Hello, World!"}'
	mut d := test_ctx('GET / HTTP/1.1\r\nHost: h\r\n\r\n')!
	d.bytes(201, 'application/octet-stream', [u8(1), 2])
	assert out_of(d).starts_with('HTTP/1.1 201 Created\r\nContent-Type: application/octet-stream\r\nContent-Length: 2\r\n')
}

fn test_capture_holds_the_response() {
	mut c := test_ctx('GET / HTTP/1.1\r\nHost: h\r\n\r\n')!
	c.capture = true
	c.text(201, 'captured')
	assert c.out.len == 0
	assert c.captured_body().bytestr() == 'captured'
	c.capture = false
	c.send_captured(c.captured_body(), 'x-test')
	s := out_of(c)
	assert s.starts_with('HTTP/1.1 201 Created\r\n')
	assert s.contains('Content-Encoding: x-test\r\n') && s.ends_with('\r\n\r\ncaptured')
}

fn mw_one(mut c Ctx) {
	c.set_header('X-1', 'a')
	c.next()
}

fn mw_two(mut c Ctx) {
	c.set_header('X-2', 'b')
	c.next()
}

fn final_handler(mut c Ctx) {
	c.text(200, 'done')
}

fn test_chain_runs_in_order() {
	mut c := test_ctx('GET / HTTP/1.1\r\nHost: h\r\n\r\n')!
	c.chain = [Handler(mw_one), Handler(mw_two), Handler(final_handler)]
	c.chain[0](mut c)
	s := out_of(c)
	assert s.index('X-1')? < s.index('X-2')?
	assert s.ends_with('done')
}

fn baseline_handler(mut c Ctx) {
	sum := (c.query_int('a') or { 0 }) + (c.query_int('b') or { 0 }) + (c.body_int() or { 0 })
	c.text_int(200, sum)
}

fn json_handler(mut c Ctx) {
	c.json(200, Msg{ message: 'Hello, World!' })
}

fn serve_once(mut c Ctx, raw []u8, f Frame, n int) {
	unsafe {
		c.out.len = 0
	}
	parse_head(raw, f.head_end, mut c.head) or { panic(err) }
	c.begin(view(raw, 0, n))
	c.set_body(view(raw, f.head_end, f.content_length))
	c.chain[0](mut c)
}

fn test_handler_path_allocates_nothing() {
	raw := 'POST /baseline11?a=1%33&b=42 HTTP/1.1\r\nHost: h\r\nContent-Length: 2\r\n\r\n20'.bytes()
	mut f := Frame{}
	n := frame(raw, mut f, Limits{})!
	mut c := Ctx.new()
	c.out = []u8{cap: 4096}
	for h in [Handler(baseline_handler), Handler(json_handler)] {
		c.chain = [h]
		for _ in 0 .. 100 {
			serve_once(mut c, raw, f, n)
		}
		before := allocated_bytes()
		for _ in 0 .. 10000 {
			serve_once(mut c, raw, f, n)
		}
		assert allocated_bytes() - before == 0
	}
	assert c.out.bytestr().ends_with('{"message":"Hello, World!"}')
}
```

- [ ] **Step 2: Run it and see it fail**

Run `t2.sh`. Expected: compile error on `test_ctx` / `Ctx`.

- [ ] **Step 3: Implement `http1/ctx.v`**

```v
module http1

import viltrum.jsonenc

pub type Handler = fn (mut c Ctx)

pub const ct_text = 'text/plain; charset=utf-8'
pub const ct_json = 'application/json'

struct HeaderPair {
	name  string
	value string
}

// Ctx is one request and its response. A worker owns a single Ctx and reuses it
// for every request, so nothing in here is allocated per request.
//
// Every string or slice a Ctx returns about the request points into connection
// buffers and is valid only until the handler returns. Clone it to keep it.
pub struct Ctx {
pub mut:
	// request
	buf         []u8 // the whole message
	head        Head
	body_bytes  []u8
	param_names []string
	params      [8]Span // absolute offsets into buf
	nparams     int
	// response
	status      int // 0 until a response is written
	close_after bool
	responded   bool
	capture     bool // gzip and other body-rewriting middleware set this around next()
	cap_type    string
	// chain
	chain []Handler
	idx   int
	// per worker
	worker    int
	out       []u8 // the connection's write buffer, lent for one batch
	send_date bool = true
	server    string
	date      DateCache
mut:
	extra  [16]HeaderPair
	nextra int
	qbuf   []u8 // percent-decoded query values
	cbuf   []u8 // decoded chunked bodies
	jbuf   []u8 // JSON bodies and captured bodies
}

pub fn Ctx.new() Ctx {
	return Ctx{
		qbuf: []u8{cap: 2048}
		cbuf: []u8{cap: 8 * 1024}
		jbuf: []u8{cap: 16 * 1024}
	}
}

// begin resets per-request state for msg; c.head must already hold its parsed head.
pub fn (mut c Ctx) begin(msg []u8) {
	c.buf = msg
	c.body_bytes = view(msg, 0, 0)
	c.nparams = 0
	c.status = 0
	c.responded = false
	c.capture = false
	c.close_after = !c.head.keep_alive
	c.idx = 0
	c.nextra = 0
	unsafe {
		c.qbuf.len = 0
		c.jbuf.len = 0
	}
}

pub fn (mut c Ctx) set_body(b []u8) {
	c.body_bytes = b
}

// set_chunked_body decodes the chunked body that starts at buf[start].
pub fn (mut c Ctx) set_chunked_body(start int) {
	unsafe {
		c.cbuf.len = 0
	}
	decode_chunked(c.buf, start, mut c.cbuf)
	c.body_bytes = view(c.cbuf, 0, c.cbuf.len)
}

// --- request ---

pub fn (c &Ctx) method() Method {
	return c.head.method
}

pub fn (c &Ctx) path() string {
	if c.head.path.len == 0 {
		return '/'
	}
	return str_view(c.buf, c.head.path.start, c.head.path.len)
}

pub fn (c &Ctx) query() string {
	return str_view(c.buf, c.head.query.start, c.head.query.len)
}

// header returns the first request field named name (any case).
pub fn (c &Ctx) header(name string) ?string {
	for k in 0 .. c.head.nfields {
		f := c.head.fields[k]
		if eq_ci_span(c.buf, f.name, name) {
			return str_view(c.buf, f.value.start, f.value.len)
		}
	}
	return none
}

pub struct HeaderValues {
	c    &Ctx
	name string
mut:
	i int
}

// header_values iterates every request field named name (repeated fields are not joined).
pub fn (c &Ctx) header_values(name string) HeaderValues {
	return HeaderValues{
		c:    unsafe { c }
		name: name
	}
}

pub fn (mut it HeaderValues) next() ?string {
	for it.i < it.c.head.nfields {
		f := it.c.head.fields[it.i]
		it.i++
		if eq_ci_span(it.c.buf, f.name, it.name) {
			return str_view(it.c.buf, f.value.start, f.value.len)
		}
	}
	return none
}

pub fn (c &Ctx) param(name string) ?string {
	for k in 0 .. c.nparams {
		if c.param_names[k] == name {
			s := c.params[k]
			return str_view(c.buf, s.start, s.len)
		}
	}
	return none
}

pub fn (c &Ctx) param_int(name string) ?i64 {
	return parse_i64(c.param(name)?)
}

// query_param returns the first value of name in the query string with %XX and '+'
// decoded. A value without escapes is a view into the request; a decoded one lives
// in a per-request buffer. Both are valid until the handler returns.
pub fn (mut c Ctx) query_param(name string) ?string {
	end := c.head.query.start + c.head.query.len
	mut i := c.head.query.start
	for i < end {
		ks := i
		for i < end && c.buf[i] != `&` && c.buf[i] != `=` {
			i++
		}
		ke := i
		mut vs := i
		mut ve := i
		if i < end && c.buf[i] == `=` {
			i++
			vs = i
			for i < end && c.buf[i] != `&` {
				i++
			}
			ve = i
		}
		if i < end {
			i++
		}
		if ke > ks && c.key_is(ks, ke, name) {
			return c.decoded(vs, ve)
		}
	}
	return none
}

pub fn (mut c Ctx) query_int(name string) ?i64 {
	return parse_i64(c.query_param(name)?)
}

pub fn (c &Ctx) body() []u8 {
	return c.body_bytes
}

pub fn (c &Ctx) body_int() ?i64 {
	b := c.body_bytes
	if b.len == 0 {
		return none
	}
	return parse_i64(unsafe { tos(&u8(b.data), b.len) })
}

// worker_id is the index of the worker serving this request (0 .. workers-1), for
// per-worker state that must not be shared between threads.
pub fn (c &Ctx) worker_id() int {
	return c.worker
}

fn (mut c Ctx) key_is(s int, e int, name string) bool {
	if !needs_decode(c.buf, s, e) {
		return str_view(c.buf, s, e - s) == name
	}
	mark := c.qbuf.len
	ok := c.decoded(s, e) == name
	unsafe {
		c.qbuf.len = mark
	}
	return ok
}

fn needs_decode(buf []u8, s int, e int) bool {
	for k in s .. e {
		if buf[k] == `%` || buf[k] == `+` {
			return true
		}
	}
	return false
}

fn (mut c Ctx) decoded(s int, e int) string {
	if !needs_decode(c.buf, s, e) {
		return str_view(c.buf, s, e - s)
	}
	start := c.qbuf.len
	mut k := s
	for k < e {
		ch := c.buf[k]
		if ch == `+` {
			c.qbuf << ` `
			k++
			continue
		}
		if ch == `%` && k + 2 < e {
			hi := hex_value(c.buf[k + 1])
			lo := hex_value(c.buf[k + 2])
			if hi >= 0 && lo >= 0 {
				c.qbuf << u8(hi * 16 + lo)
				k += 3
				continue
			}
		}
		c.qbuf << ch
		k++
	}
	return str_view(c.qbuf, start, c.qbuf.len - start)
}

// --- chain ---

// next runs the rest of the chain. Middleware calls it; the final handler does not.
pub fn (mut c Ctx) next() {
	c.idx++
	if c.idx < c.chain.len {
		c.chain[c.idx](mut c)
	}
}

// --- response ---

// close asks the engine to close the connection after this response. Call it
// before writing the response so the Connection header says so.
pub fn (mut c Ctx) close() {
	c.close_after = true
}

// set_header adds a response header. At most 16; the strings must stay valid until
// the response is written (literals and request views are fine).
pub fn (mut c Ctx) set_header(name string, value string) {
	if c.nextra == c.extra.len {
		panic('viltrum: more than 16 response headers')
	}
	c.extra[c.nextra] = HeaderPair{
		name:  name
		value: value
	}
	c.nextra++
}

pub fn (c &Ctx) has_header(name string) bool {
	for k in 0 .. c.nextra {
		if eq_fold(c.extra[k].name, name) {
			return true
		}
	}
	return false
}

// eq_fold compares two strings ignoring ASCII case on both sides.
fn eq_fold(a string, b string) bool {
	if a.len != b.len {
		return false
	}
	for k in 0 .. a.len {
		if lower(a[k]) != lower(b[k]) {
			return false
		}
	}
	return true
}

pub fn (mut c Ctx) text(status int, s string) {
	c.respond(status, ct_text, s.str, s.len)
}

pub fn (mut c Ctx) text_int(status int, n i64) {
	unsafe {
		c.jbuf.len = 0
	}
	append_int(mut c.jbuf, n)
	c.respond(status, ct_text, c.jbuf.data, c.jbuf.len)
}

pub fn (mut c Ctx) json[T](status int, val T) {
	unsafe {
		c.jbuf.len = 0
	}
	jsonenc.encode_into(mut c.jbuf, val)
	c.respond(status, ct_json, c.jbuf.data, c.jbuf.len)
}

pub fn (mut c Ctx) bytes(status int, content_type string, data []u8) {
	c.respond(status, content_type, data.data, data.len)
}

pub fn (mut c Ctx) no_content(status int) {
	c.respond(status, '', unsafe { nil }, 0)
}

// captured_body is what a handler wrote while capture was on.
pub fn (c &Ctx) captured_body() []u8 {
	return view(c.jbuf, 0, c.jbuf.len)
}

// send_captured writes the captured response with body, which may be a re-encoding
// of captured_body (content_encoding names it, '' for none).
pub fn (mut c Ctx) send_captured(body []u8, content_encoding string) {
	c.write_response(c.status, c.cap_type, content_encoding, body.data, body.len)
}

fn (mut c Ctx) respond(status int, content_type string, body voidptr, n int) {
	if c.responded {
		$if viltrum_debug ? {
			panic('viltrum: second response for one request')
		}
		return
	}
	c.responded = true
	c.status = status
	if c.capture {
		c.cap_type = content_type
		if body != c.jbuf.data {
			unsafe {
				c.jbuf.len = 0
				c.jbuf.push_many(body, n)
			}
		}
		return
	}
	c.write_response(status, content_type, '', body, n)
}

fn (mut c Ctx) write_response(status int, content_type string, content_encoding string, body voidptr, n int) {
	write_status_line(mut c.out, status)
	if content_type.len > 0 {
		write_header(mut c.out, 'Content-Type', content_type)
	}
	if content_encoding.len > 0 {
		write_header(mut c.out, 'Content-Encoding', content_encoding)
	}
	if body_allowed(status) {
		append_str(mut c.out, 'Content-Length: ')
		append_int(mut c.out, n)
		append_str(mut c.out, crlf)
	}
	for k in 0 .. c.nextra {
		write_header(mut c.out, c.extra[k].name, c.extra[k].value)
	}
	if c.send_date {
		c.date.write(mut c.out)
	}
	if c.server.len > 0 {
		write_header(mut c.out, 'Server', c.server)
	}
	if c.close_after {
		append_str(mut c.out, 'Connection: close\r\n')
	} else if c.head.minor == 0 {
		append_str(mut c.out, 'Connection: keep-alive\r\n')
	}
	append_str(mut c.out, crlf)
	if n > 0 && body_allowed(status) && c.head.method != .head {
		unsafe { c.out.push_many(body, n) }
	}
}
```

- [ ] **Step 4: Implement `http1/testing.v`**

```v
module http1

// test_ctx parses raw (one complete request) into a fresh Ctx whose response goes to
// c.out, with Date off. Meant for unit tests of handlers and middleware.
pub fn test_ctx(raw string) !Ctx {
	buf := raw.bytes()
	mut f := Frame{}
	n := frame(buf, mut f, Limits{})!
	if n < 0 {
		return error('test_ctx: incomplete request')
	}
	mut c := Ctx.new()
	c.send_date = false
	c.out = []u8{cap: 4096}
	parse_head(buf, f.head_end, mut c.head)!
	c.begin(view(buf, 0, n))
	if f.chunked {
		c.set_chunked_body(f.head_end)
	} else {
		c.set_body(view(buf, f.head_end, f.content_length))
	}
	return c
}
```

- [ ] **Step 5: Run the tests**

Run `t2.sh`. Expected: `6 passed, 6 total`.

- [ ] **Step 6: Format check and commit**

```bash
# wsl -e bash <scratchpad>/fmt.sh http1/ctx.v http1/testing.v http1/ctx_test.v
git add http1/ctx.v http1/testing.v http1/ctx_test.v
git commit -q -m "feat(http1): Ctx with request views, buffered response writer and chain"
```

---

### Task 8: Compiled router

**Files:**
- Create: `router/router.v`
- Test: `router/router_test.v`

**Interfaces:**
- Consumes: `http1.Method`, `http1.Handler`, `http1.Span`, `http1.allocated_bytes`
- Produces:
  - `pub const not_found = -1`, `pub const method_not_allowed = -2`, `pub const max_params = 8`
  - `pub struct Route { method http1.Method; pattern string; chain []http1.Handler; param_names []string }` (`pub`)
  - `pub struct Match { n int; spans [8]http1.Span }` (`pub mut`; spans are offsets into the path string)
  - `@[heap] pub struct Router { routes []Route; on_404 []http1.Handler; on_405 []http1.Handler }` (`pub mut`)
  - `pub fn (mut r Router) add(method http1.Method, pattern string, chain []http1.Handler) !`
  - `pub fn (r &Router) find(method http1.Method, path string, mut m Match) int`

Behavior notes: trailing slashes are ignored (`/a/b/` = `/a/b`), empty segments are skipped (`/a//b` matches `/a/b`), the first registered route wins, HEAD falls back to GET, and a `*rest` value is the raw rest of the path (`/files/a//b` gives `a//b`; v0.13 collapsed it to `a/b`).

- [ ] **Step 1: Write the failing test**

`router/router_test.v`:

```v
module router

import viltrum.http1

fn h(mut c http1.Ctx) {}

fn chain() []http1.Handler {
	return [http1.Handler(h)]
}

fn build() &Router {
	mut r := &Router{}
	for p in ['/', '/a/b', '/u/:id', '/u/:id/posts/:post', '/files/*rest', 'nolead'] {
		r.add(.get, p, chain()) or { panic(err) }
	}
	r.add(.post, '/a/b', chain()) or { panic(err) }
	r.add(.get, '/a/b', chain()) or { panic(err) } // duplicate: the first one wins
	return r
}

fn lookup(r &Router, method http1.Method, path string) (int, []string) {
	mut m := Match{}
	idx := r.find(method, path, mut m)
	mut vals := []string{}
	if idx >= 0 {
		for k in 0 .. m.n {
			s := m.spans[k]
			vals << path[s.start..s.start + s.len]
		}
	}
	return idx, vals
}

fn test_matching() {
	r := build()
	cases := {
		'/':              0
		'/a/b':           1
		'/a/b/':          1
		'/a//b':          1
		'//a/b':          1
		'/nolead':        5
		'/u/42':          2
		'/u/42/':         2
		'/u/42/posts/7':  3
		'/files':         4
		'/files/a/b/c':   4
		'/u':             not_found
		'/missing':       not_found
		'/u/42/posts':    not_found
		'/a/b/c':         not_found
	}
	for path, want in cases {
		idx, _ := lookup(r, .get, path)
		assert idx == want, path
	}
	_, v1 := lookup(r, .get, '/u/42/posts/7')
	assert v1 == ['42', '7']
	_, v2 := lookup(r, .get, '/files/a//b/')
	assert v2 == ['a//b']
	_, v3 := lookup(r, .get, '/files/')
	assert v3 == ['']
}

fn test_methods() {
	r := build()
	post, _ := lookup(r, .post, '/a/b')
	assert post == 6
	put, _ := lookup(r, .put, '/a/b')
	assert put == method_not_allowed
	head, _ := lookup(r, .head, '/u/9')
	assert head == 2
	miss, _ := lookup(r, .put, '/nope')
	assert miss == not_found
}

fn test_bad_patterns() {
	mut r := &Router{}
	for p in ['/x/*rest/y', '/x/:', '/x/*', '/:a/:b/:c/:d/:e/:f/:g/:h/:i'] {
		r.add(.get, p, chain()) or { continue }
		assert false, 'accepted ${p}'
	}
}

fn test_find_allocates_nothing() {
	r := build()
	mut m := Match{}
	paths := ['/a/b', '/a//b', '/u/42/posts/7', '/files/x/y', '/missing']
	before := http1.allocated_bytes()
	for _ in 0 .. 10000 {
		for p in paths {
			_ = r.find(.get, p, mut m)
		}
		_ = r.find(.put, '/a/b', mut m)
	}
	assert http1.allocated_bytes() - before == 0
}
```

- [ ] **Step 2: Run it and see it fail**

Scratchpad `t8.sh`:

```bash
export PATH=$HOME/v:$PATH
cd /mnt/c/Users/tunay/Documents/GitHub/viltrum
v test router/ 2>&1 | grep -E 'FAIL|Summary|error|>' | head
```

Expected: compile error on `Router`.

- [ ] **Step 3: Implement `router/router.v`**

```v
module router

import viltrum.http1

// Router matches method + path to a handler chain without allocating. Routes
// without params are found with one hash lookup on the request path; routes with
// :params or a trailing *wildcard walk the path bytes.

pub const not_found = -1
pub const method_not_allowed = -2
pub const max_params = 8

enum SegKind {
	lit
	param
	wild
}

struct Seg {
	kind SegKind
	text string
}

pub struct Route {
pub:
	method      http1.Method
	pattern     string
	chain       []http1.Handler
	param_names []string
mut:
	segs   []Seg
	static bool
}

pub struct Match {
pub mut:
	n     int
	spans [max_params]http1.Span // offsets into the path string
}

@[heap]
pub struct Router {
pub mut:
	routes []Route
	on_404 []http1.Handler // chain for a miss; empty means a plain-text 404
	on_405 []http1.Handler // chain for a method mismatch; empty means a plain-text 405
mut:
	statics [10]map[string]int // per Method: normalized path -> route index
}

// add registers pattern ('/users/:id', '/files/*rest'). cold: registration only.
pub fn (mut r Router) add(method http1.Method, pattern string, chain []http1.Handler) ! {
	mut segs := []Seg{}
	mut names := []string{}
	parts := pattern.split('/')
	for i, p in parts {
		if p.len == 0 {
			continue
		}
		if p[0] == `:` {
			if p.len == 1 {
				return error('router: empty param name in ${pattern}')
			}
			segs << Seg{
				kind: .param
				text: p[1..]
			}
			names << p[1..]
		} else if p[0] == `*` {
			if p.len == 1 {
				return error('router: unnamed wildcard in ${pattern}')
			}
			if parts[i + 1..].any(it.len > 0) {
				return error('router: wildcard must be last in ${pattern}')
			}
			segs << Seg{
				kind: .wild
				text: p[1..]
			}
			names << p[1..]
		} else {
			segs << Seg{
				kind: .lit
				text: p
			}
		}
	}
	if names.len > max_params {
		return error('router: more than ${max_params} params in ${pattern}')
	}
	idx := r.routes.len
	r.routes << Route{
		method:      method
		pattern:     pattern
		chain:       chain
		param_names: names
		segs:        segs
		static:      names.len == 0
	}
	if names.len == 0 {
		key := '/' + segs.map(it.text).join('/')
		if key !in r.statics[int(method)] {
			r.statics[int(method)][key] = idx
		}
	}
}

// find returns the route index for method and path, or not_found /
// method_not_allowed. Param spans in m are offsets into path. HEAD falls back to GET.
pub fn (r &Router) find(method http1.Method, path string, mut m Match) int {
	mut plen := path.len
	for plen > 1 && path[plen - 1] == `/` {
		plen--
	}
	idx := r.find_method(method, path, plen, mut m)
	if idx >= 0 {
		return idx
	}
	if method == .head {
		g := r.find_method(.get, path, plen, mut m)
		if g >= 0 {
			return g
		}
	}
	for i in 0 .. r.routes.len {
		if r.routes[i].method != method && match_segs(r.routes[i].segs, path, plen, mut m) {
			return method_not_allowed
		}
	}
	return not_found
}

fn (r &Router) find_method(method http1.Method, path string, plen int, mut m Match) int {
	clean := is_clean(path, plen)
	if clean {
		key := unsafe { tos(path.str, plen) }
		if idx := r.statics[int(method)][key] {
			m.n = 0
			return idx
		}
	}
	for i in 0 .. r.routes.len {
		if r.routes[i].method != method || (r.routes[i].static && clean) {
			continue
		}
		if match_segs(r.routes[i].segs, path, plen, mut m) {
			return i
		}
	}
	return -1
}

// is_clean is true when path[..plen] is already in key form: '/a/b', no empty segment.
fn is_clean(path string, plen int) bool {
	if plen == 0 || path[0] != `/` {
		return false
	}
	for k in 1 .. plen {
		if path[k] == `/` && path[k - 1] == `/` {
			return false
		}
	}
	return true
}

fn match_segs(segs []Seg, path string, plen int, mut m Match) bool {
	m.n = 0
	mut i := 0
	for s in segs {
		for i < plen && path[i] == `/` {
			i++
		}
		if s.kind == .wild {
			m.spans[m.n] = http1.Span{
				start: i
				len:   plen - i
			}
			m.n++
			return true
		}
		if i >= plen {
			return false
		}
		st := i
		for i < plen && path[i] != `/` {
			i++
		}
		if s.kind == .param {
			m.spans[m.n] = http1.Span{
				start: st
				len:   i - st
			}
			m.n++
		} else if !eq_at(path, st, i - st, s.text) {
			return false
		}
	}
	for i < plen && path[i] == `/` {
		i++
	}
	return i == plen
}

fn eq_at(path string, st int, n int, lit string) bool {
	if n != lit.len {
		return false
	}
	for k in 0 .. n {
		if path[st + k] != lit[k] {
			return false
		}
	}
	return true
}
```

- [ ] **Step 4: Run the tests**

Run `t8.sh`. Expected: `1 passed, 1 total`.

- [ ] **Step 5: Format check and commit**

```bash
# wsl -e bash <scratchpad>/fmt.sh router/router.v router/router_test.v
git add router
git commit -q -m "feat(router): compiled router with allocation-free matching"
```

---

### Task 9: gzip on miniz with per-worker state, and the gzip middleware

**Files:**
- Create: `http1/gzip.c.v`
- Modify: `http1/ctx.v` (add the `deflater` field)
- Test: `http1/gzip_test.v`

**Interfaces:**
- Consumes: Task 7 `Ctx` (`capture`, `captured_body`, `send_captured`, `set_header`, `has_header`, `header`, `status`, `cap_type`, `responded`, `next`), Task 2 `lower`, `view`
- Produces:
  - `@[heap] pub struct Deflater`, `pub fn new_deflater() &Deflater`, `pub fn (mut d Deflater) gzip(src []u8) ![]u8`
  - `pub fn accepts_gzip(accept_encoding string) bool`
  - `pub fn compressible(content_type string) bool`
  - `pub fn gzip_middleware(mut c Ctx)`
  - `Ctx.deflater &Deflater` (pub mut, nil until a worker sets it; the middleware passes through when nil)

- [ ] **Step 1: Write the failing test**

`http1/gzip_test.v`:

```v
module http1

import compress.gzip as vgzip

const big_msg = 'x'.repeat(600)

fn big_json(mut c Ctx) {
	c.json(200, Msg{ message: big_msg })
}

fn small_text(mut c Ctx) {
	c.text(200, 'small')
}

fn gz_run(raw string, h Handler) !Ctx {
	mut c := test_ctx(raw)!
	c.deflater = new_deflater()
	c.chain = [Handler(gzip_middleware), h]
	c.chain[0](mut c)
	return c
}

fn test_gzip_round_trips() {
	mut d := new_deflater()
	for src in ['', 'hello', '{"a":1}'.repeat(5000)] {
		packed := d.gzip(src.bytes())!
		assert vgzip.decompress(packed)!.bytestr() == src
	}
}

fn test_accepts_gzip() {
	yes := ['gzip', 'gzip, br', 'br;q=1, gzip;q=0.8', 'GZIP', '*', 'identity, *;q=0.5', 'gzip;q=1.0']
	no := ['', 'br', 'gzip;q=0', 'gzip; q=0.000, *', '*;q=0.5, gzip;q=0', '*;q=0', 'gzipx', 'x-gzip']
	for v in yes {
		assert accepts_gzip(v), v
	}
	for v in no {
		assert !accepts_gzip(v), v
	}
}

fn test_compressible() {
	for t in ['text/plain; charset=utf-8', 'application/json', 'application/javascript',
		'image/svg+xml', 'application/xml', 'Text/HTML'] {
		assert compressible(t), t
	}
	for t in ['image/png', 'application/octet-stream', ''] {
		assert !compressible(t), t
	}
}

fn test_middleware_compresses_when_accepted() {
	c := gz_run('GET / HTTP/1.1\r\nHost: h\r\nAccept-Encoding: gzip, br\r\n\r\n', big_json)!
	s := c.out.bytestr()
	assert s.contains('Content-Encoding: gzip\r\n')
	assert s.contains('Vary: Accept-Encoding\r\n')
	body_start := s.index('\r\n\r\n')? + 4
	body := c.out[body_start..]
	assert s.contains('Content-Length: ${body.len}\r\n')
	assert vgzip.decompress(body)!.bytestr() == '{"message":"${big_msg}"}'
}

fn test_middleware_passes_through() {
	plain := gz_run('GET / HTTP/1.1\r\nHost: h\r\n\r\n', big_json)!
	ps := plain.out.bytestr()
	assert !ps.contains('Content-Encoding') && ps.contains('Vary: Accept-Encoding\r\n')
	assert ps.ends_with('{"message":"${big_msg}"}')
	small := gz_run('GET / HTTP/1.1\r\nHost: h\r\nAccept-Encoding: gzip\r\n\r\n', small_text)!
	ss := small.out.bytestr()
	assert !ss.contains('Content-Encoding') && !ss.contains('Vary') && ss.ends_with('small')
	head := gz_run('HEAD / HTTP/1.1\r\nHost: h\r\nAccept-Encoding: gzip\r\n\r\n', big_json)!
	assert head.out.bytestr().ends_with('\r\n\r\n')
}

fn test_middleware_allocates_nothing() {
	raw := 'GET /j HTTP/1.1\r\nHost: h\r\nAccept-Encoding: gzip, br\r\n\r\n'.bytes()
	mut f := Frame{}
	n := frame(raw, mut f, Limits{})!
	mut c := Ctx.new()
	c.out = []u8{cap: 8192}
	c.deflater = new_deflater()
	c.chain = [Handler(gzip_middleware), Handler(big_json)]
	for _ in 0 .. 100 {
		serve_once(mut c, raw, f, n)
	}
	before := allocated_bytes()
	for _ in 0 .. 5000 {
		serve_once(mut c, raw, f, n)
	}
	assert allocated_bytes() - before == 0
}
```

`serve_once` and `Msg` live in `ctx_test.v`; V compiles each `_test.v` on its own, so copy them into `gzip_test.v`:

```v
struct Msg {
	message string
}

fn serve_once(mut c Ctx, raw []u8, f Frame, n int) {
	unsafe {
		c.out.len = 0
	}
	parse_head(raw, f.head_end, mut c.head) or { panic(err) }
	c.begin(view(raw, 0, n))
	c.set_body(view(raw, f.head_end, f.content_length))
	c.chain[0](mut c)
}
```

- [ ] **Step 2: Run it and see it fail**

Run `t2.sh`. Expected: compile error on `new_deflater`.

- [ ] **Step 3: Add the field to `Ctx`**

In `http1/ctx.v`, in the `// per worker` group of `pub mut:` fields, after `date      DateCache`, add:

```v
	deflater  &Deflater = unsafe { nil } // set by the worker; gzip passes through while nil
```

- [ ] **Step 4: Implement `http1/gzip.c.v`**

```v
module http1

// gzip on the miniz that ships with V (thirdparty/zip, also used by vlib/szip).
// The compressor state is malloc'd once per worker, outside the GC heap, and
// writes into a buffer the worker keeps: compressing a response allocates nothing.

#flag -I @VEXEROOT/thirdparty/zip
#define MINIZ_NO_ZLIB_COMPATIBLE_NAMES
#include "miniz.h"

@[typedef]
struct C.tdefl_compressor {}

fn C.tdefl_compressor_alloc() &C.tdefl_compressor
fn C.tdefl_init(d &C.tdefl_compressor, put_buf_func voidptr, put_buf_user voidptr, flags int) int
fn C.tdefl_compress_buffer(d &C.tdefl_compressor, in_buf voidptr, in_buf_size usize, flush int) int
fn C.tdefl_create_comp_flags_from_zip_params(level int, window_bits int, strategy int) u32
fn C.mz_crc32(crc u32, ptr &u8, len usize) u32

const gzip_level = 6 // zlib's default; json-comp scores size squared, so ratio matters
const gzip_min_bytes = 256 // below this the gzip framing costs more than it saves

@[heap]
pub struct Deflater {
mut:
	d     &C.tdefl_compressor = unsafe { nil }
	flags int
	out   []u8
}

pub fn new_deflater() &Deflater {
	return &Deflater{
		d:     C.tdefl_compressor_alloc()
		flags: int(C.tdefl_create_comp_flags_from_zip_params(gzip_level, -15, 0)) // -15: raw deflate
		out:   []u8{cap: 16 * 1024}
	}
}

fn deflate_put(buf voidptr, len int, user voidptr) int {
	mut out := unsafe { &[]u8(user) }
	unsafe { out.push_many(buf, len) }
	return 1
}

// gzip compresses src into one gzip member (RFC 1952). The result is a view of the
// deflater's buffer, valid until the next call.
pub fn (mut d Deflater) gzip(src []u8) ![]u8 {
	unsafe {
		d.out.len = 0
	}
	d.out << u8(0x1f)
	d.out << 0x8b
	d.out << 8 // CM = deflate
	for _ in 0 .. 6 {
		d.out << 0 // FLG, MTIME (4), XFL
	}
	d.out << 0xff // OS unknown
	C.tdefl_init(d.d, voidptr(deflate_put), voidptr(&d.out), d.flags)
	if C.tdefl_compress_buffer(d.d, src.data, usize(src.len), C.TDEFL_FINISH) != C.TDEFL_STATUS_DONE {
		return error('gzip: deflate failed') // cold
	}
	crc := C.mz_crc32(0, src.data, usize(src.len))
	size := u32(src.len)
	d.out << u8(crc)
	d.out << u8(crc >> 8)
	d.out << u8(crc >> 16)
	d.out << u8(crc >> 24)
	d.out << u8(size)
	d.out << u8(size >> 8)
	d.out << u8(size >> 16)
	d.out << u8(size >> 24)
	return view(d.out, 0, d.out.len)
}

// accepts_gzip reads an Accept-Encoding value: an explicit gzip entry wins over *;
// either counts only with a q-value above zero.
pub fn accepts_gzip(v string) bool {
	mut star := false
	mut i := 0
	for i < v.len {
		for i < v.len && (v[i] == ` ` || v[i] == `\t` || v[i] == `,`) {
			i++
		}
		cs := i
		for i < v.len && v[i] != `,` && v[i] != `;` && v[i] != ` ` && v[i] != `\t` {
			i++
		}
		ce := i
		mut q_zero := false
		for i < v.len && v[i] != `,` {
			if v[i] == `;` {
				i++
				for i < v.len && (v[i] == ` ` || v[i] == `\t`) {
					i++
				}
				if i + 1 < v.len && lower(v[i]) == `q` && v[i + 1] == `=` {
					i += 2
					qs := i
					for i < v.len && v[i] != `,` && v[i] != `;` && v[i] != ` ` {
						i++
					}
					q_zero = is_q_zero(v, qs, i)
				}
				continue
			}
			i++
		}
		if ce - cs == 4 && lower(v[cs]) == `g` && lower(v[cs + 1]) == `z` && lower(v[cs + 2]) == `i`
			&& lower(v[cs + 3]) == `p` {
			return !q_zero
		}
		if ce - cs == 1 && v[cs] == `*` {
			star = !q_zero
		}
	}
	return star
}

// is_q_zero matches "0", "0.", "0.0", "0.00" and "0.000".
fn is_q_zero(v string, s int, e int) bool {
	if e <= s || v[s] != `0` {
		return false
	}
	for k in s + 1 .. e {
		if k == s + 1 {
			if v[k] != `.` {
				return false
			}
		} else if v[k] != `0` {
			return false
		}
	}
	return true
}

// compressible is true for text, JSON, JavaScript, XML and SVG content types.
pub fn compressible(content_type string) bool {
	return has_prefix_ci(content_type, 'text/') || contains_ci(content_type, 'json')
		|| contains_ci(content_type, 'javascript') || contains_ci(content_type, 'xml')
		|| contains_ci(content_type, 'svg')
}

fn contains_ci(s string, lower_lit string) bool {
	if lower_lit.len > s.len {
		return false
	}
	for i in 0 .. s.len - lower_lit.len + 1 {
		mut ok := true
		for k in 0 .. lower_lit.len {
			if lower(s[i + k]) != lower_lit[k] {
				ok = false
				break
			}
		}
		if ok {
			return true
		}
	}
	return false
}

// gzip_middleware compresses text and JSON bodies of 256 bytes or more for clients
// that accept gzip, and sets Vary on every compressible response. Register it
// before the handlers whose bodies it should compress.
pub fn gzip_middleware(mut c Ctx) {
	c.capture = true
	c.next()
	c.capture = false
	if !c.responded {
		return
	}
	body := c.captured_body()
	eligible := body.len >= gzip_min_bytes && body_allowed(c.status) && compressible(c.cap_type)
		&& !c.has_header('content-encoding')
	if !eligible {
		c.send_captured(body, '')
		return
	}
	c.set_header('Vary', 'Accept-Encoding')
	if !isnil(c.deflater) && accepts_gzip(c.header('accept-encoding') or { '' }) {
		packed := c.deflater.gzip(body) or {
			c.send_captured(body, '')
			return
		}
		if packed.len < body.len {
			c.send_captured(packed, 'gzip')
			return
		}
	}
	c.send_captured(body, '')
}
```

- [ ] **Step 5: Run the tests**

Run `t2.sh`. Expected: `7 passed, 7 total`.

- [ ] **Step 6: Format check and commit**

```bash
# wsl -e bash <scratchpad>/fmt.sh http1/gzip.c.v http1/ctx.v http1/gzip_test.v
git add http1/gzip.c.v http1/ctx.v http1/gzip_test.v
git commit -q -m "feat(http1): gzip middleware on miniz with per-worker compressor state"
```

---

### Task 10: Engine request processing (socket-free) and the zero-allocation gate

**Files:**
- Create: `engine/options.v`, `engine/process.v`
- Test: `engine/process_test.v`

**Interfaces:**
- Consumes: `http1` (Tasks 2–9), `router.Router`, `router.Match`, `router.not_found`, `router.method_not_allowed`
- Produces:
  - `pub struct Options { workers int; limits http1.Limits; read_timeout time.Duration = 30s; write_timeout time.Duration = 30s; idle_timeout time.Duration = 60s; max_conns int; max_pending int = 1048576; send_date bool = true; server_header string; require_host bool = true; handle_signals bool = true; stop &Stop = nil }`
  - `@[heap] pub struct Stop`, `pub fn new_stop() &Stop`, `pub fn (mut s Stop) request()`, `pub fn (s &Stop) requested() bool`
  - `@[heap] pub struct Conn { fd int; rbuf []u8; wbuf []u8; woff int; frame http1.Frame; close_after bool; out_armed bool; reading bool; deadline_ms i64; counted bool }` (pub mut), `pub fn new_conn() &Conn`, `pub fn (mut c Conn) reset(fd int)`
  - `@[heap] pub struct Worker { ctx http1.Ctx; r &router.Router; opts Options; requests u64 }`, `pub fn new_worker(r &router.Router, opts Options, index int) &Worker`
  - `pub fn (mut w Worker) process(mut c Conn)` — serves every complete request in `c.rbuf` into `c.wbuf`, pauses once `c.wbuf.len >= opts.max_pending`, compacts `c.rbuf`

Spec delta applied here: instead of closing a peer at 1 MiB of pending output, the worker stops serving further pipelined requests once 1 MiB is pending and stops reading while output is pending (Task 11). Memory stays bounded at one batch, legitimate large responses still go out, and a peer that stops reading is closed by `write_timeout`. Update the spec's Backpressure bullet to say this in Step 6.

- [ ] **Step 1: Write the failing test**

`engine/process_test.v`:

```v
module engine

import viltrum.http1
import viltrum.router

struct Item {
	id    int
	name  string
	price int
	tags  []string
}

struct Page {
	items []Item
	count int
}

fn make_items() []Item {
	mut a := []Item{}
	for i in 0 .. 20 {
		a << Item{
			id:    i
			name:  'Item number ${i}'
			price: i * 3
			tags:  ['tag-a', 'tag-b']
		}
	}
	return a
}

const items = make_items()

fn first_items(n int) []Item {
	mut v := unsafe { items }
	unsafe {
		v.len = if n < items.len { n } else { items.len }
	}
	return v
}

fn baseline(mut c http1.Ctx) {
	sum := (c.query_int('a') or { 0 }) + (c.query_int('b') or { 0 }) + (c.body_int() or { 0 })
	c.text_int(200, sum)
}

fn pipeline(mut c http1.Ctx) {
	c.text(200, 'ok')
}

fn json_page(mut c http1.Ctx) {
	n := int(c.param_int('count') or { 0 })
	c.json(200, Page{
		items: first_items(n)
		count: n
	})
}

fn silent(mut c http1.Ctx) {}

fn make_router() &router.Router {
	mut r := &router.Router{}
	r.add(.get, '/baseline11', [http1.Handler(baseline)]) or { panic(err) }
	r.add(.post, '/baseline11', [http1.Handler(baseline)]) or { panic(err) }
	r.add(.get, '/pipeline', [http1.Handler(pipeline)]) or { panic(err) }
	r.add(.get, '/json/:count', [http1.Handler(json_page)]) or { panic(err) }
	r.add(.get, '/gz/:count', [http1.Handler(http1.gzip_middleware), http1.Handler(json_page)]) or {
		panic(err)
	}
	r.add(.get, '/silent', [http1.Handler(silent)]) or { panic(err) }
	return r
}

fn run(mut w Worker, mut c Conn, req []u8) {
	unsafe {
		c.rbuf.len = 0
		c.wbuf.len = 0
		c.rbuf.push_many(req.data, req.len)
	}
	c.close_after = false
	c.frame.reset()
	w.process(mut c)
}

const shapes = {
	'get':          'GET /baseline11?a=13&b=42 HTTP/1.1\r\nHost: x\r\n\r\n'
	'post_cl':      'POST /baseline11?a=13&b=42 HTTP/1.1\r\nHost: x\r\nContent-Length: 2\r\n\r\n20'
	'post_chunked': 'POST /baseline11?a=13&b=42 HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n2\r\n20\r\n0\r\n\r\n'
	'pipelined':    'GET /pipeline HTTP/1.1\r\nHost: x\r\n\r\n'.repeat(16)
	'json':         'GET /json/10 HTTP/1.1\r\nHost: x\r\n\r\n'
	'json_gzip':    'GET /gz/10 HTTP/1.1\r\nHost: x\r\nAccept-Encoding: gzip, br\r\n\r\n'
}

fn test_each_shape_is_answered() {
	mut w := new_worker(make_router(), Options{ send_date: false }, 0)
	mut c := new_conn()
	run(mut w, mut c, shapes['get'].bytes())
	assert c.wbuf.bytestr() == 'HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: 2\r\n\r\n55'
	run(mut w, mut c, shapes['post_cl'].bytes())
	assert c.wbuf.bytestr().ends_with('\r\n\r\n75')
	run(mut w, mut c, shapes['post_chunked'].bytes())
	assert c.wbuf.bytestr().ends_with('\r\n\r\n75')
	run(mut w, mut c, shapes['pipelined'].bytes())
	assert c.wbuf.bytestr().count('\r\n\r\nok') == 16
	run(mut w, mut c, shapes['json'].bytes())
	assert c.wbuf.bytestr().contains('"count":10}')
	run(mut w, mut c, shapes['json_gzip'].bytes())
	assert c.wbuf.bytestr().contains('Content-Encoding: gzip\r\n')
	assert c.rbuf.len == 0 && !c.close_after
}

// The acceptance gate of the whole rewrite: once buffers have grown to their working
// size, serving a request allocates nothing on the GC heap.
fn test_hot_path_allocates_nothing() {
	mut w := new_worker(make_router(), Options{}, 0)
	mut c := new_conn()
	for name, raw in shapes {
		req := raw.bytes()
		for _ in 0 .. 200 {
			run(mut w, mut c, req)
		}
		before := http1.allocated_bytes()
		for _ in 0 .. 10000 {
			run(mut w, mut c, req)
		}
		assert http1.allocated_bytes() - before == 0, '${name} allocates'
	}
}

// Review Focus 1: a handler that never responds still produces a response.
fn test_silent_handler_gets_500_and_close() {
	mut w := new_worker(make_router(), Options{ send_date: false }, 0)
	mut c := new_conn()
	run(mut w, mut c, 'GET /silent HTTP/1.1\r\nHost: x\r\n\r\nGET /pipeline HTTP/1.1\r\nHost: x\r\n\r\n'.bytes())
	s := c.wbuf.bytestr()
	assert s.starts_with('HTTP/1.1 500 Internal Server Error\r\n')
	assert s.contains('Connection: close\r\n') && s.count('HTTP/1.1') == 1
	assert c.close_after
}

fn test_bad_request_mid_pipeline() {
	mut w := new_worker(make_router(), Options{ send_date: false }, 0)
	mut c := new_conn()
	ok := 'GET /pipeline HTTP/1.1\r\nHost: x\r\n\r\n'
	run(mut w, mut c, (ok + ok + 'GET /pipeline HTTP/1.1\r\nHost : x\r\n\r\n' + ok).bytes())
	s := c.wbuf.bytestr()
	assert s.count('\r\n\r\nok') == 2
	assert s.contains('HTTP/1.1 400 Bad Request\r\n') && s.ends_with('bad header name')
	assert c.close_after && c.rbuf.len == 0
}

fn test_expect_continue_and_partial_requests() {
	mut w := new_worker(make_router(), Options{ send_date: false }, 0)
	mut c := new_conn()
	run(mut w, mut c, 'POST /baseline11?a=1&b=2 HTTP/1.1\r\nHost: x\r\nExpect: 100-continue\r\nContent-Length: 2\r\n\r\n'.bytes())
	assert c.wbuf.bytestr() == 'HTTP/1.1 100 Continue\r\n\r\n'
	assert c.reading && c.rbuf.len > 0
	unsafe {
		c.wbuf.len = 0
	}
	c.rbuf << '20'.bytes()
	w.process(mut c)
	assert c.wbuf.bytestr().ends_with('\r\n\r\n23')
	assert !c.reading && c.rbuf.len == 0
}

fn test_misses_and_missing_host() {
	mut w := new_worker(make_router(), Options{ send_date: false }, 0)
	mut c := new_conn()
	run(mut w, mut c, 'GET /nope HTTP/1.1\r\nHost: x\r\n\r\n'.bytes())
	assert c.wbuf.bytestr().starts_with('HTTP/1.1 404 Not Found\r\n')
	run(mut w, mut c, 'DELETE /pipeline HTTP/1.1\r\nHost: x\r\n\r\n'.bytes())
	assert c.wbuf.bytestr().starts_with('HTTP/1.1 405 Method Not Allowed\r\n')
	run(mut w, mut c, 'GET /pipeline HTTP/1.1\r\n\r\n'.bytes())
	assert c.wbuf.bytestr().starts_with('HTTP/1.1 400 Bad Request\r\n') && c.close_after
	run(mut w, mut c, 'GET /pipeline HTTP/1.0\r\n\r\n'.bytes())
	assert c.wbuf.bytestr().ends_with('ok') && c.close_after
}

fn test_pipelining_pauses_at_max_pending() {
	mut w := new_worker(make_router(), Options{
		send_date:   false
		max_pending: 200
	}, 0)
	mut c := new_conn()
	run(mut w, mut c, shapes['pipelined'].bytes())
	first := c.wbuf.bytestr().count('\r\n\r\nok')
	assert first > 0 && first < 16
	mut total := first
	for total < 16 {
		unsafe {
			c.wbuf.len = 0
		}
		w.process(mut c)
		total += c.wbuf.bytestr().count('\r\n\r\nok')
	}
	assert total == 16 && c.rbuf.len == 0
}
```

- [ ] **Step 2: Run it and see it fail**

Scratchpad `t10.sh`:

```bash
export PATH=$HOME/v:$PATH
cd /mnt/c/Users/tunay/Documents/GitHub/viltrum
v test engine/ 2>&1 | grep -E 'FAIL|Summary|error|>' | head -20
```

Expected: compile error on `new_worker`.

- [ ] **Step 3: Implement `engine/options.v`**

```v
module engine

import sync.stdatomic
import time
import viltrum.http1

pub struct Options {
pub:
	// workers is the number of event loops; 0 means VILTRUM_WORKERS, else the CPUs
	// in the process affinity mask.
	workers       int
	limits        http1.Limits
	read_timeout  time.Duration = 30 * time.second // from a request's first byte to its last
	write_timeout time.Duration = 30 * time.second // while output is pending
	idle_timeout  time.Duration = 60 * time.second // between keep-alive requests
	max_conns     int // 0 = unlimited; excess connections get 503 and are closed
	// max_pending pauses pipelined processing while this much output waits to be sent.
	max_pending    int  = 1024 * 1024
	send_date      bool = true
	server_header  string
	require_host   bool = true
	handle_signals bool = true
	stop           &Stop = unsafe { nil } // stop a server without signals (tests, embedding)
}

// Stop asks a running server to shut down; workers notice within a second.
@[heap]
pub struct Stop {
mut:
	flag u64
}

pub fn new_stop() &Stop {
	return &Stop{}
}

pub fn (mut s Stop) request() {
	stdatomic.store_u64(&s.flag, 1)
}

pub fn (s &Stop) requested() bool {
	return stdatomic.load_u64(&s.flag) == 1
}
```

- [ ] **Step 4: Implement `engine/process.v`**

```v
module engine

import viltrum.http1
import viltrum.router

pub const read_buf_size = 8 * 1024
pub const write_buf_size = 16 * 1024

// Conn is one client connection. A worker keeps the Conn after the connection
// closes and reuses it, buffers included, for the next connection on the same fd.
@[heap]
pub struct Conn {
pub mut:
	fd          int = -1
	rbuf        []u8
	wbuf        []u8
	woff        int // bytes of wbuf already sent
	frame       http1.Frame
	close_after bool
	out_armed   bool // EPOLLOUT registered: output pending, reading paused
	reading     bool // part of a request is buffered
	deadline_ms i64
	counted     bool // holds a max_conns slot
}

pub fn new_conn() &Conn {
	return &Conn{
		rbuf: []u8{cap: read_buf_size}
		wbuf: []u8{cap: write_buf_size}
	}
}

// reset prepares a reused Conn for a new connection on fd.
pub fn (mut c Conn) reset(fd int) {
	c.fd = fd
	unsafe {
		c.rbuf.len = 0
		c.wbuf.len = 0
	}
	c.woff = 0
	c.frame.reset()
	c.close_after = false
	c.out_armed = false
	c.reading = false
	c.counted = false
}

// Worker serves the requests of one event loop. It owns the Ctx, the Date cache
// and the gzip state, so requests share nothing across threads.
@[heap]
pub struct Worker {
pub mut:
	ctx      http1.Ctx
	r        &router.Router
	opts     Options
	m        router.Match
	requests u64
}

pub fn new_worker(r &router.Router, opts Options, index int) &Worker {
	mut w := &Worker{
		ctx:  http1.Ctx.new()
		r:    r
		opts: opts
	}
	w.ctx.send_date = opts.send_date
	w.ctx.server = opts.server_header
	w.ctx.deflater = http1.new_deflater()
	w.ctx.worker = index
	return w
}

// process serves every complete request buffered in c.rbuf, appending responses to
// c.wbuf, and compacts what is left. It never touches the socket.
pub fn (mut w Worker) process(mut c Conn) {
	mut off := 0
	for !c.close_after && off < c.rbuf.len && c.wbuf.len < w.opts.max_pending {
		msg := http1.view(c.rbuf, off, c.rbuf.len - off)
		n := http1.frame(msg, mut c.frame, w.opts.limits) or {
			w.refuse(mut c, err)
			off = c.rbuf.len
			break
		}
		if n < 0 {
			if c.frame.expect_continue && !c.frame.continue_sent {
				http1.append_str(mut c.wbuf, 'HTTP/1.1 100 Continue\r\n\r\n')
				c.frame.continue_sent = true
			}
			break
		}
		w.serve(mut c, http1.view(msg, 0, n))
		off += n
		c.frame.reset()
	}
	c.reading = off < c.rbuf.len
	if off > 0 {
		rest := c.rbuf.len - off
		if rest > 0 {
			unsafe { C.memmove(c.rbuf.data, &u8(c.rbuf.data) + off, rest) }
		}
		unsafe {
			c.rbuf.len = rest
		}
	}
}

fn (mut w Worker) serve(mut c Conn, msg []u8) {
	mut x := &w.ctx
	http1.parse_head(msg, c.frame.head_end, mut x.head) or {
		w.refuse(mut c, err)
		return
	}
	if w.opts.require_host && x.head.minor == 1 && !x.head.host_seen {
		w.refuse(mut c, http1.HttpError{
			status: 400
			reason: 'missing host header'
		})
		return
	}
	x.out = c.wbuf
	x.begin(msg)
	if c.frame.chunked {
		x.set_chunked_body(c.frame.head_end)
	} else {
		x.set_body(http1.view(msg, c.frame.head_end, c.frame.content_length))
	}
	idx := w.r.find(x.head.method, x.path(), mut w.m)
	if idx >= 0 {
		x.chain = w.r.routes[idx].chain
		x.param_names = w.r.routes[idx].param_names
		x.nparams = w.m.n
		for k in 0 .. w.m.n {
			x.params[k] = http1.Span{
				start: x.head.path.start + w.m.spans[k].start
				len:   w.m.spans[k].len
			}
		}
	} else {
		x.chain = if idx == router.method_not_allowed { w.r.on_405 } else { w.r.on_404 }
	}
	if x.chain.len > 0 {
		x.chain[0](mut x)
	}
	if !x.responded {
		if idx == router.not_found {
			x.text(404, 'not found')
		} else if idx == router.method_not_allowed {
			x.text(405, 'method not allowed')
		} else {
			x.close()
			x.text(500, 'internal error')
		}
	}
	c.wbuf = x.out
	c.close_after = x.close_after
	w.requests++
	$if viltrum_debug ? {
		// Poison the request so a handler that kept a view reads garbage in tests.
		unsafe { C.memset(msg.data, 0xA5, msg.len) }
	}
}

// refuse answers a framing or parse error after any earlier pipelined responses and
// marks the connection to close.
fn (mut w Worker) refuse(mut c Conn, err IError) {
	status := if err.code() >= 400 { err.code() } else { 400 }
	mut x := &w.ctx
	x.head.method = .get
	x.head.minor = 1
	x.head.keep_alive = false
	x.out = c.wbuf
	x.begin(http1.view(c.rbuf, 0, 0))
	x.text(status, err.msg())
	c.wbuf = x.out
	c.close_after = true
}
```

- [ ] **Step 5: Run the tests**

Run `t10.sh`. Expected: `1 passed, 1 total`. If `test_hot_path_allocates_nothing` fails, bisect with the shape name in the message: rerun with one shape, then remove stages (comment out the handler call, then routing) until the allocating line is found; fix it at its source rather than raising the threshold.

- [ ] **Step 6: Update the spec and commit**

In the spec's Engine section replace the Backpressure bullet with:

```markdown
- **Backpressure:** a worker stops serving further pipelined requests once 1 MiB of output is pending and
  stops reading a connection while its output is pending (`EPOLLOUT` armed). Memory stays bounded at one batch,
  large responses still go out, and a peer that stops reading is closed by `write_timeout`.
```

```bash
# wsl -e bash <scratchpad>/fmt.sh engine/options.v engine/process.v engine/process_test.v
git add engine docs/superpowers/specs/2026-10-15-v1-zero-alloc-core-design.md
git commit -q -m "feat(engine): socket-free request processing with a zero-allocation gate"
```

---

### Task 11: Epoll workers, listeners, timeouts and shutdown

**Files:**
- Create: `engine/serve_linux.c.v`, `engine/worker_linux.c.v`
- Test: `engine/serve_test.v`

**Interfaces:**
- Consumes: Task 10 `Options`, `Stop`, `Conn`, `Worker`, `new_conn`, `new_worker`
- Produces:
  - `pub fn serve(addr string, r &router.Router, opts Options) !` — blocks until stopped
  - `pub fn worker_count(requested int) int`

- [ ] **Step 1: Write the failing integration tests**

`engine/serve_test.v`:

```v
module engine

import net
import time
import viltrum.http1
import viltrum.router

const big_body = 'b'.repeat(5 * 1024 * 1024)

fn h_path(mut c http1.Ctx) {
	c.text(200, c.path())
}

fn h_echo(mut c http1.Ctx) {
	c.bytes(200, 'text/plain', c.body())
}

fn h_big(mut c http1.Ctx) {
	c.text(200, big_body)
}

fn make_router() &router.Router {
	mut r := &router.Router{}
	r.add(.get, '/p/*rest', [http1.Handler(h_path)]) or { panic(err) }
	r.add(.post, '/echo', [http1.Handler(h_echo)]) or { panic(err) }
	r.add(.get, '/big', [http1.Handler(h_big)]) or { panic(err) }
	return r
}

fn free_addr() string {
	mut l := net.listen_tcp(.ip, '127.0.0.1:0') or { panic(err) }
	a := l.addr() or { panic(err) }
	s := a.str()
	l.close() or {}
	return s
}

fn start(opts Options) (string, &Stop) {
	addr := free_addr()
	mut stop := new_stop()
	o := Options{
		...opts
		workers:        2
		handle_signals: false
		stop:           stop
		send_date:      false
	}
	r := make_router()
	spawn fn [addr, r, o] () {
		serve(addr, r, o) or { eprintln(err) }
	}()
	for _ in 0 .. 100 {
		mut c := net.dial_tcp(addr) or {
			time.sleep(20 * time.millisecond)
			continue
		}
		c.close() or {}
		break
	}
	time.sleep(50 * time.millisecond)
	return addr, stop
}

fn dial(addr string) &net.TcpConn {
	mut c := net.dial_tcp(addr) or { panic(err) }
	c.set_read_timeout(5 * time.second)
	c.set_write_timeout(5 * time.second)
	return c
}

struct Reader {
mut:
	buf []u8
}

fn (mut r Reader) fill(mut conn net.TcpConn) ! {
	mut tmp := []u8{len: 64 * 1024}
	n := conn.read(mut tmp)!
	if n <= 0 {
		return error('eof')
	}
	r.buf << tmp[..n]
}

fn head_end(b []u8) int {
	for i := 0; i + 3 < b.len; i++ {
		if b[i] == `\r` && b[i + 1] == `\n` && b[i + 2] == `\r` && b[i + 3] == `\n` {
			return i + 4
		}
	}
	return -1
}

// response reads the next Content-Length framed response.
fn (mut r Reader) response(mut conn net.TcpConn) !(int, string) {
	for {
		end := head_end(r.buf)
		if end < 0 {
			r.fill(mut conn)!
			continue
		}
		cl := http1.header_value(r.buf[..end], 'content-length')
		n := if cl.found() { r.buf[cl.start..cl.start + cl.len].bytestr().int() } else { 0 }
		if r.buf.len < end + n {
			r.fill(mut conn)!
			continue
		}
		status := r.buf[9..12].bytestr().int()
		body := r.buf[end..end + n].bytestr()
		r.buf = r.buf[end + n..].clone()
		return status, body
	}
	return error('unreachable')
}

// closed is true when the connection ends before another complete response.
fn (mut r Reader) closed(mut conn net.TcpConn) bool {
	_, _ := r.response(mut conn) or { return true }
	return false
}

fn read_until_eof(mut conn net.TcpConn) int {
	mut tmp := []u8{len: 64 * 1024}
	mut total := 0
	for {
		n := conn.read(mut tmp) or { return total }
		if n <= 0 {
			return total
		}
		total += n
	}
	return total
}

fn test_pipelined_burst_with_bodies() {
	addr, mut stop := start(Options{})
	defer {
		stop.request()
	}
	mut c := dial(addr)
	mut burst := ''
	for i in 0 .. 300 {
		match i % 3 {
			0 { burst += 'GET /p/${i} HTTP/1.1\r\nHost: x\r\n\r\n' }
			1 { burst += 'POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: ${i.str().len}\r\n\r\n${i}' }
			else { burst += 'POST /echo HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n${i.str().len:x}\r\n${i}\r\n0\r\n\r\n' }
		}
	}
	c.write(burst.bytes()) or { panic(err) }
	mut r := Reader{}
	for i in 0 .. 300 {
		st, body := r.response(mut c) or { panic('${i}: ${err}') }
		assert st == 200
		want := if i % 3 == 0 { '/p/${i}' } else { '${i}' }
		assert body == want, '${i}'
	}
	c.close() or {}
}

fn test_bad_request_and_close_mid_burst() {
	addr, mut stop := start(Options{})
	defer {
		stop.request()
	}
	ok := 'GET /p/a HTTP/1.1\r\nHost: x\r\n\r\n'
	tails := {
		'GET /p/b HTTP/1.1\r\nHost : x\r\n\r\n':                       400
		'GET /p/b HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n': 200
	}
	for tail, want in tails {
		mut c := dial(addr)
		c.write((ok + tail + ok).bytes()) or { panic(err) }
		mut r := Reader{}
		st1, _ := r.response(mut c) or { panic(err) }
		st2, _ := r.response(mut c) or { panic(err) }
		assert st1 == 200
		assert st2 == want
		assert r.closed(mut c), 'served after the connection should have closed'
		c.close() or {}
	}
}

fn test_trickled_requests() {
	addr, mut stop := start(Options{})
	defer {
		stop.request()
	}
	mut c := dial(addr)
	reqs := 'POST /echo HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n4\r\nWiki\r\n0\r\n\r\n' +
		'POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\nhello'
	for b in reqs.bytes() {
		c.write([b]) or { panic(err) }
		time.sleep(time.millisecond)
	}
	mut r := Reader{}
	_, b1 := r.response(mut c) or { panic(err) }
	_, b2 := r.response(mut c) or { panic(err) }
	assert b1 == 'Wiki' && b2 == 'hello'
	c.close() or {}
}

// Review Focus 2: a response far larger than the write buffer arrives complete and
// in order with the next pipelined response.
fn test_large_response_survives_partial_writes() {
	addr, mut stop := start(Options{})
	defer {
		stop.request()
	}
	mut c := dial(addr)
	c.write('GET /big HTTP/1.1\r\nHost: x\r\n\r\nGET /p/after HTTP/1.1\r\nHost: x\r\n\r\n'.bytes()) or {
		panic(err)
	}
	mut r := Reader{}
	_, big := r.response(mut c) or { panic(err) }
	_, after := r.response(mut c) or { panic(err) }
	assert big.len == big_body.len && big == big_body
	assert after == '/p/after'
	c.close() or {}
}

// Review Focus 3: a client that pipelines and never reads is closed by write_timeout.
fn test_client_that_never_reads_is_closed() {
	addr, mut stop := start(Options{
		write_timeout: time.second
	})
	defer {
		stop.request()
	}
	mut c := dial(addr)
	c.write('GET /big HTTP/1.1\r\nHost: x\r\n\r\n'.repeat(30).bytes()) or { panic(err) }
	time.sleep(3500 * time.millisecond)
	got := read_until_eof(mut c)
	assert got < 30 * big_body.len
	c.close() or {}
}

// Review Focus 4: trickling header bytes does not keep a connection alive past
// read_timeout.
fn test_slowloris_is_closed() {
	addr, mut stop := start(Options{
		read_timeout: time.second
	})
	defer {
		stop.request()
	}
	mut c := dial(addr)
	c.write('GET /p/x HTTP/1.1\r\n'.bytes()) or { panic(err) }
	for _ in 0 .. 12 {
		time.sleep(200 * time.millisecond)
		c.write('X'.bytes()) or { break }
	}
	time.sleep(500 * time.millisecond)
	assert read_until_eof(mut c) == 0
	c.close() or {}
}

fn test_idle_timeout_and_max_conns() {
	addr, mut stop := start(Options{
		idle_timeout: time.second
		max_conns:    1
	})
	defer {
		stop.request()
	}
	mut a := dial(addr)
	a.write('GET /p/a HTTP/1.1\r\nHost: x\r\n\r\n'.bytes()) or { panic(err) }
	mut ra := Reader{}
	st, _ := ra.response(mut a) or { panic(err) }
	assert st == 200
	mut b := dial(addr)
	mut rb := Reader{}
	st503, _ := rb.response(mut b) or { panic(err) }
	assert st503 == 503
	b.close() or {}
	time.sleep(2500 * time.millisecond)
	assert read_until_eof(mut a) == 0
	a.close() or {}
}

fn test_stop_closes_listeners() {
	addr, mut stop := start(Options{})
	stop.request()
	time.sleep(1500 * time.millisecond)
	mut c := net.dial_tcp(addr) or { return } // refused: what we want
	c.close() or {}
	assert false, 'still accepting after stop'
}
```

- [ ] **Step 2: Run them and see them fail**

Run `t10.sh`. Expected: compile error, `unknown function: serve`.

- [ ] **Step 3: Implement `engine/serve_linux.c.v`**

```v
module engine

import net
import os
import runtime
import sync.stdatomic
import viltrum.router

#include <sched.h>

fn C.sched_getaffinity(pid int, size usize, mask voidptr) int

const listen_backlog = 4096

// ConnCount is the process-wide connection count behind max_conns.
@[heap]
struct ConnCount {
mut:
	active i64
}

// try_add takes a slot unless max are taken; approximate under races, which is
// fine for a soft limit.
fn (mut cc ConnCount) try_add(max int) bool {
	if stdatomic.add_i64(&cc.active, 1) > max {
		stdatomic.sub_i64(&cc.active, 1)
		return false
	}
	return true
}

fn (mut cc ConnCount) release() {
	stdatomic.sub_i64(&cc.active, 1)
}

// serve runs one epoll worker per CPU, each with its own SO_REUSEPORT listener, and
// blocks until SIGINT/SIGTERM or opts.stop asks it to stop.
pub fn serve(addr string, r &router.Router, opts Options) ! {
	n := worker_count(opts.workers)
	mut stop := if isnil(opts.stop) { new_stop() } else { opts.stop }
	mut lfds := []int{}
	for _ in 0 .. n {
		lfds << listen_reuseport(addr)!
	}
	if opts.handle_signals {
		os.signal_opt(.int, fn [mut stop] (_ os.Signal) {
			stop.request()
		}) or {}
		os.signal_opt(.term, fn [mut stop] (_ os.Signal) {
			stop.request()
		}) or {}
	}
	eprintln('[viltrum] listening on http://${addr} (${n} workers)')
	mut count := &ConnCount{}
	mut threads := []thread{}
	for i in 1 .. n {
		threads << spawn run_worker(i, lfds[i], r, opts, stop, count)
	}
	run_worker(0, lfds[0], r, opts, stop, count)
	threads.wait()
	for fd in lfds {
		C.close(fd)
	}
}

// worker_count resolves Options.workers: an explicit count, else VILTRUM_WORKERS,
// else the CPUs in this process's affinity mask (taskset and cgroup cpusets count).
pub fn worker_count(requested int) int {
	if requested > 0 {
		return requested
	}
	if s := os.getenv_opt('VILTRUM_WORKERS') {
		n := s.int()
		if n > 0 {
			return n
		}
	}
	mut mask := [16]u64{}
	if C.sched_getaffinity(0, sizeof(mask), &mask[0]) == 0 {
		mut n := 0
		for w in mask {
			mut x := w
			for x != 0 {
				x &= x - 1
				n++
			}
		}
		if n > 0 {
			return n
		}
	}
	return runtime.nr_cpus()
}

fn listen_reuseport(addr string) !int {
	mut s := net.new_tcp_socket(.ip)!
	one := 1
	if C.setsockopt(s.handle, C.SOL_SOCKET, C.SO_REUSEPORT, &one, sizeof(int)) != 0 {
		return error('SO_REUSEPORT setsockopt failed')
	}
	s.bind(addr)!
	if C.listen(s.handle, listen_backlog) != 0 {
		return error('listen failed on ${addr}')
	}
	net.set_blocking(s.handle, false)!
	return s.handle
}
```

- [ ] **Step 4: Implement `engine/worker_linux.c.v`**

```v
module engine

import time
import viltrum.router

#include <sys/epoll.h>
#include <sys/socket.h>
#include <netinet/tcp.h>
#include <errno.h>

fn C.epoll_create1(flags int) int
fn C.epoll_ctl(epfd int, op int, fd int, event &C.epoll_event) int
fn C.epoll_wait(epfd int, events &C.epoll_event, maxevents int, timeout_ms int) int
fn C.accept4(sockfd int, addr voidptr, addrlen voidptr, flags int) int

@[typedef]
union C.epoll_data_t {
mut:
	ptr voidptr
	fd  int
	u32 u32
	u64 u64
}

@[packed]
struct C.epoll_event {
mut:
	events u32
	data   C.epoll_data_t
}

const max_events = 512
const shrink_rbuf_above = 64 * 1024
const shrink_wbuf_above = 256 * 1024
const busy_msg = 'HTTP/1.1 503 Service Unavailable\r\nContent-Length: 19\r\nConnection: close\r\n\r\nservice unavailable'

struct Loop {
mut:
	w          &Worker
	epfd       int
	lfd        int
	conns      []&Conn // indexed by fd; a Conn outlives its connection and is reused
	opts       Options
	stop       &Stop
	count      &ConnCount
	now        i64 // ms (time.ticks)
	last_sweep i64
}

fn run_worker(index int, lfd int, r &router.Router, opts Options, stop &Stop, count &ConnCount) {
	mut l := Loop{
		w:     new_worker(r, opts, index)
		epfd:  C.epoll_create1(0)
		lfd:   lfd
		opts:  opts
		stop:  stop
		count: count
	}
	l.ctl(C.EPOLL_CTL_ADD, lfd, u32(C.EPOLLIN))
	mut events := [max_events]C.epoll_event{}
	for !stop.requested() {
		n := C.epoll_wait(l.epfd, &events[0], max_events, 1000)
		l.now = time.ticks()
		for i in 0 .. n {
			fd := unsafe { events[i].data.fd }
			if fd == lfd {
				l.accept_all()
			} else {
				l.on_event(fd, events[i].events)
			}
		}
		if l.now - l.last_sweep >= 1000 {
			l.sweep()
			l.last_sweep = l.now
		}
	}
	for i in 0 .. l.conns.len {
		if !isnil(l.conns[i]) && l.conns[i].fd >= 0 {
			mut c := l.conns[i]
			l.close(mut c)
		}
	}
	C.close(l.epfd)
}

fn (mut l Loop) ctl(op int, fd int, events u32) {
	mut ev := C.epoll_event{}
	ev.events = events
	ev.data.fd = fd
	C.epoll_ctl(l.epfd, op, fd, &ev)
}

fn (mut l Loop) accept_all() {
	for {
		fd := C.accept4(l.lfd, unsafe { nil }, unsafe { nil }, C.SOCK_NONBLOCK | C.SOCK_CLOEXEC)
		if fd < 0 {
			return // EAGAIN, or an error the next readiness event retries
		}
		mut counted := false
		if l.opts.max_conns > 0 {
			if !l.count.try_add(l.opts.max_conns) {
				C.send(fd, busy_msg.str, busy_msg.len, C.MSG_NOSIGNAL)
				C.close(fd)
				continue
			}
			counted = true
		}
		one := 1
		C.setsockopt(fd, C.IPPROTO_TCP, C.TCP_NODELAY, &one, sizeof(int))
		mut c := l.conn_for(fd)
		c.reset(fd)
		c.counted = counted
		c.deadline_ms = l.now + l.opts.idle_timeout.milliseconds()
		l.ctl(C.EPOLL_CTL_ADD, fd, u32(C.EPOLLIN | C.EPOLLRDHUP))
	}
}

fn (mut l Loop) conn_for(fd int) &Conn {
	for l.conns.len <= fd {
		l.conns << unsafe { nil } // cold: once per new highest fd
	}
	if isnil(l.conns[fd]) {
		l.conns[fd] = new_conn() // cold: once per fd number
	}
	return l.conns[fd]
}

fn (mut l Loop) on_event(fd int, ev u32) {
	if fd >= l.conns.len || isnil(l.conns[fd]) || l.conns[fd].fd != fd {
		return
	}
	mut c := l.conns[fd]
	if ev & u32(C.EPOLLERR | C.EPOLLHUP) != 0 {
		l.close(mut c)
		return
	}
	if c.out_armed {
		if ev & u32(C.EPOLLOUT) != 0 {
			l.flush(mut c)
			if c.fd >= 0 && !c.out_armed {
				l.drain(mut c)
			}
		}
		return
	}
	if ev & u32(C.EPOLLIN | C.EPOLLRDHUP) != 0 {
		l.on_readable(mut c)
	}
}

fn (mut l Loop) on_readable(mut c Conn) {
	max_total := l.opts.limits.max_header_bytes + l.opts.limits.max_body_bytes + 64 * 1024
	for {
		if c.rbuf.len == c.rbuf.cap {
			if c.rbuf.cap >= max_total {
				l.close(mut c)
				return
			}
			unsafe { c.rbuf.grow_cap(c.rbuf.cap) } // cold: a request larger than the buffer
		}
		spare := c.rbuf.cap - c.rbuf.len
		n := int(C.recv(c.fd, unsafe { &u8(c.rbuf.data) + c.rbuf.len }, spare, 0))
		if n == 0 {
			l.close(mut c)
			return
		}
		if n < 0 {
			if C.errno != C.EAGAIN && C.errno != C.EWOULDBLOCK {
				l.close(mut c)
			}
			return
		}
		unsafe {
			c.rbuf.len += n
		}
		was_reading := c.reading
		l.drain(mut c)
		if c.fd < 0 || c.out_armed {
			return
		}
		if c.reading && !was_reading {
			c.deadline_ms = l.now + l.opts.read_timeout.milliseconds()
		} else if !c.reading {
			c.deadline_ms = l.now + l.opts.idle_timeout.milliseconds()
		}
		if n < spare {
			return // short read: the socket is drained, epoll reports more
		}
	}
}

// drain serves buffered requests and flushes until nothing more can be done now.
fn (mut l Loop) drain(mut c Conn) {
	for {
		before := c.rbuf.len
		l.w.process(mut c)
		l.flush(mut c)
		if c.fd < 0 || c.out_armed || c.rbuf.len == before {
			return
		}
	}
}

fn (mut l Loop) flush(mut c Conn) {
	for c.woff < c.wbuf.len {
		n := int(C.send(c.fd, unsafe { &u8(c.wbuf.data) + c.woff }, c.wbuf.len - c.woff,
			C.MSG_NOSIGNAL))
		if n < 0 {
			if C.errno == C.EAGAIN || C.errno == C.EWOULDBLOCK {
				if !c.out_armed {
					l.ctl(C.EPOLL_CTL_MOD, c.fd, u32(C.EPOLLOUT))
					c.out_armed = true
				}
				c.deadline_ms = l.now + l.opts.write_timeout.milliseconds()
				return
			}
			l.close(mut c)
			return
		}
		c.woff += n
	}
	unsafe {
		c.wbuf.len = 0
	}
	c.woff = 0
	if c.close_after {
		l.close(mut c)
		return
	}
	if c.out_armed {
		l.ctl(C.EPOLL_CTL_MOD, c.fd, u32(C.EPOLLIN | C.EPOLLRDHUP))
		c.out_armed = false
		c.deadline_ms = l.now + if c.reading {
			l.opts.read_timeout.milliseconds()
		} else {
			l.opts.idle_timeout.milliseconds()
		}
	}
}

fn (mut l Loop) close(mut c Conn) {
	if c.fd < 0 {
		return
	}
	l.ctl(C.EPOLL_CTL_DEL, c.fd, 0)
	C.close(c.fd)
	if c.counted {
		l.count.release()
		c.counted = false
	}
	c.fd = -1
	if c.rbuf.cap > shrink_rbuf_above {
		c.rbuf = []u8{cap: read_buf_size} // cold: give back what one large request grew
	}
	if c.wbuf.cap > shrink_wbuf_above {
		c.wbuf = []u8{cap: write_buf_size} // cold
	}
}

fn (mut l Loop) sweep() {
	for i in 0 .. l.conns.len {
		if isnil(l.conns[i]) || l.conns[i].fd < 0 || l.now <= l.conns[i].deadline_ms {
			continue
		}
		mut c := l.conns[i]
		l.close(mut c)
	}
}
```

- [ ] **Step 5: Run the tests**

Run `t10.sh`. Expected: `2 passed, 2 total` (about 15 s; the timeout tests sleep).

- [ ] **Step 6: Smoke test under load in WSL**

Scratchpad `smoke.sh` (server on cores 0-7, wrk on 8-15; checks it serves and stops cleanly, not a benchmark):

```bash
export PATH=$HOME/v:$PATH
cd /mnt/c/Users/tunay/Documents/GitHub/viltrum
mkdir -p /tmp/smoke && cat > /tmp/smoke/main.v <<'V'
module main

import viltrum.engine
import viltrum.http1
import viltrum.router

fn ok(mut c http1.Ctx) {
	c.text(200, 'ok')
}

fn main() {
	mut r := &router.Router{}
	r.add(.get, '/pipeline', [http1.Handler(ok)]) or { panic(err) }
	engine.serve('127.0.0.1:18080', r, engine.Options{ workers: 8 }) or { panic(err) }
}
V
v -prod -o /tmp/smoke/server /tmp/smoke/main.v || exit 1
taskset -c 0-7 /tmp/smoke/server & P=$!
sleep 1
taskset -c 8-15 wrk -t8 -c512 -d5s http://127.0.0.1:18080/pipeline | grep -E 'Requests/sec|Socket errors|Non-2xx'
kill -INT $P; wait $P; echo "exit=$?"
```

Expected: a `Requests/sec` line, no `Non-2xx`, `exit=0` within a second of SIGINT.

- [ ] **Step 7: Format check and commit**

```bash
# wsl -e bash <scratchpad>/fmt.sh engine/serve_linux.c.v engine/worker_linux.c.v engine/serve_test.v
git add engine
git commit -q -m "feat(engine): per-core epoll workers with SO_REUSEPORT, backpressure and timeouts"
```

---

### Task 12: The `viltrum` App API, built-in middleware, examples and docs

**Files:**
- Replace: `viltrum.v`
- Create: `middleware.v`, `tests/app_test.v`, `examples/hello/main.v`, `examples/rest/main.v`, `examples/features/main.v`
- Modify: `examples/README.md`, `README.md`, `docs/getting-started.md`, `docs/request-response.md`, `docs/connection.md`, `docs/ws.md`, `docs/tls.md`, `docs/upgrade.md`, `.github/workflows/ci.yml`

**Interfaces:**
- Consumes: `engine.serve`, `engine.worker_count`, `engine.new_worker`, `engine.new_conn`, `engine.Options`; `router.Router`; `http1.Ctx`, `http1.Handler`, `http1.Method`, `http1.gzip_middleware`
- Produces (public API of v1.0):
  - `pub type Ctx = http1.Ctx`, `pub type Handler = http1.Handler`, `pub type Method = http1.Method`, `pub type Options = engine.Options`
  - `pub fn new() &App`; `App.server_options(opts Options)`, `App.use(mw Handler)`, `App.get/post/put/patch/delete/head/options(pattern string, handlers ...Handler)`, `App.handle(method Method, pattern string, handlers ...Handler)`, `App.group(prefix string, mws ...Handler) Group`, `App.listen(addr string) !`, `App.worker_count() int`, `App.handle_raw(raw string) !string`
  - `Group.get/post/put/patch/delete(pattern string, handlers ...Handler)`, `Group.handle(...)`
  - Middleware: `pub fn recover(mut c Ctx)`, `pub fn gzip(mut c Ctx)`, `pub fn cors(origin string) Handler`, `pub fn logger(mut c Ctx)`

- [ ] **Step 1: Write the failing test**

`tests/app_test.v`:

```v
module main

import viltrum

fn hello(mut c viltrum.Ctx) {
	c.text(200, 'hello')
}

fn user(mut c viltrum.Ctx) {
	c.text(200, c.param('id') or { '' })
}

fn tag(mut c viltrum.Ctx) {
	c.set_header('X-Tag', 'g')
	c.next()
}

fn silent(mut c viltrum.Ctx) {}

fn big(mut c viltrum.Ctx) {
	c.text(200, 'z'.repeat(1000))
}

fn build_app() &viltrum.App {
	mut a := viltrum.new()
	a.use(viltrum.cors('*'))
	a.get('/', hello)
	mut api := a.group('/api', tag)
	api.get('/users/:id', user)
	a.get('/silent', viltrum.recover, silent)
	a.get('/big', viltrum.gzip, big)
	return a
}

fn test_routes_groups_and_global_middleware() {
	a := build_app()
	r1 := a.handle_raw('GET / HTTP/1.1\r\nHost: x\r\n\r\n')!
	assert r1.contains('Access-Control-Allow-Origin: *\r\n') && r1.ends_with('hello')
	r2 := a.handle_raw('GET /api/users/7 HTTP/1.1\r\nHost: x\r\n\r\n')!
	assert r2.contains('X-Tag: g\r\n') && r2.ends_with('\r\n\r\n7')
	r3 := a.handle_raw('GET /nope HTTP/1.1\r\nHost: x\r\n\r\n')!
	assert r3.starts_with('HTTP/1.1 404 ') && r3.contains('Access-Control-Allow-Origin')
	r4 := a.handle_raw('OPTIONS /api/users/7 HTTP/1.1\r\nHost: x\r\n\r\n')!
	assert r4.starts_with('HTTP/1.1 204 ') && r4.contains('Access-Control-Allow-Methods')
	r5 := a.handle_raw('GET /silent HTTP/1.1\r\nHost: x\r\n\r\n')!
	assert r5.starts_with('HTTP/1.1 500 ') && r5.contains('Connection: close\r\n')
	r6 := a.handle_raw('GET /big HTTP/1.1\r\nHost: x\r\nAccept-Encoding: gzip\r\n\r\n')!
	assert r6.contains('Content-Encoding: gzip\r\n')
}

fn test_bad_pattern_is_reported() {
	mut a := viltrum.new()
	a.get('/x/*rest/y', hello)
	a.handle_raw('GET / HTTP/1.1\r\nHost: x\r\n\r\n') or {
		assert err.msg().contains('wildcard')
		return
	}
	assert false, 'bad pattern accepted'
}
```

- [ ] **Step 2: Run it and see it fail**

Scratchpad `t12.sh`:

```bash
export PATH=$HOME/v:$PATH
cd /mnt/c/Users/tunay/Documents/GitHub/viltrum
v test tests/ 2>&1 | grep -E 'FAIL|Summary|error|>' | head
```

Expected: compile error, `unknown function: viltrum.new`.

- [ ] **Step 3: Replace `viltrum.v`**

```v
module viltrum

import viltrum.engine
import viltrum.http1
import viltrum.router

// Viltrum is an HTTP/1.1 framework for V with its own engine: one epoll worker per
// CPU, and no allocation per request inside the framework.

pub const version = '1.0.0-dev'

pub type Ctx = http1.Ctx
pub type Handler = http1.Handler
pub type Method = http1.Method
pub type Options = engine.Options

struct PendingRoute {
	method   http1.Method
	pattern  string
	handlers []http1.Handler
}

@[heap]
pub struct App {
mut:
	global []http1.Handler
	routes []PendingRoute
	opts   engine.Options
}

pub fn new() &App {
	return &App{}
}

// server_options replaces the engine options (workers, limits, timeouts, Date, Server).
pub fn (mut app App) server_options(opts Options) {
	app.opts = opts
}

// use adds global middleware. It runs before every route, and before the 404 and
// 405 answers too.
pub fn (mut app App) use(mw Handler) {
	app.global << mw
}

// handle registers handlers for method + pattern. The last one answers the request;
// the ones before it are route middleware that call c.next().
pub fn (mut app App) handle(method Method, pattern string, handlers ...Handler) {
	app.routes << PendingRoute{
		method:   method
		pattern:  pattern
		handlers: handlers
	}
}

pub fn (mut app App) get(pattern string, handlers ...Handler) {
	app.handle(.get, pattern, ...handlers)
}

pub fn (mut app App) post(pattern string, handlers ...Handler) {
	app.handle(.post, pattern, ...handlers)
}

pub fn (mut app App) put(pattern string, handlers ...Handler) {
	app.handle(.put, pattern, ...handlers)
}

pub fn (mut app App) patch(pattern string, handlers ...Handler) {
	app.handle(.patch, pattern, ...handlers)
}

pub fn (mut app App) delete(pattern string, handlers ...Handler) {
	app.handle(.delete, pattern, ...handlers)
}

pub fn (mut app App) head(pattern string, handlers ...Handler) {
	app.handle(.head, pattern, ...handlers)
}

pub fn (mut app App) options(pattern string, handlers ...Handler) {
	app.handle(.options, pattern, ...handlers)
}

pub struct Group {
mut:
	app    &App
	prefix string
	mws    []http1.Handler
}

// group returns routes under prefix that share mws.
pub fn (mut app App) group(prefix string, mws ...Handler) Group {
	return Group{
		app:    app
		prefix: prefix.trim_right('/')
		mws:    mws
	}
}

pub fn (mut g Group) handle(method Method, pattern string, handlers ...Handler) {
	mut chain := g.mws.clone()
	chain << handlers
	g.app.handle(method, join_path(g.prefix, pattern), ...chain)
}

pub fn (mut g Group) get(pattern string, handlers ...Handler) {
	g.handle(.get, pattern, ...handlers)
}

pub fn (mut g Group) post(pattern string, handlers ...Handler) {
	g.handle(.post, pattern, ...handlers)
}

pub fn (mut g Group) put(pattern string, handlers ...Handler) {
	g.handle(.put, pattern, ...handlers)
}

pub fn (mut g Group) patch(pattern string, handlers ...Handler) {
	g.handle(.patch, pattern, ...handlers)
}

pub fn (mut g Group) delete(pattern string, handlers ...Handler) {
	g.handle(.delete, pattern, ...handlers)
}

fn join_path(prefix string, pattern string) string {
	if pattern == '' || pattern == '/' {
		return if prefix == '' { '/' } else { prefix }
	}
	return prefix + if pattern.starts_with('/') { pattern } else { '/' + pattern }
}

fn (app &App) build() !&router.Router {
	mut r := &router.Router{}
	for pr in app.routes {
		mut chain := app.global.clone()
		chain << pr.handlers
		r.add(pr.method, pr.pattern, chain)!
	}
	if app.global.len > 0 {
		mut nf := app.global.clone()
		nf << http1.Handler(not_found)
		r.on_404 = nf
		mut na := app.global.clone()
		na << http1.Handler(method_not_allowed)
		r.on_405 = na
	}
	return r
}

fn not_found(mut c Ctx) {
	c.text(404, 'not found')
}

fn method_not_allowed(mut c Ctx) {
	c.text(405, 'method not allowed')
}

// listen serves until SIGINT/SIGTERM (or Options.stop).
pub fn (app &App) listen(addr string) ! {
	r := app.build()!
	engine.serve(addr, r, app.opts)!
}

// worker_count is how many workers listen starts; size per-worker state with it and
// index it with c.worker_id().
pub fn (app &App) worker_count() int {
	return engine.worker_count(app.opts.workers)
}

// handle_raw serves raw request bytes in-process and returns the raw response bytes.
// Meant for tests: it rebuilds the router on every call.
pub fn (app &App) handle_raw(raw string) !string {
	r := app.build()!
	mut w := engine.new_worker(r, Options{
		...app.opts
		send_date: false
	}, 0)
	mut c := engine.new_conn()
	unsafe { c.rbuf.push_many(raw.str, raw.len) }
	w.process(mut c)
	return c.wbuf.bytestr()
}
```

- [ ] **Step 4: Create `middleware.v`**

```v
module viltrum

import time
import viltrum.http1

// recover answers 500 and closes the connection when the rest of the chain wrote
// no response.
pub fn recover(mut c Ctx) {
	c.next()
	if !c.responded {
		c.close()
		c.text(500, 'internal error')
	}
}

// gzip compresses text and JSON bodies of 256 bytes or more for clients that accept
// gzip (q-values honored). Register it before the handlers it should cover.
pub fn gzip(mut c Ctx) {
	http1.gzip_middleware(mut c)
}

// cors allows cross-origin requests from origin and answers preflight requests.
pub fn cors(origin string) Handler {
	return fn [origin] (mut c Ctx) {
		c.set_header('Access-Control-Allow-Origin', origin)
		if c.method() == .options {
			c.set_header('Access-Control-Allow-Methods', 'GET, POST, PUT, PATCH, DELETE, OPTIONS')
			c.set_header('Access-Control-Allow-Headers', 'Content-Type, Authorization')
			c.set_header('Access-Control-Max-Age', '86400')
			c.no_content(204)
			return
		}
		c.next()
	}
}

// logger prints one line per request. It formats and writes per request, so it
// allocates: leave it out of benchmarks.
pub fn logger(mut c Ctx) {
	sw := time.new_stopwatch()
	c.next()
	println('${c.method()} ${c.path()} ${c.status} ${sw.elapsed().microseconds()}us')
}
```

- [ ] **Step 5: Run the tests**

Run `t12.sh`. Expected: `1 passed, 1 total`. Then run the whole suite (`t2.sh`, `t6.sh`, `t8.sh`, `t10.sh`).

- [ ] **Step 6: Write the examples**

`examples/hello/main.v`:

```v
module main

import viltrum

fn main() {
	mut app := viltrum.new()
	app.get('/', fn (mut c viltrum.Ctx) {
		c.text(200, 'Hello from viltrum\n')
	})
	app.get('/hi/:name', fn (mut c viltrum.Ctx) {
		c.text(200, c.param('name') or { 'world' })
	})
	app.listen('127.0.0.1:8080') or { panic(err) }
}
```

`examples/rest/main.v`:

```v
module main

import json
import sync
import viltrum

struct User {
	id   int
	name string
}

// Store is shared by every worker thread, so it is locked.
@[heap]
struct Store {
mut:
	mu    sync.Mutex
	users map[int]User
	next  int = 1
}

fn main() {
	mut store := &Store{}
	mut app := viltrum.new()
	app.use(viltrum.recover)
	app.get('/users/:id', fn [mut store] (mut c viltrum.Ctx) {
		id := int(c.param_int('id') or { 0 })
		store.mu.lock()
		u := store.users[id] or { User{} }
		store.mu.unlock()
		if u.id == 0 {
			c.text(404, 'no such user')
			return
		}
		c.json(200, u)
	})
	app.post('/users', fn [mut store] (mut c viltrum.Ctx) {
		input := json.decode(User, c.body().bytestr()) or {
			c.text(400, 'bad json')
			return
		}
		store.mu.lock()
		u := User{
			id:   store.next
			name: input.name
		}
		store.users[u.id] = u
		store.next++
		store.mu.unlock()
		c.json(201, u)
	})
	app.listen('127.0.0.1:8081') or { panic(err) }
}
```

`examples/features/main.v`:

```v
module main

import viltrum

struct Echo {
	q      string
	worker int
}

fn main() {
	mut app := viltrum.new()
	app.use(viltrum.logger)
	app.use(viltrum.cors('*'))
	app.get('/', fn (mut c viltrum.Ctx) {
		c.text(200, 'try /search?q=caf%C3%A9, /api/ping, /big\n')
	})
	app.get('/search', fn (mut c viltrum.Ctx) {
		q := c.query_param('q') or { '' }
		c.json(200, Echo{
			q:      q
			worker: c.worker_id()
		})
	})
	mut api := app.group('/api')
	api.get('/ping', fn (mut c viltrum.Ctx) {
		c.text(200, 'pong')
	})
	app.get('/big', viltrum.gzip, fn (mut c viltrum.Ctx) {
		c.text(200, 'viltrum '.repeat(500))
	})
	app.listen('127.0.0.1:8082') or { panic(err) }
}
```

Build them (scratchpad `ex.sh`):

```bash
export PATH=$HOME/v:$PATH
cd /mnt/c/Users/tunay/Documents/GitHub/viltrum
for e in hello rest features; do v -o /tmp/ex-$e examples/$e >/dev/null 2>/tmp/ex-$e.err && echo "ok $e" || { echo "FAIL $e"; grep error /tmp/ex-$e.err | head -3; }; done
```

Expected: `ok hello`, `ok rest`, `ok features`. Start `/tmp/ex-features` and check `curl -s 'http://127.0.0.1:8082/search?q=caf%C3%A9'` prints `{"q":"café","worker":N}`.

- [ ] **Step 7: Update CI, examples README and docs**

`.github/workflows/ci.yml` — replace the `Unit tests` step and add an examples step:

```yaml
      - name: Unit tests
        run: |
          v test http1/
          v test jsonenc/
          v test router/
          v test engine/
          v test tests/

      - name: Build examples
        run: |
          v -o /tmp/viltrum-hello examples/hello
          v -o /tmp/viltrum-rest examples/rest
          v -o /tmp/viltrum-features examples/features
```

`examples/README.md` — replace the whole file:

````markdown
# Examples

Link the module first (from the repo root): `bash scripts/install.sh`.

| Example | Port | Shows |
|---------|------|-------|
| `hello` | 8080 | text responses, a `:param` |
| `rest` | 8081 | JSON in and out, shared state behind a mutex (handlers run on every worker thread) |
| `features` | 8082 | global middleware (logger, cors), groups, decoded query params, gzip, `worker_id` |

```bash
v run examples/features
curl -s 'http://127.0.0.1:8082/search?q=caf%C3%A9'
curl -s --compressed -H 'Accept-Encoding: gzip' http://127.0.0.1:8082/big | head -c 40
```

TLS, WebSocket, static files, uploads and the HTTP client are not in 1.0 yet; see the README.
````

`README.md` — replace everything from the paragraph that starts `You write a few routes.` up to (not including) `## Numbers (laptop, not a lab)` with:

````markdown
You write routes. Viltrum owns the wire: its own HTTP/1.1 engine, one epoll worker per CPU, pipelining, and no
allocation per request inside the framework. No third-party stack under the hood.

Built for [V](https://vlang.io). Linux. Cleartext; put Caddy or nginx in front for TLS.

```bash
git clone https://github.com/Tuntii/viltrum.git && cd viltrum
bash scripts/install.sh   # ~/.vmodules/viltrum → this tree
v run examples/hello
# curl http://127.0.0.1:8080/
```

---

## A server in one file

```v
module main

import viltrum

fn main() {
	mut app := viltrum.new()
	app.use(viltrum.recover)
	app.get('/', fn (mut c viltrum.Ctx) {
		c.text(200, 'ok\n')
	})
	app.get('/hi/:name', fn (mut c viltrum.Ctx) {
		c.text(200, c.param('name') or { 'world' })
	})
	app.listen('127.0.0.1:8080') or { panic(err) }
}
```

Handlers get a `Ctx`: request views (`path`, `param`, `query_param`, `header`, `body`) and a response writer
(`text`, `text_int`, `json`, `bytes`, `no_content`, `set_header`). Request strings point into the connection's
buffer and are valid until the handler returns; `.clone()` what you keep.

---

## What you actually get

| Area | In 1.0 |
|------|--------|
| HTTP/1.1 | keep-alive, pipelining (responses batched into one write), `Expect: 100-continue`, HEAD |
| Bodies | `Content-Length` or `chunked`. Other codings, TE+CL, duplicate or non-digit CL, `Name :`, obs-fold, bare CR/LF → **400** (parser fuzzed in CI) |
| Engine | one `SO_REUSEPORT` epoll worker per CPU (cpuset-aware), backpressure, read/idle/write timeouts, `max_conns`, graceful SIGINT/SIGTERM |
| Routing | `:param`, trailing `*rest`, groups, global and per-route middleware (`c.next()`) |
| Middleware | `recover`, `gzip`, `cors`, `logger` |
| JSON | `c.json(200, value)`: compile-time encoder, no reflection |
| Tests | `app.handle_raw(raw)` serves a raw request in-process |

Not in 1.0 yet (they return on the new core): TLS/WSS, WebSocket and upgrade, static files, forms and uploads,
the HTTP client, non-Linux platforms.
````

Also replace the body of `## Roadmap, in one breath` with:

```markdown
**1.0:** the zero-allocation core above (design: [docs/superpowers/specs/2026-10-15-v1-zero-alloc-core-design.md](docs/superpowers/specs/2026-10-15-v1-zero-alloc-core-design.md)).

**Next:** TLS, WebSocket, static files and forms on the new core.
```

`docs/getting-started.md`, `docs/request-response.md`, `docs/connection.md` — replace each file's content with:

`docs/getting-started.md`:

````markdown
# Getting started

1. Install V 0.5.2 and link the module: `bash scripts/install.sh`.
2. Run `v run examples/hello` and open http://127.0.0.1:8080/.
3. Copy `examples/features/main.v` as a starting point.

A handler is `fn (mut c viltrum.Ctx)`. Middleware has the same type and calls `c.next()` to continue.

```v
fn auth(mut c viltrum.Ctx) {
	if c.header('authorization') or { '' } == '' {
		c.text(401, 'unauthorized')
		return
	}
	c.next()
}
```

Register it globally (`app.use(auth)`), on a group (`app.group('/api', auth)`) or on one route
(`app.get('/me', auth, me)`).

Handlers run on several worker threads at once. Shared state needs a lock (see `examples/rest`), or one copy per
worker indexed by `c.worker_id()` (size it with `app.worker_count()`).
````

`docs/request-response.md`:

````markdown
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
````

`docs/connection.md`:

```markdown
# Connections

- One worker per CPU in the process affinity mask (`Options.workers` or `VILTRUM_WORKERS` override), each with
  its own `SO_REUSEPORT` listener and epoll loop.
- Each connection keeps an 8 KiB read and 16 KiB write buffer for its life; they grow only for larger messages
  and shrink back when the connection closes.
- Every complete request in a read is served, and the responses go out in one `send`. Processing pauses once
  `Options.max_pending` (1 MiB) of output waits; reading pauses while output is pending.
- Limits: `max_header_bytes` 64 KiB (431), `max_body_bytes` 1 MiB (413), 32 header fields (431),
  `max_conns` (503 and close).
- Timeouts: `read_timeout` 30 s from a request's first byte, `idle_timeout` 60 s between requests,
  `write_timeout` 30 s while output is pending.
- Framing and parse errors answer 4xx after any earlier pipelined responses, then close.
- SIGINT/SIGTERM stop accepting; open connections are closed within a second.
```

At the top of `docs/ws.md`, `docs/tls.md` and `docs/upgrade.md`, insert:

```markdown
> **Not in 1.0.** This page describes v0.13. The feature returns on the 1.0 core later.
```

- [ ] **Step 8: Format check and commit**

```bash
# wsl -e bash <scratchpad>/fmt.sh viltrum.v middleware.v tests/app_test.v examples/hello/main.v examples/rest/main.v examples/features/main.v
git add -A viltrum.v middleware.v tests examples README.md docs .github/workflows/ci.yml
git commit -q -m "feat!: viltrum 1.0 App API on the zero-allocation core

Handlers take a Ctx and write into the connection buffer; middleware is
the same type and calls c.next().

BREAKING CHANGE: fn (req Request) Response handlers, HeaderMap and the
TLS, WebSocket, static, form and client features of 0.13 are gone in
1.0; see the README for what returns later."
```

---

### Task 13: CI gate, HttpArena entry, validation and measurement

**Files:**
- Create: `scripts/hotpath_lint.sh`
- Modify: `.github/workflows/ci.yml`, `benches/httparena/main.v`, `benches/httparena/meta.json`, `benches/httparena/README.md`, `benches/httparena/Dockerfile`

**Interfaces:**
- Consumes: the whole v1 API
- Produces: a CI job that fails on hot-path regressions; an HttpArena entry in standard mode that passes `validate.sh`

- [ ] **Step 1: Add the hot-path lint**

`scripts/hotpath_lint.sh`:

```bash
#!/usr/bin/env bash
# Fails when a hot-path file uses a construct that allocates per request. A line can
# opt out with a trailing "// cold:" comment explaining why it is off the hot path.
set -uo pipefail
files="http1/bytes.v http1/frame.v http1/chunked.v http1/parse.v http1/writer.v http1/date.v
http1/ctx.v http1/gzip.c.v jsonenc/encode.v engine/process.v engine/worker_linux.c.v"
pattern='\$\{|\.str\(\)|\.split\(|\.to_lower\(|\.to_upper\(|\.trim|\.bytestr\(\)|\.clone\(\)|\[[^]]*[^. ]\.\.[^]]*\]'
bad=0
for f in $files; do
	[ -f "$f" ] || continue
	hits=$(grep -nE "$pattern" "$f" | grep -vE '^[0-9]+:\s*//' | grep -v '// cold:')
	if [ -n "$hits" ]; then
		echo "$f:"
		echo "$hits"
		bad=1
	fi
done
[ "$bad" = 0 ] && echo "hot path clean"
exit $bad
```

Run it (`wsl -e bash scripts/hotpath_lint.sh`). Expected: `hot path clean`. Any hit is either a real allocation to remove or a cold line to mark `// cold:` with a reason.

Add to `.github/workflows/ci.yml` after `Unit tests`:

```yaml
      - name: Hot-path lint
        run: bash scripts/hotpath_lint.sh
```

The zero-allocation gate itself is `engine/process_test.v::test_hot_path_allocates_nothing`, already in `v test engine/`.

- [ ] **Step 2: Port the HttpArena entry to standard mode**

`benches/httparena/main.v`:

```v
module main

import json
import os
import viltrum

struct Rating {
	score int
	count int
}

struct Item {
	id       int
	name     string
	category string
	price    int
	quantity int
	active   bool
	tags     []string
	rating   Rating
mut:
	total i64
}

struct Page {
	items []Item
	count int
}

fn main() {
	dataset := json.decode([]Item, os.read_file('/data/dataset.json') or { '[]' }) or { []Item{} }
	mut app := viltrum.new()
	// One copy of the dataset per worker: totals are written per request, and a
	// worker only touches its own copy.
	mut copies := [][]Item{}
	for _ in 0 .. app.worker_count() {
		copies << dataset.clone()
	}
	app.get('/baseline11', baseline)
	app.post('/baseline11', baseline)
	app.get('/pipeline', fn (mut c viltrum.Ctx) {
		c.text(200, 'ok')
	})
	app.get('/json/:count', viltrum.gzip, fn [mut copies] (mut c viltrum.Ctx) {
		mut items := copies[c.worker_id()]
		mut n := int(c.param_int('count') or { 0 })
		if n < 0 {
			n = 0
		} else if n > items.len {
			n = items.len
		}
		m := c.query_int('m') or { 1 }
		for i in 0 .. n {
			items[i].total = i64(items[i].price) * i64(items[i].quantity) * m
		}
		mut page := unsafe { items }
		unsafe {
			page.len = n
		}
		c.json(200, Page{
			items: page
			count: n
		})
	})
	app.listen('0.0.0.0:8080') or { panic(err) }
}

fn baseline(mut c viltrum.Ctx) {
	sum := (c.query_int('a') or { 0 }) + (c.query_int('b') or { 0 }) + (c.body_int() or { 0 })
	c.text_int(200, sum)
}
```

`benches/httparena/meta.json`:

```json
{
  "display_name": "viltrum",
  "language": "V",
  "engine": "viltrum",
  "type": "emerging",
  "mode": "standard",
  "completeness": { "routing": true, "middleware": true, "request": true, "response": true },
  "description": "HTTP framework for V with its own HTTP/1.1 engine: one SO_REUSEPORT epoll worker per CPU, pipelined responses batched into one write, and no allocation per request inside the framework (CI-enforced). Router with :params, middleware chain (c.next()), compile-time JSON encoder, gzip middleware on miniz. Request framing is smuggling-hardened (Content-Length and chunked) and fuzzed in CI. Default configuration.",
  "repo": "https://github.com/Tuntii/viltrum",
  "enabled": true,
  "tests": ["baseline", "pipelined", "limited-conn", "json-comp"],
  "maintainers": ["Tuntii"]
}
```

`benches/httparena/README.md` — replace the profile table with:

```markdown
| Profile | Endpoint | Notes |
|---------|----------|-------|
| baseline, limited-conn | `GET/POST /baseline11` | `c.query_int`, `c.body_int` (Content-Length or chunked) |
| pipelined | `GET /pipeline` | the engine batches pipelined responses into one write |
| json-comp | `GET /json/:count?m=` | `c.json` per request, `viltrum.gzip` middleware |
```

and replace the paragraph about `tuned` with: `This entry runs viltrum with its default configuration (standard mode).`

`benches/httparena/Dockerfile` — set `ARG VILTRUM_REF=` to the 1.0.0 tag once it exists (Step 6); until then validation copies the local tree.

- [ ] **Step 3: Validate the entry (user gate: hostlab, port 18080)**

Ask the user before using hostlab (its ports 8080/8081 run live services). Then, from the scratchpad:

```bash
cd /c/Users/tunay/Documents/GitHub/viltrum
git archive -o "$S/vhead.tar" HEAD
tar -cf "$S/arena.tar" -C benches httparena
scp -q "$S/vhead.tar" "$S/arena.tar" hostlab:/root/
ssh hostlab 'set -e; cd /root && rm -rf HttpArena && git clone -q --depth 1 --filter=blob:none --no-checkout https://github.com/MDA2AV/HttpArena && cd HttpArena && git sparse-checkout init --no-cone && printf "/*\n!/frameworks/*\n!/site/\n" > .git/info/sparse-checkout && git checkout -q && mkdir -p frameworks && tar -xf /root/arena.tar -C frameworks && mv frameworks/httparena frameworks/viltrum && cd frameworks/viltrum && mkdir viltrum-src && tar -xf /root/vhead.tar -C viltrum-src && sed -i "s#^ARG VILTRUM_REF.*##; s#^RUN git clone .*#COPY viltrum-src /root/.vmodules/viltrum#" Dockerfile && cd /root/HttpArena && sed "s/^PORT=8080$/PORT=18080/" scripts/validate.sh > scripts/validate-alt.sh && timeout 1500 bash scripts/validate-alt.sh viltrum 2>&1 | grep -E "Results|FAIL" ; docker rmi httparena-viltrum >/dev/null 2>&1; rm -rf /root/HttpArena /root/arena.tar /root/vhead.tar'
```

Expected: `=== Frag Results: 9 passed, 0 failed ===` and `=== Results: N passed, 0 failed ===` with no `FAIL` lines.

- [ ] **Step 4: Measure on semantic (user gate: time window)**

Ask the user for a window; `semantic` runs live services, so keep each run at 10 s and skip the run if `uptime` shows a 1-minute load above 2. Ask before installing `wrk` and `linux-tools` there, and remove them afterwards if they were not present.

Copy two trees to `semantic`: `git archive v1` and `git archive v0.13.1`, each with its `benches/httparena/main.v` and the dataset (`curl -sLo /root/viltrum-bench/dataset.json https://raw.githubusercontent.com/MDA2AV/HttpArena/main/data/dataset.json`, patched into `main.v` in place of `/data/dataset.json`). Then run `/root/viltrum-bench/measure.sh`:

```bash
#!/usr/bin/env bash
# instructions per request for one server binary on two endpoints; $1 = binary, $2 = label
set -u
B=$1
L=$2
taskset -c 0-5 env VILTRUM_WORKERS=6 "$B" >/dev/null 2>&1 & P=$!
sleep 1
for url in 'http://127.0.0.1:8080/baseline11?a=13&b=42' 'http://127.0.0.1:8080/json/40?m=3'; do
	perf stat -x, -e instructions -p $P -- sleep 10 2> perf.txt &
	S=$!
	taskset -c 6-11 wrk -t6 -c256 -d10s -H 'Accept-Encoding: gzip, br' "$url" > wrk.txt
	wait $S
	ins=$(cut -d, -f1 perf.txt | head -1)
	req=$(awk '/requests in/{print $1}' wrk.txt)
	rps=$(awk '/Requests\/sec/{print $2}' wrk.txt)
	echo "$L $url instructions/request=$((ins / req)) rps=$rps"
done
kill $P
wait $P 2>/dev/null
```

(`./measure.sh ./v1-server v1` and `./measure.sh ./v013-server v0.13.1`; the v0.13.1 binary takes `epoll_cores` from its own `main.v`.) Record both in `benches/compare/V1.md` as a table of instructions/request and rps, noting that loopback rps is generator-bound and instructions/request is the comparable number. Then delete `/root/viltrum-bench`.

- [ ] **Step 5: Commit**

```bash
# wsl -e bash <scratchpad>/fmt.sh benches/httparena/main.v
git add scripts/hotpath_lint.sh .github/workflows/ci.yml benches
git commit -q -m "chore(bench): hot-path lint in CI and a standard-mode HttpArena entry"
```

Also whitelist the new doc in `.gitignore` (add `!/benches/compare/V1.md` next to the other `benches/compare` entries) before `git add`, or it will be ignored.

```bash
git status --short benches/compare/V1.md   # must show the file as added
```

- [ ] **Step 6: Release and HttpArena update (user gate)**

Ask the user to approve each of these separately:
1. Merge `v1` into `main` and push: semantic-release cuts 1.0.0 from the `feat!` / `BREAKING CHANGE` commits.
2. Set `ARG VILTRUM_REF=v1.0.0` in `benches/httparena/Dockerfile`, copy `benches/httparena/*` over `frameworks/viltrum/` on the `add-viltrum` branch of `Tuntii/HttpArena` (dropping `echo-ws` from the PR), push, and comment on PR #1559 that the entry moved to standard mode on 1.0.0 and asks for `/benchmark -f viltrum`.
