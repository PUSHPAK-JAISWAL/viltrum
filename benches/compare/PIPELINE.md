# Pipelined responses + serialize hot path (measured 2026-10-12)

TFB-shaped run: `GET /plaintext` with wrk + `pipeline.lua` depth 16, `GET /json` (V `json.encode` per request) without pipelining.
Server pinned to 4 cores (`taskset -c 0-3`), wrk to 2 (`-c 4-5`), 10 s per point, single run.

**Host:** VMware VM, Xeon E5-2690 v2 (2013), ~50% of CPU time in kernel under load. Syscalls are expensive here,
so absolute numbers are low and syscall savings are amplified. Read the ratios, not the totals.

## What changed

1. **Batch pipelined responses.** Spawn path: when the next request is already buffered, queue the response and
   write the batch once. Epoll path: serve every complete request from one read, then one `send`. Error responses
   queue behind earlier ones; upgrades flush first.
2. **Epoll bookkeeping.** No `epoll_ctl(MOD)` after every full write (only when EPOLLOUT was armed); `assem` compacted
   once per read, not per message; O(1) slot free list; no 8192 fd cap (it closed every conn past fd 8192).
3. **Serialize.** `append_str` is one `push_many` instead of a byte loop; `http_date` is built directly instead of
   `custom_format` (which re-parses its pattern on every response).

## Results (req/s)

Same session, old = v0.12.2:

| Point | old spawn | new spawn | old epoll_cores=4 | new epoll_cores=4 | Axum |
|-------|----------:|----------:|------------------:|------------------:|-----:|
| plaintext c=256 | 22.7k | 40.8k | 25.1k | 61.7k | 78.1k |
| plaintext c=1024 | 18.8k | 33.6k | 24.4k | 65.4k | 76.5k |
| plaintext c=4096 | 18.3k | 30.1k | 23.9k | 61.2k | 58.0k |
| plaintext c=16384 | 12.5k | 20.6k | 14.5k (8760 read errors) | 40.9k (0) | 29.0k |

The table above is (1)+(2) only. Adding (3), A/B in a second session:

| Point | spawn (1+2) | spawn (+3) | epoll (1+2) | epoll (+3) |
|-------|------------:|-----------:|------------:|-----------:|
| json c=64 | 14.0k | 15.9k | 18.2k | 19.3k |
| json c=256 | 12.1k | 14.2k | 17.6k | 19.0k |
| plaintext c=256 | 35.8k | 54.5k | 73.3k | 119.8k |
| plaintext c=1024 | 33.5k | 47.9k | 67.5k | 109.8k |

Axum on the same host: json c=64 19.5k, c=256 18.1k. Default I/O is unchanged (spawn); `epoll_cores` is still opt-in.

## c=16384 "timeouts" and veb (measured 2026-10-13)

Same host and pinning. veb is the TFB `frameworks/V/veb` app with the DB tests removed, run like its `run.sh`
(one pinned process per core, 4 here). veb from V 0.5.2 answers only the first request of a pipelined batch, so
the veb column uses V dev `c1bd176`, which is what TFB builds (`thevlang/vlang:debian-dev`).

| Point | viltrum epoll_cores=4 | veb (V dev) | Axum |
|-------|----------------------:|------------:|-----:|
| plaintext c=256 | 106.5k | 34.0k | 82.8k |
| plaintext c=1024 | 104.4k | 31.5k | 75.3k |
| plaintext c=4096 | 98.4k | 28.0k | 64.0k |
| plaintext c=16384 | 56.3k | 20.9k | 25.0k |
| plaintext c=16384, `--timeout 10s` | 54.4k, p99 3.20 s, 0 timeouts | 8.6k, p99 6.03 s | 27.1k, p99 6.81 s |
| json c=256 | 18.9k | 12.0k | 18.2k |

At c=16384 × depth 16 there are ~262k requests in flight. At ~55k req/s that is ~4.7 s of queueing per batch on
4 cores, so wrk's default 2 s timeout fires on the queue, not on dropped connections: with `--timeout 10s` the
timeouts are gone. The listen backlog is now 4096 (was 128; Tokio uses 1024). On this host that changed nothing
measurable for epoll. On spawn, one run went from 2073 timeouts to 124.

## Header field list + static routes (measured 2026-10-13)

1. `HeaderMap` is a field list, not a map (a V map is three allocations plus a hash per lookup).
2. Routes without `:param` / `*wildcard` compare the normalized path to a precomputed key; no split, no params map.
3. `normalize_path` / `split_target` no longer copy an unchanged origin-form target; the epoll loop skips the
   `recv` that would only return EAGAIN after a short read.

A/B against the previous commit, two alternating rounds, mean:

| Point | epoll before | epoll after | spawn before | spawn after |
|-------|-------------:|------------:|-------------:|------------:|
| plaintext c=256 | 111.6k | 146.0k | 54.5k | 64.1k |
| plaintext c=1024 | 104.8k | 137.8k | 46.0k | 61.7k |
| json c=64 | 18.9k | 20.4k | 15.2k | 16.3k |
| json c=256 | 18.7k | 20.0k | 14.0k | 14.8k |
| json c=1024 | 16.3k | 17.9k | 11.7k | 12.0k |

Then one three-way run (single run; Axum read ~10% lower here than in the run above):

| Point | viltrum epoll_cores=4 | veb (V dev) | Axum |
|-------|----------------------:|------------:|-----:|
| plaintext c=256 | 140.7k | 32.5k | 71.0k |
| plaintext c=1024 | 126.2k | 33.2k | 71.3k |
| plaintext c=4096 | 115.9k | 28.9k | 54.3k |
| plaintext c=16384 | 82.3k | 17.6k | 27.8k |
| json c=64 | 18.5k | 4.0k | 16.0k |
| json c=256 | 19.2k | 11.6k | 16.9k |

The JSON path is now ~70% kernel time on this host (loopback netfilter alone is ~5%), so further user-space
work has little left to win here.

Tests: `engine/pipeline_test.v` covers deep bursts, POST/GET mixes, a bad request mid-burst, and `Connection: close`
mid-burst on both I/O paths.
