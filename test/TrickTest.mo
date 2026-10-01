/// T5 — trick resolution and kill validity
/// (CHECKS.md 比牌与杀牌 cases).
import Array "mo:core/Array";
import Card "../src/Card";
import Combo "../src/Combo";
import Follow "../src/Follow";
import Trick "../src/Trick";
import CardParse "CardParse";
import Test "Test";

module {
  // seats 0..3 = a..d. Every follow must be legal, then the winner is checked.
  func assertWinner(
    t : Test.Harness,
    msg : Text,
    level : Nat,
    trump : Nat,
    leadStrs : [Text],
    seatHands : [[Text]],
    seatPlays : [[Text]],
    leader : Nat,
    expected : Nat,
  ) {
    let game : Card.Game = { level; trump };
    let ids = CardParse.parseMulti(seatHands);
    let leadIds = CardParse.subset(seatHands[leader], ids[leader], leadStrs);
    var followsOk = true;
    var s = 0;
    while (s < 4) {
      if (s != leader) {
        let play = CardParse.subset(seatHands[s], ids[s], seatPlays[s]);
        switch (Follow.checkPlay(leadIds, ids[s], play, game)) {
          case null {};
          case (?_) { followsOk := false };
        };
      };
      s += 1;
    };
    t.check(followsOk, msg # ": all follows legal");
    switch (Combo.determineLeadType(leadIds, game)) {
      case null { t.check(false, msg # ": lead classifiable") };
      case (?lead) {
        let order = [leader, (leader + 1) % 4, (leader + 2) % 4, (leader + 3) % 4];
        let plays = Array.map<Nat, Trick.Play>(
          order,
          func(seat) {
            {
              seat;
              cards = CardParse.subset(seatHands[seat], ids[seat], seatPlays[seat]);
              handBefore = ids[seat];
            };
          },
        );
        let got = Trick.determineTrickWinner(plays, lead, game);
        t.equalNat(got, expected, msg);
      };
    };
  };

  public func run(t : Test.Harness) {
    t.suite("T5 trick resolution");
    let H = Card.HEARTS + 1;

    // ── isValidKill: structural negatives ──
    switch (Combo.determineLeadType(CardParse.parse(["♠3", "♠3", "♠4", "♠4"]), { level = 2; trump = H })) {
      case (?lead) {
        let g : Card.Game = { level = 2; trump = H };
        t.check(
          not Trick.isValidKill(CardParse.parse(["♥10", "♥10", "♥7", "♥7"]), lead, g),
          "loose trump pairs do not kill a tractor",
        );
        t.check(
          Trick.isValidKill(CardParse.parse(["♥7", "♥7", "♥8", "♥8"]), lead, g),
          "adjacent trump pairs (a tractor) kill a tractor",
        );
        t.check(
          not Trick.isValidKill(CardParse.parse(["♥3", "♥3", "♥4", "♥4", "♥6", "♥6"]), lead, g),
          "a kill must have the lead's card count",
        );
        t.check(
          not Trick.isValidKill(CardParse.parse(["♠3", "♠3", "♠4", "♠4"]), lead, g),
          "side cards cannot kill a side tractor",
        );
      };
      case null { t.check(false, "side tractor lead classifiable") };
    };
    switch (Combo.determineLeadType(CardParse.parse(["♥2", "♥2"]), { level = 2; trump = Card.NT })) {
      case (?lead) {
        let g : Card.Game = { level = 2; trump = Card.NT };
        t.check(
          not Trick.isValidKill(CardParse.parse(["♣2", "♦2"]), lead, g),
          "different-suit level cards do not kill a pair",
        );
        t.check(
          Trick.isValidKill(CardParse.parse(["🃟", "🃟"]), lead, g),
          "a real joker pair kills a pair",
        );
      };
      case null { t.check(false, "level pair lead classifiable") };
    };

    // ── Normal side-suit comparisons ──
    assertWinner(t, "side single leader wins", 2, H, ["♥A"],
      [["♥A", "♠3", "♦4"], ["♥K", "♠4", "♦5"], ["♥Q", "♣6", "♦7"], ["♥J", "♠5", "♦8"]],
      [["♥A"], ["♥K"], ["♥Q"], ["♥J"]], 0, 0);
    assertWinner(t, "side single follower wins", 2, H, ["♥K"],
      [["♥K", "♠3", "♦4"], ["♥A", "♠4", "♦5"], ["♥Q", "♣6", "♦7"], ["♥J", "♠5", "♦8"]],
      [["♥K"], ["♥A"], ["♥Q"], ["♥J"]], 0, 1);
    assertWinner(t, "side single tie to first", 2, H, ["♥A"],
      [["♥A", "♠3", "♦4"], ["♥A", "♠4", "♦5"], ["♥K", "♣6", "♦7"], ["♥Q", "♠5", "♦8"]],
      [["♥A"], ["♥A"], ["♥K"], ["♥Q"]], 0, 0);
    assertWinner(t, "side single tie to leader b", 2, H, ["♥A"],
      [["♥A", "♠3", "♦4"], ["♥A", "♠4", "♦5"], ["♥K", "♣6", "♦7"], ["♥Q", "♠5", "♦8"]],
      [["♥A"], ["♥A"], ["♥K"], ["♥Q"]], 1, 1);
    assertWinner(t, "side pair leader wins", 2, H, ["♥K", "♥K"],
      [["♥K", "♥K", "♠3"], ["♥Q", "♥Q", "♠4"], ["♥J", "♥J", "♣5"], ["♥10", "♥10", "♦6"]],
      [["♥K", "♥K"], ["♥Q", "♥Q"], ["♥J", "♥J"], ["♥10", "♥10"]], 0, 0);
    assertWinner(t, "side pair follower wins", 2, H, ["♥Q", "♥Q"],
      [["♥Q", "♥Q", "♠3"], ["♥K", "♥K", "♠4"], ["♥J", "♥J", "♣5"], ["♥10", "♥10", "♦6"]],
      [["♥Q", "♥Q"], ["♥K", "♥K"], ["♥J", "♥J"], ["♥10", "♥10"]], 0, 1);
    assertWinner(t, "side tractor leader wins", 2, H, ["♠9", "♠9", "♠10", "♠10"],
      [["♠9", "♠9", "♠10", "♠10", "♥3"], ["♠8", "♠8", "♠7", "♠7", "♥4"], ["♠6", "♠6", "♠5", "♠5", "♦5"], ["♥5", "♥6", "♥7", "♥8", "♣9"]],
      [["♠9", "♠9", "♠10", "♠10"], ["♠8", "♠8", "♠7", "♠7"], ["♠6", "♠6", "♠5", "♠5"], ["♥5", "♥6", "♥7", "♥8"]], 0, 0);
    assertWinner(t, "side tractor follower wins", 2, H, ["♠9", "♠9", "♠10", "♠10"],
      [["♠9", "♠9", "♠10", "♠10", "♥3"], ["♠Q", "♠Q", "♠K", "♠K", "♥4"], ["♠6", "♠6", "♠5", "♠5", "♦5"], ["♥5", "♥6", "♥7", "♥8", "♣9"]],
      [["♠9", "♠9", "♠10", "♠10"], ["♠Q", "♠Q", "♠K", "♠K"], ["♠6", "♠6", "♠5", "♠5"], ["♥5", "♥6", "♥7", "♥8"]], 0, 1);
    assertWinner(t, "side tractor non-tractor disqualified", 2, H, ["♠8", "♠8", "♠9", "♠9"],
      [["♠8", "♠8", "♠9", "♠9", "♥3"], ["♠4", "♠4", "♠5", "♠5", "♥4"], ["♠A", "♠A", "♠J", "♠J", "♦5"], ["♠K", "♥7", "♦2", "♠10", "♣9"]],
      [["♠8", "♠8", "♠9", "♠9"], ["♠4", "♠4", "♠5", "♠5"], ["♠A", "♠A", "♠J", "♠J"], ["♠K", "♥7", "♦2", "♠10"]], 0, 0);
    assertWinner(t, "main tractor non-tractor disqualified", 2, H, ["♥8", "♥8", "♥9", "♥9"],
      [["♥8", "♥8", "♥9", "♥9", "♠3"], ["♥4", "♥4", "♥5", "♥5", "♠4"], ["♥A", "♥A", "♥J", "♥J", "♦5"], ["♥K", "♠7", "♦2", "♥10", "♣9"]],
      [["♥8", "♥8", "♥9", "♥9"], ["♥4", "♥4", "♥5", "♥5"], ["♥A", "♥A", "♥J", "♥J"], ["♥K", "♠7", "♦2", "♥10"]], 0, 0);

    // ── Kills ──
    assertWinner(t, "side throw pure singles leader wins", 2, H, ["♠A", "♠K", "♠Q"],
      [["♠A", "♠K", "♠Q", "♥3"], ["♠J", "♠10", "♥3", "♥4"], ["♠9", "♠8", "♦4", "♦5"], ["♠7", "♠6", "♣5", "♣6"]],
      [["♠A", "♠K", "♠Q"], ["♠J", "♠10", "♥3"], ["♠9", "♠8", "♦4"], ["♠7", "♠6", "♣5"]], 0, 0);
    assertWinner(t, "single lead one kill wins", 2, H, ["♥3"],
      [["♥3", "♠4", "♦5"], ["♠2", "♦4", "♣5"], ["♥K", "♠6", "♦7"], ["♥Q", "♠8", "♦9"]],
      [["♥3"], ["♠2"], ["♥K"], ["♥Q"]], 0, 1);
    assertWinner(t, "pair lead one kill wins", 2, H, ["♥3", "♥3"],
      [["♥3", "♥3", "♠4"], ["♠2", "♠2", "♦4"], ["♥K", "♥K", "♠5"], ["♥Q", "♥Q", "♦6"]],
      [["♥3", "♥3"], ["♠2", "♠2"], ["♥K", "♥K"], ["♥Q", "♥Q"]], 0, 1);
    assertWinner(t, "pair lead invalid kill two singles", 2, H, ["♥3", "♥3"],
      [["♥3", "♥3", "♠4"], ["🃟", "♠2", "♦4"], ["♥K", "♥K", "♠5"], ["♥Q", "♥Q", "♦6"]],
      [["♥3", "♥3"], ["🃟", "♠2"], ["♥K", "♥K"], ["♥Q", "♥Q"]], 0, 2);
    assertWinner(t, "tractor lead one kill wins", 2, H, ["♠3", "♠3", "♠4", "♠4"],
      [["♠3", "♠3", "♠4", "♠4", "♣6"], ["♥2", "♥2", "♣2", "♣2", "♦4"], ["♠5", "♠5", "♠6", "♠6", "♠7"], ["♠7", "♠8", "♥3", "♥4", "♣5"]],
      [["♠3", "♠3", "♠4", "♠4"], ["♥2", "♥2", "♣2", "♣2"], ["♠5", "♠5", "♠6", "♠6"], ["♠7", "♠8", "♥3", "♥4"]], 0, 1);
    assertWinner(t, "tractor lead invalid kill no trump tractor", 2, H, ["♠3", "♠3", "♠4", "♠4"],
      [["♠3", "♠3", "♠4", "♠4", "♥5"], ["🃏", "♠2", "♣2", "♦2", "♥4"], ["♠5", "♠5", "♠6", "♠6", "♥6"], ["♥7", "♥8", "♠9", "♦10", "♣J"]],
      [["♠3", "♠3", "♠4", "♠4"], ["🃏", "♠2", "♣2", "♦2"], ["♠5", "♠5", "♠6", "♠6"], ["♥7", "♥8", "♠9", "♦10"]], 0, 2);

    // ── Multiple kills ──
    assertWinner(t, "multiple single kills highest trump wins", 2, H, ["♥3"],
      [["♥3", "♠4", "♦5"], ["♠2", "♦4", "♣5"], ["🃟", "♠6", "♦7"], ["🃏", "♠8", "♦9"]],
      [["♥3"], ["♠2"], ["🃟"], ["🃏"]], 0, 3);
    assertWinner(t, "multiple pair kills highest pair wins", 2, H, ["♥3", "♥3"],
      [["♥3", "♥3", "♠4"], ["♠2", "♠2", "♦4"], ["🃟", "🃟", "♠5"], ["🃏", "🃏", "♦6"]],
      [["♥3", "♥3"], ["♠2", "♠2"], ["🃟", "🃟"], ["🃏", "🃏"]], 0, 3);
    assertWinner(t, "multiple tractor kills highest wins", 2, H, ["♠3", "♠3", "♠4", "♠4"],
      [["♠3", "♠3", "♠4", "♠4", "♠5"], ["♥Q", "♥Q", "♥K", "♥K", "♦4"], ["♥A", "♥A", "♠2", "♠2", "♣4"], ["♥2", "♥2", "🃟", "🃟", "♦6"]],
      [["♠3", "♠3", "♠4", "♠4"], ["♥Q", "♥Q", "♥K", "♥K"], ["♥A", "♥A", "♠2", "♠2"], ["♥2", "♥2", "🃟", "🃟"]], 0, 3);

    // ── Throw kills ──
    assertWinner(t, "pure single throw pair does not upgrade", 2, H, ["♠3", "♠4", "♠5"],
      [["♠3", "♠4", "♠5", "♥3"], ["🃏", "♣2", "♦2"], ["🃟", "🃟", "♠2"], ["♥3", "♥4", "♥5"]],
      [["♠3", "♠4", "♠5"], ["🃏", "♣2", "♦2"], ["🃟", "🃟", "♠2"], ["♥3", "♥4", "♥5"]], 0, 1);
    assertWinner(t, "throw pair+single compare pair first", 2, H, ["♠A", "♠A", "♠K"],
      [["♠A", "♠A", "♠K", "♥3"], ["♦2", "♦2", "🃟", "♥4"], ["🃏", "🃏", "♣2", "♥5"], ["♥3", "♥4", "♥5", "♥6"]],
      [["♠A", "♠A", "♠K"], ["♦2", "♦2", "🃟"], ["🃏", "🃏", "♣2"], ["♥3", "♥4", "♥5"]], 0, 2);
    assertWinner(t, "throw tractor+single compare tractor first", 2, H, ["♠3", "♠3", "♠4", "♠4", "♠A"],
      [["♠3", "♠3", "♠4", "♠4", "♠A", "♥3"], ["♦2", "♦2", "♥2", "♥2", "♠2", "♥4"], ["🃏", "🃏", "🃟", "🃟", "♣2", "♥5"], ["♥3", "♥4", "♥5", "♥6", "♥7", "♥8"]],
      [["♠3", "♠3", "♠4", "♠4", "♠A"], ["♦2", "♦2", "♥2", "♥2", "♠2"], ["🃏", "🃏", "🃟", "🃟", "♣2"], ["♥3", "♥4", "♥5", "♥6", "♥7"]], 0, 2);
    assertWinner(t, "throw two tractor slots valid kill wins", 2, H, ["♠3", "♠3", "♠4", "♠4", "♠7", "♠7", "♠8", "♠8"],
      [["♠3", "♠3", "♠4", "♠4", "♠7", "♠7", "♠8", "♠8", "♥3"], ["♦2", "♦2", "♥2", "♥2", "🃟", "🃟", "🃏", "🃏", "♥4"], ["♣2", "♣2", "♠2", "♠2", "♥5", "♥6", "♥9", "♥10", "♥J"], ["♥3", "♥4", "♥5", "♥6", "♥7", "♥8", "♥9", "♥10", "♥J"]],
      [["♠3", "♠3", "♠4", "♠4", "♠7", "♠7", "♠8", "♠8"], ["♦2", "♦2", "♥2", "♥2", "🃟", "🃟", "🃏", "🃏"], ["♣2", "♣2", "♠2", "♠2", "♥5", "♥6", "♥9", "♥10"], ["♥3", "♥4", "♥5", "♥6", "♥7", "♥8", "♥9", "♥10"]], 0, 1);
    assertWinner(t, "throw with tractor slot invalid kill loses", 2, H, ["♠3", "♠3", "♠4", "♠4", "♠A"],
      [["♠3", "♠3", "♠4", "♠4", "♠A", "♥3"], ["🃏", "🃏", "♣2", "♣2", "♦2", "♥4"], ["♥3", "♥4", "♥5", "♥6", "♥7", "♥8"], ["♠5", "♠6", "♥8", "♥9", "♥10", "♥J"]],
      [["♠3", "♠3", "♠4", "♠4", "♠A"], ["🃏", "🃏", "♣2", "♣2", "♦2"], ["♥3", "♥4", "♥5", "♥6", "♥7"], ["♠5", "♠6", "♥8", "♥9", "♥10"]], 0, 0);

    // ── Main-suit comparisons ──
    assertWinner(t, "main single highest trump wins", 2, H, ["♥3"],
      [["♥3", "♠4", "♦5"], ["♥A", "♠6", "♦7"], ["♦2", "♠8", "♣9"], ["🃏", "♠10", "♦J"]],
      [["♥3"], ["♥A"], ["♦2"], ["🃏"]], 0, 3);
    assertWinner(t, "main pair off-suit level beats ordinary pair", 2, H, ["♥A", "♥A"],
      [["♥A", "♥A", "♠3"], ["♠2", "♠2", "♦4"], ["♥K", "♥K", "♠5"], ["♦3", "♦4", "♠6"]],
      [["♥A", "♥A"], ["♠2", "♠2"], ["♥K", "♥K"], ["♦3", "♦4"]], 0, 1);

    // ── Side cannot beat a trump lead; NT structural negatives ──
    assertWinner(t, "side cannot beat a trump lead", 2, H, ["♥3"],
      [["♥3", "♠4", "♦5"], ["♠A", "♦4", "♣5"], ["♠K", "♠6", "♦7"], ["♥4", "♠8", "♦9"]],
      [["♥3"], ["♠A"], ["♠K"], ["♥4"]], 0, 3);
    assertWinner(t, "no-trump pair invalid different-suit level kill loses", 2, Card.NT, ["♥2", "♥2"],
      [["♥2", "♥2", "♠3"], ["♣2", "♦2", "♠4"], ["🃟", "🃟", "♦4"], ["♥3", "♥4", "♠5"]],
      [["♥2", "♥2"], ["♣2", "♦2"], ["🃟", "🃟"], ["♥3", "♥4"]], 0, 2);
    assertWinner(t, "no-trump tractor non-consecutive disqualified", 2, Card.NT, ["♥2", "♥2", "🃟", "🃟"],
      [["♥2", "♥2", "🃟", "🃟", "♠3"], ["♣2", "♣2", "🃏", "🃏", "♠4"], ["♠2", "♠2", "♥3", "♥4", "♦4"], ["♥5", "♥6", "♠5", "♦6", "♣7"]],
      [["♥2", "♥2", "🃟", "🃟"], ["♣2", "♣2", "🃏", "🃏"], ["♠2", "♠2", "♥3", "♥4"], ["♥5", "♥6", "♠5", "♦6"]], 0, 0);
  };
}
