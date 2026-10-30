// Felt Notes heads-up postflop solver: flop + turn + river, full game.
//
// One flop board, two players (0 = OOP acts first on every street, 1 = IP),
// preflop ranges given as 169 hand-class weights. Every turn and river card
// is dealt (no card abstraction, no sampling); hole cards are exact combos
// with card removal. Bet menu per street from the command line (fractions of
// the pot), raises to [raiseMult] x the bet, at most [maxBets] bets/raises
// per street, plus an optional all-in re-raise; any bet or raise that would
// leave less than 20% of the remaining stack behind becomes all-in.
//
// Algorithm: Discounted CFR (alpha 1.5, beta 0, gamma 2; Brown & Sandholm
// 2019), alternating updates, vectorised over combos. Showdowns use the
// sorted-strength sweep with per-card blocker sums (O(n) per terminal).
// Exploitability = (BR value of OOP + BR value of IP - pot) / 2, per hand
// pair, as % of the flop pot.
//
// Values: chips (bb) won from the flop pot net of the player's own postflop
// contributions, so folding at once = 0 and checking down = equity x pot.
//
// Output (JSON, one object): per hand class, sums over combos of
//   w * EV-mass, w * mass, w * equity-mass (mass = opponent's non-blocked
//   preflop weight) for both players, the flop decision-node strategies by
//   class, exploitability, iterations, time.
#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <map>
#include <sstream>

#include "common.h"

using namespace fn;

// ------------------------------------------------------------- config
struct Config {
  std::string board;
  double pot = 5.5, stack = 97.5;
  std::vector<double> bets[3][2];  // [street][player]
  double raiseMult = 3.0;
  int maxBets = 2;               // bet + one raise
  int maxBetsFlop = -1;          // flop override (-1: maxBets)
  bool allinReraise[3] = {false, false, true};
  bool riverAllin = true;        // all-in as an extra river bet option
  int iters = 400;
  double target = 0.3;           // % of pot
  int threads = 10;
  int checkEvery = 25;
  std::string r0, r1, out;
  double memLimitGb = 5.0;
  bool iso = true;               // turn-card suit isomorphism
};

static std::vector<double> parseList(const std::string& s) {
  std::vector<double> v;
  std::stringstream ss(s);
  std::string tok;
  while (std::getline(ss, tok, ',')) if (!tok.empty()) v.push_back(atof(tok.c_str()));
  return v;
}

static std::vector<double> readRange(const std::string& path) {
  FILE* f = fopen(path.c_str(), "r");
  if (!f) { fprintf(stderr, "cannot read %s\n", path.c_str()); exit(2); }
  std::vector<double> w(169);
  for (int i = 0; i < 169; i++) if (fscanf(f, "%lf", &w[i]) != 1) { fprintf(stderr, "short range %s\n", path.c_str()); exit(2); }
  fclose(f);
  return w;
}

// -------------------------------------------------------------- tree
enum : uint8_t { DEC, FOLD, SHOW, CHANCE };

struct Node {
  uint8_t type = DEC, player = 0, nA = 0, street = 0;
  int8_t turn = -1, river = -1;
  float inv[2] = {0, 0};
  int kid0 = 0;            // index into kids
  int nKids = 0;
  size_t off = 0;          // regret / strategy-sum offset (DEC)
  std::string label;       // flop decision nodes: action path
};

struct Combo { uint8_t a, b; };
struct Player {
  std::vector<int> c1, c2;
  std::vector<Combo> combo;
  std::vector<float> w;     // preflop weight
  std::vector<int> cls;
  std::vector<int> byCard[52];
  std::vector<int> same;    // index of the same combo in the other player, -1
  int n() const { return int(w.size()); }
};

static Config cfg;
static std::vector<Node> nodes;
static std::vector<int> kids;
static std::vector<std::string> actLabels;  // per kid: action label (flop only meaningful)
static int boardCards[3];
static Player pl[2];
static size_t poolSize = 0;
static std::vector<float> regret, ssum;

// River boards: index by (turn, river) unordered.
static int rbIndex[52][52];
struct RiverBoard { std::vector<uint32_t> sorted[2]; std::vector<int> order[2]; };
static std::vector<RiverBoard> rboards;

// Turn-card suit isomorphism. A suit permutation that maps the flop onto
// itself maps the game onto itself (ranges are by hand class, so they are
// symmetric too). Turn cards in one orbit of that group give identical
// subtrees up to relabelling: only the smallest card of each orbit is built
// and solved; the others' values are the canonical subtree's values read
// through the permutation (v_c'[i] = v_c[sigma(i)]). Exact up to float
// rounding; saves about a quarter of the work on two-tone and paired flops
// and half on monotone ones.
static std::vector<std::array<int, 4>> symPerms;   // suit maps fixing the flop
static int turnCanon[52], turnSigma[52];           // canonical card, perm index
static std::vector<std::pair<int, int>> orbitOf[52];  // canonical -> (other card, perm)
static std::vector<std::vector<int>> comboPerm[2];   // [player][perm][combo]

static int permCard(const std::array<int, 4>& sg, int c) { return makeCard(rankOf(c), sg[suitOf(c)]); }

