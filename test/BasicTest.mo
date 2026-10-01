/// Tests for the game canister's basic heuristic module (`Basic.mo`): it must
/// always produce a legal move, regardless of the hand or lead shape.
import Basic "../src/Basic";
import Card "../src/Card";
import Combo "../src/Combo";
import Follow "../src/Follow";
import Test "Test";

module {
  func has(cards : [Card.Card], id : Card.Card) : Bool {
    var found = false;
    for (c in cards.vals()) { if (c == id) { found := true } };
    found;
  };

  /// The generated follow for `leadCards` must pass the server's rule check.
  func legalFollow(t : Test.Harness, name : Text, game : Card.Game, leadCards : [Card.Card], hand : [Card.Card]) {
    let lead = switch (Combo.determineLeadType(leadCards, game)) {
      case (?l) { l };
      case null {
        t.check(false, name # ": lead is classifiable");
        return;
      };
    };
    let move = Basic.followMove(hand, Basic.emptyPlayed(), Basic.emptyVoids(), lead, [], game, 0);
    t.check(move.size() > 0, name # ": follow is non-empty");
    switch (Follow.checkPlay(leadCards, hand, move, game)) {
      case null { t.check(true, name # ": follow is legal") };
      case (?e) { t.check(false, name # ": follow is legal (" # e.detail # ")") };
    };
  };

  func testDeclare(t : Test.Harness) {
    t.suite("Basic declaration");
    let game : Card.Game = { level = 2; trump = Card.NT };

    switch (Basic.declareMove([106, 108, 1, 2, 3], game)) {
      case (?cards) { t.check(cards.size() == 2 and has(cards, 106) and has(cards, 108), "big-joker pair") };
      case null { t.check(false, "declares a big-joker pair") };
    };
    switch (Basic.declareMove([105, 107, 1, 2, 3], game)) {
      case (?cards) { t.equalNat(cards.size(), 2, "small-joker pair") };
      case null { t.check(false, "declares a small-joker pair") };
    };
    let levelA = Card.makeId(1, 0, 2);
    let levelB = Card.makeId(2, 0, 2);
    switch (Basic.declareMove([levelA, levelB, 1, 5], game)) {
      case (?cards) { t.check(cards.size() == 2 and has(cards, levelA) and has(cards, levelB), "level pair") };
      case null { t.check(false, "declares a level pair") };
    };
    switch (Basic.declareMove([levelA, 1, 5], game)) {
      case (?cards) { t.equalNat(cards.size(), 1, "single level card") };
      case null { t.check(false, "declares a single level card") };
    };
    switch (Basic.declareMove([1, 2, 3, 4, 5], game)) {
      case null { t.check(true, "no level card means no call") };
      case (?_) { t.check(false, "no level card means no call") };
    };
  };

  func testLeadBury(t : Test.Harness) {
    t.suite("Basic lead/bury");
    let game : Card.Game = { level = 2; trump = Card.NT };
    let hand = [Card.makeId(1, 1, 5), Card.makeId(1, 1, 3), Card.makeId(1, 2, 7)];
    let move = Basic.leadingMove(hand, Basic.emptyPlayed(), Basic.emptyVoids(), game, 0);
    t.equalNat(move.size(), 1, "a lead is a single card");
    t.check(has(hand, move[0]), "the lead is from the hand");

    let dealt = Card.allIds();
    let bury = Basic.buryMove(dealt, game);
    t.equalNat(bury.size(), 8, "the bury is 8 cards");
    for (c in bury.vals()) { t.check(has(dealt, c), "buried cards are in hand") };
  };

  func testFollowLegality(t : Test.Harness) {
    t.suite("Basic follow legality");
    let game : Card.Game = { level = 2; trump = Card.NT };

    // Single.
    legalFollow(t, "single", game, [Card.makeId(1, 0, 5)], [Card.makeId(1, 0, 3), Card.makeId(1, 1, 4)]);

    // Pair, with a same-suit pair in hand.
    legalFollow(
      t,
      "pair-with-pair",
      game,
      [Card.makeId(1, 0, 5), Card.makeId(2, 0, 5)],
      [Card.makeId(1, 0, 3), Card.makeId(2, 0, 3), Card.makeId(1, 1, 4)],
    );

    // Pair, with only one same-suit card: the follow must top up.
    legalFollow(
      t,
      "pair-topup",
      game,
      [Card.makeId(1, 0, 5), Card.makeId(2, 0, 5)],
      [Card.makeId(1, 0, 3), Card.makeId(1, 1, 4), Card.makeId(1, 1, 6)],
    );

    // Void in the lead category.
    legalFollow(
      t,
      "pair-void",
      game,
      [Card.makeId(1, 0, 5), Card.makeId(2, 0, 5)],
      [Card.makeId(1, 1, 4), Card.makeId(1, 1, 6), Card.makeId(1, 2, 7)],
    );

    // Tractor, with the matching tractor in hand.
    legalFollow(
      t,
      "tractor",
      game,
      [Card.makeId(1, 0, 3), Card.makeId(2, 0, 3), Card.makeId(1, 0, 4), Card.makeId(2, 0, 4)],
      [Card.makeId(1, 0, 3), Card.makeId(2, 0, 3), Card.makeId(1, 0, 4), Card.makeId(2, 0, 4), Card.makeId(1, 1, 6)],
    );

    // Throw (a pair plus a single), with a partial hand.
    legalFollow(
      t,
      "throw",
      game,
      [Card.makeId(1, 0, 3), Card.makeId(2, 0, 3), Card.makeId(1, 0, 6)],
      [
        Card.makeId(1, 0, 3),
        Card.makeId(2, 0, 3),
        Card.makeId(1, 0, 8),
        Card.makeId(1, 1, 6),
        Card.makeId(1, 2, 7),
      ],
    );
  };

  public func run(t : Test.Harness) {
    testDeclare(t);
    testLeadBury(t);
    testFollowLegality(t);
  };
}
