//! Where a moving desk is going to stop.
//!
//! The desk clears its motion bit before it has finished travelling (observed live: last
//! moving sample 40.5 in, settled at 41.1 in about a second later), and a paddle release
//! coasts the same way. So every move has an *overshoot*: the distance from the height
//! where the motor was told to stop to the height it actually stops at. This model learns
//! that overshoot from each move it watches and predicts the final height of the one under
//! way, so a UI can land on the right number before the desk does, and a manual move can
//! be shown with "where it stops if you let go now".
//!
//! Two estimates are blended, per direction (up and down coast differently: the desk
//! fights gravity one way and is helped by it the other):
//!
//! * **Physics.** A motor stopping under constant deceleration `a` from speed `v` travels
//!   `v² / 2a`. `v` is a least-squares slope over the last fraction of a second of moving
//!   samples; `a` is learned from every completed move (`v² / 2·overshoot`) by exponential
//!   averaging, seeded from the one measurement on record (1.5 in/s, 0.6 in of coast).
//! * **Memory.** The median of the last few overshoots seen in that direction, which needs
//!   no speed estimate at all and is what the physics converges to when speed is constant.
//!
//! With only a sample or two the memory is weak, so the blend leans on physics; once there
//! is a history it is an even split. Predictions are clamped to a sane range: a garbled
//! sample must not promise three inches of travel.

use std::collections::VecDeque;

use jiff::{SignedDuration, Timestamp};

use crate::registers::StatusWord;

/// Tenths of an inch per second the desk travels at full speed (1.5 in/s, measured on
/// 2026-09-11: 1.1 in in the ~0.73 s between the motor starting and the first moving sample).
pub const CRUISE_SPEED_TENTHS_PER_S: f64 = 15.0;

/// Coast on record before any move has been learned: 40.5 -> 41.1 in on 2026-09-08.
const DEFAULT_COAST_TENTHS: f64 = 6.0;

/// Deceleration implied by that one measurement at cruise speed: `v² / 2d` = 225 / 12.
const DEFAULT_DECEL_TENTHS_PER_S2: f64 = 18.75;

/// The longest coast ever worth predicting (3 in). Beyond this a reading is noise.
const MAX_COAST_TENTHS: f64 = 30.0;

/// Samples older than this no longer describe the current speed.
const SPEED_WINDOW: SignedDuration = SignedDuration::from_millis(1200);

/// Two samples closer than this in time give a slope that is mostly jitter.
const MIN_SPEED_SPAN: SignedDuration = SignedDuration::from_millis(200);

/// How many overshoots per direction the memory keeps.
const MEMORY: usize = 8;

/// Weight of a new deceleration measurement against the running one.
const DECEL_GAIN: f64 = 0.3;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Direction {
    Up,
    Down,
}

impl Direction {
    const fn sign(self) -> f64 {
        match self {
            Direction::Up => 1.0,
            Direction::Down => -1.0,
        }
    }

    const fn name(self) -> &'static str {
        match self {
            Direction::Up => "up",
            Direction::Down => "down",
        }
    }
}

/// What the model knows about one direction of travel.
#[derive(Clone, Debug)]
struct DirectionModel {
    decel: f64,
    /// Overshoots seen, in tenths, newest last.
    coasts: VecDeque<f64>,
    learned: usize,
}

impl Default for DirectionModel {
    fn default() -> Self {
        Self {
            decel: DEFAULT_DECEL_TENTHS_PER_S2,
            coasts: VecDeque::with_capacity(MEMORY),
            learned: 0,
        }
    }
}

impl DirectionModel {
    fn median_coast(&self) -> Option<f64> {
        if self.coasts.is_empty() {
            return None;
        }
        let mut sorted: Vec<f64> = self.coasts.iter().copied().collect();
        sorted.sort_by(|a, b| a.total_cmp(b));
        let n = sorted.len();
        Some(if n % 2 == 1 {
            sorted[n / 2]
        } else {
            (sorted[n / 2 - 1] + sorted[n / 2]) / 2.0
        })
    }

    /// Expected coast, in tenths, for a release at `speed` tenths per second (absolute).
    fn expect(&self, speed: Option<f64>) -> f64 {
        let physics = speed.map(|v| (v * v / (2.0 * self.decel)).clamp(0.0, MAX_COAST_TENTHS));
        let memory = self.median_coast();
        let estimate = match (physics, memory) {
            (Some(p), Some(m)) => {
                // Memory earns its half once it has a few moves behind it.
                let w = (self.coasts.len() as f64 / 3.0).min(1.0) * 0.5;
                p * (1.0 - w) + m * w
            }
            (Some(p), None) => p,
            (None, Some(m)) => m,
            (None, None) => DEFAULT_COAST_TENTHS,
        };
        estimate.clamp(0.0, MAX_COAST_TENTHS)
    }

