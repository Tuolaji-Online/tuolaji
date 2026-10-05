/// M3 tests: deck construction + seeded shuffle, the dealing tick loop (I8),
/// trump declarations during dealing (I8), bury + kitty handling (I1 partial),
/// privacy of dealt hands, and the bury deadline / auto-bury path (I9).
import Array "mo:core/Array";
import Nat "mo:core/Nat";
import Principal "mo:core/Principal";
import VarArray "mo:core/VarArray";
import Card "../src/Card";
import Table "../src/Table";
import Shuffle "../src/Shuffle";
import Types "../src/Types";
import Test "Test";

module {
  let TICK : Int = 1_000_000_000; // one second in nanoseconds

  /// Timeouts disabled, so dealing finalises immediately and games wait for
  /// input. Tests that exercise a timeout opt in explicitly.
  let noTimeouts : Types.TableConfig = {
    Types.defaultConfig with
    declareSeconds = 0;
    overrideSeconds = 0;
    burySeconds = 0;
    playSeconds = 0;
  };

  func principals() : [Principal] {
    [
      Principal.fromText("rkp4c-7iaaa-aaaaa-aaaca-cai"),
      Principal.fromText("rrkah-fqaaa-aaaaa-aaaaq-cai"),
      Principal.fromText("renrk-eyaaa-aaaaa-aaada-cai"),
      Principal.fromText("rno2w-sqaaa-aaaaa-aaacq-cai"),
      Principal.fromText("rdmx6-jaaaa-aaaaa-aaadq-cai"),
    ];
  };

  func isOk(r : Types.ActionResult) : Bool {
    switch (r) { case (#ok(_)) { true }; case _ { false } };
  };

  func isErr(r : Types.ActionResult, code : Types.ErrorCode) : Bool {
    switch (r) { case (#err(e)) { e.code == code }; case _ { false } };
  };

  func phaseEq(a : Types.Phase, b : Types.Phase) : Bool { a == b };

  func isBanker(st : Table.State, seat : Nat) : Bool {
    switch (st.banker) { case (?b) { b == seat }; case null { false } };
  };

  /// Four seated principals in `#Lobby`.
  func seated(cfg : Types.TableConfig, ps : [Principal]) : Table.State {
    let st = Table.new(0, cfg, ps[0], 0);
    ignore Table.joinTable(st, ps[1], 1, 0);
    ignore Table.joinTable(st, ps[2], 2, 0);
    ignore Table.joinTable(st, ps[3], 3, 0);
    st;
  };

  func readyAll(st : Table.State, ps : [Principal]) {
    ignore Table.ready(st, ps[0], 0);
    ignore Table.ready(st, ps[1], 0);
    ignore Table.ready(st, ps[2], 0);
    ignore Table.ready(st, ps[3], 0);
  };

  /// Build a 108-card deck equal to `newDeck()` with `(index, card)` pairs
  /// placed by swapping each card into its target index.
  func deckWith(pairs : [(Nat, Card.Card)]) : [Card.Card] {
    let arr = Array.toVarArray<Card.Card>(Shuffle.newDeck());
    for ((idx, card) in pairs.vals()) {
      var pos = 0;
      var i = 0;
      while (i < arr.size()) {
        if (arr[i] == card) { pos := i };
        i += 1;
      };
      let tmp = arr[idx];
      arr[idx] := card;
      arr[pos] := tmp;
    };
    VarArray.toArray<Card.Card>(arr);
  };

  /// Deal a full hand out, returning the time of the final tick.
  func dealAll(st : Table.State) : Int {
    Table.installDeck(st, Shuffle.newDeck(), 0);
    var now = TICK;
    var tick = 1;
    while (tick < 25) {
      ignore Table.dealTick(st, now);
      now += TICK;
      tick += 1;
    };
    now;
  };

  // ── shuffle ────────────────────────────────────────────────────────

  func testShuffle(t : Test.Harness) {
    t.suite("M3 shuffle");
    let deck = Shuffle.newDeck();
    t.equalNat(deck.size(), 108, "deck has 108 cards");
    var ordered = true;
    var i = 0;
    while (i < 108) {
      if (deck[i] != i + 1) { ordered := false };
      i += 1;
    };
    t.check(ordered, "newDeck is 1..108 in order");

    let s1 = Shuffle.shuffle(deck, 12345);
    let s2 = Shuffle.shuffle(deck, 12345);
    var sameSeed = true;
    i := 0;
    while (i < 108) {
      if (s1[i] != s2[i]) { sameSeed := false };
      i += 1;
    };
    t.check(sameSeed, "same seed yields identical shuffle");

    let seen = VarArray.repeat(false, 109);
    var perm = true;
    i := 0;
    while (i < 108) {
      if (seen[s1[i]]) { perm := false };
      seen[s1[i]] := true;
      i += 1;
    };
    t.check(perm, "shuffle is a permutation of the deck");

    let s3 = Shuffle.shuffle(deck, 999);
    var differs = false;
    i := 0;
    while (i < 108) {
      if (s1[i] != s3[i]) { differs := true };
      i += 1;
    };
    t.check(differs, "different seeds usually differ");

    let b = Array.toBlob([1, 2, 3, 4, 5, 6, 7, 8]);
    t.check(Shuffle.seedFromBlob(b) == Shuffle.seedFromBlob(b), "seedFromBlob is deterministic");

    // Entropy-driven shuffle: deterministic in the blob, a permutation, and
    // empty entropy leaves the deck untouched (the explicit-deck test path).
    let entropy = Array.toBlob(Array.tabulate<Nat8>(32, func(i) = Nat.toNat8(i * 7 + 1)));
    let h1 = Shuffle.shuffleWithEntropy(deck, entropy);
    let h2 = Shuffle.shuffleWithEntropy(deck, entropy);
    var sameEntropy = true;
    var permEntropy = true;
    let seenE = VarArray.repeat(false, 109);
    i := 0;
    while (i < 108) {
      if (h1[i] != h2[i]) { sameEntropy := false };
      if (seenE[h1[i]]) { permEntropy := false };
      seenE[h1[i]] := true;
      i += 1;
    };
    t.check(sameEntropy, "shuffleWithEntropy is deterministic in the entropy");
    t.check(permEntropy, "shuffleWithEntropy is a permutation");
    t.check(Shuffle.shuffleWithEntropy(deck, "")[0] == deck[0], "empty entropy leaves the deck untouched");
  };

  // ── I8: dealing ticks ──────────────────────────────────────────────

  func testDeal(t : Test.Harness, ps : [Principal]) {
    t.suite("M3 dealing");
    let st = seated(noTimeouts, ps);
    readyAll(st, ps);
    t.check(phaseEq(Table.info(st).phase, #Dealing), "four readies start Dealing");
    t.check(Table.needsShuffle(st), "a shuffle is pending after ready");

    let deck = Shuffle.newDeck();
    Table.installDeck(st, deck, 0);
    t.check(not Table.needsShuffle(st), "installDeck clears the pending shuffle");

    var oneEach = true;
    var i = 0;
    while (i < 4) {
      if (st.hands[i].size() != 1) { oneEach := false };
      i += 1;
    };
    t.check(oneEach, "first packet gives every seat one card");
    // Dealing starts at seat (dealer+1) = 1 with the default firstDealer 0.
    t.equalNat(st.hands[1][0], deck[0], "first card goes to seat 1");
    t.equalNat(st.hands[2][0], deck[1], "second card goes to seat 2");
    t.equalNat(st.hands[3][0], deck[2], "third card goes to seat 3");
    t.equalNat(st.hands[0][0], deck[3], "fourth card goes to seat 0");

    t.check(not Table.dealTick(st, 1), "a tick before nextDealAt is ignored");

    var now = TICK;
    var tick = 1;
    while (tick < 25) {
      t.check(Table.dealTick(st, now), "timed tick advances the deal");
      now += TICK;
      tick += 1;
    };
    t.check(phaseEq(Table.info(st).phase, #Burying), "dealing finishes into Burying");
    t.check(isBanker(st, 0), "with no declaration the dealer is the banker");
    t.equalNat(Array.size(st.kitty), 8, "kitty count is 8 after dealing");

    var total = 0;
    i := 0;
    while (i < 4) {
      let expected = if (i == 0) { 33 } else { 25 };
      t.equalNat(st.hands[i].size(), expected, "banker has 33 / others 25");
      total += st.hands[i].size();
      i += 1;
    };
    t.equalNat(total, 108, "hands partition all 108 cards");

    let seen = VarArray.repeat(false, 109);
    var distinct = true;
    i := 0;
    while (i < 4) {
      for (c in st.hands[i].vals()) {
        if (seen[c]) { distinct := false };
        seen[c] := true;
      };
      i += 1;
    };
    t.check(distinct, "every dealt card is unique");

    // I4: private hand events never reach the wrong seat.
    let p0 = Table.poll(st, ps[0], 0);
    var leaks = false;
    for (e in p0.events.vals()) {
      switch (e.body) {
        case (#HandUpdated(h)) { if (h.seat != 0) { leaks := true } };
        case _ {};
      };
    };
    t.check(not leaks, "no other seat's HandUpdated leaks to seat 0");
    t.check(p0.view.kitty == null, "the kitty is hidden while burying");
  };

  // ── I8: declarations ───────────────────────────────────────────────

  func testDeclare(t : Test.Harness, ps : [Principal]) {
    t.suite("M3 declare");
    let st = seated(noTimeouts, ps);
    readyAll(st, ps);
    // seat 1: ♠2 + second-deck ♠2; seat 2: ♥2; seat 3: ♦2 pair.
    let deck = deckWith([(0, 49), (4, 101), (1, 50), (2, 52), (6, 104)]);
    Table.installDeck(st, deck, 0);
    ignore Table.dealTick(st, TICK);

    t.check(isOk(Table.declareTrump(st, ps[1], [49], 0)), "single ♠2 declares");
    t.check(st.trump == ?1, "single sets trump to spades");
    t.check(isErr(Table.declareTrump(st, ps[2], [50], 0), #IllegalDeclaration), "a second single cannot override");
    t.check(isOk(Table.declareTrump(st, ps[1], [49, 101], 0)), "the same seat may lock with a pair");
    t.check(isErr(Table.declareTrump(st, ps[3], [52, 104], 0), #IllegalDeclaration), "a pair is terminal without enhanced override");
    t.check(isErr(Table.declareTrump(st, ps[0], [51], 0), #IllegalDeclaration), "declaring an unheld card is rejected");
    t.check(isErr(Table.declareTrump(st, ps[1], [49, 49], 0), #DuplicateCard), "duplicate declaration cards are rejected");

    // A declaration after the deal has completed is a WrongPhase.
    let st2 = seated(noTimeouts, ps);
    readyAll(st2, ps);
    ignore dealAll(st2);
    t.check(isErr(Table.declareTrump(st2, ps[0], [49], 0), #WrongPhase), "declare after dealing is WrongPhase");
  };

  func testEnhancedOverride(t : Test.Harness, ps : [Principal]) {
    t.suite("M3 enhanced joker override");
    let strong = { noTimeouts with enhancedJokerOverride = true };
    let st = seated(strong, ps);
    readyAll(st, ps);
    // seat1 small jokers, seat2 ♥2 pair, seat3 big jokers.
    let deck = deckWith([(0, 105), (4, 107), (1, 50), (5, 102), (2, 106), (6, 108)]);
    Table.installDeck(st, deck, 0);
    ignore Table.dealTick(st, TICK);

    t.check(isOk(Table.declareTrump(st, ps[2], [50, 102], 0)), "level pair declares");
    t.check(st.trump == ?2, "level pair sets hearts");
    t.check(isOk(Table.declareTrump(st, ps[1], [105, 107], 0)), "small-joker pair overrides a level pair (enhanced)");
    t.check(st.trump == ?5, "joker override is no-trump");
    t.check(isErr(Table.declareTrump(st, ps[3], [106, 108], 0), #IllegalDeclaration), "a No-Trump call is final, even enhanced");

    // The same ladder without the flag stops at the level pair.
    let plain = { noTimeouts with enhancedJokerOverride = false };
    let st2 = seated(plain, ps);
    readyAll(st2, ps);
    Table.installDeck(st2, deck, 0);
    ignore Table.dealTick(st2, TICK);
    t.check(isOk(Table.declareTrump(st2, ps[2], [50, 102], 0)), "level pair declares (non-enhanced)");
    t.check(isErr(Table.declareTrump(st2, ps[1], [105, 107], 0), #IllegalDeclaration), "joker pair cannot override without enhanced flag");
  };

  // ── I1 (partial) / I9: bury ────────────────────────────────────────

  func testBury(t : Test.Harness, ps : [Principal]) {
    t.suite("M3 bury");
    let st = seated(noTimeouts, ps);
    readyAll(st, ps);
    ignore dealAll(st);
    t.check(phaseEq(Table.info(st).phase, #Burying), "ready to bury");

    let good = Array.tabulate<Card.Card>(8, func i = st.hands[0][i]);
    let foreign = Array.tabulate<Card.Card>(8, func i = st.hands[1][i]);
    t.check(isErr(Table.buryKitty(st, ps[1], good, 0), #NotKittyOwner), "non-banker cannot bury");
    t.check(isErr(Table.buryKitty(st, ps[0], [st.hands[0][0]], 0), #KittySizeMismatch), "bury needs exactly 8 cards");
    t.check(isErr(Table.buryKitty(st, ps[0], foreign, 0), #CardNotInHand), "foreign cards cannot be buried");

    t.check(isOk(Table.buryKitty(st, ps[0], good, 0)), "the banker buries 8 cards");
    t.check(phaseEq(Table.info(st).phase, #Playing), "bury moves to Playing");
    // While playing, only the banker can see the buried kitty.
    switch (Table.view(st, ps[0]).kitty) {
      case (?k) { t.equalNat(k.size(), 8, "the banker sees the buried kitty") };
      case null { t.check(false, "the banker should see the buried kitty") };
    };
    t.check(Table.view(st, ps[1]).kitty == null, "another seat cannot see the buried kitty");
    t.check(Table.view(st, ps[2]).kitty == null, "a third seat cannot see the buried kitty");
    t.equalNat(st.hands[0].size(), 25, "banker hand drops to 25");
    t.equalNat(st.kitty.size(), 8, "kitty stores the buried cards");
    var same = true;
    var i = 0;
    while (i < 8) {
      if (st.kitty[i] != good[i]) { same := false };
      i += 1;
    };
    t.check(same, "kitty equals the buried cards");
    t.equalNat(st.nextSeat, 0, "the banker leads the first trick");
  };

  func testAutoBury(t : Test.Harness, ps : [Principal]) {
    t.suite("M3 bury deadline");
    let timed = { noTimeouts with burySeconds = 1 };
    let st = seated(timed, ps);
    readyAll(st, ps);
    ignore dealAll(st);

    let deadline = switch (st.buryDeadline) {
      case (?d) { d };
      case null { 0 };
    };
    t.check(deadline > 0, "burySeconds sets a deadline");
    t.check(not Table.autoBury(st, deadline - 1), "no auto-bury before the deadline");
    t.check(phaseEq(Table.info(st).phase, #Burying), "still burying before the deadline");
    t.check(Table.autoBury(st, deadline), "auto-bury fires at the deadline");
    t.check(phaseEq(Table.info(st).phase, #Playing), "auto-bury moves to Playing");
    t.equalNat(st.hands[0].size(), 25, "auto-bury leaves 25 cards");
    t.equalNat(st.kitty.size(), 8, "auto-bury picks 8 cards");

    let p = Table.poll(st, ps[0], 0);
    var sawAuto = false;
    var burySeq = 0;
    for (e in p.events.vals()) {
      switch (e.body) {
        case (#KittyBuried(k)) { if (k.auto) { sawAuto := true }; burySeq := e.seq };
        case _ {};
      };
    };
    t.check(sawAuto, "auto-bury emits KittyBuried{auto=true}");
    // The auto-bury must re-emit the banker's post-bury hand, so a push-based
    // client does not keep the eight buried cards and play them later.
    var sawPostBuryHand = false;
    for (e in p.events.vals()) {
      switch (e.body) {
        case (#HandUpdated(h)) {
          if (h.seat == 0 and e.seq > burySeq and h.hand.size() == 25) { sawPostBuryHand := true };
        };
        case _ {};
      };
    };
    t.check(sawPostBuryHand, "auto-bury re-emits the banker's post-bury hand (25 cards)");

    // A null deadline waits indefinitely (v1 default).
    let st2 = seated(noTimeouts, ps);
    readyAll(st2, ps);
    ignore dealAll(st2);
    t.check(st2.buryDeadline == null, "no deadline when burySeconds is 0");
    t.check(not Table.autoBury(st2, 999_999_999_999_999), "null deadline never auto-buries");
    t.check(phaseEq(Table.info(st2).phase, #Burying), "game waits indefinitely for the banker");
  };

  // ── M5: declaration window / NT fallback ───────────────────────────

  func testDeclarationWindow(t : Test.Harness, ps : [Principal]) {
    t.suite("M5 declaration window");
    // The post-deal window and the counter-declaration window are distinct.
    let cfg = { noTimeouts with declareSeconds = 7; overrideSeconds = 3 };

    // Nobody declares: the deal waits out the window, then defaults to NT.
    let st = seated(cfg, ps);
    readyAll(st, ps);
    Table.installDeck(st, Shuffle.newDeck(), 0);
    var now : Int = 0;
    var tick = 1;
    while (tick < 25) {
      now += TICK;
      ignore Table.dealTick(st, now);
      tick += 1;
    };
    t.check(phaseEq(st.phase, #Dealing), "deal stays in Dealing during the window");
    t.check(st.dealComplete, "deck is exhausted");
    t.check(st.decl == null, "no declaration yet");
    t.check(not Table.checkDealWindow(st, now + 1), "window still open");
    t.check(Table.checkDealWindow(st, now + 8 * TICK), "window closes");
    t.check(phaseEq(st.phase, #Burying), "moves to Burying");
    t.check(st.trump == ?Card.NT, "no declaration defaults to No-Trump");
    t.check(st.bankTeam == ?0, "no declaration defaults the bank to team 0");
    t.check(isBanker(st, 0), "the banker comes from the default bank team");

    // A declaration accepted during the initial window wins and does not
    // shorten that window; a call near its end extends it by the override
    // window.
    let st2 = seated(cfg, ps);
    readyAll(st2, ps);
    let deck = deckWith([(0, 49), (4, 101)]);
    Table.installDeck(st2, deck, 0);
    var now2 : Int = 0;
    var tk = 1;
    while (tk < 25) {
      now2 += TICK;
      ignore Table.dealTick(st2, now2);
      tk += 1;
    };
    t.check(isOk(Table.declareTrump(st2, ps[1], [49], now2 + TICK)), "declare during the window");
    t.check(st2.trump == ?1, "declaration takes effect");
    t.check(st2.declareDeadline == ?(now2 + 7 * TICK), "an early call keeps the initial window");
    t.check(st2.declareTotal == ?7, "an early call keeps the initial total");
    t.check(not Table.checkDealWindow(st2, now2 + 6 * TICK), "the window is still open");
    t.check(Table.checkDealWindow(st2, now2 + 7 * TICK), "the window closes at the initial deadline");
    t.check(phaseEq(st2.phase, #Burying), "moves to Burying with the declaration");
    t.check(isBanker(st2, 1), "the declarer becomes banker");

    // A call inside the last `overrideSeconds` of the window extends it.
    let st3 = seated(cfg, ps);
    readyAll(st3, ps);
    Table.installDeck(st3, deck, 0);
    var now3 : Int = 0;
    var tk3 = 1;
    while (tk3 < 25) {
      now3 += TICK;
      ignore Table.dealTick(st3, now3);
      tk3 += 1;
    };
    t.check(isOk(Table.declareTrump(st3, ps[1], [49], now3 + 6 * TICK)), "late call in the initial window");
    t.check(st3.declareDeadline == ?(now3 + 9 * TICK), "the override window extends the deadline");
    t.check(st3.declareTotal == ?3, "the extension uses the override total");
    t.check(not Table.checkDealWindow(st3, now3 + 8 * TICK), "the extended window is still open");
    t.check(Table.checkDealWindow(st3, now3 + 9 * TICK), "the extended window closes");
    t.check(phaseEq(st3.phase, #Burying), "moves to Burying after the extended window");
  };

  // ── M5: declarations use the deal level and keep the bank ─────────

  func testDeclareUsesDealLevel(t : Test.Harness, ps : [Principal]) {
    t.suite("M5 declarations use the deal level");

    // A brand-new table: the bank stays undecided through declaration and
    // is only set at finalize, to the winning declarer's team.
    let st = seated(noTimeouts, ps);
    readyAll(st, ps);
    let deck = deckWith([(0, 49)]); // seat 1 gets ♠2, a level-2 card
    Table.installDeck(st, deck, 0);
    t.check(st.bankTeam == null, "the bank starts undecided");
    t.check(isOk(Table.declareTrump(st, ps[1], [49], 0)), "first declaration accepted");
    t.check(st.bankTeam == null, "a declaration does not decide the bank");
    var now = TICK;
    var tick = 1;
    while (tick < 25) {
      now += TICK;
      ignore Table.dealTick(st, now);
      tick += 1;
    };
    t.check(st.bankTeam == ?1, "finalize gives the bank to the declarer's team");
    t.check(st.banker == ?1, "the declarer is banker when on the bank team");
    t.check(st.trump == ?1, "declared trump is kept");

    // A later deal at the banking team's level: an off-team declaration is
    // judged at that level, never moves the bank, and leaves the banker on it.
    let st2 = seated(noTimeouts, ps);
    st2.teamLevel[0] := 5;
    st2.teamLevel[1] := 3;
    st2.bankTeam := ?0;
    readyAll(st2, ps);
    let deck2 = deckWith([(0, 9)]); // seat 1 gets ♠5, a level-5 card
    Table.installDeck(st2, deck2, 0);
    t.equalNat(st2.level, 5, "the deal is played at the banking team level");
    t.check(isOk(Table.declareTrump(st2, ps[1], [9], 0)), "off-team declaration accepted at the deal level");
    t.check(st2.bankTeam == ?0, "declaration does not move the bank");
    t.equalNat(st2.level, 5, "declaration does not change the deal level");
    var now2 = TICK;
    var tick2 = 1;
    while (tick2 < 25) {
      now2 += TICK;
      ignore Table.dealTick(st2, now2);
      tick2 += 1;
    };
    t.check(st2.banker == ?0, "banker stays on the banking team");
  };

  // ── M5: the declarer becomes the team's first banker ──────────────

  func testDeclarerBanker(t : Test.Harness, ps : [Principal]) {
    t.suite("M5 declarer becomes the first banker");

    // Seat 2 (team 0) declares on the very first bank, so seat 2 — not the
    // team's lower seat 0 — should pick up the kitty.
    let st = seated(noTimeouts, ps);
    readyAll(st, ps);
    let deck = deckWith([(1, 49)]); // index 1 is dealt to seat 2
    Table.installDeck(st, deck, 0);
    t.check(isOk(Table.declareTrump(st, ps[2], [49], 0)), "seat 2 declares");
    var now = TICK;
    var tick = 1;
    while (tick < 25) {
      now += TICK;
      ignore Table.dealTick(st, now);
      tick += 1;
    };
    t.check(st.bankTeam == ?0, "team 0 owns the bank");
    t.check(isBanker(st, 2), "the declarer (seat 2) is the first banker");
    t.check(st.lastBanker[0] == ?2, "team 0's last banker is the declarer");

    // An off-team declarer must not put an attacker in the banker seat: the
    // banking team still starts on its own lower seat.
    let st2 = seated(noTimeouts, ps);
    st2.bankTeam := ?0;
    readyAll(st2, ps);
    let deck2 = deckWith([(0, 49)]); // index 0 is dealt to seat 1 (team 1)
    Table.installDeck(st2, deck2, 0);
    t.check(isOk(Table.declareTrump(st2, ps[1], [49], 0)), "off-team seat 1 declares");
    var now2 = TICK;
    var tick2 = 1;
    while (tick2 < 25) {
      now2 += TICK;
      ignore Table.dealTick(st2, now2);
      tick2 += 1;
    };
    t.check(st2.bankTeam == ?0, "the bank does not move");
    t.check(isBanker(st2, 0), "the banker stays on the banking team's lower seat");
  };

  // ── M5: declaration window closes after the deck end ──────────────

  func testWindowClosed(t : Test.Harness, ps : [Principal]) {
    t.suite("M5 declaration window closed");
    let cfg = { noTimeouts with declareSeconds = 5; overrideSeconds = 5 };
    let st = seated(cfg, ps);
    readyAll(st, ps);
    // seat 1 holds the ♠2 pair, so the second call would legally override.
    let deck = deckWith([(0, 49), (4, 101)]);
    Table.installDeck(st, deck, 0);
    var now : Int = 0;
    var tick = 1;
    while (tick < 25) {
      now += TICK;
      ignore Table.dealTick(st, now);
      tick += 1;
    };
    t.check(st.dealComplete, "deck is exhausted");
    t.check(isOk(Table.declareTrump(st, ps[1], [49], now + TICK)), "single declared inside the window");
    t.check(
      isErr(Table.declareTrump(st, ps[1], [49, 101], now + 7 * TICK), #IllegalDeclaration),
      "a stronger declaration after the window is rejected",
    );
  };

  // ── M5: a mid-deal declaration arms no timer until the deck end ────

  func testDeclarationWindowMidDeal(t : Test.Harness, ps : [Principal]) {
    t.suite("M5 mid-deal declaration waits for the deck end");
    let cfg = { noTimeouts with declareSeconds = 7; overrideSeconds = 3 };

    // A call made while cards are still being dealt arms no countdown; the
    // deck end opens the shorter override window for it.
    let st = seated(cfg, ps);
    readyAll(st, ps);
    Table.installDeck(st, deckWith([(0, 49), (4, 101)]), 0);
    t.check(isOk(Table.declareTrump(st, ps[1], [49], TICK)), "declaration during dealing is accepted");
    t.check(st.declareDeadline == null, "no timer is armed mid-deal");
    t.check(Table.view(st, ps[0]).deadline == null, "the view shows no countdown mid-deal");
    var now : Int = 0;
    var tick = 1;
    while (tick < 25) {
      now += TICK;
      ignore Table.dealTick(st, now);
      tick += 1;
    };
    t.check(st.dealComplete, "deck is exhausted");
    t.check(st.declareDeadline == ?(now + 3 * TICK), "the override window starts at the deck end");
    // Later ticks must not push the window forward.
    ignore Table.dealTick(st, now + 1);
    ignore Table.dealTick(st, now + 2);
    t.check(st.declareDeadline == ?(now + 3 * TICK), "post-deck ticks do not re-arm the window");
    t.check(
      Table.view(st, ps[0]).deadline == st.declareDeadline,
      "the declaration deadline is exposed during dealing",
    );
    t.check(Table.view(st, ps[0]).declareTotal == ?3, "the view exposes the window total");
    t.check(not Table.checkDealWindow(st, now + 1), "the window is still open");
    t.check(Table.checkDealWindow(st, now + 3 * TICK), "the window closes after overrideSeconds");
    t.check(phaseEq(st.phase, #Burying), "moves to Burying with the declaration");
    t.check(isBanker(st, 1), "the declarer becomes banker");
  };

  // ── M5: an unanswerable call skips the window ─────────────────────

  /// Tick the deck out from a fresh `installDeck`, returning the last tick time.
  func dealOut(st : Table.State) : Int {
    var now : Int = 0;
    var tick = 1;
    while (tick < 25) {
      now += TICK;
      ignore Table.dealTick(st, now);
      tick += 1;
    };
    now;
  };

  func testTerminalDeclaration(t : Test.Harness, ps : [Principal]) {
    t.suite("M5 unanswerable declaration skips the window");
    let cfg = { noTimeouts with declareSeconds = 5; overrideSeconds = 5 };
    // seat 1 holds both small jokers, seat 3 both big jokers.
    let jokerDeck = [(0, 105), (4, 107), (2, 106), (6, 108)];

    // A No-Trump call (a joker pair) cannot be answered, so the banker picks
    // the kitty up on the spot instead of after a full window.
    let st = seated(cfg, ps);
    readyAll(st, ps);
    Table.installDeck(st, deckWith(jokerDeck), 0);
    let now = dealOut(st);
    t.check(st.dealComplete and phaseEq(st.phase, #Dealing), "an open window waits at the deck end");
    t.check(isOk(Table.declareTrump(st, ps[1], [105, 107], now + TICK)), "small-joker pair declares NT");
    t.check(phaseEq(st.phase, #Burying), "NT goes straight to burying");
    t.check(st.declareDeadline == null, "no window is left open");
    t.check(st.trump == ?Card.NT, "the trump is no-trump");
    t.check(isBanker(st, 1), "the NT declarer banks");
    t.equalNat(Array.size(st.kitty), 8, "the kitty was picked up");

    // A level pair is just as unanswerable while enhanced joker override is
    // off, so it locks the deal the same way.
    let st2 = seated(cfg, ps);
    readyAll(st2, ps);
    Table.installDeck(st2, deckWith([(0, 49), (4, 101)]), 0);
    let now2 = dealOut(st2);
    t.check(isOk(Table.declareTrump(st2, ps[1], [49, 101], now2 + TICK)), "level pair declares");
    t.check(phaseEq(st2.phase, #Burying), "an uncounterable pair locks the deal at once");

    // A No-Trump call (joker pair) is final even with enhanced joker
    // override: a small-joker pair locks the deal at once.
    let strong = { cfg with enhancedJokerOverride = true };
    let st3 = seated(strong, ps);
    readyAll(st3, ps);
    Table.installDeck(st3, deckWith(jokerDeck), 0);
    let now3 = dealOut(st3);
    t.check(isOk(Table.declareTrump(st3, ps[1], [105, 107], now3 + TICK)), "small-joker pair declares (enhanced)");
    t.check(phaseEq(st3.phase, #Burying), "a No-Trump call locks the deal at once");
    t.check(st3.declareDeadline == null, "no window is left open");
    t.check(isBanker(st3, 1), "the No-Trump declarer banks");

    // A call made while the deck is still running cannot pick the kitty up
    // early, but it leaves no window behind once the deck runs out.
    let st4 = seated(cfg, ps);
    readyAll(st4, ps);
    Table.installDeck(st4, deckWith([(0, 105), (4, 107)]), 0);
    ignore Table.dealTick(st4, TICK); // seat 1 holds both small jokers from here
    t.check(isOk(Table.declareTrump(st4, ps[1], [105, 107], TICK)), "NT declared mid-deal");
    ignore Table.checkDealWindow(st4, TICK);
    t.check(phaseEq(st4.phase, #Dealing), "dealing continues to the deck end");
    var tk = 2;
    while (tk < 25) {
      ignore Table.dealTick(st4, tk * TICK);
      tk += 1;
    };
    t.check(st4.dealComplete, "deck is exhausted");
    t.check(phaseEq(st4.phase, #Burying), "the deck-exhausting tick finalises without a window");
  };

  // ── M5: event retention ────────────────────────────────────────────

  func testEventRetention(t : Test.Harness, ps : [Principal]) {
    t.suite("M5 event retention");
    let cfg = { noTimeouts with eventRetentionSeconds = 100 };
    let st = Table.new(0, cfg, ps[0], 0);
    ignore Table.joinTable(st, ps[1], 1, 0);
    ignore Table.joinTable(st, ps[2], 2, 0);
    ignore Table.joinTable(st, ps[3], 3, 0);
    ignore Table.ready(st, ps[0], 200 * TICK);

    let before = Table.poll(st, ps[0], 0);
    t.check(not before.fullSync, "log intact before pruning");
    t.equalNat(before.events.size(), 5, "five events before pruning");

    Table.prune(st, 250 * TICK);
    let after = Table.poll(st, ps[0], 0);
    t.check(after.fullSync, "stale cursor falls below the low-water mark");
    t.equalNat(after.events.size(), 1, "only the recent event remains");
    t.equalNat(after.lowWater, 5, "lowWater advances to the oldest retained event");
  };

  /// After a takeover the bank team has flipped, but `st.banker` is still the
  /// seat that banked the deal that just ended. The view's score must key its
  /// levels by that seat's team (the same banker the view reports), not by the
  /// new bank team, or the client's level pills swap until the next deal.
  func testScoringView(t : Test.Harness, ps : [Principal]) {
    t.suite("M2 scoring view keeps levels on the reported banker");
    let st = seated(noTimeouts, ps);
    st.phase := #Scoring;
    st.banker := ?0; // team 0 banked the deal that just ended
    st.bankTeam := ?1; // the attackers won, so the bank flipped to team 1
    st.teamLevel[0] := 5;
    st.teamLevel[1] := 3;
    let score = Table.view(st, ps[0]).score;
    t.equalNat(score.bankerLevel, 5, "bankerLevel follows the reported banker seat (team 0)");
    t.equalNat(score.attackerLevel, 3, "attackerLevel is the other team");
  };

  /// The deal-time deck integrity check. A deck must be a permutation of the 108
  /// canonical ids, which guarantees at most two cards of any face — the fact the
  /// pair/tractor decomposition relies on. This replaced a per-follow check that
  /// blamed the follower for a corrupt deal; see `Follow.checkPlay`.
  func testDeckIntegrity(t : Test.Harness, ps : [Principal]) {
    t.suite("M3 deck integrity");
    t.check(Table.validDeck(Shuffle.newDeck()), "the canonical deck is a permutation");

    let dup = Array.toVarArray<Card.Card>(Shuffle.newDeck());
    dup[0] := dup[1];
    t.check(not Table.validDeck(VarArray.toArray(dup)), "a repeated physical card is rejected");

    // A fabricated third copy of a face: an out-of-range id that no real deck
    // contains, which is what the deal-time integrity check rejects.
    let third = Array.toVarArray<Card.Card>(Shuffle.newDeck());
    third[0] := 131;
    t.check(not Table.validDeck(VarArray.toArray(third)), "an out-of-range card is rejected");

    t.check(not Table.validDeck(Array.sliceToArray<Card.Card>(Shuffle.newDeck(), 0, 107)), "a 107-card deck is rejected");

    // `installDeck` refuses a bad deck rather than dealing it: the shuffle stays
    // pending, so the table never plays a game the rules cannot adjudicate.
    let st = seated(noTimeouts, ps);
    readyAll(st, ps);
    t.check(Table.needsShuffle(st), "a shuffle is pending before install");
    Table.installDeck(st, Array.sliceToArray<Card.Card>(Shuffle.newDeck(), 0, 107), 0);
    t.check(Table.needsShuffle(st), "installDeck refuses a deck that is not a permutation");
    t.check(st.deck.size() == 0, "the refused deck was not installed");
    // A valid deck still installs and clears the pending shuffle.
    Table.installDeck(st, Shuffle.newDeck(), 0);
    t.check(not Table.needsShuffle(st), "a valid deck installs");
  };

  public func run(t : Test.Harness) {
    let ps = principals();
    testShuffle(t);
    testDeckIntegrity(t, ps);
    testDeal(t, ps);
    testDeclare(t, ps);
    testEnhancedOverride(t, ps);
    testBury(t, ps);
    testAutoBury(t, ps);
    testDeclarationWindow(t, ps);
    testDeclarationWindowMidDeal(t, ps);
    testDeclareUsesDealLevel(t, ps);
    testDeclarerBanker(t, ps);
    testWindowClosed(t, ps);
    testTerminalDeclaration(t, ps);
    testEventRetention(t, ps);
    testScoringView(t, ps);
  };
}
