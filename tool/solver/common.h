// Shared helpers for the Felt Notes solvers (tool/solver/*.cpp).
//
// Cards: 0..51 = rank * 4 + suit, rank 0 = deuce .. 12 = ace, suit "cdhs"
// (same encoding as lib/poker/cards.dart).
// Hand classes: index = row * 13 + col on the 13x13 grid, row/col 0 = ace;
// above the diagonal suited, below offsuit (same as lib/gto/hand_class.dart).
#pragma once
#include <atomic>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <functional>
#include <string>
#include <thread>
#include <vector>

namespace fn {

inline int rankOf(int c) { return c >> 2; }
inline int suitOf(int c) { return c & 3; }
inline int makeCard(int r, int s) { return r * 4 + s; }
static const char* kRanks = "23456789TJQKA";
static const char* kSuits = "cdhs";

inline std::string cardStr(int c) {
  return std::string(1, kRanks[rankOf(c)]) + kSuits[suitOf(c)];
}
inline int parseCard(const char* s) {
  const char* r = strchr(kRanks, s[0]);
  const char* u = strchr(kSuits, s[1]);
  if (!r || !u) { fprintf(stderr, "bad card %c%c\n", s[0], s[1]); exit(2); }
  return makeCard(int(r - kRanks), int(u - kSuits));
}

/// Hand-class index of two hole cards.
inline int classOf(int a, int b) {
  int hi = rankOf(a), lo = rankOf(b);
  if (lo > hi) std::swap(hi, lo);
  int rHi = 12 - hi, rLo = 12 - lo;
  if (hi == lo) return rHi * 13 + rHi;
  if (suitOf(a) == suitOf(b)) return rHi * 13 + rLo;
  return rLo * 13 + rHi;
}
inline int classCombos(int k) {
  int r = k / 13, c = k % 13;
  return r == c ? 6 : (r < c ? 4 : 12);
}
inline std::string className(int k) {
  int r = k / 13, c = k % 13;
  int hi = 12 - std::min(r, c), lo = 12 - std::max(r, c);
  std::string s = {kRanks[hi], kRanks[lo]};
  if (r != c) s += r < c ? 's' : 'o';
  return s;
}

// --------------------------------------------------------------- evaluator
// 7-card (or 5/6-card) evaluator: returns a value where bigger is better.
// category << 24 | up to five 4-bit kickers.

inline int topBit(uint32_t m) { return 31 - __builtin_clz(m); }

inline uint32_t straightHigh(uint32_t m) {
  // m: 13-bit rank mask. Returns high rank of best straight + 1, 0 if none.
  uint32_t x = (m << 1) | ((m >> 12) & 1);  // ace low at bit 0
  uint32_t s = x & (x << 1) & (x << 2) & (x << 3) & (x << 4);
  if (!s) return 0;
  return uint32_t(topBit(s));  // bit index in shifted space = high rank + 1
}

inline uint32_t kick(uint32_t m, int n) {
  uint32_t v = 0;
  for (int i = 0; i < n; i++) {
    if (!m) { v <<= 4; continue; }
    int b = topBit(m);
    v = (v << 4) | uint32_t(b);
    m &= ~(1u << b);
  }
  return v;
}

inline uint32_t evalCards(const int* cs, int n) {
  uint32_t suitMask[4] = {0, 0, 0, 0};
  int cnt[13] = {0};
  for (int i = 0; i < n; i++) {
    suitMask[suitOf(cs[i])] |= 1u << rankOf(cs[i]);
    cnt[rankOf(cs[i])]++;
  }
  for (int s = 0; s < 4; s++) {
    if (__builtin_popcount(suitMask[s]) >= 5) {
      uint32_t sh = straightHigh(suitMask[s]);
      if (sh) return (8u << 24) | sh;
      return (5u << 24) | kick(suitMask[s], 5);
    }
  }
  uint32_t all = suitMask[0] | suitMask[1] | suitMask[2] | suitMask[3];
  uint32_t m4 = 0, m3 = 0, m2 = 0;
  for (int r = 0; r < 13; r++) {
    if (cnt[r] == 4) m4 |= 1u << r;
    else if (cnt[r] == 3) m3 |= 1u << r;
    else if (cnt[r] == 2) m2 |= 1u << r;
  }
  if (m4) {
    int q = topBit(m4);
    return (7u << 24) | (uint32_t(q) << 4) | kick(all & ~(1u << q), 1);
  }
  if (m3) {
    int t = topBit(m3);
    uint32_t rest = (m3 & ~(1u << t)) | m2;
    if (rest) return (6u << 24) | (uint32_t(t) << 4) | uint32_t(topBit(rest));
  }
  uint32_t sh = straightHigh(all);
  if (sh) return (4u << 24) | sh;
  if (m3) {
    int t = topBit(m3);
    return (3u << 24) | (uint32_t(t) << 8) | kick(all & ~(1u << t), 2);
  }
  if (__builtin_popcount(m2) >= 2) {
    int p1 = topBit(m2);
    int p2 = topBit(m2 & ~(1u << p1));
    return (2u << 24) | (uint32_t(p1) << 8) | (uint32_t(p2) << 4) |
           kick(all & ~(1u << p1) & ~(1u << p2), 1);
  }
  if (m2) {
    int p = topBit(m2);
    return (1u << 24) | (uint32_t(p) << 12) | kick(all & ~(1u << p), 3);
  }
  return kick(all, 5);
}

// ------------------------------------------------------------------ rng
struct Rng {
  uint64_t s;
  explicit Rng(uint64_t seed) : s(seed * 0x9E3779B97F4A7C15ull + 1) {}
  uint64_t next() {
    s ^= s << 13; s ^= s >> 7; s ^= s << 17; return s;
  }
  int below(int n) { return int((next() >> 11) % uint64_t(n)); }
};

// -------------------------------------------------------------- threads
/// Run fn(i, worker) for i in [0, n) on [threads] threads.
inline void parallelFor(int n, int threads,
                        const std::function<void(int, int)>& f) {
  if (threads <= 1 || n <= 1) {
    for (int i = 0; i < n; i++) f(i, 0);
    return;
  }
  std::atomic<int> next(0);
  std::vector<std::thread> ts;
  int t = std::min(threads, n);
  for (int w = 0; w < t; w++) {
    ts.emplace_back([&, w] {
      for (;;) {
        int i = next.fetch_add(1);
        if (i >= n) break;
        f(i, w);
      }
    });
  }
  for (auto& th : ts) th.join();
}

}  // namespace fn
