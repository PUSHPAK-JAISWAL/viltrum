module engine

import time
import viltrum.router

#include <sys/epoll.h>
#include <sys/socket.h>
#include <netinet/tcp.h>
#include <errno.h>

fn C.epoll_create1(flags int) int
fn C.epoll_ctl(epfd int, op int, fd int, event &C.epoll_event) int
fn C.epoll_wait(epfd int, events &C.epoll_event, maxevents int, timeout_ms int) int
fn C.accept4(sockfd int, addr voidptr, addrlen voidptr, flags int) int

@[typedef]
union C.epoll_data_t {
mut:
	ptr voidptr
	fd  int
	u32 u32
	u64 u64
}

@[packed]
struct C.epoll_event {
mut:
	events u32
	data   C.epoll_data_t
}

const max_events = 512
const shrink_rbuf_above = 64 * 1024
const shrink_wbuf_above = 256 * 1024
const busy_msg = 'HTTP/1.1 503 Service Unavailable\r\nContent-Length: 19\r\nConnection: close\r\n\r\nservice unavailable'

struct Loop {
mut:
	w          &Worker
	epfd       int
	lfd        int
	conns      []&Conn // indexed by fd; a Conn outlives its connection and is reused
	opts       Options
	stop       &Stop
	count      &ConnCount
	now        i64 // ms (time.ticks)
	last_sweep i64
}

fn run_worker(index int, lfd int, r &router.Router, opts Options, mut stop Stop, mut count ConnCount) {
	mut l := Loop{
		w:     new_worker(r, opts, index)
		epfd:  C.epoll_create1(0)
		lfd:   lfd
		opts:  opts
		stop:  stop
		count: count
	}
	l.ctl(C.EPOLL_CTL_ADD, lfd, u32(C.EPOLLIN))
	mut events := [max_events]C.epoll_event{}
	for !stop.requested() {
		n := C.epoll_wait(l.epfd, &events[0], max_events, 1000)
		l.now = time.ticks()
		for i in 0 .. n {
			fd := unsafe { events[i].data.fd }
			if fd == lfd {
				l.accept_all()
			} else {
				l.on_event(fd, events[i].events)
			}
		}
		if l.now - l.last_sweep >= 1000 {
			l.sweep()
			l.last_sweep = l.now
		}
	}
	for i in 0 .. l.conns.len {
		if !isnil(l.conns[i]) && l.conns[i].fd >= 0 {
			mut c := l.conns[i]
			l.close(mut c)
		}
	}
	C.close(l.epfd)
}

fn (mut l Loop) ctl(op int, fd int, events u32) {
	mut ev := C.epoll_event{}
	ev.events = events
	ev.data.fd = fd
	C.epoll_ctl(l.epfd, op, fd, &ev)
}

fn (mut l Loop) accept_all() {
	for {
		fd := C.accept4(l.lfd, unsafe { nil }, unsafe { nil }, C.SOCK_NONBLOCK | C.SOCK_CLOEXEC)
		if fd < 0 {
			// EAGAIN, or an error the next readiness event retries
			return
		}
		mut counted := false
		if l.opts.max_conns > 0 {
			if !l.count.try_add(l.opts.max_conns) {
				C.send(fd, busy_msg.str, busy_msg.len, C.MSG_NOSIGNAL)
				C.close(fd)
				continue
			}
			counted = true
		}
		one := 1
		C.setsockopt(fd, C.IPPROTO_TCP, C.TCP_NODELAY, &one, sizeof(int))
		mut c := l.conn_for(fd)
		c.reset(fd)
		c.counted = counted
		c.deadline_ms = l.now + l.opts.idle_timeout.milliseconds()
		l.ctl(C.EPOLL_CTL_ADD, fd, u32(C.EPOLLIN | C.EPOLLRDHUP))
	}
}

fn (mut l Loop) conn_for(fd int) &Conn {
	for l.conns.len <= fd {
		l.conns << unsafe { &Conn(nil) } // cold: once per new highest fd
	}
	if isnil(l.conns[fd]) {
		l.conns[fd] = new_conn() // cold: once per fd number
	}
	return l.conns[fd]
}

