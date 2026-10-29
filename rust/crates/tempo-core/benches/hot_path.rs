//! The per-poll hot path on a full 8 KiB ring: decode, date, merge, roll up.

use criterion::{black_box, criterion_group, criterion_main, Criterion};
use jiff::Timestamp;
use tempo_core::cruise::CruiseSlot;
use tempo_core::history::{date_entries, decode_entries, Event, EventKind};
use tempo_core::merge::merge_observed_moves;
use tempo_core::rollup::{compute, RollupInput};
use tempo_core::time::{minutes, seconds};

/// A plausible 4 096-entry log: presence, countdowns, heights and moves every few minutes.
fn ring() -> Vec<u8> {
    let mut bytes = Vec::with_capacity(8192);
    let mut minute: u32 = 0;
    let mut up = false;
    while bytes.len() < 8192 {
        minute += 20;
        for kind in [
            0x59 | u8::from(up),
            0x26 + if up { 15 } else { 0 },
            0x5C | u8::from(up),
        ] {
            bytes.push((minute % 256) as u8);
            bytes.push(kind);
        }
        if minute % 180 == 0 {
            bytes.extend_from_slice(&[
                (minute % 256) as u8,
                0x50,
                ((minute + 7) % 256) as u8,
                0x51,
            ]);
        }
        up = !up;
    }
    bytes.truncate(8192);
    bytes
}

fn bench(c: &mut Criterion) {
    let bytes = ring();
    let now = Timestamp::from_second(1_800_000_000).unwrap();
    let observed = vec![Event::synthetic(
        now - seconds(30),
        EventKind::Move { to_standing: true },
    )];
    let cruise = Some(CruiseSlot::new(1200, 1200));
    c.bench_function("decode_date_merge_rollup_4096", |b| {
        b.iter(|| {
            let raw = decode_entries(black_box(&bytes), 0);
            let dated = date_entries(&raw, 70_000, now);
            let merged = merge_observed_moves(&dated, &observed);
            compute(RollupInput {
                cruise,
                standing_threshold_inches: Some(34),
                ..RollupInput::new(&merged, now, now - minutes(600))
            })
        })
    });
    let raw = decode_entries(&bytes, 0);
    let dated = date_entries(&raw, 70_000, now);
    let merged = merge_observed_moves(&dated, &observed);
    let reference = compute(RollupInput {
        cruise,
        standing_threshold_inches: Some(34),
        ..RollupInput::new(&merged, now, now - minutes(600))
    });
    eprintln!(
        "Fixture events={} atDeskSeconds={} stands={}",
        merged.len(),
        reference.at_desk_seconds.as_secs_f64(),
        reference.stands
    );
    c.bench_function("rollup_only_4096", |b| {
        b.iter(|| {
            compute(RollupInput {
                cruise,
                standing_threshold_inches: Some(34),
                ..RollupInput::new(black_box(&merged), now, now - minutes(600))
            })
        })
    });
}

criterion_group!(benches, bench);
criterion_main!(benches);
