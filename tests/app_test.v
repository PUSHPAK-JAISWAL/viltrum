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
