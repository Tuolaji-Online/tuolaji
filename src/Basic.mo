/// Basic game-canister heuristics: the simplest legal move.
///
/// The tractor canister (`Table.mo`) uses this policy for its built-in bot
/// seats and timeout auto-play: leads are always the lowest single card, and
/// follows are constructed to satisfy the structural rules the server enforces
/// (`Follow.checkPlay`) while preferring the lowest cards. Declarations and
/// buries are the simplest legal choices. The fuller `Auto.mo` (used by the
/// standalone `bot` canister and the reference strategy) is kept separate.
import Array "mo:core/Array";
import List "mo:core/List";
import Nat "mo:core/Nat";
import VarArray "mo:core/VarArray";
import Card "Card";
import Combo "Combo";
import Trick "Trick";

module {
  /// Void-table slot count: four side suits plus trump.
  public let VOID_SIZE : Nat = 20;

  // ── play bookkeeping (kept for the game canister's state) ──────────

  /// Empty played-count vector (all 54 pair keys). The basic heuristics ignore
  /// the played pile; `Table.mo` still tracks it for its own purposes.
  public func emptyPlayed() : [Nat] {
    VarArray.toArray<Nat>(VarArray.repeat<Nat>(0, 54));
  };

  /// Slot index of a logical category: side suits 0..3, then trump.
  func voidIndex(cat : Card.Category) : Nat {
    switch (cat) {
      case (#Trump) { 4 };
      case (#Side(s)) { s };
    };
  };

  /// Empty void table: `seat * 5 + category` booleans, all clear.
  public func emptyVoids() : [Bool] {
    VarArray.toArray<Bool>(VarArray.repeat<Bool>(false, VOID_SIZE));
  };

  /// A copy of `voids` with `seat` marked void in `cat`.
  public func markVoid(voids : [Bool], seat : Nat, cat : Card.Category) : [Bool] {
    let out = Array.toVarArray<Bool>(voids);
    out[seat * 5 + voidIndex(cat)] := true;
    VarArray.toArray<Bool>(out);
  };

  // ── generic helpers ────────────────────────────────────────────────

  /// Multiset difference `hand - remove`, preserving `hand` order.
  func removeAll(hand : [Card.Card], remove : [Card.Card]) : [Card.Card] {
    let used = VarArray.repeat(false, remove.size());
    let out = List.empty<Card.Card>();
    for (c in hand.vals()) {
      var removed = false;
      var i = 0;
      while (i < remove.size() and not removed) {
        if (not used[i] and remove[i] == c) { used[i] := true; removed := true };
        i += 1;
      };
      if (not removed) { out.add(c) };
    };
    out.toArray();
  };

  func lessMagnitude(a : Card.Card, b : Card.Card, game : Card.Game) : Bool {
    let ta = if (Card.isTrump(a, game)) { 1 } else { 0 };
    let tb = if (Card.isTrump(b, game)) { 1 } else { 0 };
    if (ta != tb) { ta < tb } else { Card.rankValue(a, game) < Card.rankValue(b, game) };
  };

  /// Sort ascending by (non-trump first, then rank).
  func sortByMagnitude(cards : [Card.Card], game : Card.Game) : [Card.Card] {
    let out = Array.toVarArray<Card.Card>(cards);
    var i = 1;
    while (i < out.size()) {
      let key = out[i];
      var j = i;
      while (j > 0 and lessMagnitude(key, out[j - 1], game)) {
        out[j] := out[j - 1];
        j -= 1;
      };
      out[j] := key;
      i += 1;
    };
    VarArray.toArray<Card.Card>(out);
  };

  /// The `count` lowest cards, optionally excluding one logical category.
  public func lowestCards(
    hand : [Card.Card],
    count : Nat,
    game : Card.Game,
    avoid : ?Card.Category,
  ) : [Card.Card] {
    let candidates = switch (avoid) {
      case null { hand };
      case (?cat) { Array.filter<Card.Card>(hand, func(c) = Card.category(c, game) != cat) };
    };
    let sorted = sortByMagnitude(candidates, game);
    let n = if (count < sorted.size()) { count } else { sorted.size() };
    Array.tabulate<Card.Card>(n, func(i) = sorted[i]);
  };

  func countCategory(cards : [Card.Card], cat : Card.Category, game : Card.Game) : Nat {
    var n = 0;
    for (c in cards.vals()) {
      if (Card.category(c, game) == cat) { n += 1 };
    };
    n;
  };

  func lowestOfCategory(handCat : [Card.Card], game : Card.Game) : ?Card.Card {
    var best : ?Card.Card = null;
    var bestRv = 0;
    for (c in handCat.vals()) {
      let rv = Card.rankValue(c, game);
      switch (best) {
        case null { best := ?c; bestRv := rv };
        case (?_) { if (rv < bestRv) { best := ?c; bestRv := rv } };
      };
    };
    best;
  };

  func lowestPair(handCat : [Card.Card], cat : Card.Category, game : Card.Game) : ?Combo.Component {
    let pairs = Combo.getPairs(handCat, cat, game);
    if (pairs.size() == 0) { null } else { ?pairs[0] };
  };

  // ── lead ───────────────────────────────────────────────────────────

  /// Lead the single lowest card in hand. Any single is a legal lead. The
  /// played pile, void table and seat are accepted for API parity with
  /// `Auto.leadingMove` and ignored.
  public func leadingMove(
    hand : [Card.Card],
    _played : [Nat],
    _voids : [Bool],
    game : Card.Game,
    _mySeat : Nat,
  ) : [Card.Card] {
    if (hand.size() == 0) { return [] };
    let sorted = sortByMagnitude(hand, game);
    [sorted[0]];
  };

  // ── follow ─────────────────────────────────────────────────────────

  func followPair(hand : [Card.Card], handCat : [Card.Card], cat : Card.Category, game : Card.Game) : [Card.Card] {
    switch (lowestPair(handCat, cat, game)) {
      case (?p) { return p.cards };
      case null {};
    };
    let need = if (handCat.size() < 2) { handCat.size() } else { 2 };
    let sel = lowestCards(handCat, need, game, null);
    let remaining = removeAll(hand, sel);
    let fill = lowestCards(remaining, Nat.sub(2, need), game, ?cat);
    Array.concat(sel, fill);
  };

  func followTractor(
    hand : [Card.Card],
    handCat : [Card.Card],
    cat : Card.Category,
    len : Nat,
    game : Card.Game,
  ) : [Card.Card] {
    let N = len * 2;
    switch (Combo.findTractor(handCat, cat, len, game, false)) {
      case (?t) { return t.cards };
      case null {};
    };
    let H = handCat.size();
    let need = if (H < N) { H } else { N };

    // Preserve the longest hand tractor.
    let comps = Combo.decomposeComponents(handCat, cat, game);
    var longestCards : [Card.Card] = [];
    var longestLen = 0;
    for (c in comps.vals()) {
      if (Combo.isTractor(c) and c.length > longestLen) {
        longestLen := c.length;
        longestCards := c.cards;
      };
    };
    var sel = longestCards;

    // Top up pairs to the required count.
    let handPairs = Combo.getPairs(handCat, cat, game);
    let required = if (handPairs.size() < len) { handPairs.size() } else { len };
    var pairsSelected = longestLen;
    let remainingPairs = Combo.getPairs(removeAll(handCat, sel), cat, game);
    var i = 0;
    while (pairsSelected < required and i < remainingPairs.size()) {
      sel := Array.concat(sel, remainingPairs[i].cards);
      pairsSelected += 1;
      i += 1;
    };

    // Fill with same-category singles up to min(H, N).
    let remainingCat = sortByMagnitude(removeAll(handCat, sel), game);
    var catSelected = countCategory(sel, cat, game);
    var j = 0;
    while (catSelected < need and j < remainingCat.size()) {
      sel := Array.concat(sel, [remainingCat[j]]);
      catSelected += 1;
      j += 1;
    };

    // Sluff the rest from the lowest non-category cards.
    let fillCount = Nat.sub(N, sel.size());
    let fill = lowestCards(removeAll(hand, sel), fillCount, game, ?cat);
    Array.concat(sel, fill);
  };

  /// Build a follow for a throw lead, maximising tractor-slot coverage.
  func allocateComponents(
    hand : [Card.Card],
    cat : Card.Category,
    components : [Combo.Component],
    game : Card.Game,
  ) : [Card.Card] {
    let handCat = Array.filter<Card.Card>(hand, func(c) = Card.category(c, game) == cat);
    var slotPairs = 0;
    var pairSlots = 0;
    var singleSlots = 0;
    for (c in components.vals()) {
      switch (c.kind) {
        case (#Tractor) { slotPairs += c.length };
        case (#Pair) { pairSlots += 1 };
        case (#Single) { singleSlots += 1 };
      };
    };
    let N = slotPairs * 2 + pairSlots * 2 + singleSlots;
    let H = handCat.size();
    let wantCat = if (H < N) { H } else { N };

    let used = VarArray.repeat(false, 109);
    let sel = List.empty<Card.Card>();
    func take(cards : [Card.Card]) {
      for (c in cards.vals()) {
        if (not used[c]) { used[c] := true; sel.add(c) };
      };
    };
    func catAvail() : [Card.Card] {
      Array.filter<Card.Card>(handCat, func(c) = not used[c]);
    };

    // 1. Maximise tractor-slot pair-units.
    let handComps = Combo.decomposeComponents(handCat, cat, game);
    let runCardsList = Array.map<Combo.Component, [Card.Card]>(
      Array.filter<Combo.Component>(handComps, Combo.isTractor),
      func(c) = c.cards,
    );
    let windows = Combo.selectTractorWindows(runCardsList, slotPairs);
    var tractorPairsPlayed = 0;
    for (w in windows.vals()) {
      take(w);
      tractorPairsPlayed += w.size() / 2;
    };

    // 2. Fill remaining tractor-slot units and pair slots with plain pairs.
    let pairUnitsNeeded = Nat.add(Nat.sub(slotPairs, tractorPairsPlayed), pairSlots);
    let pairs = Combo.getPairs(catAvail(), cat, game);
    var pairsTaken = 0;
    var pi = 0;
    while (pairsTaken < pairUnitsNeeded and pi < pairs.size()) {
      take(pairs[pi].cards);
      pairsTaken += 1;
      pi += 1;
    };

    // 3. Fill single slots.
    let singles = sortByMagnitude(catAvail(), game);
    var singlesTaken = 0;
    var si = 0;
    while (singlesTaken < singleSlots and si < singles.size()) {
      take([singles[si]]);
      singlesTaken += 1;
      si += 1;
    };

    // 4. Guarantee the min(H, N) same-category count.
    var catSelected = countCategory(sel.toArray(), cat, game);
    let moreCat = sortByMagnitude(catAvail(), game);
    var mi = 0;
    while (catSelected < wantCat and mi < moreCat.size()) {
      take([moreCat[mi]]);
      catSelected += 1;
      mi += 1;
    };

    // 5. Sluff the remaining slots with the lowest non-category cards.
    let needFill = Nat.sub(N, sel.size());
    if (needFill > 0) {
      let sluff = lowestCards(
        Array.filter<Card.Card>(hand, func(c) = not used[c]),
        needFill,
        game,
        ?cat,
      );
      take(sluff);
    };
    sel.toArray();
  };

  /// Choose a legal follow for `lead`, preferring the lowest cards. The played
  /// pile, void table, trick and seat are accepted for API parity with
  /// `Auto.followMove` and ignored.
  public func followMove(
    hand : [Card.Card],
    _played : [Nat],
    _voids : [Bool],
    lead : Combo.Lead,
    _trick : [Trick.Play],
    game : Card.Game,
    _mySeat : Nat,
  ) : [Card.Card] {
    let cat = lead.category;
    let count = lead.count;
    let handCat = Array.filter<Card.Card>(hand, func(c) = Card.category(c, game) == cat);
    if (handCat.size() == 0) {
      // Void: any `count` cards are legal (lowest trumps last).
      return lowestCards(hand, count, game, null);
    };
    switch (lead.kind) {
      case (#Single) {
        switch (lowestOfCategory(handCat, game)) {
          case (?c) { [c] };
          case null { [hand[0]] };
        };
      };
      case (#Pair) { followPair(hand, handCat, cat, game) };
      case (#Tractor) { followTractor(hand, handCat, cat, lead.components[0].length, game) };
      case (#Throw) { allocateComponents(hand, cat, lead.components, game) };
    };
  };

  // ── declare ────────────────────────────────────────────────────────

  /// The simplest legal declaration: a big-joker pair, else a small-joker
  /// pair, else a level-card pair in any suit, else a single level card. Null
  /// means no call (the deal then defaults to No-Trump). The current declarer
  /// and own seat are accepted for API parity with `Auto.declareMoveCtx` and
  /// ignored.
  public func declareMoveCtx(
    hand : [Card.Card],
    game : Card.Game,
    _currentSeat : ?Nat,
    _mySeat : Nat,
  ) : ?[Card.Card] {
    let big = Array.filter<Card.Card>(hand, func(c) = Card.isBigJoker(c));
    if (big.size() >= 2) { return ?[big[0], big[1]] };
    let small = Array.filter<Card.Card>(hand, func(c) = Card.isSmallJoker(c));
    if (small.size() >= 2) { return ?[small[0], small[1]] };
    var suit = 0;
    while (suit < 4) {
      let levels = Array.filter<Card.Card>(
        hand,
        func(c) = Card.isLevel(c, game) and Card.suitOf(c) == ?suit,
      );
      if (levels.size() >= 2) { return ?[levels[0], levels[1]] };
      suit += 1;
    };
    let anyLevel = Array.filter<Card.Card>(hand, func(c) = Card.isLevel(c, game));
    if (anyLevel.size() >= 1) { return ?[anyLevel[0]] };
    null;
  };

  /// Context-free declaration convenience wrapper.
  public func declareMove(hand : [Card.Card], game : Card.Game) : ?[Card.Card] {
    declareMoveCtx(hand, game, null, 0);
  };

  // ── bury ───────────────────────────────────────────────────────────

  /// The banker's simplest bury: the 8 lowest cards, non-trumps first.
  public func buryMove(hand : [Card.Card], game : Card.Game) : [Card.Card] {
    lowestCards(hand, 8, game, null);
  };
}
