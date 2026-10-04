/// M5 I2 — concurrent table isolation. Builds three independent tables
/// with distinct seat sets and interleaves their lifecycle, asserting that
/// operations on one never advance the others' `seq`, phase, or hands.
import Principal "mo:core/Principal";
import Card "../src/Card";
import Table "../src/Table";
import Shuffle "../src/Shuffle";
import Types "../src/Types";
import Test "Test";

module {
  let TICK : Int = 1_000_000_000;

  let noTimeouts : Types.TableConfig = {
    Types.defaultConfig with
    declareSeconds = 0;
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
      Principal.fromText("r7inp-6aaaa-aaaaa-aaabq-cai"),
      Principal.fromText("3lr5l-hyaaa-aaaaa-aabza-cai"),
      Principal.fromText("ryjl3-tyaaa-aaaaa-aaaba-cai"),
    ];
  };

  func phaseEq(a : Types.Phase, b : Types.Phase) : Bool { a == b };

  /// A table with four explicit seats (all distinct within the table).
  func fresh(id : Types.TableId, seats : [Principal]) : Table.State {
    let st = Table.new(id, noTimeouts, seats[0], 0);
    ignore Table.joinTable(st, seats[1], 1, 0);
    ignore Table.joinTable(st, seats[2], 2, 0);
    ignore Table.joinTable(st, seats[3], 3, 0);
    st;
  };

  func readyAll(st : Table.State, seats : [Principal]) {
    ignore Table.ready(st, seats[0], 0);
    ignore Table.ready(st, seats[1], 0);
    ignore Table.ready(st, seats[2], 0);
    ignore Table.ready(st, seats[3], 0);
  };

  public func run(t : Test.Harness) {
    t.suite("M5 I2 concurrent tables");
    let ps = principals();
    let seats0 = [ps[0], ps[1], ps[2], ps[3]];
    let seats1 = [ps[4], ps[5], ps[6], ps[7]];
    let seats2 = [ps[0], ps[4], ps[1], ps[5]];
    let s0 = fresh(0, seats0);
    let s1 = fresh(1, seats1);
    let s2 = fresh(2, seats2);

    let baseSeq = 4; // 4 joins each
    t.equalNat(Table.seqOf(s0), baseSeq, "s0 has only its own join events");
    t.equalNat(Table.seqOf(s1), baseSeq, "s1 has only its own join events");
    t.equalNat(Table.seqOf(s2), baseSeq, "s2 has only its own join events");

    // Interleave lobby actions; only the targeted table advances.
    ignore Table.ready(s0, seats0[0], 0);
    ignore Table.ready(s1, seats1[0], 0);
    t.equalNat(Table.seqOf(s2), baseSeq, "s2 untouched by s0/s1 readies");
    ignore Table.ready(s2, seats2[0], 0);
    t.check(Table.seqOf(s0) == baseSeq + 1, "s0 advanced exactly once");
    t.check(Table.seqOf(s1) == baseSeq + 1, "s1 advanced exactly once");
    t.check(Table.seqOf(s2) == baseSeq + 1, "s2 advanced exactly once");

    // Complete each lobby and deal independently with distinct seeds.
    readyAll(s0, seats0);
    readyAll(s1, seats1);
    readyAll(s2, seats2);
    Table.installDeck(s0, Shuffle.shuffle(Shuffle.newDeck(), 11), 0);
    Table.installDeck(s1, Shuffle.shuffle(Shuffle.newDeck(), 22), 0);
    Table.installDeck(s2, Shuffle.shuffle(Shuffle.newDeck(), 33), 0);

    // Interleave deal ticks.
    var now = TICK;
    var tick = 1;
    while (tick < 25) {
      ignore Table.dealTick(s0, now);
      ignore Table.dealTick(s2, now);
      ignore Table.dealTick(s1, now);
      now += TICK;
      tick += 1;
    };
    t.check(phaseEq(Table.info(s0).phase, #Burying), "s0 reaches Burying");
    t.check(phaseEq(Table.info(s1).phase, #Burying), "s1 reaches Burying");
    t.check(phaseEq(Table.info(s2).phase, #Burying), "s2 reaches Burying");

    // Views are scoped to their own table.
    t.equalNat(Table.view(s0, seats0[0]).tableId, 0, "s0 view is table 0");
    t.equalNat(Table.view(s1, seats1[0]).tableId, 1, "s1 view is table 1");
    t.equalNat(Table.view(s2, seats2[0]).tableId, 2, "s2 view is table 2");

    // Mutating one table leaves the others intact.
    let before1 = s1.hands[0].size();
    let before2 = s2.hands[0].size();
    s0.hands[0] := [];
    t.equalNat(s1.hands[0].size(), before1, "s1 hand unaffected by s0 mutation");
    t.equalNat(s2.hands[0].size(), before2, "s2 hand unaffected by s0 mutation");

    // A3: two racing deal triggers cannot install two decks (`startDeal`
    // re-checks `needsShuffle` with no intervening await).
    let st = fresh(3, seats0);
    readyAll(st, seats0);
    let deckA = Shuffle.shuffle(Shuffle.newDeck(), 7);
    Table.installDeck(st, deckA, 0);
    let seqAfterFirst = Table.seqOf(st);
    Table.installDeck(st, Shuffle.shuffle(Shuffle.newDeck(), 8), 0);
    t.equalNat(Table.seqOf(st), seqAfterFirst, "second deal install is a no-op");
    t.check(st.deck[0] == deckA[0], "deck is not replaced by a second trigger");
  };
}
