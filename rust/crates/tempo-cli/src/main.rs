//! `tempo`: the desk service and a command line for it.

mod serve;

use std::path::{Path, PathBuf};
use std::process::ExitCode;
use std::time::Duration;

use clap::{Parser, Subcommand, ValueEnum};
use jiff::tz::TimeZone;
use jiff::Timestamp;
use tempo_core::cruise::CruiseSlot;
use tempo_core::model::HistoryDocument;
use tempo_core::rollup::{self, RollupInput};
use tempo_core::store::{default_data_dir, Command, CommandQueue, HistoryStore, SnapshotStore};
use tempo_core::time::iso8601_seconds;
use tempo_core::{format, summary, timeline};
use tempo_desk::sim::Scenario;

#[derive(Parser)]
#[command(
    name = "tempo",
    version,
    about = "Ergodriven Tempo desk: service and command line"
)]
struct Cli {
    /// Where snapshot.json, history.json and the command queue live.
    #[arg(long, global = true, env = "DESKPILOT_DATA_DIR")]
    data_dir: Option<PathBuf>,
    /// Log filter, e.g. `info` or `tempo_core=debug`.
    #[arg(long, global = true, env = "RUST_LOG", default_value = "info")]
    log: String,
    #[command(subcommand)]
    command: Cmd,
}

#[derive(Subcommand)]
enum Cmd {
    /// Read the running service's detailed state and settings without Bluetooth writes.
    Inspect,
    /// Connect to the desk and keep the files current. Run this in the background.
    Serve {
        /// A desk that lives in memory, in this scenario, instead of the real one.
        #[arg(long, value_parser = parse_scenario)]
        sim: Option<Scenario>,
        /// Stream UI frames to stdout; stop when the hosting app closes stdin.
        #[arg(long)]
        hosted: bool,
        /// Research only: read undocumented registers near a predicted move (adds BLE traffic).
        #[arg(long)]
        probe_registers: bool,
    },
    /// One sentence about the desk right now, from the service's snapshot.
    Status {
        #[arg(long)]
        json: bool,
    },
    /// Print the snapshot as a JSON line whenever it changes.
    Watch {
        #[arg(long, default_value_t = 1.0)]
        interval_secs: f64,
    },
    /// Today, past days and the archive, from history.json.
    History {
        #[command(subcommand)]
        what: HistoryCmd,
    },
    /// Cruise control timing.
    Cruise {
        #[command(subcommand)]
        what: CruiseCmd,
    },
    /// Pause cruise control.
    Pause,
    /// Resume cruise control.
    Resume,
    /// Store the desk's current height as a preset.
    Preset { which: Preset },
    /// Pulse (nudge) instead of moving when the interval runs out: on or off.
    Pulse { on: OnOff },
    /// Make user 0 or 1 the desk's active user.
    User { index: u8 },
    /// Set the user's name, or a custom preset's name, on the desk (up to 19 bytes).
    Name { which: NameField, name: String },
    /// Write the time of day to the desk's clock (also done on every connect).
    Clock,
    /// Drop the Bluetooth connection and connect again.
    Reconnect,
    /// Copy history.json to a dated backup file after checking it parses.
    Backup {
        /// Directory for the copy. Default: history-backups next to history.json.
        #[arg(long)]
        to: Option<PathBuf>,
    },
    /// List the simulator scenarios.
    Scenarios,
}

#[derive(Subcommand)]
enum HistoryCmd {
    /// Today's totals and timeline.
    Today {
        #[arg(long)]
        json: bool,
    },
    /// Standing, sitting, away and stands per day.
    Totals {
        #[arg(long, default_value_t = 7)]
        days: u32,
        #[arg(long)]
        json: bool,
    },
    /// The whole archive as JSON.
    Export,
}

#[derive(Subcommand)]
enum CruiseCmd {
    /// Minutes standing per cycle, and the cycle length in minutes.
    Set {
        standing_minutes: u32,
        cycle_minutes: u32,
    },
    Off,
}

#[derive(Clone, Copy, ValueEnum)]
enum Preset {
    Sit,
    Stand,
    Custom1,
    Custom2,
}

#[derive(Clone, Copy, ValueEnum)]
enum OnOff {
    On,
    Off,
}

#[derive(Clone, Copy, ValueEnum)]
enum NameField {
    User,
    Preset1,
    Preset2,
}

fn parse_scenario(s: &str) -> Result<Scenario, String> {
    s.parse()
}

