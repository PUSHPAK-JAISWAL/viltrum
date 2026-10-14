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

// parse_content_length accepts 1*DIGIT only (RFC 9112 section 6.3): no sign, list or overflow.
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
