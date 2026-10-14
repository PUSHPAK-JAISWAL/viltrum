# Examples

Link the module first (from the repo root): `bash scripts/install.sh`.

| Example | Port | Shows |
|---------|------|-------|
| `hello` | 8080 | text responses, a `:param` |
| `rest` | 8081 | JSON in and out, shared state behind a mutex (handlers run on every worker thread) |
| `features` | 8082 | global middleware (logger, cors), groups, decoded query params, gzip, `worker_id` |

```bash
v run examples/features
curl -s 'http://127.0.0.1:8082/search?q=caf%C3%A9'
curl -s --compressed -H 'Accept-Encoding: gzip' http://127.0.0.1:8082/big | head -c 40
```

TLS, WebSocket, static files, uploads and the HTTP client are not in 1.0 yet; see the README.