static void setupSymmetry() {
  int su[4] = {0, 1, 2, 3};
  do {
    std::array<int, 4> sg = {su[0], su[1], su[2], su[3]};
    bool ok = true;
    for (int i = 0; i < 3 && ok; i++) {
      int m = permCard(sg, boardCards[i]);
      ok = m == boardCards[0] || m == boardCards[1] || m == boardCards[2];
    }
    if (ok) symPerms.push_back(sg);
  } while (std::next_permutation(su, su + 4));
  for (int c = 0; c < 52; c++) {
    turnCanon[c] = c; turnSigma[c] = -1;
    if (!cfg.iso) continue;
    for (size_t g = 0; g < symPerms.size(); g++) {
      int m = permCard(symPerms[g], c);
      if (m < turnCanon[c]) { turnCanon[c] = m; turnSigma[c] = int(g); }
    }
  }
  for (int c = 0; c < 52; c++)
    if (turnCanon[c] != c) orbitOf[turnCanon[c]].push_back({c, turnSigma[c]});
}

static bool skipTurn(int card) { return cfg.iso && turnCanon[card] != card; }

static int addNode(const Node& n) { nodes.push_back(n); return int(nodes.size()) - 1; }

static std::string fmtSize(double f) {
  char b[32]; snprintf(b, sizeof b, "%d", int(std::lround(f * 100))); return b;
}

static int buildStreet(int street, double inv0, double inv1, int actor, int nBets,
                       bool ipChecked, int turn, int river, const std::string& path);

static int buildRunout(int street, double inv, int turn, int river);

static int streetEnd(int street, double inv0, double inv1, int turn, int river,
                     const std::string& path) {
  double inv = inv0;  // equal after a call / check-check
  if (street == 2) {
    Node n; n.type = SHOW; n.inv[0] = float(inv); n.inv[1] = float(inv);
    n.turn = int8_t(turn); n.river = int8_t(river); n.street = 2;
    return addNode(n);
  }
  if (cfg.stack - inv < 1e-9) return buildRunout(street, inv, turn, river);
  // chance node: deal next street
  Node c; c.type = CHANCE; c.street = uint8_t(street); c.turn = int8_t(turn); c.river = int8_t(river);
  c.inv[0] = float(inv0); c.inv[1] = float(inv1);
  int ci = addNode(c);
  std::vector<int> ks;
  for (int card = 0; card < 52; card++) {
    if (card == boardCards[0] || card == boardCards[1] || card == boardCards[2] || card == turn) continue;
    if (street == 0 && skipTurn(card)) continue;
    int t = street == 0 ? card : turn, r = street == 0 ? -1 : card;
    ks.push_back(buildStreet(street + 1, inv0, inv1, 0, 0, false, t, r, path + "/"));
  }
  nodes[ci].kid0 = int(kids.size()); nodes[ci].nKids = int(ks.size());
  for (int k : ks) { kids.push_back(k); actLabels.push_back(""); }
  return ci;
}

static int buildRunout(int street, double inv, int turn, int river) {
  if (street == 2) {
    Node n; n.type = SHOW; n.inv[0] = n.inv[1] = float(inv);
    n.turn = int8_t(turn); n.river = int8_t(river); n.street = 2;
    return addNode(n);
  }
  Node c; c.type = CHANCE; c.street = uint8_t(street); c.turn = int8_t(turn); c.river = int8_t(river);
  c.inv[0] = c.inv[1] = float(inv);
  int ci = addNode(c);
  std::vector<int> ks;
  for (int card = 0; card < 52; card++) {
    if (card == boardCards[0] || card == boardCards[1] || card == boardCards[2] || card == turn) continue;
    if (street == 0 && skipTurn(card)) continue;
    int t = street == 0 ? card : turn, r = street == 0 ? -1 : card;
    ks.push_back(buildRunout(street + 1, inv, t, r));
  }
  nodes[ci].kid0 = int(kids.size()); nodes[ci].nKids = int(ks.size());
  for (int k : ks) { kids.push_back(k); actLabels.push_back(""); }
  return ci;
}

