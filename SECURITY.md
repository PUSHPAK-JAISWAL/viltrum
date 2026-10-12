# Security

Viltrum parses untrusted bytes off the wire, so parser, framing, and WebSocket bugs are security bugs.

## Reporting

Please **do not** open a public issue. Use GitHub's private report:
[Report a vulnerability](https://github.com/Tuntii/viltrum/security/advisories/new).

Include a raw request (or byte dump) that reproduces it and the Viltrum version / commit.
Expect a first reply within a few days. Fixes ship as a patch release with credit unless you ask otherwise.

## In scope

- Request smuggling / framing disagreements (Content-Length, Transfer-Encoding, header parsing)
- Crashes or panics reachable from a remote peer (HTTP, multipart, WebSocket frames)
- Limit bypasses (`max_body_bytes`, header size, timeouts, `max_conns`)
- TLS / WSS handling in `listen_tls`

## Supported versions

Only the latest release line gets fixes.
