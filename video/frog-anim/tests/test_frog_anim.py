"""frog-anim tests (stdlib unittest).

    cd video/frog-anim && uv run --no-project --with pillow==12.0.0 --with numpy==2.3.4 python -m unittest -v

The reel comparison (test_reel_matches_before) runs only when FROG_ANIM_REEL_BEFORE points at a
directory of the reel's frames rendered before the move, and the reel's footage/ exists."""
from __future__ import annotations

import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

import numpy as np
from PIL import Image

PKG = Path(__file__).resolve().parent.parent
REPO = PKG.parent.parent
sys.path.insert(0, str(PKG))

from frog_anim import ACTIONS, MARK, MOODS, layout, render_frame  # noqa: E402
from frog_anim.cli import main as cli_main, mark_tokens  # noqa: E402
from frog_anim.mark import SMILE  # noqa: E402
from frog_anim.motion import Move  # noqa: E402
from frog_anim.sprite import place, sprite  # noqa: E402

HAVE_FFMPEG = shutil.which("ffmpeg") is not None


def digest(im: Image.Image) -> str:
    return hashlib.sha256(im.mode.encode() + repr(im.size).encode() + im.tobytes()).hexdigest()


def probe(path: Path, decoder: list[str] | None = None) -> dict:
    """width, height, frame count and pix_fmt of a video, by decoding every frame."""
    out = subprocess.run(["ffprobe", "-v", "error", *(decoder or []), "-count_frames", "-select_streams", "v:0",
                          "-show_entries", "stream=width,height,nb_read_frames,pix_fmt:stream_tags=alpha_mode",
                          "-of", "json", str(path)], check=True, capture_output=True, text=True).stdout
    return json.loads(out)["streams"][0]


class Mark(unittest.TestCase):
    """The locked mark: embedded constants equal the repo's sources of truth."""

    @unittest.skipUnless((REPO / "apps/web/public/frog-mark.svg").exists(), "not in the frog repo")
    def test_smile_matches_svg(self):
        svg = (REPO / "apps/web/public/frog-mark.svg").read_text()
        d = re.search(r'<path d="(M411\.6 584\.4[^"]*)"', svg).group(1)
        pts = tuple((float(x), float(y)) for x, y in re.findall(r"([\d.]+) ([\d.]+)", d))
        self.assertEqual(SMILE, pts)

    @unittest.skipUnless((REPO / "design/tokens.json").exists(), "not in the frog repo")
    def test_colours_match_tokens(self):
        rows = mark_tokens(json.loads((REPO / "design/tokens.json").read_text()))
        hexes = lambda c: "#%02x%02x%02x" % c
        self.assertEqual(rows["mark-skin"].lower(), hexes(MARK.skin))
        self.assertEqual(rows["mark-spot"].lower(), hexes(MARK.spot))
        self.assertEqual(rows["mark-ink"].lower(), hexes(MARK.ink))
        self.assertEqual(rows["mark-paper"].lower(), hexes(MARK.paper))

    @unittest.skipUnless((REPO / "apps/FrogKit/UI/Basics/FrogFace.swift").exists(), "not in the frog repo")
    def test_moods_match_frogface(self):
        swift = (REPO / "apps/FrogKit/UI/Basics/FrogFace.swift").read_text()
        cases = re.search(r"enum FrogMood[^{]*\{\s*case ([^\n]+)", swift).group(1)
        self.assertEqual(set(MOODS), {c.strip() for c in cases.split(",")})
        for name, period in (("breathe", 3.2), ("pump", 1.1), ("ponder", 4), ("scan", 2.4), ("hop", 2.4),
                             ("tilt", 1.8), ("wide", 1.8), ("droop", 3), ("sink", 3)):
            self.assertRegex(swift, rf"static let {name} = Track\(period: {period:g}[,)]")


class Determinism(unittest.TestCase):
    def test_same_params_same_hash(self):
        lay = layout(256, 256, "full")
        for name in ("hop", "thinking", "carry"):
            a = digest(render_frame(name, 0.7, lay, seed=3))
            render_frame(name, 0.1, lay)  # other work in between must not leak state
            self.assertEqual(a, digest(render_frame(name, 0.7, lay, seed=3)), name)

    def test_same_hash_in_fresh_process(self):
        code = ("import sys, hashlib; sys.path.insert(0, %r); from frog_anim import layout, render_frame; "
                "im = render_frame('waiting', 1.1, layout(200, 200, 'head'), seed=7); "
                "print(hashlib.sha256(im.mode.encode() + repr(im.size).encode() + im.tobytes()).hexdigest())") % str(PKG)
        out = subprocess.run([sys.executable, "-c", code], check=True, capture_output=True, text=True).stdout.strip()
        self.assertEqual(out, digest(render_frame("waiting", 1.1, layout(200, 200, "head"), seed=7)))

    def test_seed_shifts_time_only_deterministically(self):
        lay = layout(200, 200, "head")
        self.assertNotEqual(digest(render_frame("idle", 2.0, lay, seed=1)), digest(render_frame("idle", 2.0, lay, seed=2)))


