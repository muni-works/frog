//! The second core: draws the bottom half of each strip while the main task draws the top.

use crate::draw_rows;
use esp_idf_svc::hal::cpu::Core;
use esp_idf_svc::hal::task::thread::ThreadSpawnConfiguration;
use puck::canvas::Canvas;
use puck::demo::Sim;
use std::sync::mpsc::{Receiver, SyncSender, sync_channel};

struct Job {
    sim: *const Sim,
    y: usize,
    rows: usize,
    out: *mut u8,
    len: usize,
}

// The pointers are only used between `start` and `wait`, while the caller keeps both alive and
// untouched.
unsafe impl Send for Job {}

pub struct Worker {
    jobs: SyncSender<Job>,
    done: Receiver<()>,
}

impl Worker {
    pub fn spawn(mut band: Canvas) -> Self {
        let (jobs, rx) = sync_channel::<Job>(1);
        let (done_tx, done) = sync_channel(1);
        ThreadSpawnConfiguration {
            name: Some(c"draw1"),
            stack_size: 16 * 1024,
            pin_to_core: Some(Core::Core1),
            ..Default::default()
        }
        .set()
        .expect("thread config");
        std::thread::spawn(move || {
            for j in rx {
                let (sim, out) = unsafe { (&*j.sim, std::slice::from_raw_parts_mut(j.out, j.len)) };
                draw_rows(&mut band, sim, j.y, j.rows, out);
                if done_tx.send(()).is_err() {
                    break;
                }
            }
        });
        ThreadSpawnConfiguration::default()
            .set()
            .expect("thread config");
        Self { jobs, done }
    }

    /// Draw `rows` rows from glass row `y` into `out` on the other core.
    ///
    /// # Safety
    /// `sim` and `out` must stay alive and unmodified until [`Worker::wait`] returns.
    pub unsafe fn start(&self, sim: &Sim, y: usize, rows: usize, out: &mut [u8]) {
        let job = Job {
            sim,
            y,
            rows,
            out: out.as_mut_ptr(),
            len: out.len(),
        };
        self.jobs.send(job).expect("worker gone");
    }

    pub fn wait(&self) {
        self.done.recv().expect("worker gone");
    }
}
