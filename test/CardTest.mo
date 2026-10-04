/// T1 — card model / encoding, and T9 — encoding lock against the JS engine.
import Array "mo:core/Array";
import Nat "mo:core/Nat";
import Card "../src/Card";
import Test "Test";

module {
  // Card names for IDs 1..108, generated from `tractor.js:cardToString`.
  // T9 asserts the Motoko mapping never drifts from the JS engine.
  let expectedNames : [Text] = [
    "♠3", "♥3", "♣3", "♦3", "♠4", "♥4",
    "♣4", "♦4", "♠5", "♥5", "♣5", "♦5",
    "♠6", "♥6", "♣6", "♦6", "♠7", "♥7",
    "♣7", "♦7", "♠8", "♥8", "♣8", "♦8",
    "♠9", "♥9", "♣9", "♦9", "♠10", "♥10",
    "♣10", "♦10", "♠J", "♥J", "♣J", "♦J",
    "♠Q", "♥Q", "♣Q", "♦Q", "♠K", "♥K",
    "♣K", "♦K", "♠A", "♥A", "♣A", "♦A",
    "♠2", "♥2", "♣2", "♦2", "♠3", "♥3",
    "♣3", "♦3", "♠4", "♥4", "♣4", "♦4",
    "♠5", "♥5", "♣5", "♦5", "♠6", "♥6",
    "♣6", "♦6", "♠7", "♥7", "♣7", "♦7",
    "♠8", "♥8", "♣8", "♦8", "♠9", "♥9",
    "♣9", "♦9", "♠10", "♥10", "♣10", "♦10",
    "♠J", "♥J", "♣J", "♦J", "♠Q", "♥Q",
    "♣Q", "♦Q", "♠K", "♥K", "♣K", "♦K",
    "♠A", "♥A", "♣A", "♦A", "♠2", "♥2",
    "♣2", "♦2", "🃟", "🃏", "🃟", "🃏",
  ];

  func g(level : Nat, trump : Nat) : Card.Game {
    { level; trump }
  };

  func catEq(a : Card.Category, b : Card.Category) : Bool { a == b };
  func keyEq(a : Card.PairKey, b : Card.PairKey) : Bool { a == b };

  func t1_encoding(t : Test.Harness) {
    t.suite("T1 encoding");
    // Round-trip ID -> (deck, suit, rank) -> ID for every non-joker.
    for (id in Card.allIds().vals()) {
      t.check(Card.isValidId(id), "id " # Nat.toText(id) # " is valid");
      if (Card.isJoker(id)) {
        t.check(Card.suitOf(id) == null, "joker " # Nat.toText(id) # " has no suit");
        t.check(Card.rankOf(id) == null, "joker " # Nat.toText(id) # " has no rank");
      } else {
        let deck = if (id <= 52) { 1 } else { 2 };
        switch (Card.suitOf(id), Card.rankOf(id)) {
          case (?s, ?r) {
            t.check(s <= 3, "suit in range for " # Nat.toText(id));
            t.check(r >= 2 and r <= 14, "rank in range for " # Nat.toText(id));
            t.equalNat(Card.makeId(deck, s, r), id, "round-trip id " # Nat.toText(id));
          };
          case _ {
            t.check(false, "non-joker " # Nat.toText(id) # " has suit+rank");
          };
        };
      };
    };

    // Explicit anchor points from Appendix D.
    t.equalText(Card.cardToString(1), "♠3", "id 1 is ♠3");
    t.equalText(Card.cardToString(29), "♠10", "id 29 is ♠10");
    t.equalText(Card.cardToString(45), "♠A", "id 45 is ♠A");
    t.equalText(Card.cardToString(60), "♦4", "id 60 is ♦4 (deck 2)");
    t.equalText(Card.cardToString(98), "♥A", "id 98 is ♥A (deck 2)");

    // Jokers.
    t.check(Card.isSmallJoker(105), "105 is small joker");
    t.check(Card.isSmallJoker(107), "107 is small joker");
    t.check(Card.isBigJoker(106), "106 is big joker");
    t.check(Card.isBigJoker(108), "108 is big joker");
    t.check(not Card.isJoker(52), "♦2 is not a joker");
  };

  func t1_trumpAndCategory(t : Test.Harness) {
    t.suite("T1 trump/category");
    // Level card is trump regardless of physical suit (level 5, trump ♠).
    let gw = g(5, Card.SPADES + 1);
    t.check(Card.isTrump(Card.makeId(1, Card.HEARTS, 5), gw), "♥5 is trump");
    t.check(Card.isTrump(Card.makeId(1, Card.DIAMONDS, 5), gw), "♦5 is trump");
    t.check(Card.isTrump(Card.makeId(1, Card.SPADES, 14), gw), "♠A is trump");
    t.check(not Card.isTrump(Card.makeId(1, Card.HEARTS, 14), gw), "♥A is side");
    t.check(Card.isTrump(105, gw), "small joker is trump");
    t.equalBy<Card.Category>(
      catEq,
      Card.category(Card.makeId(1, Card.HEARTS, 5), gw),
      #Trump,
      "♥5 category is trump",
    );
    t.equalBy<Card.Category>(
      catEq,
      Card.category(Card.makeId(1, Card.HEARTS, 14), gw),
      #Side(Card.HEARTS),
      "♥A category is side hearts",
    );

    // No-Trump: only jokers and level cards are trump.
    let nt = g(5, Card.NT);
    t.check(Card.isTrump(Card.makeId(1, Card.SPADES, 5), nt), "♠5 is trump in NT");
    t.check(not Card.isTrump(Card.makeId(1, Card.SPADES, 14), nt), "♠A is side in NT");
    t.check(not Card.isTrump(Card.makeId(1, Card.HEARTS, 14), nt), "♥A is side in NT");
    t.check(Card.isTrump(106, nt), "big joker is trump in NT");
    t.equalBy<Card.Category>(
      catEq,
      Card.category(Card.makeId(1, Card.SPADES, 14), nt),
      #Side(Card.SPADES),
      "♠A category is side spades in NT",
    );

    // Level 2, trump ♠: off-suit level ♦2 is trump.
    let g2 = g(2, Card.SPADES + 1);
    t.check(Card.isTrump(Card.makeId(1, Card.DIAMONDS, 2), g2), "♦2 is trump at level 2");
    t.check(Card.isTrump(Card.makeId(1, Card.SPADES, 2), g2), "♠2 is trump at level 2");
  };

  func t1_rankValue(t : Test.Harness) {
    t.suite("T1 rankValue");
    // Side chain skips the level: at level 10, ♥9 and ♥J are adjacent.
    let gw = g(10, Card.SPADES + 1);
    let h9 = Card.makeId(1, Card.HEARTS, 9);
    let hj = Card.makeId(1, Card.HEARTS, 11);
    t.equalNat(Card.rankValue(hj, gw), Card.rankValue(h9, gw) + 1, "♥J follows ♥9 over level 10");

    // Trump chain at level 2, trump ♠:
    // trump-suit normals < off-suit level < on-suit level < small joker < big joker.
    let g2 = g(2, Card.SPADES + 1);
    let spadeA = Card.makeId(1, Card.SPADES, 14);
    let heart2 = Card.makeId(1, Card.HEARTS, 2);
    let spade2 = Card.makeId(1, Card.SPADES, 2);
    t.equalNat(Card.rankValue(spadeA, g2), 11, "♠A is top suit normal");
    t.equalNat(Card.rankValue(heart2, g2), 12, "♥2 is off-suit level");
    t.equalNat(Card.rankValue(spade2, g2), 13, "♠2 is on-suit level");
    t.equalNat(Card.rankValue(105, g2), 14, "small joker");
    t.equalNat(Card.rankValue(106, g2), 15, "big joker");
    t.check(
      Card.rankValue(spadeA, g2) < Card.rankValue(heart2, g2) and
      Card.rankValue(heart2, g2) < Card.rankValue(spade2, g2) and
      Card.rankValue(spade2, g2) < Card.rankValue(105, g2) and
      Card.rankValue(105, g2) < Card.rankValue(106, g2),
      "trump chain is strictly ordered",
    );

    // NT chain: level cards < small joker < big joker.
    let nt = g(5, Card.NT);
    t.equalNat(Card.rankValue(Card.makeId(1, Card.SPADES, 5), nt), 0, "level card in NT");
    t.equalNat(Card.rankValue(105, nt), 1, "small joker in NT");
    t.equalNat(Card.rankValue(106, nt), 2, "big joker in NT");
  };

  func t1_pairKey(t : Test.Harness) {
    t.suite("T1 pairKey");
    // Level cards of different physical suits do not pair.
    t.notEqualBy<Card.PairKey>(
      keyEq,
      Card.pairKey(Card.makeId(1, Card.SPADES, 5)),
      Card.pairKey(Card.makeId(1, Card.HEARTS, 5)),
      "♠5 and ♥5 are not a pair",
    );
    // Big and small jokers do not pair.
    t.notEqualBy<Card.PairKey>(keyEq, Card.pairKey(105), Card.pairKey(106), "small and big jokers do not pair");
    // The two decks share pair identity.
    t.equalBy<Card.PairKey>(keyEq, Card.pairKey(1), Card.pairKey(53), "♠3 pairs across decks");
    // Two small jokers pair.
    t.equalBy<Card.PairKey>(keyEq, Card.pairKey(105), Card.pairKey(107), "small jokers pair");
    t.equalBy<Card.PairKey>(keyEq, Card.pairKey(106), Card.pairKey(108), "big jokers pair");
  };

  func t9_encodingLock(t : Test.Harness) {
    t.suite("T9 encoding lock");
    var i = 0;
    while (i < 108) {
      let id = i + 1;
      t.equalText(
        Card.cardToString(id),
        expectedNames[i],
        "cardToString(" # Nat.toText(id) # ")",
      );
      i += 1;
    };
  };

  func t1_sortPlay(t : Test.Harness) {
    t.suite("T1 sortPlay");
    let game = g(2, Card.HEARTS + 1); // hearts are trump
    let trump = Card.makeId(1, Card.HEARTS, 3);
    let side10 = Card.makeId(1, Card.SPADES, 10);
    let side3 = Card.makeId(1, Card.SPADES, 3);
    let sideA = Card.makeId(1, Card.SPADES, 14);

    let s1 = Card.sortPlay([side10, trump], game);
    t.equalNat(s1[0], trump, "a trump sorts before a side card");
    t.equalNat(s1[1], side10, "the side card follows");

    let s2 = Card.sortPlay([side3, sideA], game);
    t.equalNat(s2[0], sideA, "higher rank sorts first");
    t.equalNat(s2[1], side3, "lower rank follows");

    let s3 = Card.sortPlay(Card.sortPlay([side3, sideA, trump], game), game);
    t.equalNat(s3[0], trump, "sortPlay is idempotent (trump first)");
    t.equalNat(s3[1], sideA, "sortPlay is idempotent (rank order)");
    t.equalNat(s3[2], side3, "sortPlay is idempotent (tail)");

    // Mixed suits follow the client's `sortedHand` order: all trumps first, then
    // each side suit in the colour-alternating display order, each group by
    // descending rank. For hearts trump the side order is spades, diamonds,
    // clubs.
    let h5 = Card.makeId(1, Card.HEARTS, 5);
    let d3 = Card.makeId(1, Card.DIAMONDS, 3);
    let c4 = Card.makeId(1, Card.CLUBS, 4);
    let mixed = Card.sortPlay([c4, d3, side3, sideA, h5], game);
    t.equalNat(mixed[0], h5, "trumps sort first");
    t.equalNat(mixed[1], sideA, "the spade group leads the sides");
    t.equalNat(mixed[2], side3, "same-suit spades stay grouped");
    t.equalNat(mixed[3], d3, "diamonds follow spades");
    t.equalNat(mixed[4], c4, "clubs sort last");
  };

  public func run(t : Test.Harness) {
    t1_encoding(t);
    t1_trumpAndCategory(t);
    t1_rankValue(t);
    t1_pairKey(t);
    t1_sortPlay(t);
    t9_encodingLock(t);
  };
}
