# containerization: an image push holds each blob in memory

`ReadStream.stream` in [apple/containerization](https://github.com/apple/containerization) reads the full file into an `AsyncStream` buffer with no limit.
It does this before the consumer reads one byte.
`ImageStore.ExportOperation` pushes up to 8 blobs at the same time.
Thus `container image push` holds up to 8 full layers in memory.

In apple/container 1.3.1, `container-core-images` used 1.8 GB after 9 pushes.
The streams stay alive because of a separate async-http-client bug: [beshkenadze/async-http-client-early-response-leak](https://github.com/beshkenadze/async-http-client-early-response-leak).

Fix: branch [`fix/readstream-lazy-stream`](https://github.com/beshkenadze/containerization/tree/fix/readstream-lazy-stream) of beshkenadze/containerization.

## Run

```sh
./run.sh stall                                         # containerization 0.52.1
CONTAINERIZATION_VERSION=0.42.0 ./run.sh stall         # the version in container 1.3.1
CONTAINERIZATION_PATH=/path/to/containerization ./run.sh stall
```

The harness runs the real `ExportOperation` code. An in-process client replaces only the network.

| Scenario | The client… |
|---|---|
| `stall` | reads 1 chunk of each blob, then waits |
| `fail` | reads 1 chunk of each blob, then throws |
| `complete` | reads all data and checks size and sha256 |

## Result

8 layers of 64 MiB, peak `phys_footprint`. Raw data: [`results/`](results/).

| Scenario | 0.42.0, 0.52.1 | Fix |
|---|---|---|
| `stall` | 469–476 MiB | 13–17 MiB |
| `fail` | 382–422 MiB | 8.5–11.4 MiB |
| `complete` | 394–461 MiB | 38–46 MiB |

`main` (`0cb4d5b`), 3 runs: `stall` 472–478 MiB, `complete` 336–459 MiB. The fix on `0cb4d5b` (`e90f73e`): 11–19 MiB and 41–46 MiB ([`results/main-0cb4d5b-fix-e90f73e.jsonl`](results/main-0cb4d5b-fix-e90f73e.jsonl)).
All `complete` runs verified every blob.

`ahc-early-response/ReadStreamParkedFDProbe.swift` checks that `reset()` closes the file that a parked async-http-client request keeps open.
Output: [`evidence/parked-fd-probe-1.35.0.txt`](evidence/parked-fd-probe-1.35.0.txt).

