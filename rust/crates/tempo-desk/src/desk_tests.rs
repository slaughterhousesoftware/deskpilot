//! The service on the in-memory desk, under paused time: every sleep completes at once,
//! so the Swift suite's real-time waits become deterministic here.

use std::sync::{Arc, Mutex};
use std::time::Duration;

use jiff::{SignedDuration, Timestamp};
use tempo_core::cruise::CruiseSlot;
use tempo_core::model::{ConnectionStatus, DeskState};
use tempo_core::registers::{addr, cruise_slot_address, user_offset};
use tempo_core::rollup::{CancelReason, NextMove, MOVE_LEAD};
use tempo_core::session::{SessionConfig, ANNOUNCEMENT_GRACE, COUNTDOWN_ENTRY_TO_MOTOR};
use tempo_core::time::{seconds, Clock};
use tokio::time::timeout;

use super::*;
use crate::fake::FakeTransport;

struct TestClock(Mutex<Timestamp>);

impl TestClock {
    fn new(at: Timestamp) -> Arc<Self> {
        Arc::new(Self(Mutex::new(at)))
    }
    fn advance(&self, d: SignedDuration) {
        let mut t = self.0.lock().unwrap();
        *t += d;
    }
}

impl Clock for TestClock {
    fn now(&self) -> Timestamp {
        *self.0.lock().unwrap()
    }
}

fn now() -> Timestamp {
    Timestamp::from_second(1_800_000_000).unwrap()
}

fn make_fake() -> Arc<FakeTransport> {
    let fake = FakeTransport::new();
    fake.set_registers([
        (addr::FIRMWARE_APPLICATION, 0x0001_0005),
        (addr::MINUTES_SINCE_POWER_ON, 5883),
        (addr::HISTORY_SIZE, 8192),
        (addr::CURRENT_USER, 0),
        (addr::STATUS, 0x0000_010B),
        (4096 + user_offset::FLAGS, 0x1E3),
        (4096 + user_offset::ACTIVE_CRUISE_SLOT, 1),
        (4096 + user_offset::COUNTDOWN_AND_PULSE, 0x0008_000F),
        (4096 + user_offset::MIDDLE_OF_NIGHT_HOUR, 4),
        (4096 + user_offset::STANDING_HEIGHT, 411),
        (4096 + user_offset::SITTING_HEIGHT, 266),
        (4096 + user_offset::CUSTOM_HEIGHT_ONE, 0),
        (4096 + user_offset::CUSTOM_HEIGHT_TWO, 0),
        (cruise_slot_address(0, 1), 0x04B0_04B0),
    ]);
    // present at t=231, move up at t=231 -> "now" (5883 % 256 == 251) is 20 min later
    fake.set_history(&[0xE7, 0x51, 0xE7, 0x5D], None);
    Arc::new(fake)
}

fn config() -> DeskConfig {
    DeskConfig {
        poll_interval: Duration::from_millis(20),
        moving_poll_interval: Duration::from_millis(20),
        history_poll_interval: Duration::from_millis(20),
        settings_poll_interval: Duration::from_secs(30),
        probe_registers: false,
        initial_backoff: Duration::from_millis(10),
        background_retry_interval: Duration::from_millis(150),
        foreground_attempt_limit: 3,
        session: SessionConfig {
            tz: jiff::tz::TimeZone::UTC,
            ..SessionConfig::default()
        },
    }
}

async fn spawn(fake: &Arc<FakeTransport>, cfg: DeskConfig, clock: Arc<dyn Clock>) -> DeskHandle {
    let handle = Desk::spawn(fake.clone(), cfg, clock, None);
    handle.start().await;
    handle
}

async fn first(handle: &DeskHandle, pred: impl FnMut(&DeskState) -> bool) -> DeskState {
    match timeout(Duration::from_secs(30), handle.wait_for(pred)).await {
        Ok(state) => state,
        Err(_) => panic!(
            "state did not satisfy predicate in time; current = {:?}",
            handle.current()
        ),
    }
}