    fn learn(&mut self, coast: f64, speed: Option<f64>) {
        if self.coasts.len() == MEMORY {
            self.coasts.pop_front();
        }
        self.coasts.push_back(coast);
        self.learned += 1;
        if let Some(v) = speed.filter(|v| *v > 1.0) {
            if coast > 0.5 {
                let observed = (v * v / (2.0 * coast)).clamp(1.0, 1000.0);
                self.decel = if self.learned == 1 {
                    observed
                } else {
                    self.decel * (1.0 - DECEL_GAIN) + observed * DECEL_GAIN
                };
            }
        }
    }
}

/// The motor has been told to stop (the motion bit fell) and the desk is coasting.
#[derive(Clone, Copy, Debug, PartialEq)]
struct Release {
    at: Timestamp,
    height: u16,
    direction: Direction,
    speed: Option<f64>,
    predicted: u16,
}

/// Where the desk is heading, published while it moves and coasts.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Prediction {
    /// The height the desk should come to rest at.
    pub final_tenths: u16,
    pub direction: Direction,
    /// True once the motor has stopped and only the coast is left; false while still
    /// driven, when the figure is "where it stops if released now".
    pub coasting: bool,
    /// Tenths per second, when the last fraction of a second allowed an estimate.
    pub speed_tenths_per_s: Option<f64>,
}

/// What a completed move taught the model.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Lesson {
    pub direction: Direction,
    pub released_at_tenths: u16,
    pub settled_tenths: u16,
    pub coast_tenths: i32,
    pub predicted_tenths: u16,
    pub speed_tenths_per_s: Option<f64>,
}

#[derive(Clone, Debug, Default)]
pub struct CoastModel {
    up: DirectionModel,
    down: DirectionModel,
    /// Moving samples inside `SPEED_WINDOW`: (wall time, height).
    samples: VecDeque<(Timestamp, u16)>,
    last: Option<StatusWord>,
    /// Height when the current stretch of motion began, for the direction when the speed
    /// window is too short to say.
    motion_from: Option<u16>,
    release: Option<Release>,
    /// The height the previous stationary sample held, to call a settle on two in a row.
    held: Option<u16>,
}

impl CoastModel {
    pub fn new() -> Self {
        Self::default()
    }

    /// After a reconnect: the samples no longer join up, but what was learned stays.
    pub fn forget_motion(&mut self) {
        self.samples.clear();
        self.last = None;
        self.motion_from = None;
        self.release = None;
        self.held = None;
    }

    fn model(&self, direction: Direction) -> &DirectionModel {
        match direction {
            Direction::Up => &self.up,
            Direction::Down => &self.down,
        }
    }

    fn model_mut(&mut self, direction: Direction) -> &mut DirectionModel {
        match direction {
            Direction::Up => &mut self.up,
            Direction::Down => &mut self.down,
        }
    }

    /// Least-squares slope of the moving samples in the window, tenths per second, signed.
    fn speed(&self) -> Option<f64> {
        let (first, last) = (self.samples.front()?, self.samples.back()?);
        if last.0.duration_since(first.0) < MIN_SPEED_SPAN {
            return None;
        }
        let n = self.samples.len() as f64;
        let t0 = first.0;
        let xs = self
            .samples
            .iter()
            .map(|(t, h)| (t.duration_since(t0).as_secs_f64(), f64::from(*h)));
        let (mut sx, mut sy, mut sxx, mut sxy) = (0.0, 0.0, 0.0, 0.0);
        for (x, y) in xs {
            sx += x;
            sy += y;
            sxx += x * x;
            sxy += x * y;
        }
        let denominator = n * sxx - sx * sx;
        if denominator.abs() < f64::EPSILON {
            return None;
        }
        Some((n * sxy - sx * sy) / denominator)
    }

    fn direction(&self, height: u16, speed: Option<f64>) -> Option<Direction> {
        if let Some(v) = speed.filter(|v| v.abs() >= 1.0) {
            return Some(if v > 0.0 {
                Direction::Up
            } else {
                Direction::Down
            });
        }
        let from = self.motion_from?;
        match height.cmp(&from) {
            std::cmp::Ordering::Greater => Some(Direction::Up),
            std::cmp::Ordering::Less => Some(Direction::Down),
            std::cmp::Ordering::Equal => None,
        }
    }

    fn predict(&self, height: u16, direction: Direction, speed: Option<f64>) -> u16 {
        let coast = self.model(direction).expect(speed.map(f64::abs));
        let target = f64::from(height) + direction.sign() * coast;
        target.round().clamp(0.0, f64::from(u16::MAX)) as u16
    }

