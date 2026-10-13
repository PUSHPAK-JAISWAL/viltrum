module main

import compress.gzip
import viltrum
import viltrum.http

const gzip_json = '{"items":[' + '{"name":"alpha","price":12},'.repeat(40) + '{}]}'

fn gzip_req(accept_encoding string) viltrum.Request {
	mut h := http.HeaderMap.new()
	if accept_encoding.len > 0 {
		h.set('Accept-Encoding', accept_encoding)
	}
	return viltrum.Request{
		method:  'GET'
		path:    '/'
		headers: h
	}
}

fn gzip_handler(body string, content_type string) viltrum.Handler {
	return viltrum.gzip(fn [body, content_type] (_ viltrum.Request) viltrum.Response {
		mut r := viltrum.json(200, body)
		r.headers.set('Content-Type', content_type)
		return r
	})
}

fn test_gzip_compresses_when_accepted() {
	resp := gzip_handler(gzip_json, 'application/json')(gzip_req('gzip, br'))
	assert resp.headers.get('content-encoding')? == 'gzip'
	assert resp.headers.get('content-length')? == '${resp.body.len}'
	assert resp.headers.get('vary')? == 'Accept-Encoding'
	assert gzip.decompress(resp.body)!.bytestr() == gzip_json
}

fn test_gzip_passes_through() {
	cases := {
		'':                  gzip_json // no Accept-Encoding
		'br':                gzip_json // gzip not offered
		'gzip;q=0':          gzip_json // refused explicitly
		'*;q=0.5, gzip;q=0': gzip_json // explicit gzip wins over *
		'gzip; q=0.000, *':  gzip_json
		'gzip short body':   '{"a":1}'
	}
	for ae, body in cases {
		accept := if ae == 'gzip short body' { 'gzip' } else { ae }
		resp := gzip_handler(body, 'application/json')(gzip_req(accept))
		assert resp.headers.get_or('content-encoding', '') == '', ae
		assert resp.body.bytestr() == body, ae
	}
	img := gzip_handler(gzip_json, 'image/png')(gzip_req('gzip'))
	assert img.headers.get_or('content-encoding', '') == ''
	star := gzip_handler(gzip_json, 'text/plain; charset=utf-8')(gzip_req('*'))
	assert star.headers.get('content-encoding')? == 'gzip'
}
