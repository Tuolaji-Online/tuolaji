/// Lead legality (RULES-lead R1–R4) and the throw auto-penalty split.
///
/// Ported from `simulator.js`: isLegalThrow and checkLeadPlay.
import Array "mo:core/Array";
import Card "Card";
import Combo "Combo";
import Types "Types";
import Util "Util";

module {
  public type ThrowCheck = {
    legal : Bool;
    lead : ?Combo.Lead;
    penalty : [Card.Card];
  };

  public type LeadCheck = {
    #Ok : Combo.Lead;
    #Reject : Types.CheckError;
    #Penalty : { forced : [Card.Card]; returned : [Card.Card] };
  };

  /// The smallest face in `play`: both copies when the lowest-rank card has a
  /// pair in the play (same physical suit), otherwise the single lowest card.
  /// This is the RULES §7 fallback when no beatable component can be isolated.
  func smallestFace(play : [Card.Card], game : Card.Game) : [Card.Card] {
    var best : ?Card.Card = null;
    for (c in play.vals()) {
      switch (best) {
        case null { best := ?c };
        case (?b) {
          let rc = Card.rankValue(c, game);
          let rb = Card.rankValue(b, game);
          if (rc < rb or (rc == rb and Card.pairKeyId(c) < Card.pairKeyId(b))) { best := ?c };
        };
      };
    };
    switch (best) {
      case null { [] };
      case (?b) {
        let k = Card.pairKeyId(b);
        let pair = Array.filter<Card.Card>(play, func(c) = Card.pairKeyId(c) == k);
        if (pair.size() >= 2) { [pair[0], pair[1]] } else { [b] };
      };
    };
  };

  /// Is this lead throwable (R4)? Non-throws are always legal. Returns the
  /// first beatable component (in single → pair → tractor order, and within a
  /// kind the lowest rank first) as `penalty`.
  public func isLegalThrow(
    cards : [Card.Card],
    game : Card.Game,
    otherPlayerHands : [[Card.Card]],
  ) : ThrowCheck {
    switch (Combo.determineLeadType(cards, game)) {
      case null { { legal = false; lead = null; penalty = [] } };
      case (?lead) {
        if (lead.kind != #Throw) {
          { legal = true; lead = ?lead; penalty = [] };
        } else {
          let singles = Util.sortBy<Combo.Component>(
            Array.filter<Combo.Component>(lead.components, Combo.isSingle),
            func(a, b) {
              if (a.topRank != b.topRank) { Util.cmpNat(a.topRank, b.topRank) } else {
                Util.cmpNat(Card.pairKeyId(a.cards[0]), Card.pairKeyId(b.cards[0]));
              };
            },
          );
          let pairs = Array.filter<Combo.Component>(lead.components, Combo.isPair);
          let tractors = Array.filter<Combo.Component>(lead.components, Combo.isTractor);
          let ordered = Array.concat<Combo.Component>(
            Array.concat<Combo.Component>(singles, pairs),
            tractors,
          );
          var illegal = false;
          var penalty : [Card.Card] = [];
          for (comp in ordered.vals()) {
            if (not illegal) {
              for (hand in otherPlayerHands.vals()) {
                if (not illegal) {
                  let beaten = switch (comp.kind) {
                    case (#Single) {
                      Combo.hasHigherSingle(hand, lead.category, comp.topRank, game);
                    };
                    case (#Pair) {
                      Combo.hasHigherPair(hand, lead.category, comp.topRank, game);
                    };
                    case (#Tractor) {
                      Combo.hasHigherTractor(hand, lead.category, comp.length, comp.topRank, game);
                    };
                  };
                  if (beaten) {
                    illegal := true;
                    penalty := comp.cards;
                  };
                };
              };
            };
          };
          if (illegal) {
            { legal = false; lead = ?lead; penalty };
          } else {
            { legal = true; lead = ?lead; penalty = [] };
          };
        };
      };
    };
  };

  /// Validate a lead play and adjudicate R1–R4.
  public func checkLeadPlay(
    play : [Card.Card],
    hand : [Card.Card],
    game : Card.Game,
    otherPlayerHands : [[Card.Card]],
  ) : LeadCheck {
    // R1: ownership.
    for (c in play.vals()) {
      if (not Card.contains(hand, c)) {
        return #Reject({ code = #CardNotInHand; detail = "card not in hand" });
      };
    };
    if (Card.hasDuplicate(play)) {
      return #Reject({ code = #DuplicateCard; detail = "duplicate cards in play" });
    };
    if (play.size() == 0) {
      return #Reject({ code = #IllegalLead; detail = "empty lead" });
    };
    // R2: one logical suit.
    let cat0 = Card.category(play[0], game);
    for (c in play.vals()) {
      if (Card.category(c, game) != cat0) {
        return #Reject({ code = #IllegalLead; detail = "cards span logical suits" });
      };
    };
    // R3: structural validity.
    switch (Combo.determineLeadType(play, game)) {
      case null {
        #Reject({ code = #IllegalStructure; detail = "cannot classify lead" });
      };
      case (?lead) {
        if (lead.kind != #Throw) { return #Ok(lead) };
        // R4: throw unbeatability (auto-penalty on failure).
        let tc = isLegalThrow(play, game, otherPlayerHands);
        if (tc.legal) { return #Ok(lead) };
        // §7: if no specific component can be isolated, fall back to the
        // smallest face (a pair if the smallest face has two copies).
        let forced = if (tc.penalty.size() == 0) { smallestFace(play, game) } else { tc.penalty };
        let returned = Card.difference(play, forced);
        #Penalty({ forced; returned });
      };
    };
  };
}