fn main() -> ExitCode {
    let cli = Cli::parse();
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_new(&cli.log)
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info")),
        )
        .with_writer(std::io::stderr)
        .init();
    let dir = cli.data_dir.clone().unwrap_or_else(default_data_dir);
    // Two workers, not one per core: the daemon idles between desk polls, and every worker
    // thread is resident memory for the life of the process.
    let runtime = tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2)
        .enable_all()
        .build()
        .expect("tokio runtime");
    match runtime.block_on(run(cli.command, dir)) {
        Ok(()) => ExitCode::SUCCESS,
        Err(message) => {
            eprintln!("{message}");
            ExitCode::FAILURE
        }
    }
}

async fn run(command: Cmd, dir: PathBuf) -> Result<(), String> {
    match command {
        Cmd::Inspect => send(&dir, Command::Inspect).await,
        Cmd::Serve {
            sim,
            hosted,
            probe_registers,
        } => serve::serve(dir, sim, hosted, probe_registers).await,
        Cmd::Status { json } => status(&dir, json),
        Cmd::Watch { interval_secs } => watch(&dir, interval_secs).await,
        Cmd::History { what } => history(&dir, what),
        Cmd::Cruise { what } => match what {
            CruiseCmd::Set {
                standing_minutes,
                cycle_minutes,
            } => {
                let slot =
                    CruiseSlot::make(standing_minutes, cycle_minutes).map_err(|e| e.to_string())?;
                send(&dir, Command::SetCruise(Some(slot))).await
            }
            CruiseCmd::Off => send(&dir, Command::SetCruise(None)).await,
        },
        Cmd::Pause => send(&dir, Command::SetPaused(true)).await,
        Cmd::Resume => send(&dir, Command::SetPaused(false)).await,
        Cmd::Preset { which } => {
            send(
                &dir,
                match which {
                    Preset::Sit => Command::CaptureSittingPreset,
                    Preset::Stand => Command::CaptureStandingPreset,
                    Preset::Custom1 => Command::CaptureCustomPreset(1),
                    Preset::Custom2 => Command::CaptureCustomPreset(2),
                },
            )
            .await
        }
        Cmd::Pulse { on } => send(&dir, Command::SetPulseOnly(matches!(on, OnOff::On))).await,
        Cmd::User { index } => send(&dir, Command::SetUser(index)).await,
        Cmd::Name { which, name } => {
            send(
                &dir,
                match which {
                    NameField::User => Command::SetUserName(name),
                    NameField::Preset1 => Command::SetPresetName(1, name),
                    NameField::Preset2 => Command::SetPresetName(2, name),
                },
            )
            .await
        }
        Cmd::Clock => send(&dir, Command::SyncClock).await,
        Cmd::Reconnect => send(&dir, Command::Reconnect).await,
        Cmd::Backup { to } => backup(&dir, to),
        Cmd::Scenarios => {
            for s in Scenario::ALL {
                println!("{s}");
            }
            Ok(())
        }
    }
}

fn status(dir: &Path, json: bool) -> Result<(), String> {
    let snapshot = SnapshotStore::new(dir).read();
    if json {
        let text = serde_json::to_string_pretty(&snapshot).map_err(|e| e.to_string())?;
        println!("{text}");
    } else {
        println!("{}", summary::sentence(snapshot.as_ref(), Timestamp::now()));
    }
    Ok(())
}

async fn watch(dir: &Path, interval_secs: f64) -> Result<(), String> {
    let store = SnapshotStore::new(dir);
    let mut last = None;
    loop {
        let snapshot = store.read();
        if snapshot != last {
            if let Some(s) = &snapshot {
                println!("{}", serde_json::to_string(s).map_err(|e| e.to_string())?);
            }
            last = snapshot;
        }
        tokio::time::sleep(Duration::from_secs_f64(interval_secs.max(0.1))).await;
    }
}

fn load_history(dir: &Path) -> Result<HistoryDocument, String> {
    let store = HistoryStore::new(dir);
    store.read().ok_or_else(|| {
        format!(
            "No history at {}. Run `tempo serve` first.",
            store.path.display()
        )
    })
}