async fn wait_for_history(handle: &DeskHandle, entries: usize) {
    timeout(Duration::from_secs(5), async {
        while handle.decoded_entry_count().await < entries {
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    })
    .await
    .expect("history was not ingested in time");
}

#[tokio::test(start_paused = true)]
async fn connect_reads_settings_and_history() {
    let fake = make_fake();
    let desk = spawn(&fake, config(), TestClock::new(now())).await;
    let state = first(&desk, |s| s.is_connected() && s.today.is_some()).await;
    assert_eq!(state.height_tenths, Some(267));
    let settings = state.settings.unwrap();
    assert_eq!(settings.firmware, "1.0.5");
    assert_eq!(
        (
            settings.standing_height_tenths,
            settings.sitting_height_tenths
        ),
        (411, 266)
    );
    assert_eq!(settings.cruise, Some(CruiseSlot::new(1200, 1200)));
    assert!(!settings.paused());
    let today = state.today.unwrap();
    assert_eq!(today.stands, 1);
    assert_eq!(
        today.is_standing,
        Some(false),
        "the live height wins over the log"
    );
    assert!(today.is_present);
    assert_eq!(
        today.next_move,
        Some(NextMove::new(now() + MOVE_LEAD, false))
    );
    desk.shutdown().await;
}

#[tokio::test(start_paused = true)]
async fn poll_picks_up_new_history_entries() {
    let fake = make_fake();
    let desk = spawn(&fake, config(), TestClock::new(now())).await;
    first(&desk, |s| s.today.is_some()).await;
    fake.append_history(&[0xFB, 0x5C]);
    let state = first(&desk, |s| {
        s.today
            .and_then(|t| t.next_move)
            .is_some_and(|n| n.to_standing)
    })
    .await;
    assert_eq!(state.today.unwrap().stands, 1);
    assert_eq!(
        state.today.unwrap().next_move,
        Some(NextMove::new(now() + seconds(1200) + MOVE_LEAD, true))
    );
    desk.shutdown().await;
}

#[tokio::test(start_paused = true)]
async fn countdown_entry_hands_timing_to_the_desk() {
    let fake = make_fake();
    let clock = TestClock::new(now());
    let desk = spawn(&fake, config(), clock.clone()).await;
    first(&desk, |s| s.today.is_some()).await;
    fake.append_history(&[0xFB, 0x58]);
    let announced = first(&desk, |s| {
        s.today
            .and_then(|t| t.next_move)
            .is_some_and(|n| n.is_announced())
    })
    .await;
    assert_eq!(
        announced.today.unwrap().next_move,
        Some(NextMove::announced(
            now() + COUNTDOWN_ENTRY_TO_MOTOR,
            false,
            now()
        ))
    );
    clock.advance(seconds(13));
    fake.set_register(addr::STATUS, 0x8000_0150);
    first(&desk, |s| s.is_moving).await;
    clock.advance(seconds(8));
    fake.set_register(addr::STATUS, 0x0000_010A);
    let moved = first(&desk, |s| {
        !s.is_moving
            && s.today
                .and_then(|t| t.next_move)
                .is_some_and(|n| n.to_standing)
    })
    .await;
    let next = moved.today.unwrap().next_move.unwrap();
    assert!(!next.is_announced());
    assert_eq!(
        next,
        NextMove::new(now() + seconds(13) + seconds(1200) + MOVE_LEAD, true)
    );
    desk.shutdown().await;
}

#[tokio::test(start_paused = true)]
async fn dismissed_countdown_restarts_the_interval_once_the_grace_expires() {
    let fake = make_fake();
    let clock = TestClock::new(now());
    let desk = spawn(&fake, config(), clock.clone()).await;
    first(&desk, |s| s.today.is_some()).await;
    fake.append_history(&[0xFB, 0x58]);
    first(&desk, |s| {
        s.today
            .and_then(|t| t.next_move)
            .is_some_and(|n| n.is_announced())
    })
    .await;
    clock.advance(COUNTDOWN_ENTRY_TO_MOTOR + ANNOUNCEMENT_GRACE);
    let dismissed = first(&desk, |s| {
        s.today
            .and_then(|t| t.next_move)
            .is_some_and(|n| !n.is_announced())
    })
    .await;
    assert_eq!(dismissed.today.unwrap().stands, 1);
    assert_eq!(
        dismissed.today.unwrap().next_move,
        Some(NextMove::new(now() + seconds(1200) + MOVE_LEAD, false))
    );
    desk.shutdown().await;
}

#[tokio::test(start_paused = true)]
async fn quiet_retries_recover_and_reset_after_a_successful_sync() {
    let fake = make_fake();
    fake.set_connect_error(Some(DeskError::Timeout("scan".into())));
    let desk = spawn(&fake, config(), TestClock::new(now())).await;
    first(&desk, |s| s.reconnecting_in_background).await;
    assert_eq!(fake.connect_calls(), 3);
    fake.emit(ConnectionEvent::Connecting);
    tokio::time::sleep(Duration::from_millis(30)).await;
    let quiet = desk.current();
    assert_eq!(quiet.status, ConnectionStatus::Disconnected);
    assert!(quiet.reconnecting_in_background);
    assert_eq!(
        fake.connect_calls(),
        3,
        "quiet mode must wait before probing again"
    );

    fake.set_connect_error(None);
    first(&desk, |s| {
        s.is_connected() && s.today.is_some() && !s.reconnecting_in_background
    })
    .await;
    assert!(
        fake.connect_calls() >= 4,
        "recovery must happen without manual reconnect"
    );
    let before = fake.connect_calls();
    fake.set_connect_error(Some(DeskError::Timeout("scan".into())));
    fake.emit(ConnectionEvent::Disconnected {
        reason: Some("lost link".into()),
    });
    let retry = first(&desk, |s| s.status == ConnectionStatus::Connecting).await;
    assert!(
        !retry.reconnecting_in_background,
        "a new disconnection gets visible retries"
    );
    first(&desk, |s| s.reconnecting_in_background).await;
    assert_eq!(fake.connect_calls(), before + 3);
    desk.shutdown().await;
}

#[tokio::test(start_paused = true)]
async fn manual_restart_leaves_quiet_mode() {
    let fake = make_fake();
    fake.set_connect_error(Some(DeskError::Timeout("scan".into())));
    let cfg = DeskConfig {
        background_retry_interval: Duration::from_secs(1),
        ..config()
    };
    let desk = spawn(&fake, cfg, TestClock::new(now())).await;
    first(&desk, |s| s.reconnecting_in_background).await;
    desk.stop().await;
    desk.start().await;
    let retry = first(&desk, |s| s.status == ConnectionStatus::Connecting).await;
    assert!(!retry.reconnecting_in_background);
    desk.shutdown().await;
}

#[tokio::test(start_paused = true)]
async fn status_poll_updates_height_and_motion() {
    let fake = make_fake();
    let desk = spawn(&fake, config(), TestClock::new(now())).await;
    first(&desk, |s| s.is_connected()).await;
    fake.set_register(addr::STATUS, 0x8000_0126);
    let state = first(&desk, |s| s.is_moving).await;
    assert_eq!(state.height_tenths, Some(294));
    desk.shutdown().await;
}

#[tokio::test(start_paused = true)]
async fn adaptive_polling_speeds_up_while_moving_and_until_settled() {
    let fake = make_fake();
    let cfg = DeskConfig {
        poll_interval: Duration::from_millis(200),
        history_poll_interval: Duration::from_secs(5),
        ..config()
    };
    let desk = spawn(&fake, cfg, TestClock::new(now())).await;
    first(&desk, |s| s.today.is_some()).await;
    let reads = || fake.read_count_for(addr::STATUS);

    let before = reads();
    tokio::time::sleep(Duration::from_millis(300)).await;
    let stationary = reads() - before;
    assert!(
        stationary > 0 && stationary <= 3,
        "stationary reads in 0.3 s: {stationary}"
    );

    fake.set_register(addr::STATUS, 0x8000_0190);
    first(&desk, |s| s.is_moving).await;
    let before = reads();
    tokio::time::sleep(Duration::from_millis(300)).await;
    let moving = reads() - before;
    assert!(
        moving >= 6 && moving >= stationary * 3,
        "moving reads in 0.3 s: {moving} vs {stationary}"
    );

    // The motion bit clears while the height is still creeping: polling must stay fast.
    fake.set_register(addr::STATUS, 0x0000_0190);
    first(&desk, |s| s.is_connected() && !s.is_moving).await;
    let before = reads();
    for h in [0x195u32, 0x199, 0x19D, 0x1A1, 0x1A5, 0x1A9] {
        fake.set_register(addr::STATUS, h);
        tokio::time::sleep(Duration::from_millis(40)).await;
    }
    let settling = reads() - before;
    assert!(
        settling >= 6 && settling >= stationary * 3,
        "settling reads in 0.3 s: {settling} vs {stationary}"
    );
    desk.shutdown().await;
}

#[tokio::test(start_paused = true)]
async fn writes_go_to_the_right_registers_and_refuse_magic() {
    let fake = make_fake();
    let cfg = DeskConfig {
        poll_interval: Duration::from_secs(1),
        history_poll_interval: Duration::from_secs(1),
        ..config()
    };
    let desk = spawn(&fake, cfg, TestClock::new(now())).await;
    first(&desk, |s| s.settings.is_some() && s.height_tenths.is_some()).await;
    // The first reading of 26.7" is fresh: let the settle grace pass.
    tokio::time::sleep(Duration::from_millis(1100)).await;

    desk.capture_sitting_preset().await.unwrap();
    assert_eq!(fake.register(4096 + user_offset::SITTING_HEIGHT), Some(267));
    desk.capture_standing_preset().await.unwrap();
    assert_eq!(
        fake.register(4096 + user_offset::STANDING_HEIGHT),
        Some(267)
    );

    desk.set_cruise(Some(CruiseSlot::new(600, 3000)))
        .await
        .unwrap();
    assert_eq!(fake.register(cruise_slot_address(0, 1)), Some(0x0258_0BB8));
    assert_eq!(
        fake.register(4096 + user_offset::ACTIVE_CRUISE_SLOT),
        Some(1)
    );
    desk.set_cruise(None).await.unwrap();
    assert_eq!(
        fake.register(4096 + user_offset::ACTIVE_CRUISE_SLOT),
        Some(0)
    );

    desk.set_paused(true).await.unwrap();
    assert_eq!(fake.register(4096 + user_offset::FLAGS), Some(0x1E7));
    desk.set_paused(false).await.unwrap();
    assert_eq!(fake.register(4096 + user_offset::FLAGS), Some(0x1E3));

    desk.sync_clock().await.unwrap();
    assert!(fake.writes().iter().any(|w| w.0 == addr::CLOCK));
    assert!(!fake.writes().iter().any(|w| w.0 == addr::BOOTLOADER_MAGIC));
    desk.shutdown().await;
}

#[tokio::test(start_paused = true)]
async fn periodic_settings_poll_picks_up_desk_side_pause_change() {
    let fake = make_fake();
    let cfg = DeskConfig {
        history_poll_interval: Duration::from_secs(1),
        settings_poll_interval: Duration::from_millis(50),
        ..config()
    };
    let desk = spawn(&fake, cfg, TestClock::new(now())).await;
    let connected = first(&desk, |s| s.settings.is_some()).await;
    assert!(!connected.settings.unwrap().paused());
    fake.set_register(4096 + user_offset::FLAGS, 0x1E3 | 0x4);
    let state = first(&desk, |s| s.settings.as_ref().is_some_and(|x| x.paused())).await;
    assert!(state.settings.unwrap().paused());
    desk.shutdown().await;
}

#[tokio::test(start_paused = true)]
async fn phone_edits_are_refreshed_without_a_flag_or_slot_change() {
    let fake = make_fake();
    let cfg = DeskConfig {
        history_poll_interval: Duration::from_secs(1),
        settings_poll_interval: Duration::from_millis(50),
        ..config()
    };
    let desk = spawn(&fake, cfg, TestClock::new(now())).await;
    first(&desk, |s| s.today.is_some()).await;
    // Wait for the initial sync to finish, including its ordinary clock write.
    desk.history_document().await;
    let writes = fake.writes();
    fake.set_registers([
        (4096 + user_offset::COUNTDOWN_AND_PULSE, 0x0005_0014),
        (4096 + user_offset::MIDDLE_OF_NIGHT_HOUR, 6),
        (4096 + user_offset::STANDING_HEIGHT, 430),
        (4096 + user_offset::CUSTOM_HEIGHT_ONE, 310),
        (4096 + user_offset::CUSTOM_HEIGHT_TWO, 380),
        // The app always edits the existing custom slot, rather than selecting a new one.
        (cruise_slot_address(0, 1), 0x0258_00B4),
    ]);
    let state = first(&desk, |s| {
        s.settings
            .as_ref()
            .is_some_and(|x| x.standing_height_tenths == 430)
    })
    .await;
    let settings = state.settings.unwrap();
    assert_eq!(settings.flags, 0x1E3);
    assert_eq!(settings.active_cruise_slot, 1);
    assert_eq!(settings.cruise, Some(CruiseSlot::from_raw(0x0258_00B4)));
    assert_eq!(settings.middle_of_night_hour, 6);
    assert_eq!(
        (
            settings.custom_height_one_tenths,
            settings.custom_height_two_tenths
        ),
        (310, 380)
    );
    let timing = settings.countdown_timing.unwrap();
    assert_eq!(
        (timing.countdown_seconds, timing.pulse_time_seconds),
        (20, 5)
    );
    // The new fields ride in the existing block; none requires a separate register read.
    for offset in [
        user_offset::COUNTDOWN_AND_PULSE,
        user_offset::MIDDLE_OF_NIGHT_HOUR,
        user_offset::STANDING_HEIGHT,
    ] {
        assert_eq!(fake.read_count_for(4096 + offset), 0);
    }
    assert_eq!(
        fake.writes(),
        writes,
        "refresh must not rewrite the phone's settings"
    );
    desk.shutdown().await;
}

#[tokio::test(start_paused = true)]
async fn handset_user_switch_refreshes_settings_and_names() {
    let fake = make_fake();
    fake.burst_write(4096 + user_offset::USER_NAME, &encode_name("Kevin"))
        .await
        .unwrap();
    fake.burst_write(8192 + user_offset::USER_NAME, &encode_name("Second user"))
        .await
        .unwrap();
    fake.set_registers([
        (8192 + user_offset::FLAGS, 0x1E3),
        (8192 + user_offset::ACTIVE_CRUISE_SLOT, 0),
        (8192 + user_offset::COUNTDOWN_AND_PULSE, 0x0004_000A),
        (8192 + user_offset::MIDDLE_OF_NIGHT_HOUR, 3),
        (8192 + user_offset::STANDING_HEIGHT, 420),
        (8192 + user_offset::SITTING_HEIGHT, 270),
        (8192 + user_offset::CUSTOM_HEIGHT_ONE, 0),
        (8192 + user_offset::CUSTOM_HEIGHT_TWO, 0),
    ]);
    let cfg = DeskConfig {
        settings_poll_interval: Duration::from_millis(50),
        ..config()
    };
    let desk = spawn(&fake, cfg, TestClock::new(now())).await;
    first(&desk, |s| {
        s.settings
            .as_ref()
            .is_some_and(|x| x.user_name.as_deref() == Some("Kevin"))
    })
    .await;
    fake.set_register(addr::CURRENT_USER, 1);
    let state = first(&desk, |s| {
        s.settings
            .as_ref()
            .is_some_and(|x| x.user_index == 1 && x.user_name.as_deref() == Some("Second user"))
    })
    .await;
    let settings = state.settings.unwrap();
    assert_eq!(settings.standing_height_tenths, 420);
    assert_eq!(settings.middle_of_night_hour, 3);
    assert!(!settings.cruise_enabled());
    tokio::time::sleep(Duration::from_millis(200)).await;
    assert_eq!(fake.read_count_for(4096 + user_offset::USER_NAME), 1);
    assert_eq!(fake.read_count_for(8192 + user_offset::USER_NAME), 1);
    desk.shutdown().await;
}

#[tokio::test(start_paused = true)]
async fn undocumented_register_probes_require_explicit_opt_in() {
    assert!(!DeskConfig::default().probe_registers);
    for enabled in [false, true] {
        let fake = make_fake();
        let cfg = DeskConfig {
            history_poll_interval: Duration::from_secs(5),
            probe_registers: enabled,
            ..config()
        };
        let desk = spawn(&fake, cfg, TestClock::new(now())).await;
        first(&desk, |s| s.today.is_some()).await;
        fake.append_history(&[0xFB, 0x58]); // a fresh countdown, tightening the history cadence
        first(&desk, |s| {
            s.today
                .and_then(|t| t.next_move)
                .is_some_and(|n| n.is_announced())
        })
        .await;
        tokio::time::sleep(Duration::from_secs(2)).await;
        for address in [48, 72, 76, 228, 4096 + 32, 4096 + 36, 4096 + 40] {
            let reads = fake.read_count_for(address);
            assert_eq!(
                reads > 0,
                enabled,
                "probe {address}: {reads} reads, enabled={enabled}"
            );
        }
        assert!(fake.read_count_for(addr::STATUS) > 0);
        desk.shutdown().await;
    }
}

#[tokio::test(start_paused = true)]
async fn capture_preset_refuses_while_moving_or_settling() {
    let fake = make_fake();
    let cfg = DeskConfig {
        history_poll_interval: Duration::from_secs(1),
        ..config()
    };
    let desk = spawn(&fake, cfg, TestClock::new(now())).await;
    first(&desk, |s| s.settings.is_some()).await;

    fake.set_register(addr::STATUS, 0x8000_010C);
    first(&desk, |s| s.is_moving).await;
    assert!(matches!(
        desk.capture_sitting_preset().await,
        Err(DeskError::InvalidValue(_))
    ));
    assert!(!fake
        .writes()
        .iter()
        .any(|w| w.0 == 4096 + user_offset::SITTING_HEIGHT));

    fake.set_register(addr::STATUS, 0x0000_0190);
    first(&desk, |s| s.is_connected() && !s.is_moving).await;
    fake.set_register(addr::STATUS, 0x0000_0195);
    assert!(
        matches!(
            desk.capture_standing_preset().await,
            Err(DeskError::InvalidValue(_))
        ),
        "still settling"
    );
    assert!(!fake
        .writes()
        .iter()
        .any(|w| w.0 == 4096 + user_offset::STANDING_HEIGHT));

    tokio::time::sleep(Duration::from_millis(1100)).await;
    desk.capture_standing_preset().await.unwrap();
    assert_eq!(
        fake.register(4096 + user_offset::STANDING_HEIGHT),
        Some(405)
    );
    desk.shutdown().await;
}

#[tokio::test(start_paused = true)]
async fn preset_capture_stores_the_desks_current_height() {
    let fake = make_fake();
    let cfg = DeskConfig {
        poll_interval: Duration::from_secs(1),
        history_poll_interval: Duration::from_secs(1),
        ..config()
    };
    let desk = spawn(&fake, cfg, TestClock::new(now())).await;
    first(&desk, |s| s.settings.is_some() && s.height_tenths.is_some()).await;
    // The desk moved since the last poll; capture re-reads the register, and that fresh
    // reading is itself the first sight of 41.1", so it has to settle first.
    fake.set_register(addr::STATUS, 0x0000_019B);
    assert!(matches!(
        desk.capture_standing_preset().await,
        Err(DeskError::InvalidValue(_))
    ));
    tokio::time::sleep(Duration::from_millis(1100)).await;
    desk.capture_standing_preset().await.unwrap();
    assert_eq!(
        fake.register(4096 + user_offset::STANDING_HEIGHT),
        Some(411)
    );
    assert_eq!(desk.current().settings.unwrap().standing_height_tenths, 411);
    desk.shutdown().await;
}

#[tokio::test(start_paused = true)]
async fn reconnects_after_disconnect_with_backoff() {
    let fake = make_fake();
    let desk = spawn(&fake, config(), TestClock::new(now())).await;
    first(&desk, |s| s.is_connected()).await;
    fake.emit(ConnectionEvent::Disconnected {
        reason: Some("gone".into()),
    });
    first(&desk, |s| s.status == ConnectionStatus::Disconnected).await;
    first(&desk, |s| s.is_connected()).await;
    assert!(fake.connect_calls() >= 2);
    desk.shutdown().await;
}

#[tokio::test(start_paused = true)]
async fn stop_waits_for_the_loop_then_start_restarts_cleanly() {
    let fake = make_fake();
    let desk = spawn(&fake, config(), TestClock::new(now())).await;
    first(&desk, |s| s.is_connected()).await;
    desk.stop().await;
    assert_eq!(desk.current().status, ConnectionStatus::Disconnected);
    let reads = fake.read_count();
    tokio::time::sleep(Duration::from_millis(200)).await;
    assert_eq!(
        fake.read_count(),
        reads,
        "no reads once stop() has returned"
    );
    desk.start().await;
    first(&desk, |s| s.is_connected()).await;
    assert_eq!(fake.connect_calls(), 2);
    desk.shutdown().await;
}

#[tokio::test(start_paused = true)]
async fn reconnect_command_drops_and_reconnects() {
    let fake = make_fake();
    let desk = spawn(&fake, config(), TestClock::new(now())).await;
    first(&desk, |s| s.is_connected()).await;
    let reads = fake.read_count();
    desk.reconnect().await;
    timeout(Duration::from_secs(5), async {
        while fake.connect_calls() < 2 {
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
    })
    .await
    .expect("a second connect attempt");
    first(&desk, |s| s.is_connected()).await;
    tokio::time::sleep(Duration::from_millis(100)).await;
    assert!(
        fake.read_count() > reads + 5,
        "polling resumed on the new connection"
    );
    assert_eq!(fake.connect_calls(), 2);
    desk.shutdown().await;
}

#[tokio::test(start_paused = true)]
async fn resyncs_history_when_the_desk_reboots() {
    let fake = make_fake();
    let desk = spawn(&fake, config(), TestClock::new(now())).await;
    first(&desk, |s| s.today.is_some()).await;
    fake.set_history(&[0x05, 0x40, 0x05, 0x51, 0x0A, 0x5C], Some(10));
    let state = first(&desk, |s| s.today.is_some_and(|t| t.stands == 0)).await;
    assert_eq!(
        state.today.unwrap().next_move,
        Some(NextMove::new(now() + seconds(1200) + MOVE_LEAD, true))
    );
    desk.shutdown().await;
}

#[tokio::test(start_paused = true)]
async fn bluetooth_states_and_connect_failures_reach_the_ui_written_out() {
    for (error, status, text) in [
        (
            DeskError::BluetoothOff,
            ConnectionStatus::BluetoothOff,
            "Bluetooth is turned off",
        ),
        (
            DeskError::Unauthorized,
            ConnectionStatus::Unauthorized,
            "Bluetooth access was denied",
        ),
        (
            DeskError::Timeout("scan".into()),
            ConnectionStatus::Disconnected,
            "Couldn't find the desk. Is it on and in range?",
        ),
        (
            DeskError::Timeout("connect".into()),
            ConnectionStatus::Disconnected,
            "The desk didn't answer in time.",
        ),
        (
            DeskError::Gatt("boom".into()),
            ConnectionStatus::Disconnected,
            "Lost contact with the desk. Try again.",
        ),
    ] {
        let fake = make_fake();
        fake.set_connect_error(Some(error));
        let desk = spawn(&fake, config(), TestClock::new(now())).await;
        let state = first(&desk, |s| {
            s.updated_at.is_some() && s.status != ConnectionStatus::Connecting
        })
        .await;
        assert_eq!(state.status, status);
        assert_eq!(state.last_error.as_deref(), Some(text));
        desk.shutdown().await;
    }
}

#[tokio::test(start_paused = true)]
async fn transient_gatt_error_is_retried_instead_of_dropping_the_connection() {
    let fake = make_fake();
    fake.fail_next_reads(1);
    let cfg = DeskConfig {
        initial_backoff: Duration::from_secs(5),
        ..config()
    };
    let desk = spawn(&fake, cfg, TestClock::new(now())).await;
    let state = first(&desk, |s| s.is_connected() && s.today.is_some()).await;
    assert_eq!(state.settings.unwrap().firmware, "1.0.5");
    assert_eq!(
        fake.connect_calls(),
        1,
        "a retried read must not tear the connection down"
    );
    desk.shutdown().await;
}

#[tokio::test(start_paused = true)]
async fn observed_move_anchors_next_move_before_the_log_catches_up() {
    let fake = make_fake();
    fake.set_history(&[0xFB, 0x5C], None);
    let desk = spawn(&fake, config(), TestClock::new(now())).await;
    let sitting = first(&desk, |s| s.today.is_some()).await;
    assert_eq!(
        (
            sitting.today.unwrap().stands,
            sitting.today.unwrap().is_standing
        ),
        (0, Some(false))
    );
    fake.set_register(addr::STATUS, 0x8000_0150);
    first(&desk, |s| s.is_moving).await;
    fake.set_register(addr::STATUS, 0x0000_019B);
    let standing = first(&desk, |s| s.today.is_some_and(|t| t.stands == 1)).await;
    let today = standing.today.unwrap();
    assert_eq!(today.is_standing, Some(true));
    let next = today.next_move.unwrap();
    assert!(!next.to_standing);
    assert!((next.at.duration_since(now()) - seconds(1200) - MOVE_LEAD).abs() <= seconds(5));
    // The log catches up with the same move: still one stand.
    fake.append_history(&[0xFB, 0x59, 0xFB, 0x35, 0xFB, 0x5D]);
    wait_for_history(&desk, 4).await;
    tokio::time::sleep(Duration::from_millis(50)).await;
    let state = desk.current();
    assert_eq!(state.today.unwrap().stands, 1);
    assert_eq!(
        state.today.unwrap().next_move.map(|n| n.to_standing),
        Some(false)
    );
    desk.shutdown().await;
}

#[tokio::test(start_paused = true)]
async fn implausible_status_reading_is_never_published() {
    let fake = make_fake();
    let cfg = DeskConfig {
        history_poll_interval: Duration::from_secs(1),
        ..config()
    };
    let desk = spawn(&fake, cfg, TestClock::new(now())).await;
    let connected = first(&desk, |s| s.today.is_some()).await;
    let before = fake.read_count();
    fake.set_register(addr::STATUS, 0xDEAD_BEEF);
    while fake.read_count() < before + 10 {
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    let bogus = desk.current();
    assert_eq!(bogus.height_tenths, Some(267));
    assert_eq!(bogus.today.unwrap().stands, connected.today.unwrap().stands);
    assert_eq!(
        bogus.today.unwrap().next_move,
        connected.today.unwrap().next_move
    );
    fake.set_register(addr::STATUS, 0x0000_010B);
    let after = first(&desk, |s| s.height_tenths == Some(267)).await;
    assert_eq!(after.today.unwrap().stands, connected.today.unwrap().stands);
    desk.shutdown().await;
}

#[tokio::test(start_paused = true)]
async fn history_document_is_none_before_settings_and_merged_after() {
    let fake = make_fake();
    let desk = Desk::spawn(fake.clone(), config(), TestClock::new(now()), None);
    assert!(desk.history_document().await.is_none());
    desk.start().await;
    first(&desk, |s| s.today.is_some()).await;
    let doc = desk.history_document().await.unwrap();
    assert_eq!(doc.events.len(), 2);
    assert_eq!(doc.standing_threshold_inches, Some(34));
    assert_eq!(doc.middle_of_night_hour, 4);
    assert!(matches!(
        desk.capture_sitting_preset().await,
        Ok(()) | Err(DeskError::InvalidValue(_))
    ));
    desk.shutdown().await;
}

#[tokio::test(start_paused = true)]
async fn commands_while_disconnected_fail_fast() {
    let fake = make_fake();
    fake.set_connect_error(Some(DeskError::Timeout("scan".into())));
    let desk = spawn(&fake, config(), TestClock::new(now())).await;
    first(&desk, |s| s.updated_at.is_some()).await;
    assert_eq!(desk.set_paused(true).await, Err(DeskError::NotConnected));
    assert_eq!(
        desk.capture_sitting_preset().await,
        Err(DeskError::NotConnected)
    );
    desk.shutdown().await;
}

#[tokio::test(start_paused = true)]
async fn connect_syncs_with_two_bursts_instead_of_a_dozen_reads() {
    let fake = make_fake();
    let desk = spawn(&fake, config(), TestClock::new(now())).await;
    let state = first(&desk, |s| s.is_connected() && s.today.is_some()).await;
    assert_eq!(state.height_tenths, Some(267));
    assert_eq!(state.settings.as_ref().unwrap().firmware, "1.0.5");
    assert_eq!(fake.read_count_for(0), 1, "the global block, once");
    assert_eq!(
        fake.read_count_for(4096),
        1,
        "no redundant settings refresh after connect"
    );
    for register in [
        addr::FIRMWARE_APPLICATION,
        addr::CURRENT_USER,
        4096 + user_offset::MIDDLE_OF_NIGHT_HOUR,
        4096 + user_offset::STANDING_HEIGHT,
        4096 + user_offset::SITTING_HEIGHT,
    ] {
        assert_eq!(
            fake.read_count_for(register),
            if register == addr::CURRENT_USER { 1 } else { 0 },
            "register {register} should come from a block"
        );
    }
    assert!(
        fake.writes()
            .contains(&(addr::CLOCK, fake.register(addr::CLOCK).unwrap())),
        "the clock is written on connect"
    );
    desk.shutdown().await;
}

#[tokio::test(start_paused = true)]
async fn garbage_blocks_fall_back_to_register_reads() {
    let fake = make_fake();
    // A desk whose burst reads below the history ring return nothing sensible.
    fake.set_registers([(addr::FIRMWARE_APPLICATION, 0xDEAD_BEEF)]);
    let desk = spawn(&fake, config(), TestClock::new(now())).await;
    let state = first(&desk, |s| s.is_connected() && s.today.is_some()).await;
    assert_eq!(state.height_tenths, Some(267));
    assert_eq!(
        state.settings.as_ref().unwrap().standing_height_tenths,
        411,
        "settings still arrive, register by register"
    );
    assert!(fake.read_count_for(4096 + user_offset::FLAGS) >= 1);
    desk.shutdown().await;
}

#[tokio::test(start_paused = true)]
async fn names_are_read_once_and_written_in_a_burst() {
    let fake = make_fake();
    let mut kevin = [0u8; 20];
    kevin[..5].copy_from_slice(b"Kevin");
    fake.burst_write(4096 + user_offset::USER_NAME, &kevin)
        .await
        .unwrap();
    let desk = spawn(&fake, config(), TestClock::new(now())).await;
    let state = first(&desk, |s| {
        s.settings.as_ref().is_some_and(|x| x.user_name.is_some())
    })
    .await;
    let settings = state.settings.unwrap();
    assert_eq!(settings.user_name.as_deref(), Some("Kevin"));
    assert_eq!(settings.preset_name_one, None);
    desk.set_preset_name(2, "Drafting".into()).await.unwrap();
    let written = fake.burst_writes();
    let (address, bytes) = written.last().unwrap();
    assert_eq!(*address, 4096 + user_offset::PRESET_NAME_TWO);
    assert_eq!(bytes.len(), 20);
    assert_eq!(&bytes[..9], b"Drafting\0");
    assert_eq!(
        desk.current().settings.unwrap().preset_name_two.as_deref(),
        Some("Drafting")
    );
    assert!(matches!(
        desk.set_preset_name(3, "x".into()).await,
        Err(DeskError::InvalidValue(_))
    ));
    assert!(matches!(
        desk.set_user_name("   ".into()).await,
        Err(DeskError::InvalidValue(_))
    ));
    desk.shutdown().await;
}

#[tokio::test(start_paused = true)]
async fn custom_presets_pulse_only_and_user_switch_reach_the_desk() {
    let fake = make_fake();
    fake.set_registers([
        (8192 + user_offset::FLAGS, 0x1E3),
        (8192 + user_offset::ACTIVE_CRUISE_SLOT, 0),
        (8192 + user_offset::MIDDLE_OF_NIGHT_HOUR, 3),
        (8192 + user_offset::STANDING_HEIGHT, 420),
        (8192 + user_offset::SITTING_HEIGHT, 270),
        (8192 + user_offset::CUSTOM_HEIGHT_ONE, 0),
        (8192 + user_offset::CUSTOM_HEIGHT_TWO, 0),
    ]);
    let cfg = DeskConfig {
        poll_interval: Duration::from_secs(1),
        ..config()
    };
    let desk = spawn(&fake, cfg, TestClock::new(now())).await;
    first(&desk, |s| s.today.is_some()).await;
    tokio::time::sleep(Duration::from_millis(1100)).await;
    desk.capture_custom_preset(1).await.unwrap();
    assert_eq!(
        fake.register(4096 + user_offset::CUSTOM_HEIGHT_ONE),
        Some(267)
    );
    assert_eq!(
        desk.current().settings.unwrap().custom_height_one_tenths,
        267
    );
    assert!(matches!(
        desk.capture_custom_preset(3).await,
        Err(DeskError::InvalidValue(_))
    ));
    desk.set_pulse_only(true).await.unwrap();
    assert_eq!(fake.register(4096 + user_offset::FLAGS), Some(0x1F3));
    assert!(desk.current().settings.unwrap().pulse_only());
    desk.set_user(1).await.unwrap();
    assert_eq!(fake.register(addr::CURRENT_USER), Some(1));
    let settings = desk.current().settings.unwrap();
    assert_eq!(settings.user_index, 1);
    assert_eq!(settings.standing_height_tenths, 420);
    assert_eq!(settings.middle_of_night_hour, 3);
    assert!(!settings.cruise_enabled());
    assert!(matches!(
        desk.set_user(2).await,
        Err(DeskError::InvalidValue(_))
    ));
    desk.shutdown().await;
}

#[tokio::test(start_paused = true)]
async fn an_announced_move_is_watched_closely_and_its_wave_off_reported() {
    let fake = make_fake();
    let clock = TestClock::new(now());
    let cfg = DeskConfig {
        poll_interval: Duration::from_millis(200),
        moving_poll_interval: Duration::from_millis(20),
        history_poll_interval: Duration::from_secs(5),
        ..config()
    };
    let desk = spawn(&fake, cfg, clock.clone()).await;
    first(&desk, |s| s.today.is_some()).await;
    let reads = || fake.read_count_for(addr::STATUS);
    let before = reads();
    tokio::time::sleep(Duration::from_millis(300)).await;
    let quiet = reads() - before;
    // The desk announces a sit.
    fake.append_history(&[0xFB, 0x58]);
    first(&desk, |s| {
        s.today
            .and_then(|t| t.next_move)
            .is_some_and(|n| n.is_announced())
    })
    .await;
    let before = reads();
    tokio::time::sleep(Duration::from_millis(300)).await;
    let announced = reads() - before;
    assert!(
        announced >= quiet * 3,
        "status reads in 0.3 s: {announced} announced vs {quiet} quiet"
    );
    // Nothing happens: the paddle waved it off.
    clock.advance(COUNTDOWN_ENTRY_TO_MOTOR + ANNOUNCEMENT_GRACE);
    let cancelled = first(&desk, |s| s.today.and_then(|t| t.cancelled_move).is_some()).await;
    let today = cancelled.today.unwrap();
    let c = today.cancelled_move.unwrap();
    assert_eq!((c.to_standing, c.reason), (false, CancelReason::WavedOff));
    assert_eq!(c.at, now() + COUNTDOWN_ENTRY_TO_MOTOR + ANNOUNCEMENT_GRACE);
    assert!(!today.next_move.unwrap().is_announced());
    // Back to the quiet cadence once the window is over.
    clock.advance(seconds(5));
    tokio::time::sleep(Duration::from_millis(300)).await;
    let before = reads();
    tokio::time::sleep(Duration::from_millis(300)).await;
    assert!(reads() - before <= quiet + 1);
    desk.shutdown().await;
}

#[tokio::test(start_paused = true)]
async fn predicted_height_is_published_while_moving_and_cleared_when_settled() {
    let fake = make_fake();
    let clock = TestClock::new(now());
    let cfg = DeskConfig {
        poll_interval: Duration::from_millis(250),
        moving_poll_interval: Duration::from_millis(250),
        ..config()
    };
    let desk = spawn(&fake, cfg, clock.clone()).await;
    first(&desk, |s| s.today.is_some()).await;
    assert_eq!(desk.current().predicted_height_tenths, None);
    for h in [0x10Fu32, 0x113, 0x117] {
        fake.set_register(addr::STATUS, 0x8000_0000 | h);
        tokio::time::sleep(Duration::from_millis(250)).await;
    }
    tokio::time::sleep(Duration::from_millis(300)).await;
    let moving = desk.current();
    assert!(moving.is_moving && moving.height_tenths == Some(0x117));
    assert_eq!(
        moving.predicted_height_tenths, None,
        "driven by hand: the readout follows the desk, not a guess"
    );
    fake.set_register(addr::STATUS, 0x011B);
    let released = first(&desk, |s| !s.is_moving).await;
    let predicted = released.predicted_height_tenths.expect("coasting");
    assert!(predicted > 0x11B, "heading up: {predicted}");
    tokio::time::sleep(Duration::from_millis(600)).await;
    let settled = desk.current();
    assert_eq!(settled.height_tenths, Some(0x11B));
    assert_eq!(settled.predicted_height_tenths, None, "settled");
    desk.shutdown().await;
}
