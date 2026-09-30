/// Combination classification, decomposition, and structural matching.
///
/// Ported from `simulator.js`: getPairs / findTractor / decomposeComponents /
/// determineLeadType / componentTypeStrength / compareComponents /
/// pairEquivalents / matchComponents / maxTractorUnitsCoverable /
/// selectTractorWindows / hasHigher{Single,Pair,Tractor}.
import Array "mo:core/Array";
import List "mo:core/List";
import Nat "mo:core/Nat";
import VarArray "mo:core/VarArray";
import Card "Card";
import Types "Types";

module {
  public type ComponentKind = { #Single; #Pair; #Tractor };

  public type Component = {
    kind : ComponentKind;
    length : Nat; // tractor: number of pairs; pair/single: 1
    topRank : Nat;
    startRank : Nat;
    cards : [Card.Card];
  };

  public type LeadKind = { #Single; #Pair; #Tractor; #Throw };

  public type Lead = {
    kind : LeadKind;
    category : Card.Category;
    count : Nat;
    components : [Component];
  };

  type PairInfo = { keyId : Nat; rv : Nat; cards : [Card.Card] };

  // ── generic helpers ────────────────────────────────────────────────

  func cmpNat(a : Nat, b : Nat) : Int {
    if (a < b) { -1 } else if (a > b) { 1 } else { 0 }
  };

  func sortBy<T>(arr : [T], cmp : (T, T) -> Int) : [T] {
    let n = arr.size();
    let out = Array.toVarArray(arr);
    var i = 1;
    while (i < n) {
      let key = out[i];
      var j = i;
      while (j > 0 and cmp(out[j - 1], key) > 0) {
        out[j] := out[j - 1];
        j -= 1;
      };
      out[j] := key;
      i += 1;
    };
    VarArray.toArray(out);
  };

  public func isSingle(c : Component) : Bool { switch (c.kind) { case (#Single) true; case _ false } };
  public func isPair(c : Component) : Bool { switch (c.kind) { case (#Pair) true; case _ false } };
  public func isTractor(c : Component) : Bool { switch (c.kind) { case (#Tractor) true; case _ false } };

  public func componentStrength(kind : ComponentKind) : Nat {
    switch (kind) {
      case (#Tractor) { 3 };
      case (#Pair) { 2 };
      case (#Single) { 1 };
    };
  };

  public func compareComponents(a : Component, b : Component) : Int {
    let ta = componentStrength(a.kind);
    let tb = componentStrength(b.kind);
    if (ta != tb) { return cmpNat(ta, tb) };
    if (a.topRank != b.topRank) { return cmpNat(a.topRank, b.topRank) };
    cmpNat(a.length, b.length);
  };

  public func pairEquivalents(components : [Component]) : Nat {
    var sum = 0;
    for (comp in components.vals()) {
      switch (comp.kind) {
        case (#Tractor) { sum += comp.length };
        case (#Pair) { sum += 1 };
        case (#Single) {};
      };
    };
    sum;
  };

  // ── pairs / tractors ───────────────────────────────────────────────

  func getPairInfos(cards : [Card.Card], category : Card.Category, game : Card.Game) : [PairInfo] {
    let seen = VarArray.repeat(false, Card.PAIR_KEY_COUNT);
    let a0 = VarArray.repeat<?Card.Card>(null, Card.PAIR_KEY_COUNT);
    let a1 = VarArray.repeat<?Card.Card>(null, Card.PAIR_KEY_COUNT);
    for (c in cards.vals()) {
      if (Card.category(c, game) == category) {
        let k = Card.pairKeyId(c);
        seen[k] := true;
        switch (a0[k]) {
          case null { a0[k] := ?c };
          case (?_) {
            switch (a1[k]) {
              case null { a1[k] := ?c };
              case (?_) {};
            };
          };
        };
      };
    };
    let infos = List.empty<PairInfo>();
    var k = 0;
    while (k < Card.PAIR_KEY_COUNT) {
      if (seen[k]) {
        switch (a0[k], a1[k]) {
          case (?x, ?y) {
            infos.add({ keyId = k; rv = Card.rankValue(x, game); cards = [x, y] });
          };
          case _ {};
        };
      };
      k += 1;
    };
    sortBy<PairInfo>(
      infos.toArray(),
      func(a, b) {
        let c = cmpNat(a.rv, b.rv);
        if (c != 0) { c } else { cmpNat(a.keyId, b.keyId) };
      },
    );
  };

  /// Pairs in `cards` (same logical `category`), ordered by ascending rank.
  public func getPairs(cards : [Card.Card], category : Card.Category, game : Card.Game) : [Component] {
    Array.map<PairInfo, Component>(
      getPairInfos(cards, category, game),
      func(p) { { kind = #Pair; length = 1; topRank = p.rv; startRank = p.rv; cards = p.cards } },
    );
  };

  /// Find a tractor of exactly `length` pairs. `preferHighest` selects the
  /// window with the largest top rank, else the smallest start rank.
  public func findTractor(
    hand : [Card.Card],
    category : Card.Category,
    length : Nat,
    game : Card.Game,
    preferHighest : Bool,
  ) : ?Component {
    let pairs = getPairInfos(hand, category, game);
    var best : ?(Nat, Nat, Nat) = null; // (startIdx, startRank, topRank)
    var i = 0;
    while (i < pairs.size()) {
      var j = i;
      while (j + 1 < pairs.size() and pairs[j + 1].rv == pairs[j].rv + 1) {
        j += 1;
      };
      let runLen = Nat.sub(j, i) + 1;
      if (runLen >= length) {
        var s = i;
        while (s + Nat.sub(length, 1) <= j) {
          let startRank = pairs[s].rv;
          let topRank = pairs[s + length - 1].rv;
          switch (best) {
            case null { best := ?(s, startRank, topRank) };
            case (?(_, bStart, bTop)) {
              if (preferHighest) {
                if (topRank > bTop) { best := ?(s, startRank, topRank) };
              } else {
                if (startRank < bStart) { best := ?(s, startRank, topRank) };
              };
            };
          };
          s += 1;
        };
      };
      i := j + 1;
    };
    switch (best) {
      case null { null };
      case (?(s, startRank, topRank)) {
        var cards : [Card.Card] = [];
        var t = 0;
        while (t < length) {
          cards := Array.concat(cards, pairs[s + t].cards);
          t += 1;
        };
        ?{ kind = #Tractor; length; topRank; startRank; cards };
      };
    };
  };

  // ── decomposition ──────────────────────────────────────────────────

  /// Decompose `cards` (all same logical `category`) into maximal tractors,
  /// then pairs, then singles.
  public func decomposeComponents(cards : [Card.Card], category : Card.Category, game : Card.Game) : [Component] {
    let pairs = getPairInfos(cards, category, game);
    let usedPair = VarArray.repeat(false, pairs.size());
    let comps = List.empty<Component>();

    // Maximal tractors: a run of k >= 2 consecutive pairs is ONE component.
    var i = 0;
    while (i < pairs.size()) {
      var j = i;
      while (j + 1 < pairs.size() and pairs[j + 1].rv == pairs[j].rv + 1) {
        j += 1;
      };
      let runLen = Nat.sub(j, i) + 1;
      if (runLen >= 2) {
        var runCards : [Card.Card] = [];
        var t = i;
        while (t <= j) {
          runCards := Array.concat(runCards, pairs[t].cards);
          usedPair[t] := true;
          t += 1;
        };
        comps.add({
          kind = #Tractor;
          length = runLen;
          topRank = pairs[j].rv;
          startRank = pairs[i].rv;
          cards = runCards;
        });
      };
      i := j + 1;
    };

    var p = 0;
    while (p < pairs.size()) {
      if (not usedPair[p]) {
        comps.add({
          kind = #Pair;
          length = 1;
          topRank = pairs[p].rv;
          startRank = pairs[p].rv;
          cards = pairs[p].cards;
        });
      };
      p += 1;
    };

    let inComp = VarArray.repeat(false, 109);
    for (comp in comps.values()) {
      for (c in comp.cards.vals()) { inComp[c] := true };
    };
    for (c in cards.vals()) {
      if (not inComp[c]) {
        let rv = Card.rankValue(c, game);
        comps.add({ kind = #Single; length = 1; topRank = rv; startRank = rv; cards = [c] });
      };
    };
    comps.toArray();
  };

  /// Classify a lead. Returns null when the cards span logical suits.
  public func determineLeadType(cards : [Card.Card], game : Card.Game) : ?Lead {
    if (cards.size() == 0) { return null };
    let category = Card.category(cards[0], game);
    for (c in cards.vals()) {
      if (Card.category(c, game) != category) { return null };
    };
    let comps = decomposeComponents(cards, category, game);
    if (cards.size() == 1) {
      return ?{ kind = #Single; category; count = 1; components = comps };
    };
    if (cards.size() == 2 and comps.size() == 1 and isPair(comps[0])) {
      return ?{ kind = #Pair; category; count = 2; components = comps };
    };
    if (comps.size() == 1 and isTractor(comps[0])) {
      return ?{ kind = #Tractor; category; count = comps[0].cards.size(); components = comps };
    };
    ?{ kind = #Throw; category; count = cards.size(); components = comps };
  };

  // ── exact structural matching (backtracking) ───────────────────────

  /// Can `pool` (already filtered to one logical category) satisfy every
  /// component in `components`? Tractor demands need consecutive-rank pairs.
  /// Returns the aligned assignment, or null.
  public func matchComponents(pool : [Card.Card], components : [Component], game : Card.Game) : ?[Component] {
    let present = VarArray.repeat(false, Card.PAIR_KEY_COUNT);
    let rvOf = VarArray.repeat<Nat>(0, Card.PAIR_KEY_COUNT);
    let countOf = VarArray.repeat<Nat>(0, Card.PAIR_KEY_COUNT);
    let a0 = VarArray.repeat<?Card.Card>(null, Card.PAIR_KEY_COUNT);
    let a1 = VarArray.repeat<?Card.Card>(null, Card.PAIR_KEY_COUNT);
    for (c in pool.vals()) {
      let k = Card.pairKeyId(c);
      if (not present[k]) {
        present[k] := true;
        rvOf[k] := Card.rankValue(c, game);
      };
      if (countOf[k] == 0) { a0[k] := ?c } else if (countOf[k] == 1) { a1[k] := ?c };
      countOf[k] += 1;
    };
    let used = VarArray.repeat<Nat>(0, Card.PAIR_KEY_COUNT);
    let avail = func(k : Nat) : Nat { countOf[k] - used[k] };

    func entryCards(k : Nat) : [Card.Card] {
      switch (a0[k], a1[k]) {
        case (?x, ?y) { [x, y] };
        case (?x, null) { [x] };
        case _ { [] };
      };
    };

    // Most-constrained demands first: tractors (longest first), then pairs,
    // then singles. Stable ordering by original component index.
    let order = sortBy<Nat>(
      Array.tabulate<Nat>(components.size(), func i = i),
      func(a, b) {
        let pa = componentStrength(components[a].kind);
        let pb = componentStrength(components[b].kind);
        if (pa != pb) { return cmpNat(pb, pa) }; // stronger first
        if (isTractor(components[a]) and isTractor(components[b])) {
          return cmpNat(components[b].length, components[a].length); // longer first
        };
        0;
      },
    );

    let dummy : Component = { kind = #Single; length = 1; topRank = 0; startRank = 0; cards = [] };
    let result = VarArray.repeat<Component>(dummy, components.size());

    func keysWithAvail(min : Nat) : [Nat] {
      let ks = List.empty<Nat>();
      var k = 0;
      while (k < Card.PAIR_KEY_COUNT) {
        if (present[k] and avail(k) >= min) { ks.add(k) };
        k += 1;
      };
      // highest rank first, ties by ascending key
      sortBy<Nat>(
        ks.toArray(),
        func(a, b) {
          let c = cmpNat(rvOf[b], rvOf[a]);
          if (c != 0) { c } else { cmpNat(a, b) };
        },
      );
    };

    func solve(i : Nat) : Bool {
      if (i == order.size()) { return true };
      let ci = order[i];
      let comp = components[ci];
      switch (comp.kind) {
        case (#Tractor) {
          let L = comp.length;
          let bases = List.empty<Nat>();
          var k = 0;
          while (k < Card.PAIR_KEY_COUNT) {
            if (present[k] and avail(k) >= 2) {
              let rv = rvOf[k];
              var dup = false;
              for (b in bases.values()) { if (b == rv) { dup := true } };
              if (not dup) { bases.add(rv) };
            };
            k += 1;
          };
          let baseArr = sortBy<Nat>(bases.toArray(), func(a, b) { cmpNat(b, a) });
          for (base in baseArr.vals()) {
            let picks = VarArray.repeat<Nat>(0, L);
            func step(j : Nat) : Bool {
              if (j == L) { return true };
              let target = base + j;
              var kk = 0;
              while (kk < Card.PAIR_KEY_COUNT) {
                if (present[kk] and rvOf[kk] == target and avail(kk) >= 2) {
                  picks[j] := kk;
                  used[kk] += 2;
                  if (step(j + 1)) { return true };
                  used[kk] -= 2;
                };
                kk += 1;
              };
              false;
            };
            if (step(0)) {
              var cards : [Card.Card] = [];
              var top = 0;
              var start = 0;
              var j = 0;
              while (j < L) {
                let kk = picks[j];
                cards := Array.concat(cards, entryCards(kk));
                if (j == 0) { start := rvOf[kk] };
                if (rvOf[kk] > top) { top := rvOf[kk] };
                j += 1;
              };
              result[ci] := { kind = #Tractor; length = L; topRank = top; startRank = start; cards };
              if (solve(i + 1)) { return true };
              j := 0;
              while (j < L) { used[picks[j]] -= 2; j += 1 };
            };
          };
          false;
        };
        case (#Pair) {
          for (kk in keysWithAvail(2).vals()) {
            used[kk] += 2;
            let rv = rvOf[kk];
            result[ci] := { kind = #Pair; length = 1; topRank = rv; startRank = rv; cards = entryCards(kk) };
            if (solve(i + 1)) { return true };
            used[kk] -= 2;
          };
          false;
        };
        case (#Single) {
          for (kk in keysWithAvail(1).vals()) {
            let card = entryCards(kk)[used[kk]];
            used[kk] += 1;
            let rv = rvOf[kk];
            result[ci] := { kind = #Single; length = 1; topRank = rv; startRank = rv; cards = [card] };
            if (solve(i + 1)) { return true };
            used[kk] -= 1;
          };
          false;
        };
      };
    };

    if (solve(0)) { ?VarArray.toArray(result) } else { null };
  };

  public func canExactMatchComponents(
    hand : [Card.Card],
    category : Card.Category,
    components : [Component],
    game : Card.Game,
  ) : Bool {
    let pool = Array.filter<Card.Card>(hand, func(c) = Card.category(c, game) == category);
    matchComponents(pool, components, game) != null;
  };

  // ── tractor-slot coverage (throw follows) ──────────────────────────

  /// Maximum tractor pair-units the hand's maximal runs can cover, capped by
  /// the lead's total tractor-slot pair-units `slotPairs`.
  public func maxTractorUnitsCoverable(runLengths : [Nat], slotPairs : Nat) : Nat {
    if (slotPairs < 2) { return 0 };
    let reach = VarArray.repeat(false, slotPairs + 1);
    reach[0] := true;
    for (r in runLengths.vals()) {
      let next = VarArray.repeat(false, slotPairs + 1);
      var cur = 0;
      while (cur <= slotPairs) {
        if (reach[cur]) {
          next[cur] := true;
          var v = 2;
          while (v <= r and cur + v <= slotPairs) {
            next[cur + v] := true;
            v += 1;
          };
        };
        cur += 1;
      };
      var t = 0;
      while (t <= slotPairs) { reach[t] := next[t]; t += 1 };
    };
    var best = 0;
    var t = 0;
    while (t <= slotPairs) {
      if (reach[t] and t > best) { best := t };
      t += 1;
    };
    best;
  };

  /// Actual window cards achieving `maxTractorUnitsCoverable`: one window of
  /// the lowest `len >= 2` pairs per run.
  public func selectTractorWindows(runCardsList : [[Card.Card]], slotPairs : Nat) : [[Card.Card]] {
    if (slotPairs < 2) { return [] };
    var bestTotal = 0;
    var bestPicks : [(Nat, Nat)] = [];
    func bt(i : Nat, total : Nat, picks : List.List<(Nat, Nat)>) : () {
      if (i == runCardsList.size()) {
        if (total > bestTotal) {
          bestTotal := total;
          bestPicks := picks.toArray();
        };
        return;
      };
      bt(i + 1, total, picks);
      let r = runCardsList[i].size() / 2;
      var v = 2;
      while (v <= r) {
        if (total + v <= slotPairs) {
          picks.add((i, v));
          bt(i + 1, total + v, picks);
          ignore picks.removeLast();
        };
        v += 1;
      };
    };
    bt(0, 0, List.empty());
    Array.map<(Nat, Nat), [Card.Card]>(
      bestPicks,
      func(p) {
        let (runIdx, len) = p;
        Array.sliceToArray<Card.Card>(runCardsList[runIdx], 0, len * 2);
      },
    );
  };

  // ── throw beatability helpers ──────────────────────────────────────

  public func hasHigherSingle(hand : [Card.Card], category : Card.Category, rank : Nat, game : Card.Game) : Bool {
    var found = false;
    for (c in hand.vals()) {
      if (Card.category(c, game) == category and Card.rankValue(c, game) > rank) {
        found := true;
      };
    };
    found;
  };

  public func hasHigherPair(hand : [Card.Card], category : Card.Category, rank : Nat, game : Card.Game) : Bool {
    var found = false;
    for (p in getPairInfos(hand, category, game).vals()) {
      if (p.rv > rank) { found := true };
    };
    found;
  };

  public func hasHigherTractor(
    hand : [Card.Card],
    category : Card.Category,
    length : Nat,
    topRank : Nat,
    game : Card.Game,
  ) : Bool {
    switch (findTractor(hand, category, length, game, true)) {
      case (?t) { t.topRank > topRank };
      case null { false };
    };
  };

  // ── wire conversion ────────────────────────────────────────────────

  func splitPairs(cards : [Card.Card]) : [[Card.Card]] {
    let out = List.empty<[Card.Card]>();
    var i = 0;
    while (i + 1 < cards.size()) {
      out.add([cards[i], cards[i + 1]]);
      i += 2;
    };
    out.toArray();
  };

  /// Convert a classified lead into its wire representation.
  public func toInfo(lead : Lead) : Types.ComboInfo {
    switch (lead.kind) {
      case (#Single) { #Single(lead.components[0].cards[0]) };
      case (#Pair) { #Pair(lead.components[0].cards) };
      case (#Tractor) { #Tractor(splitPairs(lead.components[0].cards)) };
      case (#Throw) {
        let tractors = List.empty<[Card.Card]>();
        let pairs = List.empty<Card.Card>();
        let singles = List.empty<Card.Card>();
        for (c in lead.components.vals()) {
          switch (c.kind) {
            case (#Tractor) { tractors.add(c.cards) };
            case (#Pair) { for (x in c.cards.vals()) { pairs.add(x) } };
            case (#Single) { for (x in c.cards.vals()) { singles.add(x) } };
          };
        };
        #Throw({
          tractors = tractors.toArray();
          pairs = pairs.toArray();
          singles = singles.toArray();
        });
      };
    };
  };
}