fn history(dir: &Path, what: HistoryCmd) -> Result<(), String> {
    let tz = TimeZone::system();
    let now = Timestamp::now();
    match what {
        HistoryCmd::Today { json } => {
            let doc = load_history(dir)?;
            // The archive's day runs only to when it was written: presence after that is
            // unknown, and counting it up to now would grow the total while nobody can see
            // the desk.
            let end = now.min(doc.written_at);
            let day_start = rollup::day_start(now, &tz, doc.middle_of_night_hour);
            if end < day_start {
                return Err("No desk data for today yet.".into());
            }
            let mut today = rollup::compute(RollupInput {
                paused: true,
                standing_threshold_inches: doc.standing_threshold_inches,
                ..RollupInput::new(&doc.events, end, day_start)
            });
            today.next_move = None;
            let segments =
                timeline::segments(&doc.events, day_start, end, doc.standing_threshold_inches);
            if json {
                let out = serde_json::json!({ "dayStart": iso8601_seconds::format(day_start), "asOf": iso8601_seconds::format(end), "today": today, "segments": segments });
                println!(
                    "{}",
                    serde_json::to_string_pretty(&out).map_err(|e| e.to_string())?
                );
            } else {
                println!(
                    "As of {}: {} at the desk, {} stands.",
                    local(end, &tz),
                    format::duration(today.at_desk_seconds),
                    today.stands
                );
                for seg in segments {
                    println!(
                        "  {}  {}  {:<8} {}",
                        local(seg.start, &tz),
                        local(seg.end, &tz),
                        format!("{:?}", seg.state).to_lowercase(),
                        format::duration(seg.duration())
                    );
                }
            }
        }
        HistoryCmd::Totals { days, json } => {
            let doc = load_history(dir)?;
            let today = rollup::day_start(now, &tz, doc.middle_of_night_hour);
            let mut starts = Vec::new();
            let mut cursor = today;
            for _ in 0..days.max(1) {
                starts.push(cursor);
                cursor = cursor
                    .to_zoned(tz.clone())
                    .checked_sub(jiff::Span::new().days(1))
                    .map(|z| z.timestamp())
                    .unwrap_or(cursor - jiff::SignedDuration::from_hours(24));
            }
            starts.reverse();
            let totals = timeline::totals(
                &doc.events,
                &starts,
                doc.standing_threshold_inches,
                now.min(doc.written_at),
                &tz,
            );
            if json {
                println!(
                    "{}",
                    serde_json::to_string_pretty(&totals).map_err(|e| e.to_string())?
                );
            } else {
                println!(
                    "{:<12} {:>9} {:>9} {:>9} {:>6}",
                    "day", "standing", "sitting", "away", "stands"
                );
                for t in totals {
                    println!(
                        "{:<12} {:>9} {:>9} {:>9} {:>6}",
                        t.day.to_zoned(tz.clone()).strftime("%Y-%m-%d"),
                        format::duration(t.standing),
                        format::duration(t.sitting),
                        format::duration(t.away),
                        t.stands
                    );
                }
            }
        }
        HistoryCmd::Export => {
            let doc = load_history(dir)?;
            println!(
                "{}",
                serde_json::to_string_pretty(&doc).map_err(|e| e.to_string())?
            );
        }
    }
    Ok(())
}

fn local(ts: Timestamp, tz: &TimeZone) -> String {
    ts.to_zoned(tz.clone()).strftime("%H:%M").to_string()
}

async fn send(dir: &Path, command: Command) -> Result<(), String> {
    let queue = CommandQueue::new(dir);
    match tempo_desk::commands::send(
        &queue,
        command,
        Duration::from_secs(15),
        Duration::from_millis(250),
    )
    .await
    {
        Some(result) if result.success => {
            println!("{}", result.message.unwrap_or_else(|| "Done.".into()));
            Ok(())
        }
        Some(result) => Err(result
            .message
            .unwrap_or_else(|| "The desk refused the command.".into())),
        None => Err("No answer from the Tempo service. Is `tempo serve` running?".into()),
    }
}

fn backup(dir: &Path, to: Option<PathBuf>) -> Result<(), String> {
    let store = HistoryStore::new(dir);
    let bytes = std::fs::read(&store.path)
        .map_err(|e| format!("Cannot read {}: {e}", store.path.display()))?;
    let doc: HistoryDocument = serde_json::from_slice(&bytes)
        .map_err(|e| format!("{} does not parse: {e}", store.path.display()))?;
    let target_dir = to.unwrap_or_else(|| store.backups_dir());
    std::fs::create_dir_all(&target_dir).map_err(|e| e.to_string())?;
    let day = &iso8601_seconds::format(doc.written_at)[..10];
    let target = target_dir.join(format!("history-{day}.json"));
    tempo_core::store::write_atomic(&target, &bytes).map_err(|e| e.to_string())?;
    println!(
        "Backed up {} events to {}",
        doc.events.len(),
        target.display()
    );
    Ok(())
}
