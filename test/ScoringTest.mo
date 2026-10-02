/// T6 — scoring, kitty multiplier, and no-skip level progression.
import Card "../src/Card";
import Combo "../src/Combo";
import Scoring "../src/Scoring";
import CardParse "CardParse";
import Test "Test";

module {
  func leadOf(level : Nat, trump : Nat, cards : [Text]) : Combo.Lead {
    switch (Combo.determineLeadType(CardParse.parse(cards), { level; trump })) {
      case (?l) { l };
      case null { { kind = #Single; category = #Trump; count = 1; components = [] } };
    };
  };

  public func run(t : Test.Harness) {
    t.suite("T6 scoring");
    let H = Card.HEARTS + 1;

    // computeResult thresholds (winner + levels; wording is frontend work)
    func outcomeAt(pts : Nat, w : Scoring.TeamRole, g : Nat, name : Text) {
      let o = Scoring.compute(pts);
      t.check(o.winner == w and o.gain == g, name);
    };
    outcomeAt(0, #Bankers, 3, "0 points");
    outcomeAt(5, #Bankers, 2, "5 points");
    outcomeAt(35, #Bankers, 2, "35 points");
    outcomeAt(40, #Bankers, 1, "40 points");
    outcomeAt(75, #Bankers, 1, "75 points");
    outcomeAt(80, #Attackers, 0, "80 points");
    outcomeAt(115, #Attackers, 0, "115 points");
    outcomeAt(120, #Attackers, 1, "120 points");
    outcomeAt(155, #Attackers, 1, "155 points");
    outcomeAt(160, #Attackers, 2, "160 points");
    outcomeAt(195, #Attackers, 2, "195 points");
    outcomeAt(200, #Attackers, 3, "200 points");

    // kitty multiplier
    t.equalNat(Scoring.kittyMultiplier(leadOf(2, H, ["♠A"])), 2, "single ×2");
    t.equalNat(Scoring.kittyMultiplier(leadOf(2, H, ["♠K", "♠K"])), 4, "pair ×4");
    t.equalNat(Scoring.kittyMultiplier(leadOf(2, H, ["♠Q", "♠Q", "♠K", "♠K"])), 8, "tractor ×8");
    t.equalNat(Scoring.kittyMultiplier(leadOf(2, H, ["♠A", "♠Q"])), 2, "pure-singles throw ×2");
    t.equalNat(Scoring.kittyMultiplier(leadOf(2, H, ["♠J", "♠J", "♠A"])), 4, "pair+single throw ×4");
    t.equalNat(Scoring.kittyMultiplier(leadOf(2, H, ["♠3", "♠3", "♠9", "♠9", "♠A"])), 4, "two pairs throw ×4");
    t.equalNat(Scoring.kittyMultiplier(leadOf(2, H, ["♠Q", "♠Q", "♠K", "♠K", "♠A"])), 8, "tractor+single throw ×8");
    t.equalNat(Scoring.kittyMultiplier(leadOf(2, H, ["♠8", "♠8", "♠9", "♠9", "♠J", "♠J", "♠A"])), 8, "tractor+pair throw ×8");

    // point values and kitty value
    t.equalNat(Scoring.pointsOf(CardParse.parse(["♠5", "♠10", "♠K"])), 25, "kitty 5+10+K = 25");
    t.equalNat(Scoring.pointsOf(CardParse.parse(["♠5", "♠10", "♠K"])) * 2, 50, "kitty ×2");
    t.equalNat(Scoring.pointsOf(CardParse.parse(["♠5", "♠10", "♠K"])) * 4, 100, "kitty ×4");
    t.equalNat(Scoring.pointsOf(CardParse.parse(["♠5", "♠10", "♠K"])) * 8, 200, "kitty ×8");

    // gained-level progression, capped at A
    t.equalNat(Scoring.advanceLevel(9, Scoring.compute(10)), 11, "banker 9 +2 -> J");
    t.equalNat(Scoring.advanceLevel(10, Scoring.compute(0)), 13, "banker 10 +3 -> K");
    t.equalNat(Scoring.advanceLevel(9, Scoring.compute(200)), 12, "attacker 9 +3 -> Q");
    t.equalNat(Scoring.advanceLevel(12, Scoring.compute(200)), 14, "13/14 capped at A");
    t.equalNat(Scoring.advanceLevel(9, Scoring.compute(50)), 10, "banker 9 +1 -> 10");

    // epoch wrap: the gained levels continue past A around the 2..A ladder
    t.equalNat(Scoring.nextEpochLevel(14, 1), 2, "A +1 wraps to 2");
    t.equalNat(Scoring.nextEpochLevel(14, 2), 3, "A +2 wraps to 3");
    t.equalNat(Scoring.nextEpochLevel(14, 3), 4, "A +3 wraps to 4");
    t.equalNat(Scoring.nextEpochLevel(14, 13), 14, "a full ladder returns to A");
    t.equalNat(Scoring.nextEpochLevel(3, 1), 4, "a lower target wraps the same way");
  };
}
