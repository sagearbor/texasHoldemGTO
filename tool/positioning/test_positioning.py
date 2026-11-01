"""Tests for the seating-experiment analysis (stdlib unittest).

  python3 -m unittest discover -s tool/positioning
"""

import math
import os
import random
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(__file__))

import positioning as P  # noqa: E402
import synth  # noqa: E402


def _err(result, truth, frame=-1):
    f = result["frames"][frame]["pos"]
    errs = [math.dist((p["x"], p["y"]), truth[d]) for d, p in f.items() if d in truth]
    return sum(errs) / len(errs), max(errs)


class LinearAlgebra(unittest.TestCase):
    def test_mds_recovers_a_layout_up_to_rotation(self):
        rng = random.Random(3)
        pts = [(rng.uniform(-1, 1), rng.uniform(-1, 1)) for _ in range(7)]
        d = [[math.dist(a, b) for b in pts] for a in pts]
        got = P.mds(d)
        f = P.procrustes(got, pts, scale=False)
        for g, p in zip(got, pts):
            self.assertLess(math.dist(f(g), p), 1e-6)

    def test_procrustes_handles_reflection_and_scale(self):
        src = [(0, 0), (1, 0), (0, 2), (3, 1)]
        dst = [(5 - 2 * y, 1 + 2 * x) for x, y in [(x, -y) for x, y in src]]
        f = P.procrustes(src, dst, scale=True)
        for s, t in zip(src, dst):
            self.assertLess(math.dist(f(s), t), 1e-9)

    def test_path_loss_round_trip(self):
        for d in (0.3, 1.0, 2.5):
            self.assertAlmostEqual(P.rssi_to_m(P.m_to_rssi(d, 3, -2), 3, -2), d, places=9)

    def test_complete_fills_missing_pairs(self):
        est = [[None, 1.0, None], [1.0, None, 2.0], [None, 2.0, None]]
        full = P._complete(est)
        self.assertEqual(full[0][2], 3.0)
        self.assertEqual(full[0][0], 0.0)


class EndToEnd(unittest.TestCase):
    def run_synth(self, **kw):
        tmp = tempfile.mkdtemp()
        devs, truth = synth.make(tmp, **kw)
        data = P.load([tmp])
        return devs, truth, data, P.estimate(data, 60)

    def test_loads_the_app_format(self):
        devs, _, data, _ = self.run_synth(phones=5, minutes=4, seed=2)
        self.assertEqual(set(data.devices), {d["id"] for d in devs})
        # The host's "H:<night>" key resolves to its install id.
        self.assertEqual(data.resolve(devs[0]["key"]), devs[0]["id"])
        self.assertEqual(len(data.seats), 5)
        self.assertTrue(data.rssi and data.uwb)

    def test_with_uwb_iphones_are_close_and_androids_rough(self):
        for seed in (4, 8):
            devs, truth, _, r = self.run_synth(phones=8, minutes=10, seed=seed)
            t = truth[-1]["pos"]
            ios = {d["id"]: t[d["id"]] for d in devs if d["ios"]}
            android = {d["id"]: t[d["id"]] for d in devs if not d["ios"]}
            mean, worst = _err(r, ios)
            self.assertLess(mean, 0.15)
            self.assertLess(worst, 0.2)
            # RSSI only (4 dB noise): about a seat's width.
            self.assertLess(_err(r, android)[0], 0.6)

    def test_rssi_only_is_rough_but_bounded_and_biases_are_found(self):
        tmp = tempfile.mkdtemp()
        devs, truth = synth.make(tmp, phones=8, minutes=20, seed=5, sigma=3.0)
        # Drop every UWB line: Android-only table.
        for name in os.listdir(tmp):
            if name.endswith(".jsonl"):
                path = os.path.join(tmp, name)
                with open(path) as f:
                    keep = [l for l in f if '"k": "uwb"' not in l]
                with open(path, "w") as f:
                    f.writelines(keep)
        data = P.load([tmp])
        self.assertFalse(data.uwb)
        r = P.estimate(data, 60)
        mean, _ = _err(r, truth[-1]["pos"])
        self.assertLess(mean, 0.6)
        # Fitted transmit biases follow the true ones (up to the pinned mean).
        true_tx = {d["id"]: d["tx"] for d in devs}
        mt = sum(true_tx.values()) / len(true_tx)
        diffs = [abs((true_tx[d] - mt) - r["tx"][d]) for d in true_tx]
        self.assertLess(sum(diffs) / len(diffs), 2.5)

    def test_a_player_who_moves_is_followed(self):
        devs, truth, _, r = self.run_synth(phones=8, minutes=10, seed=6, move=True)
        mover = devs[4]["id"]
        before = r["frames"][2]["pos"][mover]
        after = r["frames"][-1]["pos"][mover]
        self.assertGreater(math.dist((before["x"], before["y"]), (after["x"], after["y"])), 0.5)
        self.assertLess(math.dist((after["x"], after["y"]), truth[-1]["pos"][mover]), 0.35)

    def test_html_renders(self):
        tmp = tempfile.mkdtemp()
        synth.make(tmp, phones=4, minutes=3, seed=7)
        out = os.path.join(tmp, "x.html")
        self.assertEqual(P.main([tmp, "-o", out]), 0)
        with open(out) as f:
            s = f.read()
        self.assertIn('"frames"', s)
        self.assertIn("<svg", s)


if __name__ == "__main__":
    unittest.main()
