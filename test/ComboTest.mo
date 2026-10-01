/// T2 — combination classification (CHECKS.md 牌型识别 25/25).
import Array "mo:core/Array";
import Card "../src/Card";
import Combo "../src/Combo";
import CardParse "CardParse";
import Test "Test";

module {
  func kindEq(a : Combo.LeadKind, b : Combo.LeadKind) : Bool { a == b };

  func kindText(k : Combo.LeadKind) : Text {
    switch (k) {
      case (#Single) { "single" };
      case (#Pair) { "pair" };
      case (#Tractor) { "tractor" };
      case (#Throw) { "throw" };
    };
  };

  func expectKind(t : Test.Harness, msg : Text, level : Nat, trump : Nat, cards : [Text], expected : Combo.LeadKind) {
    let game : Card.Game = { level; trump };
    switch (Combo.determineLeadType(CardParse.parse(cards), game)) {
      case null {
        t.check(false, msg # ": expected " # kindText(expected) # " but lead is invalid");
      };
      case (?lead) {
        t.equalBy<Combo.LeadKind>(kindEq, lead.kind, expected, msg);
      };
    };
  };

  func expectInvalid(t : Test.Harness, msg : Text, level : Nat, trump : Nat, cards : [Text]) {
    let game : Card.Game = { level; trump };
    t.check(Combo.determineLeadType(CardParse.parse(cards), game) == null, msg # ": expected invalid lead");
  };

  public func run(t : Test.Harness) {
    t.suite("T2 combination classification");

    // 1. same suit same rank = pair
    expectKind(t, "pair", 2, Card.HEARTS + 1, ["♠Q", "♠Q"], #Pair);
    // 2. different suits do not pair
    expectInvalid(t, "mixed suits", 2, Card.HEARTS + 1, ["♠Q", "♥Q"]);
    // 3. consecutive pairs skip the level
    expectKind(t, "tractor skips level", 5, Card.HEARTS + 1, ["♠4", "♠4", "♠6", "♠6"], #Tractor);
    // 4. small pair + big pair, no-trump
    expectKind(t, "joker tractor NT", 2, Card.NT, ["🃟", "🃟", "🃏", "🃏"], #Tractor);
    // 5. level pair + small pair, no-trump
    expectKind(t, "level+joker tractor NT", 2, Card.NT, ["♠2", "♠2", "🃟", "🃟"], #Tractor);
    // 6. single + pair = throw
    expectKind(t, "single+pair throw", 2, Card.HEARTS + 1, ["♠A", "♠Q", "♠J", "♠J"], #Throw);
    // 7. NT level-card combo (two pairs + two singles)
    let g7 : Card.Game = { level = 2; trump = Card.NT };
    switch (Combo.determineLeadType(CardParse.parse(["♠2", "♠2", "♥2", "♥2", "♦2", "♣2"]), g7)) {
      case (?lead) {
        t.equalBy<Combo.LeadKind>(kindEq, lead.kind, #Throw, "NT level combo is a throw");
        t.equalNat(Combo.pairEquivalents(lead.components), 2, "NT level combo has 2 pair-equivalents");
        var singles = 0;
        for (c in lead.components.vals()) {
          if (Combo.isSingle(c)) { singles += 1 };
        };
        t.equalNat(singles, 2, "NT level combo has 2 singles");
      };
      case null { t.check(false, "NT level combo classifiable") };
    };
    // 8. spade-2 pair + small pair, trump ♠
    expectKind(t, "♠2+small tractor", 2, Card.SPADES + 1, ["♠2", "♠2", "🃟", "🃟"], #Tractor);
    // 9. + big pair = 3-pair tractor
    expectKind(t, "♠2+small+big tractor", 2, Card.SPADES + 1, ["♠2", "♠2", "🃟", "🃟", "🃏", "🃏"], #Tractor);
    // 10. off-suit level + trump-suit level
    expectKind(t, "♦2+♠2 tractor", 2, Card.SPADES + 1, ["♦2", "♦2", "♠2", "♠2"], #Tractor);
    // 11. top suit normal + off-suit level
    expectKind(t, "♠A+♦2 tractor", 2, Card.SPADES + 1, ["♠A", "♠A", "♦2", "♦2"], #Tractor);
    // 12. off-suit level + small joker is NOT a tractor
    expectKind(t, "♦2+small not tractor", 2, Card.SPADES + 1, ["♦2", "♦2", "🃟", "🃟"], #Throw);
    // 13. ♠A + ♠2 is NOT a tractor
    expectKind(t, "♠A+♠2 not tractor", 2, Card.SPADES + 1, ["♠A", "♠A", "♠2", "♠2"], #Throw);
    // 14. ♥3 pair + small pair, level 3 hearts
    expectKind(t, "♥3+small tractor", 3, Card.HEARTS + 1, ["♥3", "♥3", "🃟", "🃟"], #Tractor);
    // 15. off-suit level + trump-suit level at level 3
    expectKind(t, "♣3+♥3 tractor", 3, Card.HEARTS + 1, ["♣3", "♣3", "♥3", "♥3"], #Tractor);
    // 16. top suit normal + off-suit level at level 3
    expectKind(t, "♥A+♣3 tractor", 3, Card.HEARTS + 1, ["♥A", "♥A", "♣3", "♣3"], #Tractor);
    // 17. off-suit level + small joker not a tractor
    expectKind(t, "♣3+small not tractor", 3, Card.HEARTS + 1, ["♣3", "♣3", "🃟", "🃟"], #Throw);
    // 18. ♥A + ♥3 not a tractor
    expectKind(t, "♥A+♥3 not tractor", 3, Card.HEARTS + 1, ["♥A", "♥A", "♥3", "♥3"], #Throw);
    // 19. club-A pair + small pair, level A clubs
    expectKind(t, "♣A+small tractor", 14, Card.CLUBS + 1, ["♣A", "♣A", "🃟", "🃟"], #Tractor);
    // 20. off-suit level + trump-suit level at A
    expectKind(t, "♠A+♣A tractor", 14, Card.CLUBS + 1, ["♠A", "♠A", "♣A", "♣A"], #Tractor);
    // 21. trump-suit K + off-suit level A
    expectKind(t, "♣K+♠A tractor", 14, Card.CLUBS + 1, ["♣K", "♣K", "♠A", "♠A"], #Tractor);
    // 22. off-suit level + small joker not a tractor
    expectKind(t, "♠A+small not tractor", 14, Card.CLUBS + 1, ["♠A", "♠A", "🃟", "🃟"], #Throw);
    // 23. ♣K + ♣A not a tractor
    expectKind(t, "♣K+♣A not tractor", 14, Card.CLUBS + 1, ["♣K", "♣K", "♣A", "♣A"], #Throw);
    // 24. different-suit level cards = two singles (throw)
    expectKind(t, "♥2+♣2 two singles", 2, Card.SPADES + 1, ["♥2", "♣2"], #Throw);
    // 25. off-suit levels + trump-suit normal pair is a throw
    expectKind(t, "♣J+♦J+♥A♥A throw", 11, Card.HEARTS + 1, ["♣J", "♦J", "♥A", "♥A"], #Throw);

    // maxTractorUnitsCoverable
    t.equalNat(Combo.maxTractorUnitsCoverable([3], 2), 2, "3-run covers 2 of 2 slots");
    t.equalNat(Combo.maxTractorUnitsCoverable([3], 4), 3, "3-run covers 3 of 4 slots");
    t.equalNat(Combo.maxTractorUnitsCoverable([2, 2], 4), 4, "two 2-runs cover 4 slots");
    t.equalNat(Combo.maxTractorUnitsCoverable([2], 1), 0, "no tractor needed for one slot");

    // selectTractorWindows returns the lowest window of a run
    let runs = [CardParse.parse(["♠3", "♠3", "♠4", "♠4", "♠5", "♠5"])];
    let windows = Combo.selectTractorWindows(runs, 2);
    t.equalNat(windows.size(), 1, "selectTractorWindows returns one window");
    t.equalNat(windows[0].size(), 4, "selected window is two pairs");
  };
}