    /// One status sample on the wall clock. Returns what to publish, and what the sample
    /// taught if it closed a move.
    pub fn observe(
        &mut self,
        word: StatusWord,
        wall: Timestamp,
    ) -> (Option<Prediction>, Option<Lesson>) {
        let previous = self.last.replace(word);
        if word.is_moving {
            self.held = None;
            self.release = None;
            if !previous.is_some_and(|p| p.is_moving) {
                self.samples.clear();
                self.motion_from = Some(previous.map_or(word.height_tenths, |p| p.height_tenths));
            }
            self.samples.push_back((wall, word.height_tenths));
            while self
                .samples
                .front()
                .is_some_and(|(t, _)| wall.duration_since(*t) > SPEED_WINDOW)
            {
                self.samples.pop_front();
            }
            let speed = self.speed();
            let prediction =
                self.direction(word.height_tenths, speed)
                    .map(|direction| Prediction {
                        final_tenths: self.predict(word.height_tenths, direction, speed),
                        direction,
                        coasting: false,
                        speed_tenths_per_s: speed,
                    });
            return (prediction, None);
        }
        // Stationary. The motor just stopped: the coast begins here.
        if previous.is_some_and(|p| p.is_moving) {
            let speed = self.speed();
            if let Some(direction) = self.direction(word.height_tenths, speed) {
                let predicted = self.predict(word.height_tenths, direction, speed);
                self.release = Some(Release {
                    at: wall,
                    height: word.height_tenths,
                    direction,
                    speed: speed.map(f64::abs),
                    predicted,
                });
                self.held = Some(word.height_tenths);
                return (
                    Some(Prediction {
                        final_tenths: predicted,
                        direction,
                        coasting: true,
                        speed_tenths_per_s: speed,
                    }),
                    None,
                );
            }
            self.samples.clear();
            self.motion_from = None;
            return (None, None);
        }
        let Some(release) = self.release else {
            self.samples.clear();
            self.motion_from = None;
            return (None, None);
        };
        // Coasting: settled once two stationary samples agree, and not before a coast
        // could plausibly have ended (the first repeat can land within the same 250 ms).
        if self.held == Some(word.height_tenths)
            && wall.duration_since(release.at) >= MIN_SPEED_SPAN
        {
            let coast = i32::from(word.height_tenths) - i32::from(release.height);
            let along = f64::from(coast) * release.direction.sign();
            if (0.0..=MAX_COAST_TENTHS).contains(&along) {
                self.model_mut(release.direction)
                    .learn(along, release.speed);
            }
            self.release = None;
            self.held = None;
            self.samples.clear();
            self.motion_from = None;
            return (
                None,
                Some(Lesson {
                    direction: release.direction,
                    released_at_tenths: release.height,
                    settled_tenths: word.height_tenths,
                    coast_tenths: coast,
                    predicted_tenths: release.predicted,
                    speed_tenths_per_s: release.speed,
                }),
            );
        }
        self.held = Some(word.height_tenths);
        (
            Some(Prediction {
                final_tenths: release.predicted,
                direction: release.direction,
                coasting: true,
                speed_tenths_per_s: release.speed,
            }),
            None,
        )
    }

