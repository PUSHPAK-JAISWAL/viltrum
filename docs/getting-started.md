# Getting started

1. Install V 0.5.2 and link the module: `bash scripts/install.sh`.
2. Run `v run examples/hello` and open http://127.0.0.1:8080/.
3. Copy `examples/features/main.v` as a starting point.

A handler is `fn (mut c viltrum.Ctx)`. Middleware has the same type and calls `c.next()` to continue.

```v
fn auth(mut c viltrum.Ctx) {
	if c.header('authorization') or { '' } == '' {
		c.text(401, 'unauthorized')
		return
	}
	c.next()
}
```

Register it globally (`app.use(auth)`), on a group (`app.group('/api', auth)`) or on one route
(`app.get('/me', auth, me)`).

Handlers run on several worker threads at once. Shared state needs a lock (see `examples/rest`), or one copy per
worker indexed by `c.worker_id()` (size it with `app.worker_count()`).
