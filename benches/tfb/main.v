module main

import json
import runtime
import viltrum

struct Message {
	message string
}

fn main() {
	mut app := viltrum.new()
	app.server_options(viltrum.ServerOptions{
		handle_signals: false
		send_date:      true
		server_header:  'viltrum'
		epoll_cores:    runtime.nr_cpus()
	})
	app.get('/plaintext', fn (_ viltrum.Request) viltrum.Response {
		return viltrum.text(200, 'Hello, World!')
	})
	app.get('/json', fn (_ viltrum.Request) viltrum.Response {
		return viltrum.json(200, json.encode(Message{ message: 'Hello, World!' }))
	})
	app.listen('0.0.0.0:8080') or { panic(err) }
}
