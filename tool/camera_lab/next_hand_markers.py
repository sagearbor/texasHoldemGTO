"""Find the owner's spoken "next hand" markers in a Watch-mode test video.

No speech-to-text is installed (and none ships in the app), so this uses
loudness only, anchored on the hand labels made by eye
(camera_data/watch/*.labels.json, one {"t", "cards"} per hand, t mid-peek):

  speech segments = ffmpeg silencedetect on a 150-4000 Hz band-pass
  card call       = the first segment of >= CALL_MIN s that starts after
                    the peek (t - 1.5 s): "ace of clubs, four of spades"
  "next hand"     = the first short segment (NEXT_MIN..NEXT_MAX s) after
                    the call ends and before the next hand's peek

Prints the markers and writes them as JSON [{"t": seconds}, ...] for
tool/watch_lab.dart --markers. The owner forgot to say it on the first few
deals of mock1; those gaps simply get no marker.

    python3 tool/camera_lab/next_hand_markers.py VIDEO LABELS.json OUT.json
"""
import json
import re
import subprocess
import sys

FFMPEG = '/opt/homebrew/bin/ffmpeg'
CALL_MIN = 0.9
NEXT_MIN, NEXT_MAX = 0.4, 0.95


def speech_segments(video):
    out = subprocess.run(
        [FFMPEG, '-hide_banner', '-i', video, '-vn', '-af',
         'highpass=f=150,lowpass=f=4000,silencedetect=noise=-35dB:d=0.25', '-f', 'null', '-'],
        capture_output=True, text=True).stderr
    segs, start = [], 0.0
    for line in out.splitlines():
        m = re.search(r'silence_start: ([\d.]+)', line)
        if m:
            end = float(m.group(1))
            if end - start > 0.05:
                segs.append((start, end))
        m = re.search(r'silence_end: ([\d.]+)', line)
        if m:
            start = float(m.group(1))
    return segs


def markers(segs, labels):
    ts = [l['t'] for l in labels]
    found = []
    for i, t in enumerate(ts):
        nxt = ts[i + 1] if i + 1 < len(ts) else 1e9
        call = next((s for s in segs if s[0] >= t - 1.5 and s[0] < nxt and s[1] - s[0] >= CALL_MIN), None)
        if call is None:
            continue
        nh = next((s for s in segs if s[0] >= call[1] and s[0] < nxt - 0.5
                   and NEXT_MIN <= s[1] - s[0] <= NEXT_MAX), None)
        if nh is not None:
            found.append({'t': round(nh[0], 2), 'after': labels[i]['cards']})
    return found


def main():
    video, labels_path, out = sys.argv[1:4]
    labels = json.load(open(labels_path))
    m = markers(speech_segments(video), labels)
    for x in m:
        print('next hand @ %.2fs (after %s)' % (x['t'], x['after']))
    print('%d markers for %d hands' % (len(m), len(labels)))
    json.dump(m, open(out, 'w'), indent=1)


if __name__ == '__main__':
    main()
