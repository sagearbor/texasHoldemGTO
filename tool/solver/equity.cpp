// Preflop all-in equity tables for the preflop solver.
//
//   equity hu SAMPLES OUT
//     169x169: exact count of non-conflicting combo pairs n[i][j] and the
//     equity of class i vs class j, by Monte Carlo (SAMPLES uniformly drawn
//     combo pairs + 5-card boards per class pair; ties count half).
//   equity mw SAMPLES THIRD_RANGE OUT
//     Three-way: classes i and j plus a third hand drawn from THIRD_RANGE
//     (169 weights). For each (i, j): equity of i and equity of j (pot
//     shares, ties split).
//
// Output: text, one line per (i, j): "i j n eq_i [eq_j]".
#include "common.h"

using namespace fn;

static std::vector<std::pair<int, int>> combosOf(int k) {
  std::vector<std::pair<int, int>> out;
  for (int a = 0; a < 52; a++)
    for (int b = a + 1; b < 52; b++)
      if (classOf(a, b) == k) out.push_back({a, b});
  return out;
}

int main(int argc, char** argv) {
  if (argc < 4) { fprintf(stderr, "usage: equity hu|mw SAMPLES [RANGE] OUT\n"); return 2; }
  std::string mode = argv[1];
  int S = atoi(argv[2]);
  bool mw = mode == "mw";
  std::vector<double> w3(169, 0);
  if (mw) {
    FILE* f = fopen(argv[3], "r");
    for (int i = 0; i < 169; i++) if (fscanf(f, "%lf", &w3[i]) != 1) return 2;
    fclose(f);
  }
  const char* outPath = argv[mw ? 4 : 3];
  std::vector<std::vector<std::pair<int, int>>> cc(169);
  for (int k = 0; k < 169; k++) cc[k] = combosOf(k);
  // third-hand sampling table (cumulative over all 1326 combos)
  std::vector<std::pair<int, int>> all3; std::vector<double> cum3;
  if (mw) {
    double c = 0;
    for (int k = 0; k < 169; k++) for (auto& x : cc[k]) if (w3[k] > 0) { c += w3[k]; all3.push_back(x); cum3.push_back(c); }
  }
  struct Row { int i, j; long n; double ei, ej; };
  std::vector<Row> rows;
  for (int i = 0; i < 169; i++) for (int j = i; j < 169; j++) rows.push_back({i, j, 0, 0, 0});
  int threads = std::max(1u, std::thread::hardware_concurrency());
  parallelFor(int(rows.size()), threads, [&](int r, int) {
    Row& R = rows[r];
    Rng rng(uint64_t(R.i) * 1000 + R.j + 17);
    std::vector<std::pair<int, int>> pairs;
    for (auto& a : cc[R.i]) for (auto& b : cc[R.j]) {
      if (a.first == b.first || a.first == b.second || a.second == b.first || a.second == b.second) continue;
      pairs.push_back({(a.first << 8) | a.second, (b.first << 8) | b.second});
    }
    R.n = long(pairs.size());
    if (pairs.empty()) return;
    double si = 0, sj = 0; int done = 0;
    int cs[9];
    while (done < S) {
      auto& p = pairs[rng.below(int(pairs.size()))];
      int a0 = p.first >> 8, a1 = p.first & 255, b0 = p.second >> 8, b1 = p.second & 255;
      uint64_t used = (1ull << a0) | (1ull << a1) | (1ull << b0) | (1ull << b1);
      int c0 = -1, c1 = -1;
      if (mw) {
        double x = (double((rng.next() >> 11)) / double(1ull << 53)) * cum3.back();
        int lo = int(std::lower_bound(cum3.begin(), cum3.end(), x) - cum3.begin());
        if (lo >= int(all3.size())) lo = int(all3.size()) - 1;
        c0 = all3[lo].first; c1 = all3[lo].second;
        if (used & ((1ull << c0) | (1ull << c1))) continue;
        used |= (1ull << c0) | (1ull << c1);
      }
      int nb = 0;
      while (nb < 5) { int c = rng.below(52); if (used & (1ull << c)) continue; used |= 1ull << c; cs[nb++] = c; }
      cs[5] = a0; cs[6] = a1; uint32_t va = evalCards(cs, 7);
      cs[5] = b0; cs[6] = b1; uint32_t vb = evalCards(cs, 7);
      if (!mw) {
        si += va > vb ? 1 : va == vb ? 0.5 : 0;
      } else {
        cs[5] = c0; cs[6] = c1; uint32_t vc = evalCards(cs, 7);
        uint32_t best = std::max(va, std::max(vb, vc));
        int nw = (va == best) + (vb == best) + (vc == best);
        if (va == best) si += 1.0 / nw;
        if (vb == best) sj += 1.0 / nw;
      }
      done++;
    }
    R.ei = si / S; R.ej = mw ? sj / S : 1 - R.ei;
  });
  FILE* f = fopen(outPath, "w");
  for (auto& R : rows) fprintf(f, "%d %d %ld %.5f %.5f\n", R.i, R.j, R.n, R.ei, R.ej);
  fclose(f);
  return 0;
}