static int buildStreet(int street, double inv0, double inv1, int actor, int nBets,
                       bool ipChecked, int turn, int river, const std::string& path) {
  (void)ipChecked;
  double inv[2] = {inv0, inv1};
  int opp = 1 - actor;
  double pot = cfg.pot + inv0 + inv1;
  double remain = cfg.stack - inv[actor];
  bool facing = inv[opp] > inv[actor] + 1e-9;
  std::vector<std::pair<std::string, std::function<int()>>> acts;
  if (!facing) {
    acts.push_back({"X", [&]() {
      if (actor == 0) return buildStreet(street, inv0, inv1, 1, nBets, false, turn, river, path + "X");
      return streetEnd(street, inv0, inv1, turn, river, path + "X");
    }});
    std::vector<double> sizes;
    for (double f : cfg.bets[street][actor]) {
      double b = f * pot;
      if (b >= remain * 0.8) b = remain;
      bool dup = false;
      for (double s : sizes) if (std::fabs(s - b) < 1e-6) dup = true;
      if (!dup && b > 0) sizes.push_back(b);
    }
    if (street == 2 && cfg.riverAllin && remain > 0) {
      bool dup = false;
      for (double s : sizes) if (std::fabs(s - remain) < 1e-6) dup = true;
      if (!dup) sizes.push_back(remain);
    }
    for (double b : sizes) {
      std::string lab = b >= remain - 1e-9 ? "A" : "B" + fmtSize(b / pot);
      acts.push_back({lab, [&, b, lab]() {
        double ni[2] = {inv0, inv1}; ni[actor] += b;
        return buildStreet(street, ni[0], ni[1], opp, nBets + 1, false, turn, river, path + lab);
      }});
    }
  } else {
    double d = inv[opp] - inv[actor];
    acts.push_back({"F", [&]() {
      Node n; n.type = FOLD; n.player = uint8_t(actor);
      n.inv[0] = float(inv0); n.inv[1] = float(inv1); n.street = uint8_t(street);
      n.turn = int8_t(turn); n.river = int8_t(river);
      return addNode(n);
    }});
    acts.push_back({"C", [&]() {
      double ni[2] = {inv0, inv1}; ni[actor] = inv[opp];
      return streetEnd(street, ni[0], ni[1], turn, river, path + "C");
    }});
    double oppRemain = cfg.stack - inv[opp];
    if (oppRemain > 1e-9 && remain > d + 1e-9) {
      double streetStart = std::min(inv0, inv1);
      // amounts at street start are equal; bet level of the opponent:
      double base = streetStart;
      // find street-start investment: the smaller of the two before this street's
      // betting is not tracked separately, so use the caller's level when
      // nobody has raised yet (nBets == 1) — the actor still has street-start.
      double level = inv[opp] - base;
      double raiseTo = -1;
      int mb = (street == 0 && cfg.maxBetsFlop > 0) ? cfg.maxBetsFlop : cfg.maxBets;
      if (nBets < mb) {
        raiseTo = base + cfg.raiseMult * level;
        if (raiseTo - inv[actor] >= remain * 0.8 || raiseTo >= cfg.stack) raiseTo = cfg.stack;
      } else if (cfg.allinReraise[street] && nBets < mb + 1) {
        raiseTo = cfg.stack;
      }
      if (raiseTo > inv[opp] + 1e-9) {
        std::string lab = raiseTo >= cfg.stack - 1e-9 ? "A" : "R";
        acts.push_back({lab, [&, raiseTo, lab]() {
          double ni[2] = {inv0, inv1}; ni[actor] = raiseTo;
          return buildStreet(street, ni[0], ni[1], opp, nBets + 1, false, turn, river, path + lab);
        }});
      }
    }
  }
  if (acts.size() == 1) return acts[0].second();  // forced check
  Node n; n.type = DEC; n.player = uint8_t(actor); n.street = uint8_t(street);
  n.turn = int8_t(turn); n.river = int8_t(river);
  n.inv[0] = float(inv0); n.inv[1] = float(inv1);
  n.nA = uint8_t(acts.size());
  if (street == 0) n.label = path;
  int ni = addNode(n);
  std::vector<int> ks;
  std::vector<std::string> labs;
  for (auto& a : acts) { ks.push_back(a.second()); labs.push_back(a.first); }
  nodes[ni].kid0 = int(kids.size()); nodes[ni].nKids = int(ks.size());
  for (size_t i = 0; i < ks.size(); i++) { kids.push_back(ks[i]); actLabels.push_back(labs[i]); }
  return ni;
}
// NOTE on raises: the street-start investment equals min(inv0, inv1) only
// before any raise; with maxBets = 2 (bet + one raise) a raise always faces
// a single bet, so base = the actor's own investment = street start. The
// all-in re-raise does not use [base].

// ------------------------------------------------------------- scratch
struct Arena {
  std::vector<float> buf;
  size_t top = 0;
  float* get(size_t n) {
    if (buf.empty()) buf.resize(1 << 21);
    if (top + n > buf.size()) { fprintf(stderr, "arena overflow\n"); exit(3); }
    float* p = buf.data() + top; top += n; return p;
  }
};
thread_local Arena arena;
struct Mark { size_t m; Mark() : m(arena.top) {} ~Mark() { arena.top = m; } };

enum Mode { M_CFR, M_BR, M_EV };

static double gPosW = 1, gStratW = 1;  // per-iteration DCFR weights

static void terminalFold(const Node& n, int p, const float* rq, float* out) {
  const Player& P = pl[p]; const Player& Q = pl[1 - p];
  float card[52]; memset(card, 0, sizeof card);
  float tot = 0;
  for (int j = 0; j < Q.n(); j++) { float r = rq[j]; if (r == 0) continue; tot += r; card[Q.c1[j]] += r; card[Q.c2[j]] += r; }
  // payoff to p
  double pay;
  if (n.player == p) pay = -n.inv[p];
  else pay = cfg.pot + n.inv[1 - p];
  for (int i = 0; i < P.n(); i++) {
    float m = tot - card[P.c1[i]] - card[P.c2[i]] + (P.same[i] >= 0 ? rq[P.same[i]] : 0);
    out[i] = float(m * pay);
  }
}

