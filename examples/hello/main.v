module main

import viltrum

fn main() {
	mut app := viltrum.new()
	app.get('/', fn (mut c viltrum.Ctx) {
		c.text(200, 'Hello from viltrum\n')
	})
	app.get('/hi/:name', fn (mut c viltrum.Ctx) {
		c.text(200, c.param('name') or { 'world' })
	})
	app.listen('127.0.0.1:8080') or { panic(err) }
}
