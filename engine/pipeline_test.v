module engine

// HTTP/1.1 pipelining stress tests (read-path correctness).
// Product claim remains: pipelining-tolerant leftover handling, not full
// "we support pipelining as a feature" marketing. See docs/connection.md.

import net
import time
import viltrum.http

fn pipeline_free_addr() string {
	mut l := net.listen_tcp(.ip, '127.0.0.1:0') or { panic('pipeline_free_addr listen: ${err}') }
	a := l.addr() or {
		l.close() or {}
		panic('pipeline_free_addr addr: ${err}')
	}
	s := a.str()
	l.close() or {}
	return s
}

fn pipeline_wait() {
	time.sleep(100 * time.millisecond)
}

// pipe_reader accumulates socket bytes and peels complete HTTP responses.
// Needed because one TCP read can contain multiple pipelined responses.
struct PipeReader {
mut:
	buf []u8
}

fn (mut r PipeReader) pull(mut conn net.TcpConn) ! {
	mut tmp := []u8{len: 4096}
	n := conn.read(mut tmp) or { return err }
	if n <= 0 {
		return error('eof')
	}
	r.buf << tmp[..n]
}

fn (mut r PipeReader) next_response(mut conn net.TcpConn) !(int, string) {
	for {
		sep := index_of_double_crlf(r.buf) or {
			r.pull(mut conn)!
			if r.buf.len > 256 * 1024 {
				return error('headers too large')
			}
			continue
		}
		hdr_end := sep + 4
		hdr := r.buf[..hdr_end]
		cl := content_length_from_headers(hdr) or { 0 }
		need := hdr_end + cl
		if r.buf.len < need {
			r.pull(mut conn)!
			continue
		}
		// status line
		status := parse_status_code(hdr.bytestr()) or { 0 }
		body := r.buf[hdr_end..need].bytestr()
		// advance leftover
		if need < r.buf.len {
			r.buf = r.buf[need..].clone()
		} else {
			r.buf = []u8{}
		}
		return status, body
	}
	return error('unreachable')
}

fn parse_status_code(hdr string) ?int {
	// HTTP/1.1 200 OK\r\n...
	line_end := hdr.index('\r\n') or { return none }
	line := hdr[..line_end]
	parts := line.split(' ')
	if parts.len < 2 {
		return none
	}
	return parts[1].int()
}

fn start_pipeline_echo_server(addr string) {
	opts := ServerOptions{
		handle_signals: false
		idle_timeout:   5 * time.second
		read_timeout:   5 * time.second
		write_timeout:  5 * time.second
	}
	spawn fn [opts, addr] () {
		listen_and_serve_full(addr, fn (req http.Request) http.Response {
			if req.method == 'POST' {
				return http.Response.text(200, 'echo:${req.text()}')
			}
			// GET /n/:id or /ping
			id := req.path
			return http.Response.text(200, 'ok:${id}')
		}, [], opts) or {}
	}()
	pipeline_wait()
}

// Two GETs in one write → two correct responses, order preserved.
fn test_pipeline_two_gets_one_write() {
	addr := pipeline_free_addr()
	start_pipeline_echo_server(addr)

	mut client := net.dial_tcp(addr) or {
		assert false, 'dial: ${err}'
		return
	}
	defer {
		client.close() or {}
	}
	client.set_read_timeout(3 * time.second)
	client.set_write_timeout(3 * time.second)

	burst := 'GET /a HTTP/1.1\r\nHost: localhost\r\n\r\nGET /b HTTP/1.1\r\nHost: localhost\r\n\r\n'
	client.write(burst.bytes()) or {
		assert false, 'write: ${err}'
		return
	}

	mut pr := PipeReader{}
	st1, body1 := pr.next_response(mut client) or {
		assert false, 'resp1: ${err}'
		return
	}
	st2, body2 := pr.next_response(mut client) or {
		assert false, 'resp2: ${err}'
		return
	}
	assert st1 == 200
	assert st2 == 200
	assert body1 == 'ok:/a'
	assert body2 == 'ok:/b'
}

