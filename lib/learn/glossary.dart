/// Poker glossary: static, hand-written plain-English definitions (no AI at
/// runtime), plus search and abbreviation lookup.
library;

enum GlossaryCategory { positions, actions, stacks, stats, concepts, app }

const glossaryCategoryLabels = {
  GlossaryCategory.positions: 'Positions',
  GlossaryCategory.actions: 'Actions',
  GlossaryCategory.stacks: 'Stacks & bets',
  GlossaryCategory.stats: 'Stats',
  GlossaryCategory.concepts: 'Concepts',
  GlossaryCategory.app: 'In Felt Notes',
};

class GlossaryEntry {
  /// Headword as shown, e.g. "UTG" or "3-bet".
  final String term;

  /// Spelled-out name shown next to an abbreviation, e.g. "Under the gun".
  final String? long;

  /// Other spellings that should find this entry ("shove", "push").
  final List<String> aliases;
  final GlossaryCategory category;
  final String definition;
  const GlossaryEntry(this.term, this.category, this.definition,
      {this.long, this.aliases = const []});

  /// Every name this entry answers to, lower-cased.
  Iterable<String> get names sync* {
    yield term.toLowerCase();
    if (long != null) yield long!.toLowerCase();
    for (final a in aliases) {
      yield a.toLowerCase();
    }
  }
}

const _p = GlossaryCategory.positions;
const _a = GlossaryCategory.actions;
const _s = GlossaryCategory.stacks;
const _st = GlossaryCategory.stats;
const _c = GlossaryCategory.concepts;
const _app = GlossaryCategory.app;

