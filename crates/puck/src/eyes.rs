//! The pupils are physical: each one is the bob of a two-axis pendulum hung in its socket and
//! simulated with phyz. Gravity comes from the IMU, so tilting the puck rolls the pupils toward
//! the low side and shaking it makes them jiggle. A spring on each joint pulls toward where the
//! frog wants to look, and the joint limits are the socket wall.
//!
//! Device frame: x right, y up the glass, z out of the glass toward you. Lying flat face-up,
//! gravity is -z and the bob hangs straight back, which puts the pupil in the middle.

use phyz::model::Joint;
use phyz::rigid::aba;
use phyz::{Mat3, Model, ModelBuilder, SpatialInertia, SpatialTransform, State, Vec3};

/// How far the pendulum may swing before it hits the socket wall (radians).
const LIMIT: f64 = 0.6;
/// The physics runs on its own fixed step, independent of the frame rate.
const HZ: f64 = 240.0;
/// Gravity is artistic, not 9.81: it sets how strongly a tilt beats the gaze spring.
const G: f64 = 200.0;

/// Joint tuning. Two eyes get slightly different damping so they never move in perfect lockstep.
struct Tune {
    stiffness: f64,
    damping: f64,
}
const TUNE: [Tune; 2] = [
    Tune {
        stiffness: 400.0,
        damping: 9.0,
    },
    Tune {
        stiffness: 400.0,
        damping: 10.5,
    },
];

pub struct Eyes {
    model: Model,
    state: State,
    acc: f64,
    dt: f64,
    /// Where the frog wants to look, each axis in -1..=1 (x right, y up).
    pub gaze: (f64, f64),
}

impl Default for Eyes {
    fn default() -> Self {
        Self::new()
    }
}

impl Eyes {
    pub fn new() -> Self {
        Self::with_rate(HZ)
    }

    /// Step the physics `hz` times a second. The device can't afford 240 Hz in f64; the pendulums
    /// stay stable down to about 60.
    pub fn with_rate(hz: f64) -> Self {
        let dt = 1.0 / hz;
        let link = SpatialInertia::new(
            1e-3,
            Vec3::zeros(),
            Mat3::from_diagonal(&Vec3::new(1e-4, 1e-4, 1e-4)),
        );
        let bob = SpatialInertia::new(
            1.0,
            Vec3::new(0.0, 0.0, -1.0),
            Mat3::from_diagonal(&Vec3::new(1e-3, 1e-3, 1e-3)),
        );
        let joint = |axis: Vec3, t: &Tune| {
            let mut j = Joint::revolute(SpatialTransform::identity());
            j.axis = axis;
            j.stiffness = t.stiffness;
            j.damping = t.damping;
            j.limits = Some([-LIMIT, LIMIT]);
            j.limit_stiffness = 2000.0;
            j.limit_damping = 30.0;
            j
        };
        let mut b = ModelBuilder::new().gravity(Vec3::new(0.0, 0.0, -G)).dt(dt);
        for (eye, t) in TUNE.iter().enumerate() {
            // pitch about x, then yaw about y, then the bob one unit behind the pivot
            let base = (eye * 2) as i32;
            b = b
                .add_body(
                    &format!("socket{eye}"),
                    -1,
                    joint(Vec3::new(1.0, 0.0, 0.0), t),
                    link,
                )
                .add_body(
                    &format!("pupil{eye}"),
                    base,
                    joint(Vec3::new(0.0, 1.0, 0.0), t),
                    bob,
                );
        }
        let model = b.build();
        let state = model.default_state();
        Self {
            model,
            state,
            acc: 0.0,
            dt,
            gaze: (0.0, 0.0),
        }
    }

    /// Gravity in the device frame, as the IMU reports it (any magnitude; only direction is used),
    /// plus `shake`, the device's own acceleration in g, which the pupils feel as a push the other way.
    pub fn set_gravity(&mut self, down: [f64; 3], shake: [f64; 3]) {
        let n = (down[0] * down[0] + down[1] * down[1] + down[2] * down[2])
            .sqrt()
            .max(1e-6);
        let g = Vec3::new(
            down[0] / n - shake[0],
            down[1] / n - shake[1],
            down[2] / n - shake[2],
        );
        self.model.gravity = g * G;
    }

