module viltrum

// gzip members built on the miniz copy that ships with V (thirdparty/zip, also
// used by vlib/szip). miniz allocates with malloc, so a compressed response puts
// one copy on the GC heap instead of the many buffers of compress.gzip, whose
// fixed-Huffman deflate was also ~2x slower and ~25% larger on JSON.

#flag -I @VEXEROOT/thirdparty/zip
#define MINIZ_NO_ZLIB_COMPATIBLE_NAMES
#include "miniz.h"

fn C.tdefl_compress_mem_to_heap(src voidptr, n usize, out_len &usize, flags int) voidptr
fn C.tdefl_create_comp_flags_from_zip_params(level int, window_bits int, strategy int) u32
fn C.mz_crc32(crc u32, ptr &u8, len usize) u32

const gzip_level = 6 // zlib's default

fn gzip_bytes(data []u8) ![]u8 {
	flags := C.tdefl_create_comp_flags_from_zip_params(gzip_level, -15, 0) // -15: raw deflate
	mut n := usize(0)
	p := C.tdefl_compress_mem_to_heap(data.data, usize(data.len), &n, int(flags))
	if p == 0 {
		return error('gzip: deflate failed')
	}
	defer {
		unsafe { C.free(p) }
	}
	crc := C.mz_crc32(0, data.data, usize(data.len))
	size := u32(data.len)
	mut out := []u8{cap: 18 + int(n)}
	// RFC 1952 header: magic, CM=deflate, no flags, no mtime, XFL=0, OS=unknown
	out << u8(0x1f)
	out << 0x8b
	out << 8
	for _ in 0 .. 6 {
		out << 0
	}
	out << 0xff
	unsafe { out.push_many(p, int(n)) }
	// trailer: CRC-32 and input size, little-endian
	out << u8(crc)
	out << u8(crc >> 8)
	out << u8(crc >> 16)
	out << u8(crc >> 24)
	out << u8(size)
	out << u8(size >> 8)
	out << u8(size >> 16)
	out << u8(size >> 24)
	return out
}