static void terminalShow(const Node& n, int p, const float* rq, float* out) {
  // One ascending sweep over both sorted lists: for each strength group of
  // p's combos, W = opponent mass strictly weaker, LE = mass weaker or equal
  // (both net of blocked cards); then lose mass = M - LE, tie = LE - W.
  const Player& P = pl[p]; const Player& Q = pl[1 - p];
  const RiverBoard& rb = rboards[rbIndex[n.turn][n.river]];
  const auto& oP = rb.order[p]; const auto& oQ = rb.order[1 - p];
  const auto& sP = rb.sorted[p]; const auto& sQ = rb.sorted[1 - p];
  const Combo* cq = Q.combo.data();
  const Combo* cp = P.combo.data();
  float cardM[52]; memset(cardM, 0, sizeof cardM);
  float totM = 0;
  for (int q = 0; q < Q.n(); q++) { float r = rq[q]; totM += r; cardM[cq[q].a] += r; cardM[cq[q].b] += r; }
  float cardW[52]; memset(cardW, 0, sizeof cardW);
  float totW = 0;
  double inv = n.inv[p];
  float win = float(cfg.pot + inv), lose = float(-inv), tie = float(cfg.pot / 2);
  int nP = int(oP.size()), nQ = int(oQ.size());
  if (nP != P.n()) memset(out, 0, sizeof(float) * P.n());
  int j = 0, k = 0;
  while (k < nP) {
    uint32_t s = sP[k];
    // weaker opponent combos
    while (j < nQ && sQ[j] < s) { int q = oQ[j]; float r = rq[q]; totW += r; cardW[cq[q].a] += r; cardW[cq[q].b] += r; j++; }
    // equal-strength opponent combos: accumulate separately
    int j2 = j;
    float cardE[52]; bool anyE = false; float totE = 0;
    while (j2 < nQ && sQ[j2] == s) {
      if (!anyE) { memset(cardE, 0, sizeof cardE); anyE = true; }
      int q = oQ[j2]; float r = rq[q]; totE += r; cardE[cq[q].a] += r; cardE[cq[q].b] += r; j2++;
    }
    int k2 = k;
    while (k2 < nP && sP[k2] == s) {
      int i = oP[k2]; int a = cp[i].a, b = cp[i].b;
      float same = P.same[i] >= 0 ? rq[P.same[i]] : 0;
      float M = totM - cardM[a] - cardM[b] + same;
      float W = totW - cardW[a] - cardW[b];
      float E = anyE ? totE - cardE[a] - cardE[b] + same : 0;
      float L = M - W - E;
      out[i] = W * win + L * lose + E * tie;
      k2++;
    }
    k = k2;
  }
  // p's combos blocked by this board are not in the order list: zero them
  // (callers zero them anyway).
}

static void walk(int ni, int p, const float* rp, const float* rq, float* out, Mode mode, bool top);

// The other turn cards of canonical card c's orbit: their values are the
// canonical subtree's, read through the suit permutation.
static void addOrbit(int p, int c, const float* o, float* out) {
  const int np = pl[p].n();
  for (auto& oc : orbitOf[c]) {
    const std::vector<int>& pm = comboPerm[p][oc.second];
    for (int i = 0; i < np; i++) { int j = pm[i]; if (j >= 0) out[i] += o[j]; }
  }
}

static void chanceNode(const Node& n, int p, const float* rp, const float* rq, float* out, Mode mode, bool top) {
  const Player& P = pl[p]; const Player& Q = pl[1 - p];
  int nk = n.nKids;
  double denom = n.street == 0 ? 45.0 : 44.0;
  // card dealt for child k
  auto cardOf = [&](int k) {
    const Node& c = nodes[kids[n.kid0 + k]];
    return n.street == 0 ? int(c.turn) : int(c.river);
  };
  for (int i = 0; i < P.n(); i++) out[i] = 0;
  if (top && cfg.threads > 1) {
    std::vector<float> res(size_t(nk) * P.n());
    parallelFor(nk, cfg.threads, [&](int k, int) {
      Mark mk;
      int c = cardOf(k);
      float* rp2 = arena.get(P.n()); float* rq2 = arena.get(Q.n());
      memcpy(rp2, rp, sizeof(float) * P.n()); memcpy(rq2, rq, sizeof(float) * Q.n());
      for (int i : P.byCard[c]) rp2[i] = 0;
      for (int j : Q.byCard[c]) rq2[j] = 0;
      float* o = res.data() + size_t(k) * P.n();
      walk(kids[n.kid0 + k], p, rp2, rq2, o, mode, false);
      for (int i : P.byCard[c]) o[i] = 0;
    });
    for (int k = 0; k < nk; k++) {
      const float* o = res.data() + size_t(k) * P.n();
      for (int i = 0; i < P.n(); i++) out[i] += o[i];
      if (n.street == 0) addOrbit(p, cardOf(k), o, out);
    }
  } else {
    Mark mk;
    float* rp2 = arena.get(P.n()); float* rq2 = arena.get(Q.n()); float* o = arena.get(P.n());
    for (int k = 0; k < nk; k++) {
      int c = cardOf(k);
      memcpy(rp2, rp, sizeof(float) * P.n()); memcpy(rq2, rq, sizeof(float) * Q.n());
      for (int i : P.byCard[c]) rp2[i] = 0;
      for (int j : Q.byCard[c]) rq2[j] = 0;
      walk(kids[n.kid0 + k], p, rp2, rq2, o, mode, false);
      for (int i : P.byCard[c]) o[i] = 0;
      for (int i = 0; i < P.n(); i++) out[i] += o[i];
      if (n.street == 0) addOrbit(p, c, o, out);
    }
  }
  float inv = float(1.0 / denom);
  for (int i = 0; i < P.n(); i++) out[i] *= inv;
}

static inline void currentStrategy(const Node& n, int actorN, float* s) {
  const float* R = regret.data() + n.off;
  int A = n.nA;
  for (int i = 0; i < actorN; i++) {
    float sum = 0;
    for (int a = 0; a < A; a++) { float r = R[a * actorN + i]; sum += r > 0 ? r : 0; }
    if (sum > 0) for (int a = 0; a < A; a++) { float r = R[a * actorN + i]; s[a * actorN + i] = (r > 0 ? r : 0) / sum; }
    else for (int a = 0; a < A; a++) s[a * actorN + i] = 1.0f / A;
  }
}

