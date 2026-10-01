/// Trick resolution (RULES-trick): kill validity and winner comparison.
///
/// Ported from `simulator.js`: isValidKill / determineTrickWinner /
/// extractSlots / compareSlots / highestByComponents.
import Array "mo:core/Array";
import List "mo:core/List";
import Card "Card";
import Combo "Combo";
import Util "Util";

module {
  public type Play = {
    seat : Nat;
    cards : [Card.Card];
    handBefore : [Card.Card];
  };

  type Candidate = {
    seat : Nat;
    cards : [Card.Card];
    relevant : [Card.Card];
    isKill : Bool;
  };

  type Slot = { kind : Combo.ComponentKind; length : Nat; topRank : Nat };

  func sortSlots(slots : [Slot]) : [Slot] {
    Util.sortBy<Slot>(slots, func(a, b) {
      let sa = Combo.componentStrength(a.kind);
      let sb = Combo.componentStrength(b.kind);
      if (sa != sb) { Util.cmpNat(sb, sa) } else { Util.cmpNat(b.topRank, a.topRank) };
    });
  };

  /// A kill must match the lead's type and card count, and be all trump.
  public func isValidKill(killCards : [Card.Card], lead : Combo.Lead, game : Card.Game) : Bool {
    if (killCards.size() != lead.count) { return false };
    for (c in killCards.vals()) {
      if (not Card.isTrump(c, game)) { return false };
    };
    switch (lead.kind) {
      case (#Throw) {
        var hasPairsOrTractors = false;
        for (c in lead.components.vals()) {
          switch (c.kind) {
            case (#Pair) { hasPairsOrTractors := true };
            case (#Tractor) { hasPairsOrTractors := true };
            case (#Single) {};
          };
        };
        if (not hasPairsOrTractors) { return true };
        Combo.canExactMatchComponents(killCards, #Trump, lead.components, game);
      };
      case (#Single) { true };
      case (#Pair) {
        let killComps = Combo.decomposeComponents(killCards, #Trump, game);
        killComps.size() == 1 and Combo.isPair(killComps[0]);
      };
      case (#Tractor) {
        let killComps = Combo.decomposeComponents(killCards, #Trump, game);
        killComps.size() == 1 and Combo.isTractor(killComps[0]) and
        killComps[0].length == lead.components[0].length;
      };
    };
  };

  func extractSlots(relevant : [Card.Card], lead : Combo.Lead, game : Card.Game) : ?[Slot] {
    switch (Combo.matchComponents(relevant, lead.components, game)) {
      case null { null };
      case (?assignment) {
        ?sortSlots(
          Array.map<Combo.Component, Slot>(
            assignment,
            func(a) { { kind = a.kind; length = a.length; topRank = a.topRank } },
          )
        );
      };
    };
  };

  func compareSlotValues(a : Slot, b : Slot) : Int {
    let ta = Combo.componentStrength(a.kind);
    let tb = Combo.componentStrength(b.kind);
    if (ta != tb) { return Util.cmpNat(ta, tb) };
    if (a.topRank != b.topRank) { return Util.cmpNat(a.topRank, b.topRank) };
    Util.cmpNat(a.length, b.length);
  };

  func compareSlots(a : Candidate, b : Candidate, lead : Combo.Lead, game : Card.Game) : Int {
    let sa = extractSlots(a.relevant, lead, game);
    let sb = extractSlots(b.relevant, lead, game);
    switch (sa, sb) {
      case (null, null) { return 0 };
      case (null, _) { return -1 };
      case (_, null) { return 1 };
      case (?slotsA, ?slotsB) {
        let n = if (slotsA.size() > slotsB.size()) { slotsA.size() } else { slotsB.size() };
        var i = 0;
        while (i < n) {
          let ca = if (i < slotsA.size()) { ?slotsA[i] } else { null };
          let cb = if (i < slotsB.size()) { ?slotsB[i] } else { null };
          switch (ca, cb) {
            case (null, null) { return 0 };
            case (null, _) { return -1 };
            case (_, null) { return 1 };
            case (?x, ?y) {
              let cmp = compareSlotValues(x, y);
              if (cmp != 0) { return cmp };
            };
          };
          i += 1;
        };
      };
    };
    0;
  };

  func highestByComponents(candidates : [Candidate], lead : Combo.Lead, game : Card.Game, fallback : Nat) : Nat {
    if (candidates.size() == 0) { return fallback };
    var best = candidates[0];
    var i = 1;
    while (i < candidates.size()) {
      if (compareSlots(candidates[i], best, lead, game) > 0) {
        best := candidates[i];
      };
      i += 1;
    };
    best.seat;
  };

  /// Resolve the winning seat of a trick.
  public func determineTrickWinner(plays : [Play], lead : Combo.Lead, game : Card.Game) : Nat {
    let cands = List.empty<Candidate>();
    for (play in plays.vals()) {
      let catCards = Array.filter<Card.Card>(play.cards, func(c) = Card.category(c, game) == lead.category);
      let trumpCards = Array.filter<Card.Card>(play.cards, func(c) = Card.isTrump(c, game));
      var isVoid = true;
      for (c in play.handBefore.vals()) {
        if (Card.category(c, game) == lead.category) { isVoid := false };
      };
      let isTrumpLead = switch (lead.category) { case (#Trump) true; case _ false };
      if (isTrumpLead) {
        if (catCards.size() == lead.count) {
          cands.add({ seat = play.seat; cards = play.cards; relevant = catCards; isKill = false });
        };
      } else {
        if (isVoid and trumpCards.size() == lead.count) {
          cands.add({ seat = play.seat; cards = play.cards; relevant = trumpCards; isKill = true });
        } else if (catCards.size() == lead.count) {
          cands.add({ seat = play.seat; cards = play.cards; relevant = catCards; isKill = false });
        };
      };
    };

    let all = cands.toArray();
    let isTrumpLead = switch (lead.category) { case (#Trump) true; case _ false };
    if (not isTrumpLead) {
      let validKillers = List.empty<Candidate>();
      for (c in all.vals()) {
        if (c.isKill and isValidKill(c.relevant, lead, game)) { validKillers.add(c) };
      };
      let killers = validKillers.toArray();
      if (lead.kind == #Throw) {
        if (killers.size() == 0) { return plays[0].seat };
        return highestByComponents(killers, lead, game, plays[0].seat);
      };
      if (killers.size() > 0) {
        return highestByComponents(killers, lead, game, plays[0].seat);
      };
      let sameSuit = List.empty<Candidate>();
      for (c in all.vals()) {
        if (not c.isKill) { sameSuit.add(c) };
      };
      return highestByComponents(sameSuit.toArray(), lead, game, plays[0].seat);
    };
    highestByComponents(all, lead, game, plays[0].seat);
  };
}