// POST with body pipelined with a following GET — leftover after Content-Length.
fn test_pipeline_post_then_get() {
	addr := pipeline_free_addr()
	start_pipeline_echo_server(addr)

	mut client := net.dial_tcp(addr) or {
		assert false, 'dial: ${err}'
		return
	}
	defer {
		client.close() or {}
	}
	client.set_read_timeout(3 * time.second)
	client.set_write_timeout(3 * time.second)

	burst := 'POST /echo HTTP/1.1\r\nHost: localhost\r\nContent-Length: 5\r\n\r\nhelloGET /after HTTP/1.1\r\nHost: localhost\r\n\r\n'
	client.write(burst.bytes()) or {
		assert false, 'write: ${err}'
		return
	}

	mut pr := PipeReader{}
	st1, body1 := pr.next_response(mut client) or {
		assert false, 'post resp: ${err}'
		return
	}
	st2, body2 := pr.next_response(mut client) or {
		assert false, 'get resp: ${err}'
		return
	}
	assert st1 == 200
	assert body1 == 'echo:hello'
	assert st2 == 200
	assert body2 == 'ok:/after'
}

// Stress: many pipelined GETs on one connection in a single write.
fn test_pipeline_stress_many_gets() {
	addr := pipeline_free_addr()
	start_pipeline_echo_server(addr)

	mut client := net.dial_tcp(addr) or {
		assert false, 'dial: ${err}'
		return
	}
	defer {
		client.close() or {}
	}
	client.set_read_timeout(10 * time.second)
	client.set_write_timeout(10 * time.second)

	n := 64
	mut burst := ''
	for i in 0 .. n {
		burst += 'GET /n/${i} HTTP/1.1\r\nHost: localhost\r\n\r\n'
	}
	client.write(burst.bytes()) or {
		assert false, 'write burst: ${err}'
		return
	}

	mut pr := PipeReader{}
	for i in 0 .. n {
		st, body := pr.next_response(mut client) or {
			assert false, 'resp ${i}: ${err}'
			return
		}
		assert st == 200, 'status at ${i}: ${st}'
		assert body == 'ok:/n/${i}', 'body at ${i}: ${body}'
	}
}

// Stress: alternating POST/GET pairs in one burst (body leftover correctness).
fn test_pipeline_stress_post_get_pairs() {
	addr := pipeline_free_addr()
	start_pipeline_echo_server(addr)

	mut client := net.dial_tcp(addr) or {
		assert false, 'dial: ${err}'
		return
	}
	defer {
		client.close() or {}
	}
	client.set_read_timeout(10 * time.second)
	client.set_write_timeout(10 * time.second)

	pairs := 32
	mut burst := ''
	for i in 0 .. pairs {
		payload := 'p${i}'
		burst += 'POST /e HTTP/1.1\r\nHost: localhost\r\nContent-Length: ${payload.len}\r\n\r\n${payload}'
		burst += 'GET /g/${i} HTTP/1.1\r\nHost: localhost\r\n\r\n'
	}
	client.write(burst.bytes()) or {
		assert false, 'write: ${err}'
		return
	}

	mut pr := PipeReader{}
	for i in 0 .. pairs {
		st_p, body_p := pr.next_response(mut client) or {
			assert false, 'post ${i}: ${err}'
			return
		}
		assert st_p == 200
		assert body_p == 'echo:p${i}', 'post body ${i}: ${body_p}'

		st_g, body_g := pr.next_response(mut client) or {
			assert false, 'get ${i}: ${err}'
			return
		}
		assert st_g == 200
		assert body_g == 'ok:/g/${i}', 'get body ${i}: ${body_g}'
	}
}

// Two concurrent clients each pipelining — isolation across connections.
fn test_pipeline_concurrent_clients() {
	addr := pipeline_free_addr()
	start_pipeline_echo_server(addr)

	n_clients := 4
	per_client := 16
	mut threads := []thread{}
	for c in 0 .. n_clients {
		threads << spawn fn [addr, c, per_client] () {
			mut client := net.dial_tcp(addr) or {
				assert false, 'dial ${c}: ${err}'
				return
			}
			defer {
				client.close() or {}
			}
			client.set_read_timeout(10 * time.second)
			client.set_write_timeout(10 * time.second)
			mut burst := ''
			for i in 0 .. per_client {
				burst += 'GET /c/${c}/${i} HTTP/1.1\r\nHost: localhost\r\n\r\n'
			}
			client.write(burst.bytes()) or {
				assert false, 'write ${c}: ${err}'
				return
			}
			mut pr := PipeReader{}
			for i in 0 .. per_client {
				st, body := pr.next_response(mut client) or {
					assert false, 'client ${c} resp ${i}: ${err}'
					return
				}
				assert st == 200
				assert body == 'ok:/c/${c}/${i}'
			}
		}()
	}
	for t in threads {
		t.wait()
	}
}

