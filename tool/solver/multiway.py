"""Felt Notes N-player preflop solver (the facing-a-limper games, where the
seats behind the hero act).

Players: 0 = the hero, 1.. = everyone else who acts (the limper and the
seats behind the hero). Hands are the 169 classes.

Deal model (star card removal). The joint weight of a deal is
    w(h) = prod_p prior_p(h_p) * prod_{p >= 1} phi(h_0, h_p)
where prior_p = combos x the player's input range and
phi(a, b) = N[a, b] / (combos(a) combos(b)) is the probability that two
combos of classes a and b do not share a card. Card removal is exact between
the hero and each opponent and ignored between two opponents. With two
players this is exactly the heads-up model of preflop.py.

Terminals pay, to every player p, u_p = c_p + [p active] * pot * share_p:
  * c_p: minus what p put in (plus the whole pot for a fold winner);
  * share_p over the players who see the flop (2 or 3):
        share_i = e_i R_i(h_i) / sum_j e_j R_j(h_j)
    where e_i is the all-in equity of i (heads-up table, or the three-way
    tensor) and R_i the solved realisation of that player's seat. This is
    the heads-up formula of preflop.py extended to three players; it keeps
    the pot whole, so the game is zero-sum overall.

Solved with Discounted CFR (alpha 1.5, beta 0, gamma 2), simultaneous
updates, the same as preflop.py. With more than two players CFR has no
convergence guarantee, so every solve reports its Nash gap (NashConv): the
sum over players of the best-response gain against the average profile, in
bb per hand dealt into the spot. A published spot must get it under the
same 0.001bb gate as the heads-up games.
"""
import numpy as np

np.seterr(all="ignore")


class Node:
    def __init__(self, player, actions, kids, name):
        self.player, self.actions, self.kids, self.name = player, actions, kids, name
        self.R = np.zeros((len(actions), 169))
        self.S = np.zeros((len(actions), 169))


class Term:
    """const: {player: c_p}; active: players who see the flop (or are
    all-in), in seat order; pot: chips in the middle; R: {player: table} or
    None (plain equity); info: metadata (kind, potType...)."""

    def __init__(self, const, active=(), pot=0.0, R=None, info=None):
        self.const, self.active, self.pot = dict(const), tuple(active), pot
        self.R = R or {}
        self.info = info or {}
        self.G = None


def fold_win(winner, inv, dead):
    """[winner] takes the pot; inv: {player: chips put in}."""
    pot = sum(inv.values()) + dead
    c = {p: -x for p, x in inv.items()}
    c[winner] = c.get(winner, 0.0) + pot
    return Term(c, info={"kind": "fold", "winner": winner})


def showdown(inv, dead, active, R=None, info=None):
    """[active] see a flop (or are all-in): pot split by realisation shares.
    inv: {player: chips put in} (folded players included)."""
    pot = sum(inv.values()) + dead
    c = {p: -x for p, x in inv.items()}
    return Term(c, active, pot, R, info)


