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
	} $else $if T.unaliased_typ is f32 {
		write_float(mut out, f64(val), true)
	} $else $if T.unaliased_typ is $float {
		write_float(mut out, f64(val), false)
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
			`"` {
				out << `"`
			}
			`\\` {
				out << `\\`
			}
			`\n` {
				out << `n`
			}
			`\r` {
				out << `r`
			}
			`\t` {
				out << `t`
			}
			0x08 {
				out << `b`
			}
			0x0c {
				out << `f`
			}
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

#include <stdlib.h>

fn C.strtod(&char, voidptr) f64

// write_float prints the shortest of %.15g, %.16g, %.17g that parses back to the same
// value (f32: %.6g to %.9g, compared as f32); NaN and infinities are null.
fn write_float(mut out []u8, f f64, is32 bool) {
	if math.is_nan(f) || math.is_inf(f, 0) {
		push(mut out, 'null')
		return
	}
	mut tmp := [32]u8{}
	lo := if is32 { 6 } else { 15 }
	hi := if is32 { 10 } else { 18 }
	unsafe {
		mut n := 0
		for prec in lo .. hi {
			n = C.snprintf(&char(&tmp[0]), 32, c'%.*g', prec, f)
			back := C.strtod(&char(&tmp[0]), nil)
			if (is32 && f32(back) == f32(f)) || back == f {
				break
			}
		}
		out.push_many(&tmp[0], n)
	}
}
