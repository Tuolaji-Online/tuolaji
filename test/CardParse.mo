/// Test helper: parse card strings like ["♠A", "♠A", "🃟"] into card IDs,
/// matching the JS `toIds` helper (first deck by default, second deck for the
/// second occurrence of a face value; 105/107 small jokers, 106/108 big).
import Array "mo:core/Array";
import List "mo:core/List";
import Text "mo:core/Text";
import VarArray "mo:core/VarArray";
import Card "../src/Card";

module {
  func suitIdx(s : Text) : ?Nat {
    if (Text.startsWith(s, #text("♠"))) { ?Card.SPADES }
    else if (Text.startsWith(s, #text("♥"))) { ?Card.HEARTS }
    else if (Text.startsWith(s, #text("♣"))) { ?Card.CLUBS }
    else if (Text.startsWith(s, #text("♦"))) { ?Card.DIAMONDS }
    else { null };
  };

  func rankFromText(t : Text) : ?Nat {
    if (t == "2") { ?2 }
    else if (t == "3") { ?3 }
    else if (t == "4") { ?4 }
    else if (t == "5") { ?5 }
    else if (t == "6") { ?6 }
    else if (t == "7") { ?7 }
    else if (t == "8") { ?8 }
    else if (t == "9") { ?9 }
    else if (t == "10") { ?10 }
    else if (t == "J") { ?11 }
    else if (t == "Q") { ?12 }
    else if (t == "K") { ?13 }
    else if (t == "A") { ?14 }
    else { null };
  };

  /// Next physical ID for face value `s`, marking `used`.
  func assignId(s : Text, used : [var Bool]) : Card.Card {
    let id : Card.Card = if (s == "🃟") {
      if (not used[105]) { 105 } else { 107 };
    } else if (s == "🃏") {
      if (not used[106]) { 106 } else { 108 };
    } else {
      let chars = Text.toArray(s);
      let suit = switch (suitIdx(s)) { case (?x) x; case null 0 };
      let rankText = Text.fromArray(Array.sliceToArray<Char>(chars, 1, chars.size()));
      let rank = switch (rankFromText(rankText)) { case (?r) r; case null 0 };
      let base = Card.makeId(1, suit, rank);
      if (not used[base]) { base } else { base + 52 };
    };
    used[id] := true;
    id;
  };

  /// Physical ID of the k-th copy (0-indexed) of a face value. Copies 0 and 1
  /// are the two real two-deck cards; copy 2+ is an out-of-range ID that
  /// `Card.faceKey` still maps to the same face, used to fabricate a
  /// hypothetical "third copy" for the two-deck integrity guard.
  public func copyId(s : Text, k : Nat) : Card.Card {
    if (s == "🃟") {
      if (k == 0) { 105 } else { 107 };
    } else if (s == "🃏") {
      if (k == 0) { 106 } else { 108 };
    } else {
      let chars = Text.toArray(s);
      let suit = switch (suitIdx(s)) { case (?x) x; case null 0 };
      let rankText = Text.fromArray(Array.sliceToArray<Char>(chars, 1, chars.size()));
      let rank = switch (rankFromText(rankText)) { case (?r) r; case null 0 };
      let base = Card.makeId(1, suit, rank);
      if (k == 0) {
        base;
      } else if (k == 1) {
        base + 52;
      } else {
        let cand = base + 104;
        if (cand >= 105 and cand <= 108) { base + 156 } else { cand };
      };
    };
  };

  public func parse(cards : [Text]) : [Card.Card] {
    let used = VarArray.repeat(false, 109);
    let out = List.empty<Card.Card>();
    for (s in cards.vals()) { out.add(assignId(s, used)) };
    out.toArray();
  };

  /// Parse several hands with distinct physical copies shared across all of
  /// them (like the JS `dealIds` helper).
  public func parseMulti(hands : [[Text]]) : [[Card.Card]] {
    let used = VarArray.repeat(false, 109);
    Array.map<[Text], [Card.Card]>(
      hands,
      func(hand) {
        let out = List.empty<Card.Card>();
        for (s in hand.vals()) { out.add(assignId(s, used)) };
        out.toArray();
      },
    );
  };

  /// Map `playStrs` (a face-value subset of `handStrs`) to the corresponding
  /// IDs in `handIds`, consuming each hand entry at most once.
  public func subset(handStrs : [Text], handIds : [Card.Card], playStrs : [Text]) : [Card.Card] {
    let used = VarArray.repeat(false, handIds.size());
    let out = List.empty<Card.Card>();
    for (ps in playStrs.vals()) {
      var found = false;
      var i = 0;
      while (i < handStrs.size() and not found) {
        if (not used[i] and handStrs[i] == ps) {
          used[i] := true;
          out.add(handIds[i]);
          found := true;
        };
        i += 1;
      };
    };
    out.toArray();
  };
}
