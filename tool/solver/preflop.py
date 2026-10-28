"""Felt Notes preflop solver: two-player preflop games over the 169 hand
classes, solved with Discounted CFR (alpha 1.5, beta 0, gamma 2),
simultaneous updates, exact card-removal pair counts.

A game is a tree of decision nodes and terminals. Terminal kinds:
  fold   one player gives up; the other wins everything in the middle.
  allin  both all-in preflop: pot x all-in equity.
  post   heads-up flop: pot x realisation-adjusted share
           s0 = e R0(h0) / (e R0(h0) + (1 - e) R1(h1))
         where e is the all-in equity of the two classes and R_i(h) the
         solved postflop realisation factor of class h for that player in
         that pot type (EV / (equity x pot), from tool/solver/postflop.cpp).
         With R = 1 this is plain equity. Zero-sum per hand pair.
  mw     three-way limped flop with a non-strategic big blind (checks its
         option with a fixed range): each strategic player gets
           pot x eq3_i(h0, h1) x R_i(h_i)
         from the three-way all-in equity table and the heads-up limped-pot
         realisation of that seat (a model, documented as such).
Payoffs are bb won relative to the start of the hand (folding a posted blind
= -blind).

Exploitability: sum of both players' best-response gains against the average
profile, bb per hand dealt into the spot (pairs weighted by the fixed input
ranges and card removal). For the general-sum mw leaves this is the Nash gap.
"""
import numpy as np

# Apple Accelerate raises spurious FP warnings inside matmul (numpy 2.0).
np.seterr(all="ignore")


class Tables:
    """HU equity matrix E[i, j] (equity of i vs j) and pair counts N[i, j]."""

    def __init__(self, path):
        E = np.zeros((169, 169))
        N = np.zeros((169, 169))
        for line in open(path):
            i, j, n, ei, ej = line.split()
            i, j, n, ei, ej = int(i), int(j), float(n), float(ei), float(ej)
            N[i, j] = N[j, i] = n
            E[i, j] = ei
            E[j, i] = ej
        self.E, self.N = E, N


class MWTable:
    """Three-way equities: A[i, j] = equity of class i (player 0) with class
    j (player 1) and a third hand from the fixed range; B[i, j] = equity of
    class j in the same deal."""

    def __init__(self, path):
        A = np.zeros((169, 169))
        B = np.zeros((169, 169))
        for line in open(path):
            i, j, n, ei, ej = line.split()
            i, j, ei, ej = int(i), int(j), float(ei), float(ej)
            A[i, j], B[i, j] = ei, ej
            A[j, i], B[j, i] = ej, ei
        self.A, self.B = A, B


class Node:
    def __init__(self, player, actions, kids, name):
        self.player, self.actions, self.kids, self.name = player, actions, kids, name
        self.R = np.zeros((len(actions), 169))
        self.S = np.zeros((len(actions), 169))


class Term:
    def __init__(self, U0, U1, info):
        self.U0, self.U1, self.info = U0, U1, info
        self.A0 = None


def fold(winner, inv0, inv1, dead):
    """Payoff matrices when [winner] takes the pot (the other folded)."""
    pot = inv0 + inv1 + dead
    if winner == 0:
        u0, u1 = pot - inv0, -inv1
    else:
        u0, u1 = -inv0, pot - inv1
    return Term(np.full((169, 169), u0), np.full((169, 169), u1),
                {"kind": "fold", "winner": winner})


def allin(tab, inv, dead, kind="allin", info=None):
    pot = 2 * inv + dead
    U0 = pot * tab.E - inv
    U1 = pot * (1 - tab.E) - inv
    d = {"kind": kind, "inv": inv, "pot": pot}
    d.update(info or {})
    return Term(U0, U1, d)


def post(tab, pot_type, inv, dead, R0=None, R1=None):
    """Heads-up flop; R0/R1: realisation of preflop player 0 / 1 by class."""
    pot = 2 * inv + dead
    e = tab.E
    r0 = np.ones(169) if R0 is None else np.asarray(R0)
    r1 = np.ones(169) if R1 is None else np.asarray(R1)
    a = e * r0[:, None]
    b = (1 - e) * r1[None, :]
    s0 = np.where(a + b > 0, a / np.maximum(a + b, 1e-12), 0.5)
    U0 = pot * s0 - inv
    U1 = pot * (1 - s0) - inv
    return Term(U0, U1, {"kind": "post", "potType": pot_type, "inv": inv, "pot": pot})


def mw(mwt, pot_type, inv0, inv1, pot, R0=None, R1=None):
    r0 = np.ones(169) if R0 is None else np.asarray(R0)
    r1 = np.ones(169) if R1 is None else np.asarray(R1)
    U0 = pot * mwt.A * r0[:, None] - inv0
    U1 = pot * mwt.B * r1[None, :] - inv1
    return Term(U0, U1, {"kind": "mw", "potType": pot_type, "pot": pot})