// Last request asks for close; still get all prior pipelined responses first.
fn test_pipeline_then_connection_close() {
	addr := pipeline_free_addr()
	start_pipeline_echo_server(addr)

	mut client := net.dial_tcp(addr) or {
		assert false, 'dial: ${err}'
		return
	}
	defer {
		client.close() or {}
	}
	client.set_read_timeout(3 * time.second)
	client.set_write_timeout(3 * time.second)

	burst := 'GET /1 HTTP/1.1\r\nHost: localhost\r\n\r\nGET /2 HTTP/1.1\r\nHost: localhost\r\n\r\nGET /last HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n'
	client.write(burst.bytes()) or {
		assert false, 'write: ${err}'
		return
	}

	mut pr := PipeReader{}
	_, b1 := pr.next_response(mut client) or {
		assert false, '1: ${err}'
		return
	}
	_, b2 := pr.next_response(mut client) or {
		assert false, '2: ${err}'
		return
	}
	_, b3 := pr.next_response(mut client) or {
		assert false, '3: ${err}'
		return
	}
	assert b1 == 'ok:/1'
	assert b2 == 'ok:/2'
	assert b3 == 'ok:/last'
}

fn start_pipeline_server_mode(addr string, epoll bool) {
	opts := ServerOptions{
		handle_signals: false
		idle_timeout:   5 * time.second
		read_timeout:   5 * time.second
		write_timeout:  5 * time.second
		epoll_cores:    if epoll { 1 } else { 0 }
	}
	spawn fn [opts, addr] () {
		listen_and_serve_full(addr, fn (req http.Request) http.Response {
			if req.method == 'POST' {
				return http.Response.text(200, 'echo:${req.text()}')
			}
			return http.Response.text(200, 'ok:${req.path}')
		}, [], opts) or {}
	}()
	pipeline_wait()
}

fn pipeline_dial(addr string) !&net.TcpConn {
	mut client := net.dial_tcp(addr)!
	client.set_read_timeout(5 * time.second)
	client.set_write_timeout(5 * time.second)
	return client
}

// Responses are batched per read; every queued response must still go out, in
// order, before the 400 for a bad request later in the same burst. Both I/O paths.
fn test_pipeline_bad_request_mid_burst_flushes_prior_responses() {
	for epoll in [false, true] {
		addr := pipeline_free_addr()
		start_pipeline_server_mode(addr, epoll)
		mut client := pipeline_dial(addr) or {
			assert false, 'dial: ${err}'
			return
		}
		burst := 'GET /1 HTTP/1.1\r\nHost: x\r\n\r\nGET /2 HTTP/1.1\r\nHost: x\r\n\r\nGET /3 HTTP/1.1\r\nHost : x\r\n\r\nGET /never HTTP/1.1\r\nHost: x\r\n\r\n'
		client.write(burst.bytes()) or { assert false, 'write: ${err}' }
		mut pr := PipeReader{}
		for want in ['ok:/1', 'ok:/2'] {
			st, body := pr.next_response(mut client) or {
				assert false, 'epoll=${epoll} ${want}: ${err}'
				return
			}
			assert st == 200 && body == want, 'epoll=${epoll}: ${st} ${body}'
		}
		st, _ := pr.next_response(mut client) or {
			assert false, 'epoll=${epoll} 400: ${err}'
			return
		}
		assert st == 400, 'epoll=${epoll}'
		// connection closes after the 400; /never is not served
		if _, body := pr.next_response(mut client) {
			assert false, 'epoll=${epoll} served after 400: ${body}'
		}
		client.close() or {}
	}
}