fn (mut l Loop) on_event(fd int, ev u32) {
	if fd >= l.conns.len || isnil(l.conns[fd]) || l.conns[fd].fd != fd {
		return
	}
	mut c := l.conns[fd]
	if ev & u32(C.EPOLLERR | C.EPOLLHUP) != 0 {
		l.close(mut c)
		return
	}
	if c.out_armed {
		if ev & u32(C.EPOLLOUT) != 0 {
			l.flush(mut c)
			if c.fd >= 0 && !c.out_armed {
				l.drain(mut c)
			}
		}
		return
	}
	if ev & u32(C.EPOLLIN | C.EPOLLRDHUP) != 0 {
		l.on_readable(mut c)
	}
}

fn (mut l Loop) on_readable(mut c Conn) {
	max_total := l.opts.limits.max_header_bytes + l.opts.limits.max_body_bytes + 64 * 1024
	for {
		if c.rbuf.len == c.rbuf.cap {
			if c.rbuf.cap >= max_total {
				l.close(mut c)
				return
			}
			unsafe { c.rbuf.grow_cap(c.rbuf.cap) } // cold: a request larger than the buffer
		}
		spare := c.rbuf.cap - c.rbuf.len
		n := int(C.recv(c.fd, unsafe { &u8(c.rbuf.data) + c.rbuf.len }, spare, 0))
		if n == 0 {
			l.close(mut c)
			return
		}
		if n < 0 {
			if C.errno != C.EAGAIN && C.errno != C.EWOULDBLOCK {
				l.close(mut c)
			}
			return
		}
		unsafe {
			c.rbuf.len += n
		}
		was_reading := c.reading
		l.drain(mut c)
		if c.fd < 0 || c.out_armed {
			return
		}
		if c.reading && !was_reading {
			c.deadline_ms = l.now + l.opts.read_timeout.milliseconds()
		} else if !c.reading {
			c.deadline_ms = l.now + l.opts.idle_timeout.milliseconds()
		}
		if n < spare {
			// short read: the socket is drained, epoll reports more
			return
		}
	}
}

// drain serves buffered requests and flushes until nothing more can be done now.
fn (mut l Loop) drain(mut c Conn) {
	for {
		before := c.rbuf.len
		l.w.process(mut c)
		l.flush(mut c)
		if c.fd < 0 || c.out_armed || c.rbuf.len == before {
			return
		}
	}
}

fn (mut l Loop) flush(mut c Conn) {
	for c.woff < c.wbuf.len {
		n := int(C.send(c.fd, unsafe { &u8(c.wbuf.data) + c.woff }, c.wbuf.len - c.woff,
			C.MSG_NOSIGNAL))
		if n < 0 {
			if C.errno == C.EAGAIN || C.errno == C.EWOULDBLOCK {
				if !c.out_armed {
					l.ctl(C.EPOLL_CTL_MOD, c.fd, u32(C.EPOLLOUT))
					c.out_armed = true
				}
				c.deadline_ms = l.now + l.opts.write_timeout.milliseconds()
				return
			}
			l.close(mut c)
			return
		}
		c.woff += n
	}
	unsafe {
		c.wbuf.len = 0
	}
	c.woff = 0
	if c.close_after {
		l.close(mut c)
		return
	}
	if c.out_armed {
		l.ctl(C.EPOLL_CTL_MOD, c.fd, u32(C.EPOLLIN | C.EPOLLRDHUP))
		c.out_armed = false
		c.deadline_ms = l.now + if c.reading {
			l.opts.read_timeout.milliseconds()
		} else {
			l.opts.idle_timeout.milliseconds()
		}
	}
}

fn (mut l Loop) close(mut c Conn) {
	if c.fd < 0 {
		return
	}
	l.ctl(C.EPOLL_CTL_DEL, c.fd, 0)
	C.close(c.fd)
	if c.counted {
		l.count.release()
		c.counted = false
	}
	c.fd = -1
	if c.rbuf.cap > shrink_rbuf_above {
		c.rbuf = []u8{cap: read_buf_size} // cold: give back what one large request grew
	}
	if c.wbuf.cap > shrink_wbuf_above {
		c.wbuf = []u8{cap: write_buf_size} // cold
	}
}

fn (mut l Loop) sweep() {
	for i in 0 .. l.conns.len {
		if isnil(l.conns[i]) || l.conns[i].fd < 0 || l.now <= l.conns[i].deadline_ms {
			continue
		}
		mut c := l.conns[i]
		l.close(mut c)
	}
}