class Actions(unittest.TestCase):
    def test_every_action_renders_at_several_sizes(self):
        for name, act in ACTIONS.items():
            for w, h in ((64, 64), (200, 120), (512, 512)):
                for body in ("full", "head"):
                    for t in (0.0, act.loop * 0.37, act.loop * 0.8):
                        im = render_frame(name, t, layout(w, h, body), body=body)
                        self.assertEqual(im.size, (w, h))
                        self.assertEqual(im.mode, "RGBA")
            # something is drawn at the action's still point
            im = render_frame(name, act.loop * 0.8, layout(256, 256, act.body))
            self.assertGreater(np.asarray(im)[..., 3].max(), 0, name)

    def test_opaque_background(self):
        im = render_frame("sit", 0, layout(128, 128), background=(1, 2, 3))
        self.assertEqual(im.mode, "RGB")
        self.assertEqual(im.getpixel((0, 0)), (1, 2, 3))

    def test_frog_stays_on_canvas(self):
        """No action's frog is cut by the canvas edge in the default layout (peek and hop-in enter
        from off-canvas on purpose and are skipped)."""
        for name, act in ACTIONS.items():
            if name in ("peek", "hop-in"): continue
            lay = layout(240, 240, act.body)
            for i in range(24):
                a = np.asarray(render_frame(name, act.loop * i / 24, lay))[..., 3]
                edges = np.concatenate([a[0], a[-1], a[:, 0], a[:, -1]])
                self.assertEqual(edges.max(), 0, f"{name} touches the edge at frame {i}")

    def test_facing_left_mirrors(self):
        lay = layout(200, 200)
        r = np.asarray(render_frame("wave", 0, lay))
        l = np.asarray(render_frame("wave", 0, lay, facing="left"))
        self.assertFalse(np.array_equal(r, l))
        # the left-facing frog is the right-facing one flipped, give or take a pixel of rounding
        best = min(np.abs(np.roll(r[:, ::-1], s, axis=1).astype(int) - l).mean() for s in (-1, 0, 1))
        self.assertLess(best, 0.5)

    def test_transparent_edges_are_not_darkened(self):
        """On a transparent canvas the frog's edge pixels keep the skin colour (alpha-composited,
        not alpha-squared through paste)."""
        im = Image.new("RGBA", (300, 300), (0, 0, 0, 0))
        place(im, sprite(120, "head"), 150, 260)
        a = np.asarray(im).astype(int)
        edge = (a[..., 3] > 30) & (a[..., 3] < 200)
        self.assertTrue(edge.any())
        # the head's outer edge is skin over nothing: its colour should stay near skin
        g = a[edge][:, 1]
        self.assertGreater(np.median(g), 150)

    def test_default_eyes_equal_rest_move_free_path(self):
        """The reel path (no eye move) and the mood path at rest differ only by the eye code, and
        a rest eye move draws the same pupils."""
        a = digest(sprite(100, "head")[0])
        b = digest(sprite(100, "head", eyes=Move())[0])
        self.assertEqual(a, b)


