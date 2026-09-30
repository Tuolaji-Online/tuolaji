/// Lead legality (RULES-lead R1–R4) and the throw auto-penalty split.
///
/// Ported from `simulator.js`: isLegalThrow and checkLeadPlay.
import Array "mo:core/Array";
import List "mo:core/List";
import VarArray "mo:core/VarArray";
import Card "Card";
import Combo "Combo";
import Types "Types";

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

  func containsCard(hand : [Card.Card], c : Card.Card) : Bool {
    var found = false;
    for (x in hand.vals()) { if (x == c) { found := true } };
    found;
  };

  func hasDuplicate(play : [Card.Card]) : Bool {
    var i = 0;
    while (i < play.size()) {
      var j = i + 1;
      while (j < play.size()) {
        if (play[i] == play[j]) { return true };
        j += 1;
      };
      i += 1;
    };
    false;
  };

  /// Multiset difference `play - remove`, preserving `play` order.
  func difference(play : [Card.Card], remove : [Card.Card]) : [Card.Card] {
    let used = VarArray.repeat(false, remove.size());
    let out = List.empty<Card.Card>();
    for (c in play.vals()) {
      var removed = false;
      var i = 0;
      while (i < remove.size()) {
        if (not used[i] and remove[i] == c) {
          used[i] := true;
          removed := true;
          i := remove.size(); // stop
        } else {
          i += 1;
        };
      };
      if (not removed) { out.add(c) };
    };
    out.toArray();
  };

  /// Is this lead throwable (R4)? Non-throws are always legal. Returns the
  /// first beatable component (in single → pair → tractor order) as `penalty`.
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
          let singles = Array.filter<Combo.Component>(lead.components, Combo.isSingle);
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
      if (not containsCard(hand, c)) {
        return #Reject({ code = #CardNotInHand; detail = "card not in hand" });
      };
    };
    if (hasDuplicate(play)) {
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
        let forced = tc.penalty;
        let returned = difference(play, forced);
        #Penalty({ forced; returned });
      };
    };
  };
}
