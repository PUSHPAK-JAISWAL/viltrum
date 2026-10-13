module router

// Method + path router: :param and *wildcard, trailing slashes normalized.

import viltrum.http

pub type HandlerFn = fn (req http.Request) http.Response

struct Route {
	method  string
	pattern string
	parts   []string
	// key is '/' + parts joined: the only path a route without :params or
	// *wildcard matches, compared as a string instead of splitting the path.
	key     string
	static  bool
	handler HandlerFn = unsafe { nil }
}

pub struct Router {
mut:
	routes []Route
}

pub fn Router.new() Router {
	return Router{}
}

pub fn (mut r Router) add(method string, pattern string, handler HandlerFn) {
	// keep *wildcards; only normalize slashes (do not strip *)
	norm := normalize_pattern(pattern)
	parts := split_pattern(norm)
	r.routes << Route{
		method:  method.to_upper()
		pattern: norm
		parts:   parts
		key:     '/' + parts.join('/')
		static:  !parts.any(it.starts_with(':') || it.starts_with('*'))
		handler: handler
	}
}

pub fn (mut r Router) get(pattern string, handler HandlerFn) {
	r.add('GET', pattern, handler)
}

pub fn (mut r Router) post(pattern string, handler HandlerFn) {
	r.add('POST', pattern, handler)
}

pub fn (mut r Router) put(pattern string, handler HandlerFn) {
	r.add('PUT', pattern, handler)
}

pub fn (mut r Router) delete(pattern string, handler HandlerFn) {
	r.add('DELETE', pattern, handler)
}

pub fn (mut r Router) patch(pattern string, handler HandlerFn) {
	r.add('PATCH', pattern, handler)
}

pub fn (mut r Router) options(pattern string, handler HandlerFn) {
	r.add('OPTIONS', pattern, handler)
}

pub fn (mut r Router) head(pattern string, handler HandlerFn) {
	r.add('HEAD', pattern, handler)
}

pub fn (r &Router) handle(req http.Request) http.Response {
	// OPTIONS * is not path-routed; apps handle via middleware (e.g. cors) or explicit route.
	path := if req.path == '*' { '*' } else { http.normalize_path(req.path) }
	mut m := Match{
		path: path
	}
	method := upper_ascii(req.method)

	// Prefer exact method match; HEAD may fall back to GET (RFC 9110).
	if resp := r.dispatch(method, mut m, req) {
		return resp
	}
	if method == 'HEAD' {
		if resp := r.dispatch('GET', mut m, req) {
			return resp
		}
	}

	// Distinguish 405 vs 404: path matched any method?
	for route in r.routes {
		if m.hits(route) {
			return http.Response.method_not_allowed()
		}
	}
	return http.Response.not_found()
}

// Match is the request path, split into segments only when a :param or
// *wildcard route (or an odd path like '/a//b') needs them.
struct Match {
	path string
mut:
	key   string
	parts []string
	split bool
}

fn (mut m Match) ensure_split() {
	if m.split {
		return
	}
	m.split = true
	m.parts = if m.path == '*' {
		['*']
	} else {
		m.path.trim_right('/').split('/').filter(it.len > 0)
	}
}

// path_key is the path in Route.key form. A normalized path that starts with
// '/' and has no empty segment already is one, so the common case allocates nothing.
fn (mut m Match) path_key() string {
	if m.path.len > 0 && m.path[0] == `/` && !m.path.contains('//') {
		return m.path
	}
	if m.key.len == 0 {
		m.ensure_split()
		m.key = '/' + m.parts.join('/')
	}
	return m.key
}

fn (mut m Match) hits(route Route) bool {
	if route.static {
		return m.path_key() == route.key
	}
	m.ensure_split()
	return match_ok(route.parts, m.parts)
}

fn (r &Router) dispatch(method string, mut m Match, req http.Request) ?http.Response {
	for route in r.routes {
		if route.method != method || !m.hits(route) {
			continue
		}
		enriched := http.Request{
			method:  req.method
			target:  req.target
			path:    m.path
			query:   req.query
			version: req.version
			headers: req.headers
			body:    req.body
			params:  if route.static { req.params } else { route_params(route.parts, m.parts) }
			ctx:     req.ctx
		}
		return route.handler(enriched)
	}
	return none
}

// upper_ascii returns s itself when it has no lowercase ASCII (the usual method token).
fn upper_ascii(s string) string {
	for c in s {
		if c >= `a` && c <= `z` {
			return s.to_upper()
		}
	}
	return s
}

fn normalize_pattern(pattern string) string {
	if pattern.len == 0 {
		return '/'
	}
	mut p := pattern
	if !p.starts_with('/') {
		p = '/' + p
	}
	// collapse trailing slash except root; keep /*name
	if p.len > 1 && p.ends_with('/') {
		p = p.trim_right('/')
	}
	return p
}

fn split_pattern(pattern string) []string {
	return pattern.trim_right('/').split('/').filter(it.len > 0)
}

// match_ok supports :id params and a trailing *rest wildcard (named, last segment only).
fn match_ok(pattern []string, path []string) bool {
	for i, p in pattern {
		if p.starts_with('*') {
			return i == pattern.len - 1 && p.len > 1
		}
		if i >= path.len {
			return false
		}
		if !p.starts_with(':') && p != path[i] {
			return false
		}
	}
	return pattern.len == path.len
}

// route_params extracts :id and *rest values for a pattern match_ok accepted.
fn route_params(pattern []string, path []string) map[string]string {
	mut params := map[string]string{}
	for i, p in pattern {
		if p.starts_with('*') {
			params[p[1..]] = if i < path.len { path[i..].join('/') } else { '' }
			break
		}
		if p.starts_with(':') {
			params[p[1..]] = path[i]
		}
	}
	return params
}
