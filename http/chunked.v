module http

// Chunked request bodies (RFC 9112 §7.1). The engine frames a message with
// ChunkScan and parse_request decodes it with the same walker, so the two can
// never disagree on where a message ends.

const max_chunk_size_digits = 8 // 0xffffffff; the body limit cuts in long before
const max_chunk_trailer_bytes = 8192
const max_chunk_line_bytes = 4096 // size line incl. extensions

// ChunkScan is resumable framing state. pos is an offset into the buffer passed
// to scan_chunked; it only moves past complete units, so a slow client sending a
// byte at a time costs one pass over the body, not one pass per read.
pub struct ChunkScan {
pub mut:
	pos int
mut:
	total         int
	in_trailers   bool
	trailer_bytes int
}

// ChunkScan.new starts scanning at body_start (just past the header CRLFCRLF).
pub fn ChunkScan.new(body_start int) ChunkScan {
	return ChunkScan{
		pos: body_start
	}
}

// is_chunked reports whether a Transfer-Encoding value is exactly `chunked`.
// Any other coding, or a list, is not supported and must be rejected.
pub fn is_chunked(te string) bool {
	return eq_ascii_ci(te, 'chunked')
}

// scan_chunked advances st over buf. It returns true when the whole chunked body
// (last chunk, trailers and final CRLF) is in buf; st.pos is then the message end.
// It returns false when more bytes are needed. With decode set, chunk data is
// appended to out.
pub fn scan_chunked(buf []u8, mut st ChunkScan, max_body int, decode bool, mut out []u8) !bool {
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
				return error('bad chunk size')
			}
			size = size * 16 + i64(v)
			i++
		}
		if i >= buf.len {
			return false
		}
		if digits == 0 {
			return error('bad chunk size')
		}
		// chunk-ext: BWS ';' ... up to CRLF; its content is only checked for control bytes.
		for i < buf.len && (buf[i] == ` ` || buf[i] == `\t`) {
			i++
		}
		if i >= buf.len {
			if buf.len - st.pos > max_chunk_line_bytes {
				return error('chunk line too long')
			}
			return false
		}
		if buf[i] != `\r` && buf[i] != `;` {
			return error('bad chunk size')
		}
		i = line_end(buf, i) or { return error('bad chunk line') }
		if i < 0 {
			if buf.len - st.pos > max_chunk_line_bytes {
				return error('chunk line too long')
			}
			return false
		}
		if size == 0 {
			st.pos = i
			st.in_trailers = true
			break
		}
		if i64(st.total) + size > i64(max_body) {
			return error('payload too large')
		}
		n := int(size)
		if buf.len < i + n + 2 {
			return false
		}
		if buf[i + n] != `\r` || buf[i + n + 1] != `\n` {
			return error('bad chunk data')
		}
		if decode {
			unsafe { out.push_many(&buf[i], n) }
		}
		st.total += n
		st.pos = i + n + 2
	}
	// trailer-section: field lines until an empty line. Trailers are dropped.
	for {
		start := st.pos
		i := line_end(buf, start) or { return error('bad chunk trailer') }
		if i < 0 {
			if buf.len - start > max_chunk_trailer_bytes {
				return error('chunk trailers too large')
			}
			return false
		}
		st.pos = i
		if i == start + 2 {
			return true
		}
		st.trailer_bytes += i - start
		if st.trailer_bytes > max_chunk_trailer_bytes {
			return error('chunk trailers too large')
		}
		colon := index_byte(buf[start..i - 2], `:`) or { return error('bad chunk trailer') }
		if colon == 0 || !is_token(buf[start..start + colon]) {
			return error('bad chunk trailer')
		}
	}
	return false
}

// line_end returns the offset just past the CRLF that ends the line at from, -1
// when buf ends first, or an error for a bare CR/LF or other control byte.
fn line_end(buf []u8, from int) !int {
	mut i := from
	for i < buf.len {
		c := buf[i]
		if c == `\r` {
			if i + 1 >= buf.len {
				return -1
			}
			if buf[i + 1] != `\n` {
				return error('bare cr')
			}
			return i + 2
		}
		if (c < 0x20 && c != `\t`) || c == 0x7f {
			return error('control byte')
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
