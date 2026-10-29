"""Facing-one-limper games with the seats behind the hero (multiway.py).

UTG limps (a fixed loose-passive range), everyone up to the hero folds; the
hero isos, overlimps / completes, or folds (the BB raises or checks). Every
seat behind the hero then acts too:

  over the hero's overlimp / complete:
    * each seat behind may raise (the BTN to 5bb, the blinds to 6bb) or fold
      (the BB checks instead of folding); once one raises, the seats after
      it fold;
    * the limper then folds or calls, and the hero folds, calls, or (only
      if the limper folded) re-raises to 4x (the raiser then folds, calls,
      or jams; a called re-raise is valued as all-in equity, SPR about 2);
    * nobody raises: a three-way limped pot (hero, limper, BB).
  over the hero's iso-raise:
    * the BTN may fold, call, or 3-bet to 12bb; the SB folds or 3-bets to
      15bb; the BB folds, calls, or 3-bets to 15bb; after a call or 3-bet
      the seats after it fold;
    * after a 3-bet the limper folds and the hero folds, calls, or 4-bets
      (2.2x in position, 2.5x out of position); the 3-bettor then folds,
      calls, or jams;
    * after a cold call the limper folds or calls (a three-way pot if it
      calls);
    * nobody behind acts: the limper folds, calls, or re-raises to 4x (as
      in the heads-up game).

Flop values (realisation tables R by pot type and seat):
  * heads-up pots the hero and the limper reach after an iso
    (ISO:<hero>-UTG) and the BB's limped pot (LIMP:BB-UTG) are solved;
  * the other heads-up pots are valued with the table of the matching
    open-raise pot, e.g. hero iso, BTN calls -> SRP:<hero>-BTN; hero iso,
    BB 3-bets -> 3BP:<hero>-BB; BB raises the hero's overlimp, hero calls ->
    ISO:BB-UTG (raiser = aggressor table, hero = caller table). These are
    BORROWED tables (an approximation): the borrowing gate re-solves with
    a second, equally plausible donor for every borrowed table and requires
    the hero's strategy to stay put;
  * three-way pots: share e_i R_i / sum e_j R_j (multiway.py) with the
    aggressor's and callers' tables of the matching heads-up pot (limped:
    first to act the BB's table, last to act the limper's, the middle seat
    the mean of the two).
"""
import numpy as np

import multiway as mw

STACK = 100.0
ORDER_PRE = ["UTG", "HJ", "CO", "BTN", "SB", "BB"]
ORDER_POST = ["SB", "BB", "UTG", "HJ", "CO", "BTN"]
RAISE_OVER_LIMPS = {"BTN": 5.0, "SB": 6.0, "BB": 6.0, "CO": 5.0}
THREE_BET_ISO = {"BTN": 12.0, "SB": 15.0, "BB": 15.0, "CO": 12.0}
ISO = {"CO": 4.0, "BTN": 4.0, "SB": 5.0, "BB": 5.0}
CAN_COLD_CALL = {"BTN": True, "CO": True, "SB": False, "BB": True}

# Donor pot types for borrowed tables: (primary, alternative). Roles:
# player 0 = the opener / iso-raiser analogue, 1 = the caller / 3-bettor.
SRP_DONOR = {("CO", "BTN"): ("SRP:CO-BTN", "SRP:UTG-BTN"),
             ("CO", "BB"): ("SRP:CO-BB", "SRP:UTG-BB"),
             ("BTN", "BB"): ("SRP:BTN-BB", "SRP:CO-BB"),
             ("SB", "BB"): ("SRP:SB-BB", "SRP:BTN-BB")}
TBP_DONOR = {("CO", "BTN"): ("CO-BTN", "UTG-BTN"),
             ("CO", "SB"): ("CO-BB", "BTN-SB"),
             ("CO", "BB"): ("CO-BB", "UTG-BB"),
             ("BTN", "SB"): ("BTN-SB", "BTN-BB"),
             ("BTN", "BB"): ("BTN-BB", "CO-BB"),
             ("SB", "BB"): ("SB-BB", "BTN-BB")}
# a seat that raises over limpers: donor = its own iso pot (aggressor, caller)
ISO_DONOR = {"BTN": ("ISO:BTN-UTG", "ISO:CO-UTG"), "CO": ("ISO:CO-UTG", "ISO:BTN-UTG"),
             "SB": ("ISO:SB-UTG", "ISO:BB-UTG"), "BB": ("ISO:BB-UTG", "ISO:SB-UTG")}