static inline void averageStrategy(const Node& n, int actorN, float* s) {
  const float* S = ssum.data() + n.off;
  int A = n.nA;
  for (int i = 0; i < actorN; i++) {
    float sum = 0;
    for (int a = 0; a < A; a++) sum += S[a * actorN + i];
    if (sum > 0) for (int a = 0; a < A; a++) s[a * actorN + i] = S[a * actorN + i] / sum;
    else for (int a = 0; a < A; a++) s[a * actorN + i] = 1.0f / A;
  }
}

static void walk(int ni, int p, const float* rp, const float* rq, float* out, Mode mode, bool top) {
  const Node& n = nodes[ni];
  switch (n.type) {
    case FOLD: terminalFold(n, p, rq, out); return;
    case SHOW: { Mark mk; terminalShow(n, p, rq, out); return; }
    case CHANCE: chanceNode(n, p, rp, rq, out, mode, top && n.street == 0); return;
    default: break;
  }
  Mark mk;
  int A = n.nA, actor = n.player;
  int an = pl[actor].n();
  const Player& P = pl[p];
  float* s = arena.get(size_t(A) * an);
  if (mode == M_CFR) currentStrategy(n, an, s);
  else averageStrategy(n, an, s);
  if (actor == p) {
    float* vals = arena.get(size_t(A) * P.n());
    float* rp2 = arena.get(P.n());
    for (int a = 0; a < A; a++) {
      for (int i = 0; i < an; i++) rp2[i] = rp[i] * s[a * an + i];
      walk(kids[n.kid0 + a], p, rp2, rq, vals + size_t(a) * an, mode, top);
    }
    if (mode == M_BR) {
      for (int i = 0; i < an; i++) {
        float m = vals[i];
        for (int a = 1; a < A; a++) m = std::max(m, vals[a * an + i]);
        out[i] = m;
      }
      return;
    }
    for (int i = 0; i < an; i++) {
      float v = 0;
      for (int a = 0; a < A; a++) v += s[a * an + i] * vals[a * an + i];
      out[i] = v;
    }
    if (mode == M_CFR) {
      float* R = regret.data() + n.off;
      float* S = ssum.data() + n.off;
      float pw = float(gPosW), sw = float(gStratW);
      for (int a = 0; a < A; a++) {
        for (int i = 0; i < an; i++) {
          size_t k = size_t(a) * an + i;
          float r = R[k];
          r = r > 0 ? r * pw : r * 0.5f;
          R[k] = r + vals[k] - out[i];
          S[k] += sw * rp[i] * s[k];
        }
      }
    }
  } else {
    float* rq2 = arena.get(an);
    float* v = arena.get(P.n());
    for (int i = 0; i < P.n(); i++) out[i] = 0;
    for (int a = 0; a < A; a++) {
      for (int j = 0; j < an; j++) rq2[j] = rq[j] * s[a * an + j];
      walk(kids[n.kid0 + a], p, rp, rq2, v, mode, top);
      for (int i = 0; i < P.n(); i++) out[i] += v[i];
    }
  }
}

// --------------------------------------------------------------- setup
static void setupPlayers(const std::vector<double>& w0, const std::vector<double>& w1) {
  const std::vector<double>* ws[2] = {&w0, &w1};
  for (int p = 0; p < 2; p++) {
    Player& P = pl[p];
    for (int a = 0; a < 52; a++)
      for (int b = a + 1; b < 52; b++) {
        if (a == boardCards[0] || a == boardCards[1] || a == boardCards[2]) continue;
        if (b == boardCards[0] || b == boardCards[1] || b == boardCards[2]) continue;
        int k = classOf(a, b);
        double w = (*ws[p])[k];
        if (w <= 1e-6) continue;
        int idx = P.n();
        P.c1.push_back(b); P.c2.push_back(a); P.combo.push_back({uint8_t(b), uint8_t(a)}); P.w.push_back(float(w)); P.cls.push_back(k);
        P.byCard[a].push_back(idx); P.byCard[b].push_back(idx);
      }
  }
  for (int p = 0; p < 2; p++) {
    Player& P = pl[p]; const Player& Q = pl[1 - p];
    std::map<int, int> qi;
    for (int j = 0; j < Q.n(); j++) qi[Q.c1[j] * 52 + Q.c2[j]] = j;
    P.same.assign(P.n(), -1);
    for (int i = 0; i < P.n(); i++) { auto it = qi.find(P.c1[i] * 52 + P.c2[i]); if (it != qi.end()) P.same[i] = it->second; }
  }
}

static void setupRiverBoards() {
  for (int a = 0; a < 52; a++) for (int b = 0; b < 52; b++) rbIndex[a][b] = -1;
  std::vector<std::pair<int, int>> pairs;
  for (int t = 0; t < 52; t++) for (int r = t + 1; r < 52; r++) {
    bool bad = false;
    for (int x : boardCards) if (x == t || x == r) bad = true;
    if (bad) continue;
    rbIndex[t][r] = rbIndex[r][t] = int(pairs.size());
    pairs.push_back({t, r});
  }
  rboards.resize(pairs.size());
  parallelFor(int(pairs.size()), cfg.threads, [&](int k, int) {
    int cs[7] = {boardCards[0], boardCards[1], boardCards[2], pairs[k].first, pairs[k].second, 0, 0};
    for (int p = 0; p < 2; p++) {
      const Player& P = pl[p];
      std::vector<uint32_t> st(P.n());
      std::vector<int> ord;
      for (int i = 0; i < P.n(); i++) {
        cs[5] = P.c1[i]; cs[6] = P.c2[i];
        bool blocked = P.c1[i] == cs[3] || P.c1[i] == cs[4] || P.c2[i] == cs[3] || P.c2[i] == cs[4];
        st[i] = blocked ? 0 : evalCards(cs, 7);
        if (!blocked) ord.push_back(i);
      }
      std::sort(ord.begin(), ord.end(), [&](int x, int y) { return st[x] < st[y]; });
      rboards[k].order[p] = ord;
      auto& so = rboards[k].sorted[p];
      so.resize(ord.size());
      for (size_t x = 0; x < ord.size(); x++) so[x] = st[ord[x]];
    }
  });
}

