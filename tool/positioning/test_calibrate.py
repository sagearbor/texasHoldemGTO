"""Tests for calibrate.py: python3 -m unittest discover -s tool/positioning"""

import io
import json
import math
import os
import random
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(__file__))

import calibrate as C  # noqa: E402


def synth_file(path, a=-55.0, n=2.0, sigma=3.0, seed=1, place_off=None):
    rng = random.Random(seed)
    place_off = place_off or {"tableUp": 0.0}
    run = 0
    with open(path, "w") as f:
        for d in (0.5, 1.0, 2.0, 4.0):
            for place, off in place_off.items():
                for _ in range(2):  # two runs each
                    run += 1
                    for _ in range(300):
                        r = a - 10 * n * math.log10(d) + off + rng.gauss(0, sigma)
                        f.write(json.dumps({"t": "2026-11-01T20:00:00.000Z", "m": 1, "r": 1, "k": "sample", "run": run,
                                            "obs": "AAAAAAAAAAAA", "obs_model": "Pixel 10", "peer": "D:BBBBBBBBBBBB",
                                            "peer_model": "Pixel 10", "rssi": round(r), "d_m": d, "place": place}) + "\n")
        f.write('{"k": "sample", "rssi": ')  # torn last line


class Calibrate(unittest.TestCase):
    def test_fit_recovers_a_n_sigma(self):
        tmp = tempfile.mkdtemp()
        synth_file(os.path.join(tmp, "x.jsonl"))
        s = C.load_samples([tmp])
        self.assertEqual(len(s), 4 * 2 * 300)
        a, n, sigma = C.fit_path_loss(s)
        self.assertAlmostEqual(a, -55, delta=0.5)
        self.assertAlmostEqual(n, 2.0, delta=0.08)
        self.assertAlmostEqual(sigma, 3.0, delta=0.3)  # rounding adds a little

    def test_exact_line(self):
        s = [{"rssi": -50 - 20 * math.log10(d), "d": d} for d in (0.5, 1, 3)]
        a, n, sigma = C.fit_path_loss(s)
        self.assertAlmostEqual(a, -50)
        self.assertAlmostEqual(n, 2.0)
        self.assertAlmostEqual(sigma, 0.0)
        self.assertIsNone(C.fit_path_loss([{"rssi": -60, "d": 1.0}, {"rssi": -61, "d": 1.0}]))

    def test_run_spread_and_placement_offsets(self):
        tmp = tempfile.mkdtemp()
        synth_file(os.path.join(tmp, "x.jsonl"), place_off={"tableUp": 0.0, "pocket": -8.0})
        s = C.load_samples([tmp])
        spread = C.run_median_spread(s)
        meds, sd = spread[(1.0, "pocket")]
        self.assertEqual(len(meds), 2)
        self.assertLess(sd, 1.0)  # 300 samples a run: the medians agree
        off = C.placement_offsets(s, C.fit_path_loss(s))
        self.assertAlmostEqual(off["tableUp"] - off["pocket"], 8.0, delta=0.5)

    def test_report(self):
        tmp = tempfile.mkdtemp()
        synth_file(os.path.join(tmp, "x.jsonl"))
        buf = io.StringIO()
        self.assertEqual(C.report(C.load_samples([tmp]), out=buf), 0)
        self.assertIn("A = ", buf.getvalue())
        self.assertIn("BBBB (Pixel 10)", buf.getvalue())
        self.assertEqual(C.report([], out=io.StringIO()), 1)


if __name__ == "__main__":
    unittest.main()
