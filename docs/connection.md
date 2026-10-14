# Connections

- One worker per CPU in the process affinity mask (`Options.workers` or `VILTRUM_WORKERS` override), each with
  its own `SO_REUSEPORT` listener and epoll loop.
- Each connection keeps an 8 KiB read and 16 KiB write buffer for its life; they grow only for larger messages
  and shrink back when the connection closes.
- Every complete request in a read is served, and the responses go out in one `send`. Processing pauses once
  `Options.max_pending` (1 MiB) of output waits; reading pauses while output is pending.
- Limits: `max_header_bytes` 64 KiB (431), `max_body_bytes` 1 MiB (413), 32 header fields (431),
  `max_conns` (503 and close).
- Timeouts: `read_timeout` 30 s from a request's first byte, `idle_timeout` 60 s between requests,
  `write_timeout` 30 s while output is pending.
- Framing and parse errors answer 4xx after any earlier pipelined responses, then close.
- SIGINT/SIGTERM stop accepting; open connections are closed within a second.
