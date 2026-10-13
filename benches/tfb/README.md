# [viltrum](https://github.com/Tuntii/viltrum) Benchmarking Test

Viltrum is an HTTP framework for V with its own HTTP/1.1 engine. This test runs one process with
one epoll loop per CPU (`epoll_cores`, `SO_REUSEPORT`).

This folder is the TechEmpower entry, kept here so it is versioned with the framework. To submit or
update it, copy the folder to `frameworks/V/viltrum/` in
[FrameworkBenchmarks](https://github.com/TechEmpower/FrameworkBenchmarks) and run:

```bash
./tfb --mode verify --test viltrum
```

## Test URLs

### JSON

http://localhost:8080/json

### PLAINTEXT

http://localhost:8080/plaintext