// Equity of every combo vs the opponent's preflop range, by full runout.
static std::vector<double> equities(int p) {
  const Player& P = pl[p]; const Player& Q = pl[1 - p];
  int nb = int(rboards.size());
  std::vector<std::vector<double>> part(cfg.threads, std::vector<double>(P.n(), 0));
  std::vector<int> pairsT, pairsR;
  for (int t = 0; t < 52; t++) for (int r = t + 1; r < 52; r++) if (rbIndex[t][r] >= 0) { pairsT.push_back(t); pairsR.push_back(r); }
  parallelFor(nb, cfg.threads, [&](int k, int w) {
    Mark mk;
    int t = pairsT[k], r = pairsR[k];
    float* rq = arena.get(Q.n());
    for (int j = 0; j < Q.n(); j++) rq[j] = Q.w[j];
    for (int j : Q.byCard[t]) rq[j] = 0;
    for (int j : Q.byCard[r]) rq[j] = 0;
    Node n; n.type = SHOW; n.turn = int8_t(t); n.river = int8_t(r);
    n.inv[0] = n.inv[1] = 0;
    float* o = arena.get(P.n());
    // with inv 0 the showdown value is pot * (win + tie/2)
    terminalShow(n, p, rq, o);
    for (int i : P.byCard[t]) o[i] = 0;
    for (int i : P.byCard[r]) o[i] = 0;
    for (int i = 0; i < P.n(); i++) part[w][i] += o[i];
  });
  std::vector<double> eq(P.n(), 0);
  for (auto& v : part) for (int i = 0; i < P.n(); i++) eq[i] += v[i];
  // per pair 990 boards; divide by pot and 990 -> mass-weighted equity
  for (int i = 0; i < P.n(); i++) eq[i] /= cfg.pot * 990.0;
  return eq;
}

static double nowSec() {
  return std::chrono::duration<double>(std::chrono::steady_clock::now().time_since_epoch()).count();
}

static double massOf(int p, std::vector<double>* massOut) {
  const Player& P = pl[p]; const Player& Q = pl[1 - p];
  double card[52] = {0}; double tot = 0;
  for (int j = 0; j < Q.n(); j++) { tot += Q.w[j]; card[Q.c1[j]] += Q.w[j]; card[Q.c2[j]] += Q.w[j]; }
  double all = 0;
  massOut->assign(P.n(), 0);
  for (int i = 0; i < P.n(); i++) {
    double m = tot - card[P.c1[i]] - card[P.c2[i]] + (P.same[i] >= 0 ? Q.w[P.same[i]] : 0);
    (*massOut)[i] = m; all += P.w[i] * m;
  }
  return all;
}