class Game:
    def __init__(self, root, reach0, reach1, tab):
        self.root = root
        self.reach0 = np.asarray(reach0, float)
        self.reach1 = np.asarray(reach1, float)
        self.W = tab.N * self.reach0[:, None] * self.reach1[None, :]
        self.total = self.W.sum()
        self.nodes, self.terms = [], []
        self._index(root)
        for t in self.terms:
            t.A0 = self.W * t.U0
            t.A1 = self.W * t.U1

    def _index(self, n):
        if isinstance(n, Term):
            self.terms.append(n)
            return
        self.nodes.append(n)
        for k in n.kids:
            self._index(k)

    # ------------------------------------------------------------ CFR
    @staticmethod
    def _strategy(n):
        pos = np.maximum(n.R, 0)
        s = pos.sum(0)
        out = np.where(s > 0, pos / np.where(s > 0, s, 1), 1.0 / len(n.actions))
        return out

    @staticmethod
    def _avg(n):
        s = n.S.sum(0)
        return np.where(s > 0, n.S / np.where(s > 0, s, 1), 1.0 / len(n.actions))

    def _walk(self, n, r0, r1, mode, t):
        """Returns (cfv0, cfv1): counterfactual values by class (mass-weighted)."""
        if isinstance(n, Term):
            return n.A0 @ r1, n.A1.T @ r0
        s = self._strategy(n) if mode == "cfr" else self._avg(n)
        A = len(n.actions)
        vals0, vals1 = [], []
        for a in range(A):
            if n.player == 0:
                v0, v1 = self._walk(n.kids[a], r0 * s[a], r1, mode, t)
            else:
                v0, v1 = self._walk(n.kids[a], r0, r1 * s[a], mode, t)
            vals0.append(v0)
            vals1.append(v1)
        vals0, vals1 = np.array(vals0), np.array(vals1)
        if n.player == 0:
            mine, other = vals0, vals1
        else:
            mine, other = vals1, vals0
        if mode == "br" and n.player == self._brp:
            v_mine = mine.max(0)
        else:
            v_mine = (s * mine).sum(0)
        v_other = other.sum(0)
        if mode == "cfr":
            ta = t ** 1.5
            R = n.R
            R[:] = np.where(R > 0, R * (ta / (ta + 1)), R * 0.5) + (mine - v_mine)
            own = r0 if n.player == 0 else r1
            n.S += (t ** 2) * own * s
        return (v_mine, v_other) if n.player == 0 else (v_other, v_mine)

    def solve(self, iters=4000, target=1e-4, check=250, log=None):
        r0, r1 = self.reach0 * 0 + 1, self.reach1 * 0 + 1
        # fixed input ranges are already inside W, so the walk starts at 1.
        self.iters = 0
        self.expl = None
        for t in range(1, iters + 1):
            self._walk(self.root, r0, r1, "cfr", t)
            self.iters = t
            if t % check == 0 or t == iters:
                self.expl = self.exploitability()
                if log:
                    log(f"    it {t} nash gap {self.expl:.5f} bb/hand")
                if self.expl < target:
                    break
        return self.expl

    def value(self):
        r = np.ones(169)
        v0, v1 = self._walk(self.root, r, r, "avg", 0)
        return v0, v1

    def exploitability(self):
        r = np.ones(169)
        v0, v1 = self._walk(self.root, r, r, "avg", 0)
        self._brp = 0
        b0, _ = self._walk(self.root, r, r, "br", 0)
        self._brp = 1
        _, b1 = self._walk(self.root, r, r, "br", 0)
        self._brp = None
        gain = (b0.sum() - v0.sum()) + (b1.sum() - v1.sum())
        return gain / self.total

    # --------------------------------------------------------- outputs
    def mass(self, player):
        """Opponent mass by class (for normalising cfvs to per-hand EVs)."""
        return self.W.sum(1) if player == 0 else self.W.sum(0)

    def action_evs(self, node):
        """Per-class EV (bb) of each action at [node] for its actor, under the
        average profile; NaN where the class has no mass."""
        out = {}
        path = self._path_to(self.root, node, [])
        r0, r1 = np.ones(169), np.ones(169)
        for (n, a) in path:
            s = self._avg(n)
            if n.player == 0:
                r0 = r0 * s[a]
            else:
                r1 = r1 * s[a]
        # opponent reach scales the cfvs; normalise by the opponent's reach mass
        p = node.player
        opp_r = r1 if p == 0 else r0
        m = (self.W @ opp_r) if p == 0 else (self.W.T @ opp_r)
        res = []
        for a in range(len(node.actions)):
            v0, v1 = self._walk(node.kids[a], r0 if p == 1 else np.ones(169),
                                r1 if p == 0 else np.ones(169), "avg", 0)
            v = v0 if p == 0 else v1
            res.append(np.where(m > 0, v / np.where(m > 0, m, 1), np.nan))
        return np.array(res)

    def _path_to(self, cur, target, acc):
        if cur is target:
            return acc
        if isinstance(cur, Term):
            return None
        for a, k in enumerate(cur.kids):
            r = self._path_to(k, target, acc + [(cur, a)])
            if r is not None:
                return r
        return None

    def leaf_ranges(self):
        """For every post/mw terminal: (term, reach0 by class, reach1 by class),
        absolute (fixed input range x strategy along the path)."""
        out = []

        def rec(n, r0, r1):
            if isinstance(n, Term):
                if n.info["kind"] in ("post", "mw"):
                    out.append((n, self.reach0 * r0, self.reach1 * r1))
                return
            s = self._avg(n)
            for a, k in enumerate(n.kids):
                if n.player == 0:
                    rec(k, r0 * s[a], r1)
                else:
                    rec(k, r0, r1 * s[a])

        rec(self.root, np.ones(169), np.ones(169))
        return out

    def reach_at(self, node):
        path = self._path_to(self.root, node, [])
        r0, r1 = self.reach0.copy(), self.reach1.copy()
        for (n, a) in path:
            s = self._avg(n)
            if n.player == 0:
                r0 = r0 * s[a]
            else:
                r1 = r1 * s[a]
        return r0, r1
