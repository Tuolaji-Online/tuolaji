/// T4 — follow legality (CHECKS.md 跟牌规则, rule cases).
import Array "mo:core/Array";
import Card "../src/Card";
import Combo "../src/Combo";
import Follow "../src/Follow";
import CardParse "CardParse";
import Test "Test";

module {
  func legal(level : Nat, trump : Nat, leadStrs : [Text], handStrs : [Text], playStrs : [Text]) : Bool {
    let game : Card.Game = { level; trump };
    let lead = CardParse.parse(leadStrs);
    let hand = CardParse.parse(handStrs);
    let play = CardParse.parse(playStrs);
    switch (Follow.checkPlay(lead, hand, play, game)) {
      case null { true };
      case _ { false };
    };
  };

  func legalIds(level : Nat, trump : Nat, lead : [Card.Card], hand : [Card.Card], play : [Card.Card]) : Bool {
    let game : Card.Game = { level; trump };
    switch (Follow.checkPlay(lead, hand, play, game)) {
      case null { true };
      case _ { false };
    };
  };

  func expect(t : Test.Harness, msg : Text, want : Bool, got : Bool) {
    t.check(want == got, msg # " (expected " # (if (want) { "legal" } else { "illegal" }) # ")");
  };

  public func run(t : Test.Harness) {
    t.suite("T4 follow legality");
    let H = Card.HEARTS + 1;
    let C = Card.CLUBS + 1;
    let NT = Card.NT;

    // single follow
    expect(t, "single follow - must follow suit", false, legal(2, H, ["♣7"], ["♣K", "♦4", "♣3", "♥5"], ["♦4"]));
    expect(t, "single follow - following suit is legal", true, legal(2, H, ["♣7"], ["♣K", "♦4", "♣3", "♥5"], ["♣K"]));
    expect(t, "single follow - void is legal", true, legal(2, H, ["♣7"], ["♦4", "♥5"], ["♦4"]));

    // pair follow
    expect(t, "pair follow - has pair must play pair", true, legal(2, H, ["♣9", "♣9"], ["♣Q", "♣Q", "♣10", "♣5"], ["♣Q", "♣Q"]));
    expect(t, "pair follow - breaking the pair is illegal", false, legal(2, H, ["♣9", "♣9"], ["♣Q", "♣Q", "♣10", "♣5"], ["♣Q", "♣10"]));
    expect(t, "pair follow - no pair, lone suit card must be played", true, legal(2, H, ["♣9", "♣9"], ["♣5", "♦3", "♦4", "♥2"], ["♣5", "♦3"]));
    expect(t, "pair follow - skipping the lone suit card is illegal", false, legal(2, H, ["♣9", "♣9"], ["♣5", "♦3", "♦4", "♥2"], ["♦3", "♦4"]));

    // tractor follow
    expect(t, "tractor follow - has tractor must play it", true, legal(2, H, ["♣8", "♣8", "♣9", "♣9"], ["♣3", "♣3", "♣4", "♣4"], ["♣3", "♣3", "♣4", "♣4"]));
    expect(t, "tractor follow - broken pairs are illegal", false, legal(2, H, ["♣8", "♣8", "♣9", "♣9"], ["♣3", "♣3", "♣4", "♣4", "♣5", "♣5"], ["♣3", "♣3", "♣5", "♣5"]));
    expect(t, "tractor follow - no tractor, play available pairs", true, legal(2, H, ["♣8", "♣8", "♣9", "♣9"], ["♣K", "♣K", "♦7", "♣6", "♣5", "♣4", "♣3"], ["♣K", "♣K", "♣3", "♣4"]));
    expect(t, "tractor follow - skipping available pair is illegal", false, legal(2, H, ["♣8", "♣8", "♣9", "♣9"], ["♣K", "♣K", "♦7", "♣6", "♣5", "♣4", "♣3"], ["♣6", "♣5", "♣4", "♣3"]));
    expect(t, "tractor follow - void is legal", true, legal(2, H, ["♣8", "♣8", "♣9", "♣9"], ["♦7", "♥3", "♠3", "♥A"], ["♦7", "♥3", "♠3", "♥A"]));

    // wrong length
    expect(t, "wrong number of cards is illegal", false, legal(2, H, ["♣9", "♣9"], ["♣Q", "♣Q", "♣10", "♣5"], ["♣Q"]));

    // throw follow
    expect(t, "throw follow - pair-equivalents", true, legal(2, C, ["♣8", "♣8", "♣9", "♣9", "♣A"], ["♣K", "♣K", "♣7", "♣6", "♣5", "♣4", "♦3"], ["♣K", "♣K", "♣4", "♣5", "♣6"]));
    expect(t, "throw follow - skipping the pair is illegal", false, legal(2, C, ["♣8", "♣8", "♣9", "♣9", "♣A"], ["♣K", "♣K", "♣7", "♣6", "♣5", "♣4", "♦3"], ["♣K", "♣7", "♣6", "♣5", "♣4"]));
    expect(t, "throw follow - tractor pairs count", true, legal(2, H, ["♠A", "♠K", "♠10", "♠A", "♠10"], ["♠4", "♠4", "♠5", "♠5", "♠8", "♠8", "♠9", "♠3"], ["♠4", "♠4", "♠5", "♠5", "♠3"]));
    expect(t, "throw follow - not enough pair-equivalents", false, legal(2, H, ["♠A", "♠K", "♠10", "♠A", "♠10"], ["♠4", "♠4", "♠5", "♠5", "♠8", "♠8", "♠9", "♠3"], ["♠8", "♠8", "♠9", "♠3", "♠4"]));

    // off-suit level cards do not pair
    expect(t, "pair follow - fake off-suit level pair is illegal", false, legal(11, H, ["♥K", "♥K"], ["♣J", "♦J", "♥A", "♥A"], ["♣J", "♦J"]));
    expect(t, "pair follow - real pair is legal", true, legal(11, H, ["♥K", "♥K"], ["♣J", "♦J", "♥A", "♥A"], ["♥A", "♥A"]));

    // jokers do not pair across ranks
    expect(t, "pair follow - small+big joker is not a pair", false, legal(2, H, ["♣9", "♣9"], ["🃟", "🃏", "♣5", "♣4"], ["🃟", "🃏"]));

    // ── ownership ──
    expect(t, "follow - card not in hand is illegal", false, legal(2, H, ["♣7"], ["♣K", "♦4"], ["♥5"]));

    // ── trump / no-trump single skips ──
    expect(t, "trump single follow - skip trump is illegal", false, legal(2, H, ["🃏"], ["🃟", "♥3", "♣4", "♠6"], ["♠6"]));
    expect(t, "trump single follow - joker follows joker", true, legal(2, H, ["🃏"], ["🃟", "♥3", "♣4", "♠6"], ["🃟"]));
    expect(t, "trump single follow - skip off-suit level card is illegal", false, legal(5, H, ["♥7"], ["♣5", "♦5", "♥3", "♠6"], ["♠6"]));
    expect(t, "trump single follow - off-suit level card is trump", true, legal(5, H, ["♥7"], ["♣5", "♦5", "♥3", "♠6"], ["♣5"]));
    expect(t, "no-trump single follow - skip level card is illegal", false, legal(2, NT, ["🃟"], ["🃏", "♣2", "♦2", "♥3", "♠5"], ["♥3"]));
    expect(t, "no-trump single follow - level card is trump", true, legal(2, NT, ["🃟"], ["🃏", "♣2", "♦2", "♥3", "♠5"], ["♣2"]));

    // ── trump pair / tractor skips ──
    expect(t, "trump pair follow - skip real trump pair is illegal", false, legal(2, H, ["♥3", "♥3"], ["♥5", "♥5", "🃟", "♣2"], ["🃟", "♣2"]));
    expect(t, "trump tractor follow - broken trump pairs is illegal", false, legal(2, H, ["♥3", "♥3", "♥4", "♥4"], ["♥5", "♥5", "♥6", "♥6", "♥8", "♥8"], ["♥5", "♥5", "♥8", "♥8"]));

    // ── level-card / joker pairing ──
    expect(t, "no-trump different-suit level cards are not a pair", false, legal(2, NT, ["♣2", "♣2"], ["♥2", "♦2", "♠2", "♠2"], ["♥2", "♦2"]));
    expect(t, "no-trump same-suit level pair is legal", true, legal(2, NT, ["♣2", "♣2"], ["♥2", "♦2", "♠2", "♠2"], ["♠2", "♠2"]));
    expect(t, "jokers do not pair with a real pair available", false, legal(2, NT, ["♠2", "♠2"], ["🃟", "🃏", "♣2", "♣2"], ["🃟", "🃏"]));

    // ── two-deck face-value integrity ──
    let lead9 = CardParse.parse(["♣9", "♣9"]);
    let hand9 = Array.concat<Card.Card>([CardParse.copyId("♣9", 2)], CardParse.parse(["♥3", "♥4"]));
    let play9 = CardParse.parse(["♥3", "♥4"]);
    expect(t, "two-deck: third copy of a lead pair is illegal", false, legalIds(2, H, lead9, hand9, play9));
    let lead7 = CardParse.parse(["♣7"]);
    let hand7 = Array.concat<Card.Card>([CardParse.copyId("♣7", 1), CardParse.copyId("♣7", 2)], CardParse.parse(["♥3", "♥4"]));
    let play7 = CardParse.parse(["♥3", "♥4"]);
    expect(t, "two-deck: two extra copies of a lead single is illegal", false, legalIds(2, H, lead7, hand7, play7));
    let leadO = [CardParse.copyId("♣7", 0)];
    let handO = Array.concat<Card.Card>([CardParse.copyId("♣7", 1)], CardParse.parse(["♣K", "♦4"]));
    let playO = [CardParse.copyId("♣7", 1)];
    expect(t, "two-deck: holding the other copy is legal", true, legalIds(2, H, leadO, handO, playO));
    let leadJ = [CardParse.copyId("🃏", 0)];
    let handJ = Array.concat<Card.Card>([CardParse.copyId("🃏", 1)], CardParse.parse(["♣K", "♦4"]));
    let playJ = [CardParse.copyId("🃏", 1)];
    expect(t, "two-deck: holding the other big joker is legal", true, legalIds(2, H, leadJ, handJ, playJ));
    let ownLead = CardParse.parse(["♠A", "♠A"]);
    let ownHand = CardParse.parse(["♠A", "♠A", "♥3"]);
    let ownPlay = CardParse.parse(["♠A", "♠A"]);
    expect(t, "two-deck: leader's own pair is not double-counted", true, legalIds(2, H, ownLead, ownHand, ownPlay));
    let ownTLead = CardParse.parse(["♣8", "♣8", "♣9", "♣9"]);
    let ownTHand = CardParse.parse(["♣8", "♣8", "♣9", "♣9", "♥3"]);
    let ownTPlay = CardParse.parse(["♣8", "♣8", "♣9", "♣9"]);
    expect(t, "two-deck: leader's own tractor is not double-counted", true, legalIds(2, H, ownTLead, ownTHand, ownTPlay));
  };
}
