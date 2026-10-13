module http

const chunked_req = 'POST /c HTTP/1.1\r\nHost: x\r\ntransfer-encoding: Chunked\r\n\r\n' +
	'4;name=val\r\nWiki\r\n5 \r\npedia\r\nE\r\n in\r\n\r\nchunks.\r\n0\r\nX-Trailer: 1\r\n\r\n'

fn test_chunked_decodes_extensions_and_trailers() {
	req := parse_request(chunked_req.bytes()) or {
		assert false, err.msg()
		return
	}
	assert req.body.bytestr() == 'Wikipedia in\r\n\r\nchunks.'
}

// The engine frames with a resumable scan; feeding one byte at a time must end
// at the same offset as one pass over the whole message, and never earlier.
fn test_chunked_scan_resumes_byte_by_byte() {
	raw := (chunked_req + 'GET /next HTTP/1.1\r\n\r\n').bytes()
	body_start := chunked_req.index('\r\n\r\n') or { 0 } + 4
	mut sink := []u8{}
	mut whole := ChunkScan.new(body_start)
	assert scan_chunked(raw, mut whole, 1 << 20, false, mut sink)!
	assert whole.pos == chunked_req.len

	mut st := ChunkScan.new(body_start)
	for n in body_start .. raw.len + 1 {
		if scan_chunked(raw[..n], mut st, 1 << 20, false, mut sink)! {
			assert n == chunked_req.len
			assert st.pos == chunked_req.len
			return
		}
	}
	assert false, 'scan never completed'
}

fn test_chunked_body_limit() {
	raw :=
		'POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n10\r\n0123456789abcdef\r\n0\r\n\r\n'.bytes()
	body_start := raw.bytestr().index('\r\n\r\n') or { 0 } + 4
	mut st := ChunkScan.new(body_start)
	mut sink := []u8{}
	scan_chunked(raw, mut st, 15, false, mut sink) or {
		assert err.msg() == 'payload too large'
		return
	}
	assert false, 'expected payload too large'
}
