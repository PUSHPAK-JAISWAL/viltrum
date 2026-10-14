module http1

import time

fn C.time(t voidptr) i64

const day_names = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun']
const month_names = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov',
	'Dec']

// DateCache holds the IMF-fixdate for the current second. A worker owns one, so
// the header is formatted at most once per second per worker.
pub struct DateCache {
mut:
	sec  i64 = -1
	text [29]u8
}

// write appends `Date: <IMF-fixdate>\r\n`.
pub fn (mut d DateCache) write(mut out []u8) {
	now := C.time(unsafe { nil })
	if now != d.sec {
		d.sec = now
		d.format(time.unix(now))
	}
	append_str(mut out, 'Date: ')
	unsafe { out.push_many(&d.text[0], 29) }
	append_str(mut out, crlf)
}

// format writes "Sun, 06 Nov 1994 08:49:37 GMT" into text.
fn (mut d DateCache) format(t time.Time) {
	mut i := d.put_str(0, day_names[t.day_of_week() - 1])
	i = d.put_str(i, ', ')
	i = d.put2(i, t.day)
	d.text[i] = ` `
	i = d.put_str(i + 1, month_names[t.month - 1])
	d.text[i] = ` `
	i = d.put2(i + 1, t.year / 100)
	i = d.put2(i, t.year % 100)
	d.text[i] = ` `
	i = d.put2(i + 1, t.hour)
	d.text[i] = `:`
	i = d.put2(i + 1, t.minute)
	d.text[i] = `:`
	i = d.put2(i + 1, t.second)
	d.put_str(i, ' GMT')
}

fn (mut d DateCache) put_str(i int, s string) int {
	for k in 0 .. s.len {
		d.text[i + k] = s[k]
	}
	return i + s.len
}

fn (mut d DateCache) put2(i int, n int) int {
	d.text[i] = u8(`0` + n / 10)
	d.text[i + 1] = u8(`0` + n % 10)
	return i + 2
}