    /// The learned state, one line per direction, for the log.
    pub fn describe(&self) -> String {
        let one = |d: Direction, m: &DirectionModel| {
            format!(
                "{}: decel={:.1} coast~{} n={}",
                d.name(),
                m.decel,
                m.median_coast()
                    .map_or_else(|| "?".to_string(), |c| format!("{c:.1}")),
                m.learned
            )
        };
        format!(
            "{} {}",
            one(Direction::Up, &self.up),
            one(Direction::Down, &self.down)
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn t0() -> Timestamp {
        Timestamp::from_second(1_800_000_000).unwrap()
    }
    fn ms(n: i64) -> Timestamp {
        t0() + SignedDuration::from_millis(n)
    }
    fn moving(h: u16) -> StatusWord {
        StatusWord::from_raw(0x8000_0000 | u32::from(h))
    }
    fn still(h: u16) -> StatusWord {
        StatusWord::from_raw(u32::from(h))
    }

    /// Drives a full rise at 15 tenths/s sampled every 250 ms, released at `release`,
    /// settling `coast` tenths further.
    fn rise(
        m: &mut CoastModel,
        start: u16,
        release: u16,
        coast: u16,
        base_ms: i64,
    ) -> Option<Lesson> {
        let mut h = start;
        let mut t = base_ms;
        m.observe(still(start), ms(t));
        while h < release {
            t += 250;
            h = (h + 4).min(release);
            m.observe(moving(h), ms(t));
        }
        t += 250;
        let (p, _) = m.observe(still(release), ms(t));
        assert!(p.unwrap().coasting);
        t += 250;
        m.observe(still(release + coast), ms(t));
        t += 250;
        let (p, lesson) = m.observe(still(release + coast), ms(t));
        assert!(p.is_none(), "settled: nothing left to predict");
        lesson
    }

    #[test]
    fn predicts_the_default_coast_before_learning_anything() {
        let mut m = CoastModel::new();
        m.observe(still(267), ms(0));
        m.observe(moving(271), ms(250));
        let (p, _) = m.observe(moving(275), ms(500));
        let p = p.unwrap();
        assert_eq!(p.direction, Direction::Up);
        assert!(!p.coasting);
        let v = p.speed_tenths_per_s.unwrap();
        assert!((v - 16.0).abs() < 0.01, "slope of 4 tenths per 250 ms: {v}");
        // Physics at 16 tenths/s with the seed deceleration: 256 / 37.5 = 6.8 tenths.
        assert_eq!(p.final_tenths, 275 + 7);
    }

    #[test]
    fn release_freezes_the_prediction_and_the_settle_teaches() {
        let mut m = CoastModel::new();
        let lesson = rise(&mut m, 267, 403, 6, 0).unwrap();
        assert_eq!(lesson.direction, Direction::Up);
        assert_eq!(
            (lesson.released_at_tenths, lesson.settled_tenths),
            (403, 409)
        );
        assert_eq!(lesson.coast_tenths, 6);
        assert!((lesson.speed_tenths_per_s.unwrap() - 16.0).abs() < 0.01);
        assert!(m.up.learned == 1 && m.down.learned == 0);
        // Deceleration now fits what was seen: 256 / 12 = 21.3.
        assert!((m.up.decel - 21.33).abs() < 0.1, "{}", m.up.decel);
    }

    #[test]
    fn learns_a_direction_and_predicts_it_better_than_the_seed() {
        let mut m = CoastModel::new();
        // A desk that coasts 10 tenths going up, every time.
        for i in 0..4 {
            rise(&mut m, 267, 403, 10, i * 60_000);
        }
        m.observe(still(267), ms(300_000));
        m.observe(moving(271), ms(300_250));
        m.observe(moving(275), ms(300_500));
        let (p, _) = m.observe(still(275), ms(300_750));
        let p = p.unwrap();
        assert!(
            (284..=286).contains(&p.final_tenths),
            "memory and physics agree on ~10: {}",
            p.final_tenths
        );
        assert!(m.describe().starts_with("up: decel="));
    }

    #[test]
    fn down_is_learned_separately() {
        let mut m = CoastModel::new();
        m.observe(still(411), ms(0));
        m.observe(moving(407), ms(250));
        m.observe(moving(403), ms(500));
        let (p, _) = m.observe(still(403), ms(750));
        let p = p.unwrap();
        assert_eq!(p.direction, Direction::Down);
        assert!(p.final_tenths < 403);
        m.observe(still(399), ms(1000));
        let (_, lesson) = m.observe(still(399), ms(1250));
        let lesson = lesson.unwrap();
        assert_eq!(lesson.coast_tenths, -4);
        assert_eq!(m.down.learned, 1);
        assert_eq!(m.up.learned, 0);
    }

    #[test]
    fn a_reversal_during_the_coast_is_not_learned() {
        let mut m = CoastModel::new();
        m.observe(still(267), ms(0));
        m.observe(moving(271), ms(250));
        m.observe(moving(275), ms(500));
        m.observe(still(275), ms(750));
        // The user tapped the paddle down: the desk ends below where the motor stopped.
        m.observe(still(270), ms(1000));
        let (_, lesson) = m.observe(still(270), ms(1250));
        assert!(lesson.is_some());
        assert_eq!(m.up.learned, 0, "a negative coast is not a coast");
    }

    #[test]
    fn a_single_moving_sample_still_predicts_from_the_start_height() {
        let mut m = CoastModel::new();
        m.observe(still(267), ms(0));
        let (p, _) = m.observe(moving(280), ms(1000));
        let p = p.unwrap();
        assert_eq!(
            p.direction,
            Direction::Up,
            "no slope yet: direction from where it started"
        );
        assert!(p.speed_tenths_per_s.is_none());
        assert_eq!(p.final_tenths, 286, "the default coast");
    }

    #[test]
    fn forgetting_motion_keeps_the_lessons() {
        let mut m = CoastModel::new();
        rise(&mut m, 267, 403, 6, 0);
        m.forget_motion();
        assert_eq!(m.up.learned, 1);
        let (p, lesson) = m.observe(still(411), ms(99_000));
        assert!(p.is_none() && lesson.is_none());
    }
}
