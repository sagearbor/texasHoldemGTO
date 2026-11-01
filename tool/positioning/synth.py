#!/usr/bin/env python3
"""Synthetic seating-experiment logs, in the app's own format (one
sense/<night>.jsonl per phone, see lib/nearby/nearby_service.dart), for
developing positioning.py without a game night.

Phones sit around an oval table (the host at the bottom), each with its
own transmit and receive bias; RSSI follows the same path-loss model as
the estimator plus Gaussian noise and dropouts; iPhone pairs also get UWB
distances. --move makes one player change seats half way.

  python3 tool/positioning/synth.py -o tmp/synth --phones 8 --minutes 20
"""

import argparse
import json
import math
import os
import random
from datetime import datetime, timezone

CODE = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
A_1M, PATH_N = -59.0, 2.2


def code(rng, n):
    return "".join(rng.choice(CODE) for _ in range(n))


def iso(ms):
    return datetime.fromtimestamp(ms / 1000, tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.") + f"{ms % 1000:03d}Z"


def seat_xy(k, n):
    """Seat k of n on the table diagram (0..1, host = seat 0 at the bottom),
    clockwise seen from above."""
    a = math.pi / 2 + 2 * math.pi * k / n  # bottom, then left, top, right
    return 0.5 + 0.40 * math.cos(a), 0.5 + 0.36 * math.sin(a)


def to_m(x, y):
    return ((x - 0.5) * 2.4 / 0.7, (0.5 - y) * 1.2 / 0.64)


def make(out, phones=8, minutes=20, seed=1, sigma=4.0, move=False, start_ms=1730851200000):
    rng = random.Random(seed)
    night = code(rng, 8)
    devs = []
    for k in range(phones):
        ios = k % 3 != 1
        devs.append({
            "id": code(rng, 12),
            "key": None,
            "model": ("iPhone15,%d" % (2 + k % 3)) if ios else ("Pixel %d" % (7 + k % 4)),
            "ios": ios,
            "tx": rng.gauss(0, 4),
            "rx": rng.gauss(0, 3),
            "seat": k,
        })
    devs[0]["key"] = "H:" + night
    for d in devs[1:]:
        d["key"] = "D:" + d["id"]
    mover = devs[phones // 2] if move else None
    os.makedirs(out, exist_ok=True)
    files = {d["id"]: open(os.path.join(out, f"{d['id']}.jsonl"), "w") for d in devs}
    m0 = {d["id"]: 0 for d in devs}

    def line(d, ms, k, **f):
        m0[d["id"]] += 1
        files[d["id"]].write(json.dumps({"t": iso(ms), "m": ms - start_ms + m0[d["id"]], "r": 1, "k": k, **f}) + "\n")

    for d in devs:
        line(d, start_ms, "device", night=night, device=d["id"], model=d["model"], os="iOS 18" if d["ios"] else "Android 15",
             uwb=d["ios"], key=d["key"])
        x, y = seat_xy(d["seat"], phones)
        line(d, start_ms + 5000, "seat", x=round(x + rng.gauss(0, 0.02), 3), y=round(y + rng.gauss(0, 0.02), 3), a=0)
    truth = []
    for step in range(minutes * 2):  # a scan every 30 s
        ms = start_ms + 30000 * step + 10000
        if mover and step == minutes:  # half way: swap with the next seat over
            other = devs[(phones // 2 + 1) % phones]
            mover["seat"], other["seat"] = other["seat"], mover["seat"]
        pos = {d["id"]: to_m(*seat_xy(d["seat"], phones)) for d in devs}
        truth.append({"t": ms, "pos": pos})
        for d in devs:
            peers = []
            for e in devs:
                if e is d:
                    continue
                dist = math.dist(pos[d["id"]], pos[e["id"]])
                mean = A_1M - 10 * PATH_N * math.log10(max(dist, 0.05)) + e["tx"] + d["rx"]
                rs = [round(mean + rng.gauss(0, sigma)) for _ in range(rng.randint(0, 10)) if rng.random() > 0.1]
                if rs:
                    peers.append({"p": e["key"], "rssi": rs, **({} if e["ios"] else {"tx": -7})})
            line(d, ms, "scan", scan_ms=4000, peers=peers, fg=True, scr=True, bat=80, chg=False)
            if d["ios"]:
                for e in devs:
                    if e is not d and e["ios"]:
                        dist = math.dist(pos[d["id"]], pos[e["id"]])
                        line(d, ms + 500, "uwb", p="D:" + e["id"], m=round(dist + rng.gauss(0, 0.05), 3))
    for f in files.values():
        f.close()
    with open(os.path.join(out, "truth.json"), "w") as f:
        json.dump({"night": night, "devices": devs, "truth": truth[-1]}, f)
    return devs, truth


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("-o", "--out", default="synth")
    ap.add_argument("--phones", type=int, default=8)
    ap.add_argument("--minutes", type=int, default=20)
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--sigma", type=float, default=4.0, help="RSSI noise, dB")
    ap.add_argument("--move", action="store_true", help="one player changes seats half way")
    a = ap.parse_args()
    make(a.out, a.phones, a.minutes, a.seed, a.sigma, a.move)
    print(f"wrote {a.phones} phone logs to {a.out}")


if __name__ == "__main__":
    main()
