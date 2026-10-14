module http1

// test_ctx parses raw (one complete request) into a fresh Ctx whose response goes to
// c.out, with Date off. Meant for unit tests of handlers and middleware.
pub fn test_ctx(raw string) !Ctx {
	buf := raw.bytes()
	mut f := Frame{}
	n := frame(buf, mut f, Limits{})!
	if n < 0 {
		return error('test_ctx: incomplete request')
	}
	mut c := Ctx.new()
	c.send_date = false
	c.out = []u8{cap: 4096}
	parse_head(buf, f.head_end, mut c.head)!
	c.begin(view(buf, 0, n))
	if f.chunked {
		c.set_chunked_body(f.head_end)
	} else {
		c.set_body(view(buf, f.head_end, f.content_length))
	}
	return c
}
