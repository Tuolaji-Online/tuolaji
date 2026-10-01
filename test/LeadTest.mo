/// T3 — lead legality and throw auto-penalty
/// (CHECKS.md 甩牌合法性与是否可出 5/5 + R1/R2).
import Array "mo:core/Array";
import Card "../src/Card";
import Combo "../src/Combo";
import Lead "../src/Lead";
import Types "../src/Types";
import CardParse "CardParse";
import Test "Test";

module {
  func isRejectWith(check : Lead.LeadCheck, code : Types.ErrorCode) : Bool {
    switch (check) {
      case (#Reject(e)) { e.code == code };
      case _ { false };
    };
  };

  public func run(t : Test.Harness) {
    t.suite("T3 lead legality");

    // R1: card not held.
    let game : Card.Game = { level = 2; trump = Card.HEARTS + 1 };
    let hand = CardParse.parse(["♣K", "♦4", "♣3"]);
    let play = CardParse.parse(["♥5"]);
    t.check(
      isRejectWith(Lead.checkLeadPlay(play, hand, game, []), #CardNotInHand),
      "card not in hand is rejected",
    );

    // R2: mixed logical suits.
    let mixed = CardParse.parse(["♠Q", "♥Q"]);
    t.check(
      isRejectWith(Lead.checkLeadPlay(mixed, mixed, game, []), #IllegalLead),
      "mixed logical suits are rejected",
    );

    // Duplicate cards.
    let dup = CardParse.parse(["♠Q", "♠Q"]);
    let dupPlay = [dup[0], dup[0]];
    t.check(
      isRejectWith(Lead.checkLeadPlay(dupPlay, dup, game, []), #DuplicateCard),
      "duplicate cards are rejected",
    );

    // Helper for throw checks.
    func throwCheck(level : Nat, trump : Nat, leadStrs : [Text], oppStrs : [Text]) : Lead.LeadCheck {
      let g : Card.Game = { level; trump };
      let lead = CardParse.parse(leadStrs);
      let h = CardParse.parse(leadStrs);
      let opp = CardParse.parse(oppStrs);
      Lead.checkLeadPlay(lead, h, g, [opp]);
    };

    // 1. Illegal throw: opponent single beats the single component.
    let r1 = throwCheck(2, Card.HEARTS + 1, ["♠K", "♠Q", "♠Q"], ["♠A"]);
    switch (r1) {
      case (#Penalty(p)) {
        t.equalNat(p.forced.size(), 1, "beatable throw forces the single ♠K");
        t.equalNat(p.returned.size(), 2, "beatable throw returns the ♠Q pair");
      };
      case _ { t.check(false, "beatable throw yields a penalty") };
    };

    // 2. Legal throw: each component is maximal.
    switch (throwCheck(2, Card.HEARTS + 1, ["♠A", "♠Q", "♠Q"], ["♠K"])) {
      case (#Ok(_)) { t.check(true, "maximal throw is legal") };
      case _ { t.check(false, "maximal throw is legal") };
    };

    // 3. Trump throw (two off-suit level singles); opponent off-suit level is equal, not higher.
    switch (throwCheck(2, Card.SPADES + 1, ["♥2", "♣2"], ["♦2"])) {
      case (#Ok(_)) { t.check(true, "equal off-suit level does not beat the throw") };
      case _ { t.check(false, "equal off-suit level does not beat the throw") };
    };

    // 4. Opponent trump-suit level beats the off-suit level single.
    switch (throwCheck(2, Card.SPADES + 1, ["♥2", "♣2"], ["♠2"])) {
      case (#Penalty(_)) { t.check(true, "trump-suit level beats the throw") };
      case _ { t.check(false, "trump-suit level beats the throw") };
    };

    // 5. Opponent small joker beats the off-suit level single.
    switch (throwCheck(2, Card.SPADES + 1, ["♥2", "♣2"], ["🃟"])) {
      case (#Penalty(_)) { t.check(true, "small joker beats the throw") };
      case _ { t.check(false, "small joker beats the throw") };
    };

    // R2 variants: every combination spanning logical suits is rejected.
    func rejectLead(cards : [Text], tr : Nat, msg : Text) {
      let g : Card.Game = { level = 2; trump = tr };
      let p = CardParse.parse(cards);
      t.check(isRejectWith(Lead.checkLeadPlay(p, p, g, []), #IllegalLead), msg);
    };
    rejectLead(["♠A", "♥3", "♣4"], Card.HEARTS + 1, "three mixed-category cards rejected");
    rejectLead(["♥K", "♠K"], Card.HEARTS + 1, "trump + side suit mix rejected");
    rejectLead(["♠A", "♣A"], Card.HEARTS + 1, "same rank different side suits rejected");
    rejectLead(["🃟", "♠A"], Card.HEARTS + 1, "joker + side card rejected");
    rejectLead(["♠A", "♠K", "♠Q", "♥3"], Card.HEARTS + 1, "mostly side with one trump rejected");

    // ... but two jokers (both trump) form a legal 2-single throw.
    let jokers = CardParse.parse(["🃟", "🃏"]);
    switch (Lead.checkLeadPlay(jokers, jokers, game, [])) {
      case (#Ok(_)) { t.check(true, "two jokers form a legal throw") };
      case _ { t.check(false, "two jokers form a legal throw") };
    };

    // ── non-trump KK JJ (the reported case) ──────────────────────────
    // K and J are not consecutive ranks, so KK JJ is a throw, not a tractor.
    // A throw is legal only when no other hand can beat any of its pairs.
    let sideGame : Card.Game = { level = 2; trump = Card.HEARTS + 1 };
    let kkjj = CardParse.parse(["♠K", "♠K", "♠J", "♠J"]);
    let jj = CardParse.parse(["♠J", "♠J"]);
    let kk = CardParse.parse(["♠K", "♠K"]);

    // The exact reported hand holds the only remaining ♠Q (and one of the two
    // ♠A), so no QQ/AA pair can exist anywhere: the throw is legal.
    let exactHand = CardParse.parse(["♠A", "♠K", "♠K", "♠Q", "♠J", "♠J"]);
    switch (
      Lead.checkLeadPlay(kkjj, exactHand, sideGame, [
        CardParse.parse(["♠A"]),
        CardParse.parse(["♠Q"]),
        [],
      ])
    ) {
      case (#Ok(_)) { t.check(true, "non-trump KK JJ is legal when no higher pair remains") };
      case _ { t.check(false, "non-trump KK JJ is legal when no higher pair remains") };
    };

    // With the ♠Q held elsewhere, an opponent's QQ beats the JJ pair, so the
    // throw is penalised: JJ is forced out and KK is returned.
    let noQHand = CardParse.parse(["♠A", "♠K", "♠K", "♠J", "♠J", "♥Q"]);
    switch (
      Lead.checkLeadPlay(kkjj, noQHand, sideGame, [CardParse.parse(["♠Q", "♠Q"]), [], []])
    ) {
      case (#Penalty(p)) {
        t.check(true, "non-trump KK JJ is penalised when an opponent holds QQ");
        t.check(
          p.forced.size() == 2 and Array.any<Card.Card>(p.forced, func(c) = c == jj[0]) and Array.any<Card.Card>(p.forced, func(c) = c == jj[1]),
          "the beatable JJ pair is forced out",
        );
        t.check(
          p.returned.size() == 2 and Array.any<Card.Card>(p.returned, func(c) = c == kk[0]) and Array.any<Card.Card>(p.returned, func(c) = c == kk[1]),
          "the KK pair is returned",
        );
      };
      case _ { t.check(false, "non-trump KK JJ is penalised when an opponent holds QQ") };
    };
  };
}
