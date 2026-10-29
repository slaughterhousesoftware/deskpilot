# Swift/Rust rollup comparison

Use the same Mac and run these sequentially, without simultaneous builds. Both fixtures
use the identical 8 KiB ring, timestamp 1,800,000,000, 70,000 boot minutes, 600-minute day,
20/20-minute cruise, threshold 34, and one synthetic move. They produce 4,097 merged
entries, 34,740 at-desk seconds, and 15 stands. Only the already-dated daily rollup is timed.

```sh
swiftc -O Sources/DeskpilotKit/Registers.swift Sources/DeskpilotKit/HistoryDecoder.swift \
  Sources/DeskpilotKit/DayRollup.swift Sources/DeskpilotKit/CruiseSlot.swift \
  tools/performance/main.swift -o /tmp/tempo-swift-perf
/tmp/tempo-swift-perf
cd rust
cargo bench -p tempo-core --bench hot_path -- rollup_only_4096 \
  --warm-up-time 1 --measurement-time 2 --sample-size 20
```

October 14, 2026, Mac mini: Swift's five warmed batches measured 148.6–152.9 µs
(median 149.8 µs); Rust's estimate was 10.96 µs, interval 10.82–11.11 µs.
This fixture's Rust rollup is about 13.7× faster. It does not measure Bluetooth latency,
file I/O, rendering, or overall application responsiveness/memory.