def behind(hero):
    i = ORDER_PRE.index(hero)
    return ORDER_PRE[i + 1:]


class Builder:
    """Builds one game. Rt: {potType: {0: R, 1: R}}; Rdef(potType, p)
    gives a default table when a pot type is not solved yet; alt: use the
    alternative donors (borrowing gate)."""

    def __init__(self, hero, Rt, Rdef, alt=False):
        self.hero = hero
        self.Rt, self.Rdef, self.alt = Rt, Rdef, alt
        self.seats = [hero, "UTG"] + [s for s in behind(hero)]
        self.idx = {s: i for i, s in enumerate(self.seats)}
        self.dead = 0.0 if hero == "BB" else 0.0
        # blinds not in the game are dead money
        self.dead = sum(b for s, b in (("SB", 0.5), ("BB", 1.0)) if s not in self.seats)
        self.borrowed = set()
        self.solved = set()
        self.names = {}

    def R(self, pt, p, borrowed):
        (self.borrowed if borrowed else self.solved).add(pt)
        t = self.Rt.get(pt)
        return np.asarray(t[p]) if t is not None else self.Rdef(pt, p)

    def nm(self, base):
        n = self.names.get(base, 0)
        self.names[base] = n + 1
        return base if n == 0 else f"{base}#{n}"

    def node(self, seat, actions, kids, name):
        return mw.Node(self.idx[seat], actions, kids, self.nm(name))

    def blinds(self):
        inv = {i: 0.0 for i in range(len(self.seats))}
        for s, b in (("SB", 0.5), ("BB", 1.0)):
            if s in self.idx:
                inv[self.idx[s]] = b
        inv[self.idx["UTG"]] = 1.0
        return inv

    def P(self, s):
        return self.idx[s]

    # ------------------------------------------------------ R lookups
    def hu_R(self, a, b, line):
        """Tables for a heads-up flop between seats a and b on [line].
        Returns {player index: table}."""
        H = self.hero
        if line == "iso-limper":  # hero iso, limper calls: solved
            pt = f"ISO:{H}-UTG"
            return {self.P(H): self.R(pt, 0, False), self.P("UTG"): self.R(pt, 1, False)}
        if line == "limped":  # BB vs limper: solved
            pt = "LIMP:BB-UTG"
            return {self.P("BB"): self.R(pt, 0, False), self.P("UTG"): self.R(pt, 1, False)}
        if line == "iso-coldcall":  # hero iso, seat b calls
            pt = SRP_DONOR[(H, b)][1 if self.alt else 0]
            return {self.P(H): self.R(pt, 0, True), self.P(b): self.R(pt, 1, True)}
        if line in ("3bp", "4bp"):  # hero iso, seat b 3-bets
            pt = ("3BP:" if line == "3bp" else "4BP:") + TBP_DONOR[(H, b)][1 if self.alt else 0]
            return {self.P(H): self.R(pt, 0, True), self.P(b): self.R(pt, 1, True)}
        if line == "raise-over-limps":  # seat a raised the limps, b called
            pt = ISO_DONOR[a][1 if self.alt else 0]
            exact = (b == "UTG" and pt == f"ISO:{a}-UTG")
            return {self.P(a): self.R(pt, 0, not exact), self.P(b): self.R(pt, 1, not exact)}
        raise ValueError(line)

    def mw_R(self, players, line, raiser=None):
        """Three-way pot tables."""
        if line == "limped":
            pt = "LIMP:BB-UTG"
            first, last = self.R(pt, 0, True), self.R(pt, 1, True)
            order = sorted(players, key=ORDER_POST.index)
            out = {self.P(order[0]): first, self.P(order[2]): last,
                   self.P(order[1]): 0.5 * (first + last)}
            return out
        if line == "iso-3way":  # hero iso, a cold caller and the limper call
            pt = f"ISO:{self.hero}-UTG"
        else:  # raise over limps called by two
            pt = ISO_DONOR[raiser][1 if self.alt else 0]
        agg, call = self.R(pt, 0, True), self.R(pt, 1, True)
        r = raiser if raiser else self.hero
        return {self.P(s): (agg if s == r else call) for s in players}

    # ----------------------------------------------------- terminals
    def fold_to(self, winner, inv):
        return mw.fold_win(self.P(winner), inv, self.dead)

    def show(self, inv, seats, R, kind, info=None):
        act = sorted((self.P(s) for s in seats))
        d = {"kind": kind, "seats": list(seats)}
        d.update(info or {})
        return mw.showdown(inv, self.dead, act, {self.P(s): R[self.P(s)] for s in seats} if R else None, d)

    @staticmethod
    def put(inv, p, to):
        x = dict(inv)
        x[p] = to
        return x

    # ------------------------------------------------------- lines
    def allin_call_fold(self, caller, jammer, inv, tag):
        """[caller] faces [jammer]'s all-in."""
        return self.node(caller, ["Call", "Fold"], [
            self.show(self.put(inv, self.P(caller), STACK), [caller, jammer], None, "allin"),
            self.fold_to(jammer, inv)], f"{caller}VsJam{tag}")

    def reraise_line(self, hero, raiser, inv, to, tag):
        """[hero] re-raised [raiser] to [to] (limper folded): raiser folds,
        calls (all-in equity, SPR about 2) or jams."""
        inv_h = self.put(inv, self.P(hero), to)
        jam = self.put(inv_h, self.P(raiser), STACK)
        return self.node(raiser, ["Fold", "Call", "All-in"], [
            self.fold_to(hero, inv_h),
            self.show(self.put(inv_h, self.P(raiser), to), [hero, raiser], None, "allin",
                      {"potType": "LRR"}),
            self.allin_call_fold(hero, raiser, jam, tag)], f"{raiser}VsReraise{tag}")

    def passive_branch(self):
        """Hero overlimped / completed to 1bb."""
        H = self.hero
        inv = self.blinds()
        inv[self.P(H)] = 1.0
        return self._behind_vs_limps(behind(H), inv)

    def _behind_vs_limps(self, seats, inv):
        H = self.hero
        if not seats:
            # nobody raised: three-way limped pot hero, limper, BB
            ps = [H, "UTG", "BB"] if H != "BB" else [H, "UTG"]
            return self.show(inv, ps, self.mw_R(ps, "limped"), "post",
                             {"potType": f"MW:{H}-UTG-BB"})
        s, rest = seats[0], seats[1:]
        size = RAISE_OVER_LIMPS[s]
        raised = self._vs_raise_over_limps(s, self.put(inv, self.P(s), size), size)
        passive = self._behind_vs_limps(rest, inv)
        if s == "BB":
            return self.node(s, ["Check", "Raise"], [passive, raised], f"{s}VsLimps")
        return self.node(s, ["Fold", "Raise"], [passive, raised], f"{s}VsLimps")

    def _vs_raise_over_limps(self, X, inv, size):
        """Seat X raised the limps to [size]; later seats fold. The limper
        folds or calls, then the hero folds, calls or re-raises."""
        H = self.hero

        def hero_node(lim_called):
            inv2 = self.put(inv, self.P("UTG"), size) if lim_called else inv
            tag = "LC" if lim_called else "LF"
            call_inv = self.put(inv2, self.P(H), size)
            if lim_called:
                ps = [H, "UTG", X]
                call = self.show(call_inv, ps, self.mw_R(ps, "raise", raiser=X), "post",
                                 {"potType": f"MWR:{X}-{H}-UTG"})
                fold = self.show(inv2, ["UTG", X], self.hu_R(X, "UTG", "raise-over-limps"), "post",
                                 {"potType": f"RL:{X}-UTG"})
            else:
                call = self.show(call_inv, [H, X], self.hu_R(X, H, "raise-over-limps"), "post",
                                 {"potType": f"RL:{X}-{H}"})
                fold = self.fold_to(X, inv2)
            if lim_called:
                # no squeeze: the model would fold the limper's dead call
                return self.node(H, ["Fold", "Call"], [fold, call], f"heroVs{X}Raise{tag}")
            rr = self.reraise_line(H, X, inv2, 4 * size, f"{X}{tag}")
            return self.node(H, ["Fold", "Call", "Re-raise"], [fold, call, rr], f"heroVs{X}Raise{tag}")

        return self.node("UTG", ["Fold", "Call"], [hero_node(False), hero_node(True)],
                         f"limperVs{X}Raise")

    def iso_branch(self):
        H = self.hero
        iso = ISO[H]
        inv = self.blinds()
        inv[self.P(H)] = iso
        return self._behind_vs_iso(behind(H), inv, iso)

    def _behind_vs_iso(self, seats, inv, iso):
        H = self.hero
        if not seats:
            return self._limper_vs_iso(inv, iso)
        s, rest = seats[0], seats[1:]
        acts, kids = ["Fold"], [self._behind_vs_iso(rest, inv, iso)]
        if CAN_COLD_CALL[s]:
            acts.append("Call")
            kids.append(self._limper_vs_coldcall(s, self.put(inv, self.P(s), iso), iso))
        t = THREE_BET_ISO[s]
        acts.append("3-bet")
        kids.append(self._hero_vs_3bet(s, self.put(inv, self.P(s), t), t))
        return self.node(s, acts, kids, f"{s}VsIso")

    def _limper_vs_iso(self, inv, iso):
        H = self.hero
        call_inv = self.put(inv, self.P("UTG"), iso)
        lrr = 4 * iso
        rr_inv = self.put(inv, self.P("UTG"), lrr)
        # hero vs the limp-reraise: fold / call (all-in equity) / jam
        jam_inv = self.put(rr_inv, self.P(H), STACK)
        hero_vs = self.node(H, ["Fold", "Call", "All-in"], [
            self.fold_to("UTG", rr_inv),
            self.show(self.put(rr_inv, self.P(H), lrr), [H, "UTG"], None, "allin", {"potType": "LRR"}),
            self.allin_call_fold("UTG", H, jam_inv, "LRR")], "heroVsLimpReraise")
        return self.node("UTG", ["Fold", "Call", "Raise"], [
            self.fold_to(H, inv),
            self.show(call_inv, [H, "UTG"], self.hu_R(H, "UTG", "iso-limper"), "post",
                      {"potType": f"ISO:{H}-UTG"}),
            hero_vs], "limperVsIso")

    def _limper_vs_coldcall(self, C, inv, iso):
        H = self.hero
        ps = [H, "UTG", C]
        three = self.show(self.put(inv, self.P("UTG"), iso), ps, self.mw_R(ps, "iso-3way"), "post",
                          {"potType": f"MWI:{H}-{C}-UTG"})
        two = self.show(inv, [H, C], self.hu_R(H, C, "iso-coldcall"), "post",
                        {"potType": f"CC:{H}-{C}"})
        return self.node("UTG", ["Fold", "Call"], [two, three], f"limperVs{C}Call")

    def _hero_vs_3bet(self, X, inv, t):
        H = self.hero
        hero_ip = ORDER_POST.index(H) > ORDER_POST.index(X)
        f = round((2.2 if hero_ip else 2.5) * t, 1)
        inv4 = self.put(inv, self.P(H), f)
        jam = self.put(inv4, self.P(X), STACK)
        v4 = self.node(X, ["Fold", "Call", "All-in"], [
            self.fold_to(H, inv4),
            self.show(self.put(inv4, self.P(X), f), [H, X], self.hu_R(H, X, "4bp"), "post",
                      {"potType": f"I4:{H}-{X}"}),
            self.allin_call_fold(H, X, jam, f"{X}5")], f"{X}Vs4bet")
        call = self.show(self.put(inv, self.P(H), t), [H, X], self.hu_R(H, X, "3bp"), "post",
                         {"potType": f"I3:{H}-{X}"})
        return self.node(H, [f"4-bet {f:g}bb", "Call", "Fold"], [v4, call, self.fold_to(X, inv)],
                         f"heroVs{X}3bet")

    # -------------------------------------------------------- the game
    def build(self, tab, tri, limp_range):
        H = self.hero
        n = len(self.seats)
        if H == "BB":
            inv = self.blinds()
            iso = ISO["BB"]
            root = self.node(H, ["Raise 5bb", "Check"], [
                self._limper_vs_iso(self.put(inv, self.P(H), iso), iso),
                self.show(inv, [H, "UTG"], self.hu_R(H, "UTG", "limped"), "post",
                          {"potType": "LIMP:BB-UTG"})], "hero")
        else:
            iso = ISO[H]
            pas = "Complete" if H == "SB" else "Overlimp"
            inv0 = self.blinds()
            root = self.node(H, [f"Iso {int(iso)}bb", pas, "Fold"], [
                self.iso_branch(), self.passive_branch(), self.fold_to("UTG", inv0)], "hero")
        ranges = [np.ones(169) for _ in range(n)]
        ranges[self.P("UTG")] = np.asarray(limp_range, float)
        g = mw.Game(root, ranges, tab.N, tab.E, tri)
        g.hero = root
        g.seats = self.seats
        g.borrowed = sorted(self.borrowed)
        g.solved_pots = sorted(self.solved)
        return g
