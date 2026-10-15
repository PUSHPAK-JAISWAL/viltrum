module main

import viltrum

struct Echo {
	q      string
	worker int
}

fn main() {
	mut app := viltrum.new()
	app.use(viltrum.logger)
	app.use(viltrum.cors('*'))
	app.get('/', fn (mut c viltrum.Ctx) {
		c.text(200, 'try /search?q=caf%C3%A9, /api/ping, /big\n')
	})
	app.get('/search', fn (mut c viltrum.Ctx) {
		q := c.query_param('q') or { '' }
		c.json(200, Echo{
			q:      q
			worker: c.worker_id()
		})
	})
	mut api := app.group('/api')
	api.get('/ping', fn (mut c viltrum.Ctx) {
		c.text(200, 'pong')
	})
	app.get('/big', viltrum.gzip, fn (mut c viltrum.Ctx) {
		c.text(200, 'viltrum '.repeat(500))
	})
	app.listen('127.0.0.1:8082') or { panic(err) }
}
