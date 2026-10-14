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
	return unsafe {
		&Deflater{
			d:     C.tdefl_compressor_alloc()
			flags: int(C.tdefl_create_comp_flags_from_zip_params(gzip_level, -15, 0)) // -15: raw deflate
			out:   []u8{cap: 16 * 1024}
		}
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
	unsafe { C.tdefl_init(d.d, voidptr(deflate_put), voidptr(&d.out), d.flags) }
	st := unsafe { C.tdefl_compress_buffer(d.d, src.data, usize(src.len), C.TDEFL_FINISH) }
	if st != C.TDEFL_STATUS_DONE {
		return error('gzip: deflate failed') // cold
	}
	crc := unsafe { C.mz_crc32(0, src.data, usize(src.len)) }
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
