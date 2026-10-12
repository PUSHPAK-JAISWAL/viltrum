module http

import os
import rand

// Framing that a front proxy might read differently than we do. Every case must be
// a parse error (engine answers 400 + close), never a silently "fixed" request.
fn test_rejects_ambiguous_framing() {
	bad := [
		'POST / HTTP/1.1\r\nHost: x\r\nContent-Length : 5\r\n\r\nhello', // space before colon
		'POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\nContent-Length: 6\r\n\r\nhelloo',
		'POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\nContent-Length: 5\r\n\r\nhello',
		'POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 5, 5\r\n\r\nhello',
		'POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 5abc\r\n\r\nhello',
		'POST / HTTP/1.1\r\nHost: x\r\nContent-Length: +5\r\n\r\nhello',
		'POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 0x5\r\n\r\nhello',
		'POST / HTTP/1.1\r\nHost: x\r\nContent-Length: \r\n\r\n',
		'POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 4294967301\r\n\r\nhello', // wraps to 5 in 32-bit
		'POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 99999999999999999999999\r\n\r\nhello',
		'GET / HTTP/1.1\r\nHost: x\r\n folded: value\r\n\r\n', // obs-fold
		'GET / HTTP/1.1\r\nHost: x\r\nX: a\nContent-Length: 5\r\n\r\nhello', // bare LF
		'GET / HTTP/1.1\r\nHost: x\r\nX: a\rb\r\n\r\n', // bare CR
		'GET / HTTP/1.1\r\nHost: x\r\nX: a\x00b\r\n\r\n', // NUL
		'GET / HTTP/1.1\r\nHost: a\r\nHost: b\r\n\r\n',
		'GET / HTTP/1.1\r\nHost: x\r\nX(y): z\r\n\r\n', // non-token name
		'GET / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding : chunked\r\n\r\n',
		'GET /a\nb HTTP/1.1\r\nHost: x\r\n\r\n', // bare LF in request line
	]
	for raw in bad {
		if req := parse_request(raw.bytes()) {
			assert false, 'accepted: ${raw.replace('\r', '\\r').replace('\n', '\\n')} -> body=${req.body.len}'
		}
	}
}

fn test_accepts_well_formed_edges() {
	ok := [
		'GET / HTTP/1.1\r\nHost: x\r\nX-Tab:\tv\t\r\n\r\n',
		'POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 0\r\n\r\n',
		'POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 005\r\n\r\nhello',
		"GET / HTTP/1.1\r\nHost: x\r\nX-Ok!#$%&'*+-.^_`|~: v\r\n\r\n",
		'GET / HTTP/1.1\r\nHost: x\r\nX-Utf8: caf\xc3\xa9\r\n\r\n', // obs-text is legal in values
	]
	for raw in ok {
		parse_request(raw.bytes()) or { assert false, '${raw}: ${err.msg()}' }
	}
}

// Found by test_fuzz_parse_request: string.to_lower() on non-ASCII bytes changed the
// length, so the boundary index overran content_type and the process panicked.
fn test_multipart_non_ascii_content_type_no_panic() {
	for b in 0x80 .. 0x100 {
		ct := 'multipart/form-data;' + [u8(b)].bytestr() + 'boundary=B'
		parse_multipart('--B\r\nContent-Disposition: form-data; name="f"\r\n\r\nx\r\n--B--'.bytes(),
			ct) or {}
		disp_param('form-data;' + [u8(b)].bytestr() + 'name="f"', 'name')
	}
}

const fuzz_seeds = [
	'GET /hi/tunay?x=1 HTTP/1.1\r\nHost: localhost\r\nUser-Agent: t\r\n\r\n',
	'POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\nhello',
	'OPTIONS * HTTP/1.1\r\nHost: x\r\n\r\n',
	'GET http://x/a/../b?q HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n',
	'POST /u HTTP/1.1\r\nHost: x\r\nContent-Type: multipart/form-data; boundary=B\r\nContent-Length: 78\r\n\r\n--B\r\nContent-Disposition: form-data; name="f"; filename="a.txt"\r\n\r\nhi\r\n--B--\r\n',
	'GET / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n',
]

const fuzz_tokens = [':', ' ', '\t', '\r', '\n', '\r\n', '\r\n\r\n', '\x00', '\xff', ',',
	'Content-Length: ', 'Transfer-Encoding: ', 'Host: ', '--B', '--B--', '%', '?', '/../', '-1',
	'4294967296', 'HTTP/1.1']

// Random mutations over seed requests. Invariants: no panic (V aborts on OOB), and a
// successful parse never claims more body than the buffer holds or than CL says.
// Deterministic seed; set VILTRUM_FUZZ_ITERS for a longer local run.
fn test_fuzz_parse_request() {
	iters := os.getenv_opt('VILTRUM_FUZZ_ITERS') or { '20000' }.int()
	rand.seed([u32(0x5eed), 0x1])
	for _ in 0 .. iters {
		mut b := fuzz_seeds[rand.intn(fuzz_seeds.len) or { 0 }].bytes()
		for _ in 0 .. 1 + (rand.intn(4) or { 0 }) {
			b = mutate(b)
		}
		req := parse_request(b) or { continue }
		assert req.body.len <= b.len
		if cl := req.headers.get_lowered('content-length') {
			assert req.body.len == cl.int()
		}
		assert req.method.len > 0
		req.form_parts() or {}
		req.form_value('f')
		req.query_param('q')
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
			out = out[..pos].clone() // truncate
		}
	}
	return out
}