class Game:
    def __init__(self, root, ranges, tabN, tabE, tri=None):
        """ranges: list (one per player) of 169 input class weights;
        tabN / tabE: heads-up pair counts and equities; tri: three-way
        tensor T[a, b, c] (equity of a vs b, c) or None."""
        self.root = root
        self.n = len(ranges)
        combos = np.array([6 if r == c else (4 if r < c else 12) for r in range(13) for c in range(13)], float)
        self.prior_range = [np.asarray(x, float) for x in ranges]
        self.prior = [combos * x for x in self.prior_range]
        self.phi = tabN / np.outer(combos, combos)
        self.E = tabE
        self.T = tri
        self.Q = [None] + [self.phi * self.prior[p][None, :] for p in range(1, self.n)]
        self.nodes, self.terms = [], []
        self._index(root)
        names = [nd.name for nd in self.nodes]
        assert len(set(names)) == len(names), "node names must be unique"
        tot = self.prior[0].copy()
        for k in range(1, self.n):
            tot = tot * self.Q[k].sum(1)
        self.total = float(tot.sum())
        for t in self.terms:
            self._prepare(t)

    def _index(self, x):
        if isinstance(x, Term):
            self.terms.append(x)
            return
        self.nodes.append(x)
        for k in x.kids:
            self._index(k)

    # ---------------------------------------------------------- terminals
    def _prepare(self, t):
        """Share tensors G[p] over the active players' hands, oriented with
        the active players in t.active order (hero first if active)."""
        A = t.active
        if not A:
            return
        R = [np.asarray(t.R.get(p), float) if t.R.get(p) is not None else np.ones(169) for p in A]
        if len(A) == 2:
            e = self.E  # e[a, b] equity of A[0]'s class a vs A[1]'s class b
            x = e * R[0][:, None]
            y = (1 - e) * R[1][None, :]
            s = np.where(x + y > 0, x / np.maximum(x + y, 1e-12), 0.5)
            t.G = [s, 1 - s]
        elif len(A) == 3:
            T = self.T
            e0 = T
            e1 = T.transpose(1, 0, 2)  # e1[a, b, c] = T[b, a, c]
            e2 = T.transpose(1, 2, 0)  # e2[a, b, c] = T[c, a, b]
            x0 = e0 * R[0][:, None, None]
            x1 = e1 * R[1][None, :, None]
            x2 = e2 * R[2][None, None, :]
            tot = np.maximum(x0 + x1 + x2, 1e-12)
            t.G = [(x0 / tot).astype(np.float32), (x1 / tot).astype(np.float32),
                   (x2 / tot).astype(np.float32)]
        else:
            raise ValueError("at most three players see a flop")

    def _term_cfv(self, t, r):
        """cfv[p] (169) for every player: sum over the others' hands of
        w(h) u_p(h) prod_{k != p} r_k(h_k), own prior included."""
        n = self.n
        a = self.prior[0] * r[0]
        B = [None] + [self.Q[k] * r[k][None, :] for k in range(1, n)]
        m = [None] + [B[k].sum(1) for k in range(1, n)]
        out = np.zeros((n, 169))

        def prod_m(excl):
            v = np.ones(169)
            for k in range(1, n):
                if k not in excl:
                    v = v * m[k]
            return v

        # constant part
        if t.const:
            allm = prod_m(())
            c0 = t.const.get(0, 0.0)
            if c0:
                out[0] += c0 * self.prior[0] * allm
            for p in range(1, n):
                cp = t.const.get(p, 0.0)
                if cp:
                    g = a * prod_m((p,))
                    out[p] += cp * self.prior[p] * (self.phi.T @ g)
        A = t.active
        if not A:
            return out
        pot = t.pot
        G = t.G
        if len(A) == 2:
            i, j = A
            if i == 0:
                O = prod_m((j,))
                out[0] += pot * self.prior[0] * O * (B[j] * G[0]).sum(1)
                out[j] += pot * self.prior[j] * (((a * O)[:, None]) * self.phi * G[1]).sum(0)
            else:
                # neither is the hero: G[*][hi, hj]
                O = a * prod_m((i, j))
                Mi = (self.phi * O[:, None]).T @ B[j]  # [hi, hj]
                Mj = (self.phi * O[:, None]).T @ B[i]  # [hj, hi]
                out[i] += pot * self.prior[i] * (Mi * G[0]).sum(1)
                out[j] += pot * self.prior[j] * (Mj * G[1].T).sum(1)
        else:
            i, j, k = A
            if i != 0:
                raise ValueError("a three-way pot must include the hero")
            O = prod_m((j, k))
            # hero: sum_{b,c} B_j[a,b] B_k[a,c] G0[a,b,c]
            Bj, Bk = B[j].astype(np.float32), B[k].astype(np.float32)
            X0 = np.matmul(G[0], Bk[:, :, None])[:, :, 0].astype(float)  # [a, b]
            out[0] += pot * self.prior[0] * O * (B[j] * X0).sum(1)
            aO = a * O
            X1 = np.matmul(G[1], Bk[:, :, None])[:, :, 0].astype(float)  # [a, b]
            out[j] += pot * self.prior[j] * (aO[:, None] * self.phi * X1).sum(0)
            X2 = np.matmul(Bj[:, None, :], G[2])[:, 0, :].astype(float)  # [a, c]
            out[k] += pot * self.prior[k] * (aO[:, None] * self.phi * X2).sum(0)
        return out

    # ---------------------------------------------------------------- CFR
    @staticmethod
    def _strategy(nd):
        pos = np.maximum(nd.R, 0)
        s = pos.sum(0)
        return np.where(s > 0, pos / np.where(s > 0, s, 1), 1.0 / len(nd.actions))

    @staticmethod
    def _avg(nd):
        s = nd.S.sum(0)
        return np.where(s > 0, nd.S / np.where(s > 0, s, 1), 1.0 / len(nd.actions))

    def _walk(self, x, r, mode, t, brp=None):
        if isinstance(x, Term):
            return self._term_cfv(x, r)
        s = self._strategy(x) if mode == "cfr" else self._avg(x)
        q = x.player
        vals = []
        for ai, kid in enumerate(x.kids):
            r2 = list(r)
            r2[q] = r[q] * s[ai]
            vals.append(self._walk(kid, r2, mode, t, brp))
        vals = np.array(vals)  # (A, n, 169)
        out = vals.sum(0)
        mine = vals[:, q, :]
        if mode == "br" and q == brp:
            out[q] = mine.max(0)
        else:
            out[q] = (s * mine).sum(0)
        if mode == "cfr":
            ta = t ** 1.5
            x.R[:] = np.where(x.R > 0, x.R * (ta / (ta + 1)), x.R * 0.5) + (mine - out[q])
            x.S += (t ** 2) * r[q] * s
        return out

    def solve(self, iters=6000, target=2e-5, check=250, log=None, warm=None):
        if warm is not None:
            self.load_state(warm)
        ones = [np.ones(169)] * self.n
        self.iters = 0
        self.expl = None
        t0 = getattr(self, "t_offset", 0)
        for t in range(1, iters + 1):
            self._walk(self.root, ones, "cfr", t + t0)
            self.iters = t
            if t % check == 0 or t == iters:
                self.expl = self.exploitability()
                if log:
                    log(f"    it {t} nash gap {self.expl:.6f} bb/hand")
                if self.expl < target:
                    break
        return self.expl

    def values(self):
        ones = [np.ones(169)] * self.n
        return self._walk(self.root, ones, "avg", 0)

    def exploitability(self):
        ones = [np.ones(169)] * self.n
        v = self._walk(self.root, ones, "avg", 0)
        gain = 0.0
        self.br_gain = []
        for p in range(self.n):
            b = self._walk(self.root, ones, "br", 0, brp=p)
            g = float(b[p].sum() - v[p].sum())
            self.br_gain.append(g / self.total)
            gain += g
        return gain / self.total

    # ----------------------------------------------------------- outputs
    def _path_to(self, cur, target, acc):
        if cur is target:
            return acc
        if isinstance(cur, Term):
            return None
        for ai, k in enumerate(cur.kids):
            res = self._path_to(k, target, acc + [(cur, ai)])
            if res is not None:
                return res
        return None

    def reach_at(self, node):
        r = [np.ones(169) for _ in range(self.n)]
        for nd, ai in self._path_to(self.root, node, []):
            r[nd.player] = r[nd.player] * self._avg(nd)[ai]
        return r

    def action_evs(self, node):
        """Per-class EV (bb) of each action at [node] for its actor."""
        r = self.reach_at(node)
        p = node.player
        # normaliser: the actor's cfv mass with u = 1
        unit = Term({q: (1.0 if q == p else 0.0) for q in range(self.n)})
        m = self._term_cfv(unit, [np.ones(169) if q == p else r[q] for q in range(self.n)])[p]
        res = []
        for ai, kid in enumerate(node.kids):
            rr = [np.ones(169) if q == p else r[q] for q in range(self.n)]
            v = self._walk(kid, rr, "avg", 0)[p]
            res.append(np.where(m > 0, v / np.where(m > 0, m, 1), np.nan))
        return np.array(res)

    def leaf_ranges(self):
        """Every terminal with players who see a flop: (term, [absolute
        range by class for each player])."""
        out = []

        def rec(x, r):
            if isinstance(x, Term):
                if x.active:
                    out.append((x, [self.prior_range[p] * r[p] for p in range(self.n)]))
                return
            s = self._avg(x)
            for ai, k in enumerate(x.kids):
                r2 = list(r)
                r2[x.player] = r[x.player] * s[ai]
                rec(k, r2)

        rec(self.root, [np.ones(169) for _ in range(self.n)])
        return out

    # ------------------------------------------------------- warm starts
    def state(self):
        return {nd.name: (nd.R.copy(), nd.S.copy()) for nd in self.nodes}

    def load_state(self, st):
        for nd in self.nodes:
            if nd.name in st and st[nd.name][0].shape == nd.R.shape:
                nd.R[:], nd.S[:] = st[nd.name]