    /// Advance by `dt` seconds of wall time.
    pub fn step(&mut self, dt: f64) {
        // The gaze target is the spring's rest angle.
        let (tx, ty) = (self.gaze.0.clamp(-1.0, 1.0), self.gaze.1.clamp(-1.0, 1.0));
        let s = LIMIT.sin() * 0.95;
        for eye in 0..2 {
            self.model.joints[eye * 2].spring_ref = (ty * s).asin() * PITCH_SIGN;
            self.model.joints[eye * 2 + 1].spring_ref = (tx * s).asin() * YAW_SIGN;
        }
        self.acc += dt.min(0.1);
        let dt = self.dt;
        while self.acc >= dt {
            // Semi-implicit Euler over aba, which already includes the springs, damping and soft
            // limits. Every joint is revolute, so q += v·dt is exact bookkeeping.
            let qdd = aba(&self.model, &self.state);
            self.state.v += &(&qdd * dt);
            let v = self.state.v.clone();
            self.state.q += &(&v * dt);
            self.acc -= dt;
        }
    }

    /// Each pupil's offset from the middle of its eye, each axis in -1..=1 of the travel available
    /// (x right, y down, as screen pixels go).
    pub fn pupils(&self) -> [(f32, f32); 2] {
        let k = 1.0 / LIMIT.sin();
        [0, 1].map(|eye| {
            let (q0, q1) = (self.state.q[eye * 2], self.state.q[eye * 2 + 1]);
            let x = q1.sin() * YAW_SIGN * k;
            let y = -(q0.sin() * q1.cos()) * PITCH_SIGN * k;
            // The soft limit lets the bob press a little past the wall; the drawn pupil stops at it.
            let r = (x * x + y * y).sqrt().max(1.0);
            ((x / r) as f32, (y / r) as f32)
        })
    }
}

// Which way a positive joint angle moves the bob on the glass, worked out by the tests below.
const PITCH_SIGN: f64 = 1.0;
const YAW_SIGN: f64 = -1.0;

#[cfg(test)]
mod tests {
    use super::*;

    /// The host's rate and the device's.
    const RATES: [f64; 2] = [HZ, 60.0];

    fn settle(e: &mut Eyes) {
        for _ in 0..600 {
            e.step(1.0 / 60.0);
        }
    }

    #[test]
    fn flat_and_looking_ahead_means_centered() {
        for hz in RATES {
            let mut e = Eyes::with_rate(hz);
            settle(&mut e);
            for (x, y) in e.pupils() {
                assert!(x.abs() < 0.02 && y.abs() < 0.02, "{x} {y}");
            }
        }
    }

    #[test]
    fn tilting_rolls_pupils_downhill() {
        // Bottom edge lowered: gravity points down the glass (-y), so pupils move down (+y on screen).
        for hz in RATES {
            let mut e = Eyes::with_rate(hz);
            e.set_gravity([0.0, -0.7, -0.7], [0.0; 3]);
            settle(&mut e);
            for (x, y) in e.pupils() {
                assert!(y > 0.3 && x.abs() < 0.05, "{x} {y}");
            }
            // Right edge lowered: pupils roll right.
            e.set_gravity([0.7, 0.0, -0.7], [0.0; 3]);
            settle(&mut e);
            for (x, y) in e.pupils() {
                assert!(x > 0.3 && y.abs() < 0.05, "{x} {y}");
            }
        }
    }

    #[test]
    fn gaze_pulls_against_gravity() {
        for hz in RATES {
            let mut e = Eyes::with_rate(hz);
            e.gaze = (0.8, 0.8); // up and to the right
            settle(&mut e);
            for (x, y) in e.pupils() {
                assert!(x > 0.3 && y < -0.3, "{x} {y}");
            }
        }
    }

    #[test]
    fn pupils_stay_in_their_sockets() {
        for hz in RATES {
            let mut e = Eyes::with_rate(hz);
            e.set_gravity([0.0, -1.0, 0.0], [0.0, 3.0, 0.0]); // on its edge, being shaken
            for _ in 0..300 {
                e.step(1.0 / 60.0);
                for (x, y) in e.pupils() {
                    assert!((x * x + y * y).sqrt() <= 1.0 + 1e-6, "{x} {y}");
                }
            }
        }
    }
}
