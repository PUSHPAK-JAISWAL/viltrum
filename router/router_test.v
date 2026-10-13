module router

import viltrum.http

fn test_wildcard_and_param() {
	mut r := Router.new()
	mut hit := ''
	r.get('/files/*path', fn [hit] (req http.Request) http.Response {
		// capture via headers hack - just return path param in body
		p := req.param('path') or { '' }
		return http.Response.text(200, p)
	})
	// rebuild with mutable approach
	r = Router.new()
	r.get('/files/*path', fn (req http.Request) http.Response {
		p := req.param('path') or { '' }
		return http.Response.text(200, p)
	})
	r.get('/u/:id', fn (req http.Request) http.Response {
		return http.Response.text(200, req.param('id') or { '' })
	})
	req := http.parse_request('GET /files/a/b/c HTTP/1.1\r\nHost: x\r\n\r\n'.bytes()) or {
		assert false
		return
	}
	resp := r.handle(req)
	assert resp.body.bytestr() == 'a/b/c'
	req2 := http.parse_request('GET /u/9 HTTP/1.1\r\nHost: x\r\n\r\n'.bytes()) or {
		assert false
		return
	}
	assert r.handle(req2).body.bytestr() == '9'
}

fn test_head_falls_back_to_get() {
	mut r := Router.new()
	r.get('/hi', fn (req http.Request) http.Response {
		return http.Response.text(200, 'hello')
	})
	req := http.parse_request('HEAD /hi HTTP/1.1\r\nHost: x\r\n\r\n'.bytes()) or {
		assert false, err.msg()
		return
	}
	resp := r.handle(req)
	assert resp.status == 200
	assert resp.body.bytestr() == 'hello' // handler may set body; engine strips on wire
	assert resp.headers.get('content-length')? == '5'
}

fn test_patch_route() {
	mut r := Router.new()
	r.patch('/x', fn (req http.Request) http.Response {
		return http.Response.text(200, 'patched')
	})
	req := http.parse_request('PATCH /x HTTP/1.1\r\nHost: x\r\n\r\n'.bytes()) or {
		assert false, err.msg()
		return
	}
	assert r.handle(req).body.bytestr() == 'patched'
}

// old_match is the pre-fast-path matcher: split both sides, build params.
fn old_match(pattern []string, path []string) (map[string]string, bool) {
	mut params := map[string]string{}
	mut i := 0
	for pi, p in pattern {
		if p.starts_with('*') {
			if pi != pattern.len - 1 || p.len == 1 {
				return map[string]string{}, false
			}
			params[p[1..]] = if i < path.len { path[i..].join('/') } else { '' }
			return params, true
		}
		if i >= path.len {
			return map[string]string{}, false
		}
		if p.starts_with(':') {
			params[p[1..]] = path[i]
		} else if p != path[i] {
			return map[string]string{}, false
		}
		i++
	}
	return params, i == path.len
}

fn params_str(m map[string]string) string {
	mut keys := m.keys()
	keys.sort()
	return keys.map('${it}=${m[it]}').join('&')
}

fn test_static_fast_path_matches_split_matcher() {
	patterns := ['/', '/a', 'a', '/a/', '/a/b', '/a//b', '/:id', '/a/:id', '/a/*rest', '/*', '/*all',
		'/a/*rest/b']
	paths := ['/', '', '*', '/a', '/a/', '/a//', '//a', '/a/b', '/a//b', '/a/b/', '/a/b/c', 'a',
		'a/b', '/b', '/A']
	for pat in patterns {
		mut r := Router.new()
		r.get(pat, fn (req http.Request) http.Response {
			return http.Response.text(200, params_str(req.params))
		})
		pparts := split_pattern(normalize_pattern(pat))
		for p in paths {
			req := http.Request{
				method:  'get'
				path:    p
				headers: http.HeaderMap.new()
			}
			norm := if p == '*' { '*' } else { http.normalize_path(p) }
			path_parts := if norm == '*' {
				['*']
			} else {
				norm.trim_right('/').split('/').filter(it.len > 0)
			}
			want, ok := old_match(pparts, path_parts)
			resp := r.handle(req)
			if ok {
				assert resp.status == 200, '${pat} ${p}'
				assert resp.body.bytestr() == params_str(want), '${pat} ${p}'
			} else {
				assert resp.status == 404, '${pat} ${p}'
			}
		}
	}
}

fn test_405_when_path_matches_other_method() {
	mut r := Router.new()
	r.post('/x', fn (req http.Request) http.Response {
		return http.Response.text(200, 'p')
	})
	req := http.parse_request('GET /x HTTP/1.1\r\nHost: x\r\n\r\n'.bytes()) or {
		assert false, err.msg()
		return
	}
	assert r.handle(req).status == 405
}
