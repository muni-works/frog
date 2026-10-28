//! The eyes find you: a webcam, a face detector, and where the nearest face is.
//!
//! A thread pulls frames from the camera (nokhwa: AVFoundation on macOS, V4L2 on the Jetson), shrinks them to a small
//! grey image and runs SeetaFace's frontal detector over it (rustface, pure Rust). The biggest face is the person
//! nearest the head; its centre, as the face's gaze (-1..1 each way, x toward the viewer's right, y down), is kept
//! for the render loop to read.

use anyhow::{Context, Result};
use nokhwa::Camera;
use nokhwa::pixel_format::RgbFormat;
use nokhwa::utils::{CameraIndex, RequestedFormat, RequestedFormatType};
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

/// Detection runs on frames this wide: plenty for a face across a room, cheap on an A78.
const WIDTH: u32 = 320;
/// A sighting older than this is no sighting.
const STALE: Duration = Duration::from_millis(600);
/// The last sighting: when, and where (gaze -1..1).
type Seen = Mutex<Option<(Instant, (f32, f32))>>;

/// Where SeetaFace's model lives when `--face-model` doesn't say.
pub fn default_model() -> PathBuf {
    let home = PathBuf::from(std::env::var("HOME").unwrap_or_default());
    home.join(".local/share/node-face/seeta_fd_frontal_v1.0.bin")
}

pub struct Eyes {
    seen: Arc<Seen>,
}

impl Eyes {
    /// Start watching camera `index`. Fails now if the model's missing; a camera that won't open is logged by the
    /// thread, and the face just never sees anyone.
    pub fn spawn(index: u32, model: PathBuf) -> Result<Self> {
        let path = model
            .to_str()
            .context("face model path isn't UTF-8")?
            .to_string();
        anyhow::ensure!(
            model.is_file(),
            "no face model at {path}: get seeta_fd_frontal_v1.0.bin from rustface's model/ folder"
        );
        let seen = Arc::new(Mutex::new(None));
        let out = seen.clone();
        nokhwa::nokhwa_initialize(|_| {}); // macOS asks for camera access once
        std::thread::spawn(move || {
            // the detector isn't Send: it's made where it runs
            let det = rustface::create_detector(&path).map_err(anyhow::Error::from);
            if let Err(e) = det.and_then(|det| watch(index, det, &out)) {
                eprintln!("camera: {e:#}");
            }
        });
        Ok(Self { seen })
    }

    /// Where the nearest face is, if one's been seen in the last moment.
    pub fn person(&self) -> Option<(f32, f32)> {
        let s = *self.seen.lock().unwrap();
        s.filter(|(at, _)| at.elapsed() < STALE).map(|(_, p)| p)
    }
}

fn watch(index: u32, mut det: Box<dyn rustface::Detector>, out: &Seen) -> Result<()> {
    det.set_min_face_size(24);
    det.set_score_thresh(2.0);
    det.set_pyramid_scale_factor(0.8);
    det.set_slide_window_step(4, 4);
    let fmt = RequestedFormat::new::<RgbFormat>(RequestedFormatType::AbsoluteHighestFrameRate);
    if !nokhwa::nokhwa_check() {
        eprintln!(
            "camera: no access yet (macOS: allow the app that launched node-face under Privacy & Security > Camera)"
        );
    }
    let mut cam = Camera::new(CameraIndex::Index(index), fmt).context("opening the camera")?;
    cam.open_stream().context("starting the camera")?;
    let mut grey = Vec::new();
    loop {
        let img = cam.frame()?.decode_image::<RgbFormat>()?;
        let (w, h) = (img.width(), img.height());
        // shrink to WIDTH wide, box-averaged, straight to grey
        let s = (w / WIDTH).max(1);
        let (gw, gh) = (w / s, h / s);
        let px = img.as_raw();
        grey.clear();
        grey.extend(
            (0..gh)
                .flat_map(|y| (0..gw).map(move |x| (x, y)))
                .map(|(x, y)| {
                    let mut sum = 0u32;
                    for dy in 0..s {
                        for dx in 0..s {
                            let i = (((y * s + dy) * w + x * s + dx) * 3) as usize;
                            sum += (px[i] as u32 * 77
                                + px[i + 1] as u32 * 150
                                + px[i + 2] as u32 * 29)
                                >> 8;
                        }
                    }
                    (sum / (s * s)) as u8
                }),
        );
        let faces = det.detect(&rustface::ImageData::new(&grey, gw, gh));
        let near = faces
            .iter()
            .max_by_key(|f| f.bbox().width() * f.bbox().height());
        if let Some(f) = near {
            let b = f.bbox();
            let cx = (b.x() as f32 + b.width() as f32 / 2.0) / gw as f32;
            let cy = (b.y() as f32 + b.height() as f32 / 2.0) / gh as f32;
            // The camera sees you mirrored: a person to the viewer's right is on the image's left.
            let at = ((0.5 - cx) * 2.2, (cy - 0.45) * 1.8);
            *out.lock().unwrap() = Some((
                Instant::now(),
                (at.0.clamp(-1.0, 1.0), at.1.clamp(-1.0, 1.0)),
            ));
        }
    }
}