@unittest.skipUnless(HAVE_FFMPEG, "ffmpeg not installed")
class Cli(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="frog-anim-test-"))

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def run_cli(self, *args: str) -> int:
        return cli_main(list(args))

    def test_list(self):
        self.assertEqual(self.run_cli("list"), 0)

    def test_mp4(self):
        out = self.tmp / "hop.mp4"
        self.assertEqual(self.run_cli("render", "--action", "hop", "--size", "128", "--seconds", "1", "--fps", "30", "--out", str(out)), 0)
        p = probe(out)
        self.assertEqual((p["width"], p["height"], int(p["nb_read_frames"])), (128, 128, 30))
        self.assertEqual(p["pix_fmt"], "yuv420p")

    def test_mp4_refuses_transparent_and_odd(self):
        with self.assertRaises(SystemExit):
            self.run_cli("render", "--action", "hop", "--transparent", "--out", str(self.tmp / "x.mp4"))
        self.assertEqual(self.run_cli("render", "--action", "hop", "--size", "127", "--out", str(self.tmp / "y.mp4")), 2)

    def test_webm_alpha(self):
        out = self.tmp / "t.webm"
        self.assertEqual(self.run_cli("render", "--action", "thinking", "--size", "96", "--seconds", "0.5", "--fps", "24", "--transparent", "--out", str(out)), 0)
        p = probe(out, ["-c:v", "libvpx-vp9"])
        self.assertEqual((p["width"], p["height"], int(p["nb_read_frames"])), (96, 96, 12))
        self.assertEqual(p.get("tags", {}).get("alpha_mode"), "1")
        # decode with libvpx and check the first frame really has transparent and opaque pixels
        raw = subprocess.run(["ffmpeg", "-v", "error", "-c:v", "libvpx-vp9", "-i", str(out), "-frames:v", "1",
                              "-f", "rawvideo", "-pix_fmt", "rgba", "-"], check=True, capture_output=True).stdout
        a = np.frombuffer(raw, np.uint8).reshape(96, 96, 4)[..., 3]
        self.assertEqual(a.min(), 0); self.assertGreater(a.max(), 200)

    def test_mov_alpha(self):
        out = self.tmp / "t.mov"
        self.assertEqual(self.run_cli("render", "--action", "wave", "--size", "64", "--seconds", "0.2", "--transparent", "--out", str(out)), 0)
        p = probe(out)
        self.assertEqual((p["width"], p["height"], int(p["nb_read_frames"])), (64, 64, 6))
        self.assertIn("yuva444p", p["pix_fmt"])

    def test_png_sequence(self):
        out = self.tmp / "frames"
        self.assertEqual(self.run_cli("render", "--action", "sit", "--size", "80", "--seconds", "0.5", "--fps", "10", "--transparent", "--out", str(out)), 0)
        files = sorted(out.glob("*.png"))
        self.assertEqual(len(files), 5)
        im = Image.open(files[0])
        self.assertEqual((im.size, im.mode), ((80, 80), "RGBA"))
        self.assertEqual(np.asarray(im)[0, 0, 3], 0)

    def test_still(self):
        out = self.tmp / "s.png"
        self.assertEqual(self.run_cli("render", "--action", "wave", "--width", "300", "--height", "200", "--at", "0.5", "--background", "#000000", "--out", str(out)), 0)
        im = Image.open(out)
        self.assertEqual((im.size, im.mode), ((300, 200), "RGB"))

    def test_gif_transparent(self):
        out = self.tmp / "a.gif"
        self.assertEqual(self.run_cli("render", "--action", "hop", "--size", "64", "--seconds", "1", "--fps", "20", "--transparent", "--out", str(out)), 0)
        im = Image.open(out)
        self.assertEqual(im.size, (64, 64))
        self.assertEqual(getattr(im, "n_frames", 1), 20)
        self.assertIn("transparency", im.info)

    def test_apng(self):
        out = self.tmp / "a.apng"
        self.assertEqual(self.run_cli("render", "--action", "waiting", "--size", "64", "--seconds", "0.5", "--fps", "20", "--transparent", "--out", str(out)), 0)
        im = Image.open(out)
        self.assertEqual((im.size, getattr(im, "n_frames", 1), im.mode), ((64, 64), 10, "RGBA"))


BEFORE = os.environ.get("FROG_ANIM_REEL_BEFORE")
REEL = REPO / "video/hype-reel"


@unittest.skipUnless(BEFORE and (REEL / "footage").exists(), "set FROG_ANIM_REEL_BEFORE to the pre-move frames; needs the reel's footage/")
class Reel(unittest.TestCase):
    # peek (open), mid-hop, landing squash, swarm, pool, carry (setup), wave (own), wink (end)
    FRAMES = (60, 85, 90, 99, 101, 300, 420, 520, 640, 820, 870, 940, 1010, 1050, 1080)

    def test_reel_matches_before(self):
        with tempfile.TemporaryDirectory() as d:
            subprocess.run([sys.executable, str(REEL / "comp.py"), d, ",".join(map(str, self.FRAMES))],
                           check=True, cwd=REEL, env={**os.environ, "NPROC": "2"}, capture_output=True)
            for f in self.FRAMES:
                a = np.asarray(Image.open(Path(BEFORE) / f"{f:04d}.png"))
                b = np.asarray(Image.open(Path(d) / f"{f:04d}.png"))
                self.assertTrue(np.array_equal(a, b), f"frame {f} differs")


if __name__ == "__main__":
    unittest.main()