// Deep bursts (TFB plaintext uses depth 16) and POST/GET mixes on both I/O paths,
// including a burst larger than one read chunk.
fn test_pipeline_deep_bursts_both_paths() {
	for epoll in [false, true] {
		addr := pipeline_free_addr()
		start_pipeline_server_mode(addr, epoll)
		mut client := pipeline_dial(addr) or {
			assert false, 'dial: ${err}'
			return
		}
		mut pr := PipeReader{}
		for round in 0 .. 3 {
			n := [16, 300, 16][round]
			mut burst := ''
			for i in 0 .. n {
				if i % 3 == 0 {
					p := 'p${i}'
					burst += 'POST /e HTTP/1.1\r\nHost: x\r\nContent-Length: ${p.len}\r\n\r\n${p}'
				} else {
					burst += 'GET /r${round}/${i} HTTP/1.1\r\nHost: x\r\n\r\n'
				}
			}
			client.write(burst.bytes()) or { assert false, 'write: ${err}' }
			for i in 0 .. n {
				want := if i % 3 == 0 { 'echo:p${i}' } else { 'ok:/r${round}/${i}' }
				st, body := pr.next_response(mut client) or {
					assert false, 'epoll=${epoll} round=${round} i=${i}: ${err}'
					return
				}
				assert st == 200 && body == want, 'epoll=${epoll} round=${round} i=${i}: ${body}'
			}
		}
		client.close() or {}
	}
}

// Connection: close in the middle of a burst on the epoll path: earlier responses,
// then the close response, then EOF (later requests dropped).
fn test_pipeline_close_mid_burst_epoll() {
	addr := pipeline_free_addr()
	start_pipeline_server_mode(addr, true)
	mut client := pipeline_dial(addr) or {
		assert false, 'dial: ${err}'
		return
	}
	burst := 'GET /1 HTTP/1.1\r\nHost: x\r\n\r\nGET /2 HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\nGET /3 HTTP/1.1\r\nHost: x\r\n\r\n'
	client.write(burst.bytes()) or { assert false, 'write: ${err}' }
	mut pr := PipeReader{}
	for want in ['ok:/1', 'ok:/2'] {
		_, body := pr.next_response(mut client) or {
			assert false, '${want}: ${err}'
			return
		}
		assert body == want
	}
	if _, body := pr.next_response(mut client) {
		assert false, 'served after close: ${body}'
	}
	client.close() or {}
}

// Chunked request bodies on both I/O paths: pipelined between other requests,
// trickled one byte per write, and the framing errors that must close.
fn test_chunked_bodies_both_paths() {
	chunked := 'POST /c HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n4;e=1\r\nWiki\r\n5\r\npedia\r\n0\r\nX-T: 1\r\n\r\n'
	for epoll in [false, true] {
		addr := pipeline_free_addr()
		start_pipeline_server_mode(addr, epoll)
		mut client := pipeline_dial(addr) or {
			assert false, 'dial: ${err}'
			return
		}
		mut pr := PipeReader{}
		burst := chunked + 'GET /mid HTTP/1.1\r\nHost: x\r\n\r\n' + chunked
		client.write(burst.bytes()) or { assert false, 'write: ${err}' }
		for want in ['echo:Wikipedia', 'ok:/mid', 'echo:Wikipedia'] {
			st, body := pr.next_response(mut client) or {
				assert false, 'epoll=${epoll} ${want}: ${err}'
				return
			}
			assert st == 200 && body == want, 'epoll=${epoll}: ${st} ${body}'
		}
		for b in chunked.bytes() {
			client.write([b]) or { assert false, 'trickle: ${err}' }
			time.sleep(time.millisecond)
		}
		st, body := pr.next_response(mut client) or {
			assert false, 'epoll=${epoll} trickle: ${err}'
			return
		}
		assert st == 200 && body == 'echo:Wikipedia', 'epoll=${epoll} trickle: ${body}'
		client.close() or {}

		bad := {
			'POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\nContent-Length: 3\r\n\r\n0\r\n\r\n': 400
			'POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: gzip\r\n\r\n0\r\n\r\n':                         400
			'POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\nzz\r\n':                         400
		}
		for raw, want in bad {
			mut c2 := pipeline_dial(addr) or {
				assert false, 'dial: ${err}'
				return
			}
			c2.write((raw + 'GET /never HTTP/1.1\r\nHost: x\r\n\r\n').bytes()) or {}
			mut pr2 := PipeReader{}
			st2, _ := pr2.next_response(mut c2) or {
				assert false, 'epoll=${epoll} bad: ${err}'
				return
			}
			assert st2 == want, 'epoll=${epoll} ${raw}: ${st2}'
			if _, b2 := pr2.next_response(mut c2) {
				assert false, 'epoll=${epoll} served after framing error: ${b2}'
			}
			c2.close() or {}
		}
	}
}
