"""Re-score saved tool/watch_lab.dart outputs against (corrected) labels.

Same rules as scoreAgainstLabels in tool/watch_lab.dart: the decisions in
a run's "--- decisions" block become a hand log (newHand / newHandUnread
start a hand, fill starts the first or fills an unread one, correct
replaces the cards); each logged hand is matched to the nearest unused
label within 6 s of its start.

    python3 tool/camera_lab/rescore_watch.py LABELS.json RUN.txt...
"""
import json
import re
import sys

SUIT = {'♣': 'c', '♦': 'd', '♥': 'h', '♠': 's'}
RANKS = '23456789TJQKA'


def card(tok):
    return RANKS.index(tok[0]) * 4 + 'cdhs'.index(SUIT.get(tok[1], tok[1]))


def pair(s):
    cs = sorted((card(t) for t in s.split()), reverse=True)
    return tuple(cs)


def decisions(path):
    text = open(path).read()
    if '--- decisions' not in text:
        return None
    block = text.split('--- decisions')[1].split('---')[0]
    out = []
    for line in block.strip().splitlines():
        m = re.match(r'([\d.]+)s (\w+)\s+(.*?)(?: \(was .*\))?$', line.strip())
        if not m:
            continue
        t, action, cards = float(m.group(1)), m.group(2), m.group(3).strip()
        toks = cards.split()
        out.append((t, action, tuple(sorted((card(x) for x in toks), reverse=True))))
    return out


def hand_log(decs):
    hands = []
    for t, a, cs in decs:
        if a == 'fill':
            if hands and not hands[-1][1]:
                hands[-1] = (hands[-1][0], cs)
            else:
                hands.append((t, cs))
        elif a == 'newHand':
            hands.append((t, cs))
        elif a == 'newHandUnread':
            hands.append((t, ()))
        elif a == 'correct' and hands:
            hands[-1] = (hands[-1][0], cs)
    return hands


def score(decs, labels):
    hands = hand_log(decs)
    hand_of = [None] * len(labels)
    label_of = [None] * len(hands)
    for h, (ht, _) in enumerate(hands):
        best, bd = -1, 6.001
        for l, (lt, _) in enumerate(labels):
            if hand_of[l] is not None:
                continue
            d = abs(ht - lt)
            if d < bd:
                best, bd = l, d
        if best >= 0:
            label_of[h], hand_of[best] = best, h
    right = wrong = unread = missed = 0
    for l, (_, truth) in enumerate(labels):
        h = hand_of[l]
        if h is None:
            missed += 1
        elif not hands[h][1]:
            unread += 1
        elif hands[h][1] == truth:
            right += 1
        else:
            wrong += 1
    spurious = sum(1 for x in label_of if x is None)
    return right, wrong, unread, missed, spurious


def main():
    labels = [(l['t'], pair(l['cards'])) for l in json.load(open(sys.argv[1]))]
    for path in sys.argv[2:]:
        d = decisions(path)
        if d is None:
            print(path, 'no decisions')
            continue
        r, w, u, m, s = score(d, labels)
        print('%s: hands %d right %d wrong %d unread %d missed %d spurious %d'
              % (path.split('/')[-1], len(labels), r, w, u, m, s))


if __name__ == '__main__':
    main()