int main(int argc, char** argv) {
  for (int i = 1; i + 1 < argc; i += 2) {
    std::string k = argv[i], v = argv[i + 1];
    if (k == "--board") cfg.board = v;
    else if (k == "--pot") cfg.pot = atof(v.c_str());
    else if (k == "--stack") cfg.stack = atof(v.c_str());
    else if (k == "--r0") cfg.r0 = v;
    else if (k == "--r1") cfg.r1 = v;
    else if (k == "--out") cfg.out = v;
    else if (k == "--iters") cfg.iters = atoi(v.c_str());
    else if (k == "--target") cfg.target = atof(v.c_str());
    else if (k == "--threads") cfg.threads = atoi(v.c_str());
    else if (k == "--raise") cfg.raiseMult = atof(v.c_str());
    else if (k == "--maxbets") cfg.maxBets = atoi(v.c_str());
    else if (k == "--maxbets-flop") cfg.maxBetsFlop = atoi(v.c_str());
    else if (k == "--mem") cfg.memLimitGb = atof(v.c_str());
    else if (k == "--river-allin") cfg.riverAllin = atoi(v.c_str()) != 0;
    else if (k == "--iso") cfg.iso = atoi(v.c_str()) != 0;
    else if (k == "--reraise-allin") { for (int st = 0; st < 3; st++) cfg.allinReraise[st] = v.size() > size_t(st) && v[st] == '1'; }
    else if (k.rfind("--bets-", 0) == 0) {
      // --bets-flop-oop 0.33,0.75
      std::string rest = k.substr(7);
      int st = rest.rfind("flop", 0) == 0 ? 0 : rest.rfind("turn", 0) == 0 ? 1 : 2;
      int pp = rest.find("oop") != std::string::npos ? 0 : 1;
      cfg.bets[st][pp] = parseList(v == "-" ? "" : v);
    } else { fprintf(stderr, "unknown arg %s\n", k.c_str()); return 2; }
  }
  if (cfg.board.size() != 6) { fprintf(stderr, "need --board\n"); return 2; }
  for (int i = 0; i < 3; i++) boardCards[i] = parseCard(cfg.board.c_str() + 2 * i);
  double t0 = nowSec();
  setupSymmetry();
  setupPlayers(readRange(cfg.r0), readRange(cfg.r1));
  for (int p = 0; p < 2; p++) {
    const Player& P = pl[p];
    std::map<int, int> at;
    for (int i = 0; i < P.n(); i++) at[P.c1[i] * 52 + P.c2[i]] = i;
    comboPerm[p].assign(symPerms.size(), std::vector<int>(P.n(), -1));
    for (size_t g = 0; g < symPerms.size(); g++)
      for (int i = 0; i < P.n(); i++) {
        int a = permCard(symPerms[g], P.c1[i]), b = permCard(symPerms[g], P.c2[i]);
        if (a < b) std::swap(a, b);
        auto it = at.find(a * 52 + b);
        if (it != at.end()) comboPerm[p][g][i] = it->second;
        else { fprintf(stderr, "asymmetric range: no image for combo %d\n", i); return 5; }
      }
  }
  fprintf(stderr, "suit symmetries %zu, turn cards solved %d of 49\n", symPerms.size(),
          [] { int n = 0; for (int c = 0; c < 52; c++) if (c != boardCards[0] && c != boardCards[1] && c != boardCards[2] && !skipTurn(c)) n++; return n; }());
  buildStreet(0, 0, 0, 0, 0, false, -1, -1, "");
  // allocate
  size_t off = 0, decs = 0;
  for (auto& n : nodes) if (n.type == DEC) { n.off = off; off += size_t(n.nA) * pl[n.player].n(); decs++; }
  poolSize = off;
  double gb = 2.0 * poolSize * 4 / 1e9;
  fprintf(stderr, "board %s combos %d/%d nodes %zu decisions %zu pool %.2f GB\n", cfg.board.c_str(), pl[0].n(), pl[1].n(), nodes.size(), decs, gb);
  if (gb > cfg.memLimitGb) { fprintf(stderr, "tree too large (%.2f GB > %.2f)\n", gb, cfg.memLimitGb); return 4; }
  regret.assign(poolSize, 0); ssum.assign(poolSize, 0);
  setupRiverBoards();

  std::vector<double> mass0, mass1;
  double tm0 = massOf(0, &mass0), tm1 = massOf(1, &mass1);
  (void)tm1;
  auto initReach = [&](int p) { std::vector<float> r(pl[p].w.begin(), pl[p].w.end()); return r; };
  std::vector<float> r0 = initReach(0), r1 = initReach(1);
  std::vector<float> o0(pl[0].n()), o1(pl[1].n());
  const double alpha = 1.5, gamma = 2.0;
  double expl = 1e9; int it = 0;
  std::vector<std::pair<int, double>> curve;
  auto exploit = [&]() {
    walk(0, 0, r0.data(), r1.data(), o0.data(), M_BR, true);
    walk(0, 1, r1.data(), r0.data(), o1.data(), M_BR, true);
    double b0 = 0, b1 = 0;
    for (int i = 0; i < pl[0].n(); i++) b0 += r0[i] * o0[i];
    for (int i = 0; i < pl[1].n(); i++) b1 += r1[i] * o1[i];
    b0 /= tm0; b1 /= tm0;  // per hand pair
    return (b0 + b1 - cfg.pot) / 2 / cfg.pot * 100;
  };
  // Exploitability checks: every [checkEvery] iterations until two points
  // exist, then at the iteration where a power-law fit of the last two
  // points (expl ~ c / t^k) predicts the target (+3%), within 5..2x
  // checkEvery of the last check. Saves the overshoot of a fixed interval.
  int nextCheck = cfg.checkEvery;
  // Divergence guard. DCFR(1.5, 0, 2) occasionally runs away on a spot
  // (seen once in about 1,700 solves: 3.7% of the pot at 50 iterations,
  // then rising to 27%); DCFR with alpha = 1 (and CFR+) converge on the same
  // spot. If exploitability climbs above twice its best so far, the solve
  // restarts from zero with alpha = 1. The iteration count keeps running.
  double alphaNow = alpha, bestExpl = 1e9;
  int t0it = 0, restarts = 0;
  size_t curveStart = 0;
  for (it = 1; it <= cfg.iters; it++) {
    int t = it - t0it;
    double ta = std::pow(double(t), alphaNow);
    gPosW = ta / (ta + 1);
    gStratW = std::pow(double(t), gamma);
    walk(0, 0, r0.data(), r1.data(), o0.data(), M_CFR, true);
    walk(0, 1, r1.data(), r0.data(), o1.data(), M_CFR, true);
    if (it == nextCheck || it == cfg.iters) {
      expl = exploit();
      curve.push_back({it, expl});
      fprintf(stderr, "  it %d expl %.3f%% pot  (%.1fs)\n", it, expl, nowSec() - t0);
      if (expl < cfg.target) break;
      bestExpl = std::min(bestExpl, expl);
      if (restarts == 0 && expl > 2 * bestExpl && t > 50) {
        fprintf(stderr, "  diverging (best %.3f%%): restart with alpha 1\n", bestExpl);
        std::fill(regret.begin(), regret.end(), 0.0f);
        std::fill(ssum.begin(), ssum.end(), 0.0f);
        alphaNow = 1.0; t0it = it; restarts = 1; bestExpl = 1e9;
        curveStart = curve.size();
        nextCheck = it + cfg.checkEvery;
        continue;
      }
      int step = cfg.checkEvery;
      size_t m = curve.size();
      if (m >= curveStart + 2) {
        double t1 = curve[m - 2].first - t0it, e1 = curve[m - 2].second, t2 = curve[m - 1].first - t0it, e2 = curve[m - 1].second;
        if (e2 < e1 && e2 > 0) {
          double k = std::log(e1 / e2) / std::log(t2 / t1);
          if (k > 0.2) {
            double ts = t2 * std::pow(e2 / cfg.target, 1.0 / k) * 1.03;
            step = std::max(5, std::min(2 * cfg.checkEvery, int(std::ceil(ts - t2))));
          }
        }
      }
      nextCheck = it + step;
    }
  }
  if (it > cfg.iters) it = cfg.iters;
  // EVs under the average strategy
  walk(0, 0, r0.data(), r1.data(), o0.data(), M_EV, true);
  walk(0, 1, r1.data(), r0.data(), o1.data(), M_EV, true);
  std::vector<double> eq0 = equities(0), eq1 = equities(1);
  double ev0tot = 0, ev1tot = 0;
  for (int i = 0; i < pl[0].n(); i++) ev0tot += r0[i] * o0[i];
  for (int i = 0; i < pl[1].n(); i++) ev1tot += r1[i] * o1[i];
  ev0tot /= tm0; ev1tot /= tm0;

  FILE* f = cfg.out.empty() ? stdout : fopen(cfg.out.c_str(), "w");
  fprintf(f, "{\"board\":\"%s\",\"pot\":%g,\"stack\":%g,\"iters\":%d,\"exploitPctPot\":%.5f,\"seconds\":%.1f,\"restarts\":%d,",
          cfg.board.c_str(), cfg.pot, cfg.stack, it, expl, nowSec() - t0, restarts);
  fprintf(f, "\"ev\":[%.6f,%.6f],\"curve\":[", ev0tot, ev1tot);
  for (size_t i = 0; i < curve.size(); i++) fprintf(f, "%s[%d,%.4f]", i ? "," : "", curve[i].first, curve[i].second);
  fprintf(f, "],\"players\":[");
  std::vector<double>* masses[2] = {&mass0, &mass1};
  std::vector<float>* outs[2] = {&o0, &o1};
  std::vector<double>* eqs[2] = {&eq0, &eq1};
  for (int p = 0; p < 2; p++) {
    std::vector<double> evS(169, 0), mS(169, 0), eqS(169, 0);
    for (int i = 0; i < pl[p].n(); i++) {
      int k = pl[p].cls[i];
      evS[k] += pl[p].w[i] * (*outs[p])[i];
      mS[k] += pl[p].w[i] * (*masses[p])[i];
      eqS[k] += pl[p].w[i] * (*eqs[p])[i];
    }
    fprintf(f, "%s{\"evMass\":[", p ? "," : "");
    for (int k = 0; k < 169; k++) fprintf(f, "%s%.5g", k ? "," : "", evS[k]);
    fprintf(f, "],\"mass\":[");
    for (int k = 0; k < 169; k++) fprintf(f, "%s%.5g", k ? "," : "", mS[k]);
    fprintf(f, "],\"eqMass\":[");
    for (int k = 0; k < 169; k++) fprintf(f, "%s%.5g", k ? "," : "", eqS[k]);
    fprintf(f, "]}");
  }
  // flop decision nodes: reach-weighted average strategy by class.
  fprintf(f, "],\"flop\":[");
  bool first = true;
  // compute own reach along flop paths
  std::function<void(int, std::vector<float>&, std::vector<float>&)> rec =
      [&](int ni, std::vector<float>& ra, std::vector<float>& rb) {
        const Node& n = nodes[ni];
        if (n.type != DEC || n.street != 0) return;
        int an = pl[n.player].n(), A = n.nA;
        std::vector<float> s(size_t(A) * an);
        averageStrategy(n, an, s.data());
        std::vector<float>& own = n.player == 0 ? ra : rb;
        std::vector<double> fr(169 * A, 0), tot(169, 0);
        for (int i = 0; i < an; i++) {
          int k = pl[n.player].cls[i];
          double rr = own[i] * (*masses[n.player])[i];
          tot[k] += rr;
          for (int a = 0; a < A; a++) fr[k * A + a] += rr * s[a * an + i];
        }
        fprintf(f, "%s{\"path\":\"%s\",\"player\":%d,\"actions\":[", first ? "" : ",", n.label.c_str(), n.player);
        first = false;
        for (int a = 0; a < A; a++) fprintf(f, "%s\"%s\"", a ? "," : "", actLabels[n.kid0 + a].c_str());
        fprintf(f, "],\"reach\":[");
        for (int k = 0; k < 169; k++) fprintf(f, "%s%.4g", k ? "," : "", tot[k]);
        fprintf(f, "],\"freq\":[");
        for (int k = 0; k < 169 * A; k++) fprintf(f, "%s%.4g", k ? "," : "", fr[k]);
        fprintf(f, "]}");
        for (int a = 0; a < A; a++) {
          std::vector<float> o2 = own;
          for (int i = 0; i < an; i++) o2[i] *= s[a * an + i];
          if (n.player == 0) rec(kids[n.kid0 + a], o2, rb); else rec(kids[n.kid0 + a], ra, o2);
        }
      };
  std::vector<float> ra(pl[0].w.begin(), pl[0].w.end()), rbv(pl[1].w.begin(), pl[1].w.end());
  rec(0, ra, rbv);
  fprintf(f, "]}\n");
  if (f != stdout) fclose(f);
  fprintf(stderr, "done %s: %d iters, expl %.3f%%, EV oop %.3f ip %.3f (sum %.3f vs pot %.3f), %.1fs\n",
          cfg.board.c_str(), it, expl, ev0tot, ev1tot, ev0tot + ev1tot, cfg.pot, nowSec() - t0);
  return 0;
}
