/// T7 — declaration classification and override precedence.
import Card "../src/Card";
import Trump "../src/Trump";
import CardParse "CardParse";
import Test "Test";

module {
  public func run(t : Test.Harness) {
    t.suite("T7 declaration");

    let g5 : Card.Game = { level = 5; trump = Card.HEARTS + 1 };
    let hand = CardParse.parse(["♥5", "♥5", "♠5", "🃟", "🃟", "🃏", "🃏"]);
    let single = CardParse.parse(["♥5"]);
    let pair = CardParse.parse(["♥5", "♥5"]);
    let smallPair = CardParse.parse(["🃟", "🃟"]);
    let bigPair = CardParse.parse(["🃏", "🃏"]);

    // classify
    switch (Trump.classify(single, g5)) {
      case (?(_, _)) { t.check(true, "single level card classifies") };
      case null { t.check(false, "single level card classifies") };
    };
    switch (Trump.classify(smallPair, g5)) {
      case (?(_, suit)) {
        t.check(suit == Card.NT, "small joker pair is no-trump");
      };
      case null { t.check(false, "small joker pair classifies") };
    };

    // single declares from nothing
    let d1 = switch (Trump.declareTrump(single, hand, g5, 0, true, null, false)) {
      case (#Ok(d)) { ?d };
      case _ { t.check(false, "single declares from none"); null };
    };
    // pair overrides single
    switch (d1) {
      case (?cur) {
        switch (Trump.declareTrump(pair, hand, g5, 1, true, ?cur, false)) {
          case (#Ok(d)) { t.equalNat(d.value, 2, "pair overrides single") };
          case _ { t.check(false, "pair overrides single") };
        };
      };
      case null {};
    };

    // pair is terminal without enhanced
    let locked : Trump.Declaration = { seat = 0; kind = #Pair; suit = Card.HEARTS + 1; value = 2 };
    switch (Trump.declareTrump(bigPair, hand, g5, 1, true, ?locked, false)) {
      case (#Reject(_)) { t.check(true, "big joker pair cannot override a locked pair") };
      case _ { t.check(false, "big joker pair cannot override a locked pair") };
    };
    // ... but can with enhanced
    switch (Trump.declareTrump(bigPair, hand, g5, 1, true, ?locked, true)) {
      case (#Ok(_)) { t.check(true, "enhanced big joker pair overrides a level pair") };
      case _ { t.check(false, "enhanced big joker pair overrides a level pair") };
    };

    // big joker pair over small joker pair
    let smallDecl : Trump.Declaration = { seat = 0; kind = #SmallJokerPair; suit = Card.NT; value = 3 };
    switch (Trump.declareTrump(bigPair, hand, g5, 1, true, ?smallDecl, false)) {
      case (#Reject(_)) { t.check(true, "big joker pair cannot override a small-joker pair without enhanced") };
      case _ { t.check(false, "big joker pair cannot override a small-joker pair without enhanced") };
    };
    switch (Trump.declareTrump(bigPair, hand, g5, 1, true, ?smallDecl, true)) {
      case (#Reject(_)) { t.check(true, "a No-Trump call is final even with enhanced override") };
      case _ { t.check(false, "a No-Trump call is final even with enhanced override") };
    };

    // not held
    let foreign = CardParse.parse(["♣5"]);
    switch (Trump.declareTrump(foreign, hand, g5, 0, true, null, false)) {
      case (#Reject(_)) { t.check(true, "declaring a card not held is rejected") };
      case _ { t.check(false, "declaring a card not held is rejected") };
    };

    // outside dealing
    switch (Trump.declareTrump(single, hand, g5, 0, false, null, false)) {
      case (#Reject(_)) { t.check(true, "declaring outside dealing is rejected") };
      case _ { t.check(false, "declaring outside dealing is rejected") };
    };
  };
}