const glossary = <GlossaryEntry>[
  // ---- Positions ---------------------------------------------------------
  GlossaryEntry('UTG', _p,
      'First player to act before the flop, sitting just left of the big '
          'blind. With the whole table still to act behind, it opens the '
          'tightest range.',
      long: 'Under the gun'),
  GlossaryEntry('UTG+1', _p,
      'The seat directly left of UTG (UTG+2 is the next one). Still early '
          'position at a full table, so it opens only slightly wider than UTG.',
      long: 'Under the gun plus one',
      aliases: ['UTG+2', 'UTG+3']),
  GlossaryEntry('LJ', _p,
      'Lojack: the seat two to the right of the cutoff (just before the '
          'hijack). At 6-max it is the first seat to act, so this app calls '
          'it UTG there.',
      long: 'Lojack'),
  GlossaryEntry('HJ', _p,
      'Hijack: the seat just to the right of the cutoff, two seats before '
          'the button. A middle position.',
      long: 'Hijack'),
  GlossaryEntry('CO', _p,
      'Cutoff: the seat just to the right of the button. The second-best '
          'seat, so it opens a wide range.',
      long: 'Cutoff'),
  GlossaryEntry('BTN', _p,
      'Button (the dealer). Acts last on every street after the flop, which '
          'makes it the best seat and the widest opener. Heads-up the button '
          'also posts the small blind ("BTN/SB").',
      long: 'Button',
      aliases: ['Dealer', 'BTN/SB']),
  GlossaryEntry('SB', _p,
      'Small blind: posts half a big blind before the cards are dealt. Acts '
          'first on every street after the flop, so it is the worst seat.',
      long: 'Small blind'),
  GlossaryEntry('BB', _p,
      'Big blind: posts one full big blind and acts last before the flop. '
          'Already having a big blind in, it gets a good price to defend.',
      long: 'Big blind'),
  GlossaryEntry('Early position', _p,
      'The first seats to act before the flop (UTG, UTG+1). Many players '
          'still act behind you, so you play your tightest range.',
      aliases: ['EP']),
  GlossaryEntry('Middle position', _p,
      'The seats between early and late position (LJ, HJ). Ranges widen '
          'as fewer players are left to act.',
      aliases: ['MP']),
  GlossaryEntry('Late position', _p,
      'The cutoff and the button (some count the hijack too). You act last '
          'after the flop, so you can open many more hands.',
      aliases: ['LP']),
  GlossaryEntry('In position', _p,
      'Acting after your opponent on each street after the flop (IP). Out '
          'of position (OOP) means acting first, which is a disadvantage.',
      aliases: ['IP', 'OOP', 'Out of position', 'Position']),

  // ---- Actions -----------------------------------------------------------
  GlossaryEntry('Open', _a,
      'The first raise before the flop when everyone before you has folded '
          '(an open-raise). Same thing as RFI.',
      aliases: ['Open-raise', 'Opening']),
  GlossaryEntry('RFI', _a,
      'Raise first in: opening the pot with a raise when everyone before '
          'you folded. The "Open (RFI)" charts show which hands to do it with.',
      long: 'Raise first in'),
  GlossaryEntry('Limp', _a,
      'Just calling the big blind before the flop instead of raising. '
          'Common in home games, rare in GTO play outside the small blind.',
      aliases: ['Limper', 'Limping']),
  GlossaryEntry('Overlimp', _a,
      'Limping after someone else has already limped.',
      aliases: ['Over-limp']),
  GlossaryEntry('Complete', _a,
      'The small blind calling the extra half big blind to match the big '
          'blind in a pot nobody has raised.'),
  GlossaryEntry('Iso', _a,
      'Isolate: raise over one or more limpers to push the others out and '
          'play the limper heads-up, ideally in position.',
      long: 'Isolation raise',
      aliases: ['Isolate', 'Iso-raise']),
  GlossaryEntry('Raise', _a,
      'Increase the current bet, so others must put in more to stay in.'),
  GlossaryEntry('3-bet', _a,
      'A re-raise of an open raise before the flop. The big blind counts as '
          'bet 1 and the open as bet 2, so the re-raise is the third bet.',
      aliases: ['3bet', 'Three-bet', 'Re-raise']),
  GlossaryEntry('4-bet', _a,
      'A re-raise of a 3-bet. With 100bb stacks it is usually all-in or '
          'close to it by the 5-bet.',
      aliases: ['4bet', 'Four-bet']),
  GlossaryEntry('Squeeze', _a,
      'A 3-bet made after someone opened and one or more players called. '
          'The callers are "squeezed" in the middle.'),
  GlossaryEntry('Jam', _a,
      'Go all-in, usually as a raise. Shove and push mean the same.',
      aliases: ['Shove', 'Push', 'Jam / shove']),
  GlossaryEntry('All-in', _a,
      'Putting all your remaining chips in. You can never be made to put in '
          'more, and you can only win as much from each player as you put in.',
      aliases: ['All in']),
  GlossaryEntry('Call', _a,
      'Match the current bet to stay in the hand.'),
  GlossaryEntry('Fold', _a,
      'Give up the hand, and with it any chips you already put in the pot.'),
  GlossaryEntry('Check', _a,
      'Pass the action without betting. Only possible when nobody has bet '
          'on this street (or you are the big blind in an unraised pot).'),
  GlossaryEntry('C-bet', _a,
      'Continuation bet: a bet on the flop by the player who made the last '
          'raise before the flop, "continuing" the aggression.',
      long: 'Continuation bet',
      aliases: ['Cbet']),
  GlossaryEntry('Donk', _a,
      'Donk bet: betting into the player who raised on the previous street, '
          'from out of position, before they get a chance to c-bet.',
      aliases: ['Donk bet', 'Lead']),
  GlossaryEntry('Check-raise', _a,
      'Check, then raise after an opponent bets. A strong move out of '
          'position, with value hands and some bluffs.'),
  GlossaryEntry('Overbet', _a,
      'A bet bigger than the pot. Used with very strong hands and bluffs '
          'when your range has the edge.'),

  // ---- Stacks & bets -----------------------------------------------------
  GlossaryEntry('bb', _s,
      'Big blinds, the unit stacks and bets are measured in. A 2.5bb open '
          'is two and a half big blinds.',
      long: 'Big blinds'),
  GlossaryEntry('5bb', _s,
      'A stack (or bet) of 5 big blinds. "10bb" in the push/fold charts is '
          'a 10 big blind stack.',
      aliases: ['10bb', '20bb', '100bb']),
  GlossaryEntry('Effective stack', _s,
      'The smaller of the stacks involved: the most two players can win or '
          'lose against each other. Charts are read at the effective stack.',
      aliases: ['Effective']),
  GlossaryEntry('Push/fold', _s,
      'Short-stack play (roughly 15bb or less) where the only options are '
          'all-in or fold. Small raises waste too much of the stack.',
      aliases: ['Push fold', 'Push-fold']),
  GlossaryEntry('Blinds', _s,
      'The forced bets (small blind and big blind) posted before the cards, '
          'so every hand has something to win.',
      aliases: ['Blind']),
  GlossaryEntry('Ante', _s,
      'A small forced bet from every player (or the big blind for all) on '
          'top of the blinds, common late in tournaments. Antes make you play '
          'wider.'),

  // ---- Stats -------------------------------------------------------------
  GlossaryEntry('VPIP', _st,
      'Voluntarily put money in pot: the % of hands where you call or raise '
          'before the flop. Posting a blind does not count.',
      long: 'Voluntarily put money in pot'),
  GlossaryEntry('PFR', _st,
      'Preflop raise: the % of hands you raise before the flop. Close to '
          'your VPIP means you raise rather than call.',
      long: 'Preflop raise'),
  GlossaryEntry('3-bet %', _st,
      'How often you 3-bet when you get the chance (someone opened in front '
          'of you).',
      aliases: ['3-bet percentage', '3bet%']),
  GlossaryEntry('AF', _st,
      'Aggression factor: (bets + raises) divided by calls after the flop. '
          'Above about 2 is aggressive, below 1 is passive.',
      long: 'Aggression factor'),
  GlossaryEntry('WTSD', _st,
      'Went to showdown: of the hands where you saw the flop, the % you '
          'played all the way to showing cards.',
      long: 'Went to showdown'),
  GlossaryEntry('Fold to c-bet', _st,
      'How often you fold when facing a continuation bet. Too high and '
          'opponents can c-bet any two cards.',
      aliases: ['Fold to cbet']),

  // ---- Concepts ----------------------------------------------------------
  GlossaryEntry('GTO', _c,
      'Game-theory optimal: a strategy that cannot be exploited. It does not '
          'try to read opponents; it just never gives them an edge.',
      long: 'Game-theory optimal'),
  GlossaryEntry('Range', _c,
      'All the hands a player could hold in a spot (and how often each). '
          'You play your whole range, not just the cards in front of you.'),
  GlossaryEntry('Equity', _c,
      'Your share of the pot if all the remaining cards were dealt with no '
          'more betting. AA has about 82% equity against KK.'),
  GlossaryEntry('Pot odds', _c,
      'The price of a call: your call divided by the pot after you call. '
          'Calling 10 to make a 40 pot needs 25% equity to break even.'),
  GlossaryEntry('EV', _c,
      'Expected value: what a decision wins or loses on average over many '
          'repeats. +EV makes money long term, even if this hand loses.',
      long: 'Expected value'),
  GlossaryEntry('Exploitability', _c,
      'How much a perfect counter-strategy would win against a strategy. '
          'GTO has zero; every leak adds some.',
      aliases: ['Exploitable']),
  GlossaryEntry('Exploit', _c,
      'Moving away from GTO on purpose to punish a specific opponent\'s '
          'mistakes, e.g. bluffing less against someone who never folds.'),
  GlossaryEntry('Nash', _c,
      'Nash equilibrium: strategies where no player can do better by '
          'changing only their own. The push/fold charts here are one.',
      long: 'Nash equilibrium',
      aliases: ['Equilibrium']),
  GlossaryEntry('Solver', _c,
      'Software that computes an equilibrium strategy by having the '
          'strategies play each other over and over until neither can improve.'),
  GlossaryEntry('CFR', _c,
      'Counterfactual regret minimisation: the algorithm most poker solvers '
          'use (Felt Notes solves its river spots with the CFR+ variant).',
      long: 'Counterfactual regret minimisation',
      aliases: ['CFR+']),
  GlossaryEntry('Mixed hand', _c,
      'A hand the solver plays more than one way, e.g. raise 60%, fold 40%. '
          'Either action is fine; the mix keeps you hard to read.',
      aliases: ['Mixed', 'Mix', 'Mixing']),
  GlossaryEntry('Blocker', _c,
      'A card in your hand that makes some opponent hands less likely. '
          'On a three-spade board, holding the A♠ means nobody has the nut flush.',
      aliases: ['Blockers', 'Card removal']),
  GlossaryEntry('Suited', _c,
      'Both hole cards are the same suit, written with "s": AKs. Suited '
          'hands make flushes, so they play better than offsuit ones.',
      aliases: ['s']),
  GlossaryEntry('Offsuit', _c,
      'The two hole cards are different suits, written with "o": AKo.',
      aliases: ['o', 'Off-suit']),
  GlossaryEntry('Pocket pair', _c,
      'Two hole cards of the same rank, such as 77. They sit on the '
          'diagonal of the range grid.',
      aliases: ['Pair', 'Pocket pairs']),
  GlossaryEntry('Broadway', _c,
      'The cards ten to ace (T, J, Q, K, A). A broadway straight is '
          'A-K-Q-J-T, the highest straight.',
      aliases: ['Broadways']),
  GlossaryEntry('Suited connector', _c,
      'Two cards next to each other in rank and of the same suit, like 87s. '
          'They make straights and flushes.',
      aliases: ['Suited connectors', 'Connector']),
  GlossaryEntry('Dry board', _c,
      'A flop with few draws, such as K♠7♦2♣: unlikely to have changed who '
          'is ahead. Good for small c-bets.',
      aliases: ['Dry']),
  GlossaryEntry('Wet board', _c,
      'A flop full of straight and flush draws, such as J♥T♥9♣. The lead '
          'can change on the turn, so bets get bigger.',
      aliases: ['Wet']),
  GlossaryEntry('Nuts', _c,
      'The best possible hand given the board. The "nut flush" is the '
          'ace-high flush.',
      aliases: ['Nut', 'The nuts']),
  GlossaryEntry('Cooler', _c,
      'A big hand losing to an even bigger one, where the money goes in '
          'either way. Bad luck, not a mistake.'),
  GlossaryEntry('Bad beat', _c,
      'Losing a hand you were a big favourite to win when the money went '
          'in, to a lucky card.',
      aliases: ['Beat']),
  GlossaryEntry('Suckout', _c,
      'Winning from far behind by hitting a lucky card: the other side of a '
          'bad beat.',
      aliases: ['Suck out', 'Suck-out']),
  GlossaryEntry('Outs', _c,
      'Cards still in the deck that would improve your hand to the likely '
          'winner. A flush draw on the flop has 9.',
      aliases: ['Out']),
  GlossaryEntry('Kicker', _c,
      'The side card that breaks ties between equal hands: AK beats AQ on '
          'an ace-high board thanks to the king kicker.'),
  GlossaryEntry('Leak', _c,
      'A mistake you keep making in the same kind of spot, slowly costing '
          'money. Felt Notes tracks yours.',
      aliases: ['Leaks']),

  // ---- In Felt Notes -----------------------------------------------------
  GlossaryEntry('Daily 10', _app,
      'The same 10 hands for everyone each day. One try per day; keep a '
          'streak going and share your result.',
      aliases: ['Daily', 'Daily ten']),
  GlossaryEntry('Card luck', _app,
      'How good your dealt cards were: average equity against a random '
          'hand, minus 50%. +3.0% means better cards than average.',
      aliases: ['Luck']),
  GlossaryEntry('Golden Arm', _app,
      'Night recap award for the dealer who dealt you the best cards '
          '(highest card luck), among dealers with enough hands.'),
  GlossaryEntry('Dealer of Doom', _app,
      'Night recap award for the dealer who dealt you the worst cards '
          '(lowest card luck), among dealers with enough hands.',
      aliases: ['Doom']),
  GlossaryEntry('Solver dice', _app,
      'For a mixed hand, a 0–99 roll that shows which action the solver\'s '
          'mix would pick this time. Settings can hide it.',
      aliases: ['Dice']),
  GlossaryEntry('Spaced repetition', _app,
      'Hands you miss come back in 10 minutes, then after 1, 3, 7 and 21 '
          'days as you keep getting them right ("Drill my leaks").',
      aliases: ['SR', 'Leitner']),
  GlossaryEntry('GTO grade', _app,
      'In the home game: the share of your graded decisions (raise or fold, '
          'folded to you) that a GTO chart would also make.',
      aliases: ['GTO score']),
  GlossaryEntry('Mistake heatmap', _app,
      'Charts → My mistakes: each hand coloured by how often you have '
          'played it right in that spot, recent answers counting most.',
      aliases: ['My mistakes', 'Heatmap']),
];

