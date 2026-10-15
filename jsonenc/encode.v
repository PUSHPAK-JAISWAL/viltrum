module jsonenc

import math

// encode_into appends the JSON encoding of val to out without allocating and returns
// the number of bytes appended. It is generated per type at compile time, so there is
// no reflection at run time.
//
// V 0.5.2 -prod builds with Boehm pin every by-value struct or array of pointers in
// scope around each call statement: they walk all its pointers and, past 32, take
// the global GC lock. Encoding a 40-item page that way serialized every worker. So
// every call made while a struct or array is in scope is written as `_ = f()`, an
// assignment, which is not pinned. Keep it that way: scripts/gcpin_check.sh fails CI
// on a pin in the hot path.
pub fn encode_into[T](mut out []u8, val T) int {
	start := out.len
	_ = encode(mut out, val)
	return out.len - start
}

fn encode[T](mut out []u8, val T) bool {
	$if T.unaliased_typ is string {
		_ = write_string(mut out, string(val))
	} $else $if T.unaliased_typ is bool {
		if bool(val) {
			_ = push(mut out, 'true')
		} else {
			_ = push(mut out, 'false')
		}
	} $else $if T.unaliased_typ is u64 {
		_ = write_u64(mut out, u64(val))
	} $else $if T.unaliased_typ is $int {
		_ = write_i64(mut out, i64(val))
	} $else $if T.unaliased_typ is f32 {
		_ = write_float(mut out, f64(val), true)
	} $else $if T.unaliased_typ is $float {
		_ = write_float(mut out, f64(val), false)
	} $else $if T.unaliased_typ is $array {
		out << `[`
		for i, item in val {
			if i > 0 {
				out << `,`
			}
			_ = encode(mut out, item)
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
			_ = push(mut out, field.name)
			out << `"`
			out << `:`
			_ = encode(mut out, val.$(field.name))
		}
		out << `}`
	} $else {
		$compile_error('viltrum.jsonenc: unsupported type')
	}
	return true
}

@[inline]
fn push(mut out []u8, s string) bool {
	if s.len > 0 {
		unsafe { out.push_many(s.str, s.len) }
	}
	return true
}

const hex_digits = '0123456789abcdef'

// write_string escapes per RFC 8259: quote, backslash and control bytes. UTF-8
// passes through unchanged.
fn write_string(mut out []u8, s string) bool {
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
	return true
}

fn write_u64(mut out []u8, n u64) bool {
	if n == 0 {
		out << `0`
		return true
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
	return true
}

fn write_i64(mut out []u8, n i64) bool {
	if n < 0 {
		out << `-`
		return write_u64(mut out, u64(-(n + 1)) + 1)
	}
	return write_u64(mut out, u64(n))
}

#include <stdlib.h>

fn C.strtod(&char, voidptr) f64

// write_float prints the shortest of %.15g, %.16g, %.17g that parses back to the same
// value (f32: %.6g to %.9g, compared as f32); NaN and infinities are null.
fn write_float(mut out []u8, f f64, is32 bool) bool {
	if math.is_nan(f) || math.is_inf(f, 0) {
		return push(mut out, 'null')
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
	return true
}
