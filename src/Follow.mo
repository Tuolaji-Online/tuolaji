/// Follow legality (RULES-follow R1–R7) and same-suit maximisation.
///
/// Ported from `simulator.js:checkPlay`. Returns null when the follow is
/// legal, or a `CheckError` describing the violation.
import Array "mo:core/Array";
import Card "Card";
import Combo "Combo";
import Types "Types";

module {
  func longestTractorLength(comps : [Combo.Component]) : Nat {
    var best = 0;
    for (c in comps.vals()) {
      if (Combo.isTractor(c) and c.length > best) { best := c.length };
    };
    best;
  };

  func totalTractorPairs(comps : [Combo.Component]) : Nat {
    var sum = 0;
    for (c in comps.vals()) {
      if (Combo.isTractor(c)) { sum += c.length };
    };
    sum;
  };

  /// Validate a follower's play against the lead.
  public func checkPlay(
    leadPlay : [Card.Card],
    hand : [Card.Card],
    play : [Card.Card],
    game : Card.Game,
  ) : ?Types.CheckError {
    // R1: ownership.
    for (c in play.vals()) {
      if (not Card.contains(hand, c)) {
        return ?{ code = #CardNotInHand; detail = "card not in hand" };
      };
    };

    // Deck integrity is not checked here. A hand holding a third copy of a face
    // means the deal was corrupt, and rejecting the *follower* for it punished
    // the one player who could not fix it (and, on a real deck, could never
    // happen). `Table.validDeck` rejects such a deck when it is installed, so the
    // engine only ever adjudicates a permutation of the 108 canonical cards.
    if (play.size() != leadPlay.size()) {
      return ?{ code = #IllegalFollow; detail = "wrong number of cards" };
    };

    let lead = switch (Combo.determineLeadType(leadPlay, game)) {
      case null {
        return ?{ code = #IllegalLead; detail = "invalid lead" };
      };
      case (?l) { l };
    };
    let category = lead.category;
    let handCat = Array.filter<Card.Card>(hand, func(c) = Card.category(c, game) == category);
    let playCat = Array.filter<Card.Card>(play, func(c) = Card.category(c, game) == category);

    if (handCat.size() == 0) {
      return null;
    };

    let expectedCatCount = if (handCat.size() < leadPlay.size()) { handCat.size() } else { leadPlay.size() };
    if (playCat.size() != expectedCatCount) {
      return ?{ code = #IllegalFollow; detail = "must follow with the same logical suit up to hand size" };
    };

    switch (lead.kind) {
      case (#Single) { return null };
      case (#Pair) {
        let handPairs = Combo.getPairs(handCat, category, game);
        if (handPairs.size() > 0) {
          let playPairs = Combo.getPairs(playCat, category, game);
          if (playPairs.size() == 0) {
            return ?{ code = #IllegalFollow; detail = "must play a pair because you have one" };
          };
        };
        return null;
      };
      case (#Tractor) {
        let len = lead.components[0].length;
        let handComps = Combo.decomposeComponents(handCat, category, game);
        let longest = longestTractorLength(handComps);
        if (longest >= len) {
          let playComps = Combo.decomposeComponents(playCat, category, game);
          var hasTractor = false;
          for (c in playComps.vals()) {
            if (Combo.isTractor(c) and c.length >= len) { hasTractor := true };
          };
          if (not hasTractor) {
            return ?{ code = #IllegalFollow; detail = "must play a tractor of the lead length" };
          };
        } else if (longest > 0) {
          let playComps = Combo.decomposeComponents(playCat, category, game);
          if (totalTractorPairs(playComps) < longest) {
            return ?{ code = #IllegalFollow; detail = "must preserve the longest hand tractor" };
          };
          let handPairs = Combo.getPairs(handCat, category, game);
          let neededPairs = if (handPairs.size() < len) { handPairs.size() } else { len };
          let playPairs = Combo.getPairs(playCat, category, game);
          if (playPairs.size() < neededPairs) {
            return ?{ code = #IllegalFollow; detail = "must play enough pairs" };
          };
        } else {
          let handPairs = Combo.getPairs(handCat, category, game);
          let neededPairs = if (handPairs.size() < len) { handPairs.size() } else { len };
          let playPairs = Combo.getPairs(playCat, category, game);
          if (playPairs.size() < neededPairs) {
            return ?{ code = #IllegalFollow; detail = "must play enough pairs" };
          };
        };
        return null;
      };
      case (#Throw) {
        let leadPairsNeeded = Combo.pairEquivalents(lead.components);
        let handComps = Combo.decomposeComponents(handCat, category, game);
        let handPairsAvail = Combo.pairEquivalents(handComps);
        let playComps = Combo.decomposeComponents(playCat, category, game);
        let playPairsAvail = Combo.pairEquivalents(playComps);
        let required = if (handPairsAvail < leadPairsNeeded) { handPairsAvail } else { leadPairsNeeded };
        if (playPairsAvail < required) {
          return ?{ code = #IllegalFollow; detail = "must match the lead's pair-equivalents" };
        };
        // Tractor slots must be filled by tractors, maximally (R5/R6).
        let slotPairs = totalTractorPairs(lead.components);
        if (slotPairs > 0) {
          let handRuns = Array.map<Combo.Component, Nat>(
            Array.filter<Combo.Component>(handComps, Combo.isTractor),
            func(c) = c.length,
          );
          let mandatory = Combo.maxTractorUnitsCoverable(handRuns, slotPairs);
          let playTractorPairs = totalTractorPairs(playComps);
          if (playTractorPairs < mandatory) {
            return ?{ code = #IllegalFollow; detail = "must fill the lead's tractor slots with tractors" };
          };
        };
        return null;
      };
    };
  };
}