String _norm(String s) => s.toLowerCase().trim();

/// Entries matching [query], best first: an exact name match (exact case
/// first, so "bb" finds big blinds and "BB" the big blind seat), then names
/// starting with it, then names containing it, then definitions containing
/// it. An empty query returns the whole glossary in its listed order.
List<GlossaryEntry> searchGlossary(String query,
    [List<GlossaryEntry> entries = glossary]) {
  final raw = query.trim();
  final q = _norm(query);
  if (q.isEmpty) return List.of(entries);
  int? rank(GlossaryEntry e) {
    if (e.term == raw || e.aliases.contains(raw)) return 0;
    final names = e.names.toList();
    if (names.contains(q)) return 1;
    // Single letters ("s", "o") only match a whole name.
    if (q.length < 2) return null;
    if (names.any((n) => n.startsWith(q))) return 2;
    if (names.any((n) => n.contains(q))) return 3;
    if (e.definition.toLowerCase().contains(q)) return 4;
    return null;
  }

  final hits = <(int, int, GlossaryEntry)>[];
  for (var i = 0; i < entries.length; i++) {
    final r = rank(entries[i]);
    if (r != null) hits.add((r, i, entries[i]));
  }
  hits.sort((a, b) => a.$1 != b.$1 ? a.$1 - b.$1 : a.$2 - b.$2);
  return [for (final h in hits) h.$3];
}

/// The entry an on-screen abbreviation such as "CO" or "UTG+2" refers to,
/// or null when the glossary has none. Exact case wins ("BB" vs "bb").
GlossaryEntry? lookupTerm(String label) {
  final raw = label.trim();
  for (final e in glossary) {
    if (e.term == raw || e.aliases.contains(raw)) return e;
  }
  final q = _norm(label);
  for (final e in glossary) {
    if (e.names.contains(q)) return e;
  }
  return null;
}
