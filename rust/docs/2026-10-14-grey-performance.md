# Darker grey and performance measurements — October 14, 2026

The Dashboard ring and chart breaks, and the menu timeline breaks, now use neutral
white levels 0.62 in light mode (previously 0.76) and 0.48 in dark mode. A native month
render was inspected. Both signed apps were installed on the MacBook with pre-install
app/data backups at `~/Library/Application Support/Tempo-Recovery/20261014-192822-grey-update/`.

A matched, optimized rollup-only benchmark on the Mac mini used identical 4,097-event
fixtures and produced identical totals: 34,740 seconds and 15 stands. Swift median:
149.8 µs; Rust estimate: 10.96 µs. Rust was about 13.7× faster for this computation.
Reproduction: `tools/performance/README.md`. This does not compare Bluetooth latency or
end-to-end UI responsiveness.

Profiling the open Dashboard found repeated chart/layout work. Its poll still reads the
snapshot every two seconds for controls, but now avoids assigning unchanged snapshots,
only decodes history when the file modification time changes, and recomputes unchanged
charts at most every 30 seconds. File attributes use an uncached filesystem read. History
changes still trigger immediate recomputation on the next poll.

The open Dashboard showed about 11–12% CPU before this change. After installation, a
35-second CPU-time delta measured 1.31% for the Dashboard, 0.14% for the menu UI, and
0.17% for Rust. These are observations with an open window, not exhaustive benchmarks
across every chart range or user interaction.

The final sample's RSS was 30.6 MiB for the menu UI, 10.0 MiB for Rust, and 129.8 MiB for
the Dashboard. RSS varies with warm-up, compression, and shared pages; no controlled
comparison establishes an overall memory reduction. Running Rust as a separate service
adds its own process overhead.

The desk remained connected. All 1,476 recovered historical events were retained;
the current archive held 1,529 events. Verification JSON and an independent history copy
are on the Mac mini at `~/Library/Application Support/Tempo-Recovery/20261014-grey-update/`.
Both Xcode builds, strict recursive signing checks, rustfmt, Clippy with warnings denied,
and `git diff --check` passed.
