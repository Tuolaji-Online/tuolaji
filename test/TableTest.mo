/// M2 protocol tests: cursor semantics (I3), privacy (I4), auth/phase
/// enforcement (I5), and reconnect/late-join (I12), exercised directly
/// against `Table.mo` with distinct principals.
import Principal "mo:core/Principal";
import Nat "mo:core/Nat";
import List "mo:core/List";
import Card "../src/Card";
import Table "../src/Table";
import Types "../src/Types";
import Test "Test";

module {
  // Known-valid distinct principals.
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

  // Build a fresh 4-seat table in #Lobby.
  func fresh(ps : [Principal]) : Table.State {
    let st = Table.new(0, Types.defaultConfig, ps[0], 0);
    ignore Table.joinTable(st, ps[1], 1, 0);
    ignore Table.joinTable(st, ps[2], 2, 0);
    ignore Table.joinTable(st, ps[3], 3, 0);
    st;
  };

  // ── I3: cursor semantics ───────────────────────────────────────────

  func testCursor(t : Test.Harness, ps : [Principal]) {
    t.suite("M2 I3 cursor");
    let st = fresh(ps);
    ignore Table.ready(st, ps[0], 0);
    ignore Table.ready(st, ps[1], 0);
    // seq should now be 6: 4 joins + 2 readies.
    t.equalNat(Table.seqOf(st), 6, "seq after 4 joins + 2 readies");

    let all = Table.poll(st, ps[0], 0);
    t.equalNat(all.events.size(), 6, "poll(0) returns all 6 events");
    // strictly increasing, no gaps/duplicates
    var prev = 0;
    var i = 0;
    var monotonic = true;
    while (i < all.events.size()) {
      if (all.events[i].seq <= prev) { monotonic := false };
      if (all.events[i].seq != prev + 1) { monotonic := false };
      prev := all.events[i].seq;
      i += 1;
    };
    t.check(monotonic, "event seqs are contiguous and strictly increasing");

    // Advance one event at a time; union must equal the full set exactly once.
    var cursor = 0;
    var seen = 0;
    while (cursor < 6) {
      let r = Table.poll(st, ps[0], cursor);
      seen += r.events.size();
      if (r.events.size() > 0) { cursor := r.events[r.events.size() - 1].seq } else {
        cursor += 1;
      };
    };
    t.equalNat(seen, 6, "advancing cursor sees each event exactly once");

    // A command's effect appears in the next poll.
    ignore Table.ready(st, ps[2], 0);
    let after = Table.poll(st, ps[0], 6);
    t.equalNat(after.events.size(), 1, "new command produces exactly one new event");
    switch (after.events[0].body) {
      case (#PlayerReady(p)) { t.equalNat(p.seat, 2, "new event is PlayerReady(2)") };
      case _ { t.check(false, "new event is PlayerReady(2)") };
    };

    // fullSync after trimming the log window.
    Table.trim(st, 2);
    let trimmed = Table.poll(st, ps[0], 0);
    t.check(trimmed.fullSync, "fullSync when cursor is below the low-water mark");
    t.equalNat(trimmed.lowWater, 6, "lowWater points at the oldest retained event");
    t.equalNat(trimmed.events.size(), 2, "only retained events are returned");
    // A full reset from `view` reconstructs the same authoritative state.
    let v = trimmed.view;
    t.equalNat(v.tableId, 0, "view tableId");
    t.equalNat(v.dealNo, 0, "view dealNo");
    t.equalNat(v.seats.size(), 4, "view has 4 seats");
  };

  // ── I4: privacy ────────────────────────────────────────────────────

  func testPrivacy(t : Test.Harness, ps : [Principal]) {
    t.suite("M2 I4 privacy");
    let st = fresh(ps);
    // Spectator (5th principal) sees no hand, no seat, hidden kitty.
    let spec = Table.view(st, ps[4]);
    t.check(spec.mySeat == null, "spectator has no seat");
    t.equalNat(spec.myHand.size(), 0, "spectator hand is empty");
    t.check(spec.kitty == null, "kitty is hidden");
    // A seated player sees only their own (empty, in lobby) hand.
    let seated = Table.view(st, ps[2]);
    switch (seated.mySeat) {
      case (?s) { t.equalNat(s, 2, "seated player view reports own seat") };
      case null { t.check(false, "seated player view reports own seat") };
    };
    t.equalNat(seated.myHand.size(), 0, "seated hand empty in lobby");
    // Seat info exposes identity/readiness/handCount but no cards.
    var i = 0;
    var okCounts = true;
    while (i < 4) {
      if (seated.seats[i].handCount != 0) { okCounts := false };
      i += 1;
    };
    t.check(okCounts, "seat handCounts are zero in lobby");
    // Spectator's poll still returns public events.
    let p = Table.poll(st, ps[4], 0);
    t.equalNat(p.events.size(), 4, "spectator sees the 4 public join events");
  };

  // ── I5: auth / phase enforcement ───────────────────────────────────

  func testAuth(t : Test.Harness, ps : [Principal]) {
    t.suite("M2 I5 auth");
    let st = fresh(ps);

    // Double join.
    t.check(isErr(Table.joinTable(st, ps[0], 0, 0), #AlreadyJoined), "double join rejected");
    // Non-seat leave.
    t.check(isErr(Table.leave(st, ps[4], null, 0), #NotASeat), "non-seat leave rejected");
    // Non-seat play / bury / declare.
    t.check(isErr(Table.play(st, ps[4], [1], 0), #NotASeat), "non-seat play rejected");
    t.check(isErr(Table.buryKitty(st, ps[4], [], 0), #NotASeat), "non-seat bury rejected");
    t.check(isErr(Table.declareTrump(st, ps[4], [1], 0), #NotASeat), "non-seat declare rejected");
    // Seated but wrong phase.
    t.check(isErr(Table.play(st, ps[0], [1], 0), #WrongPhase), "play in lobby is WrongPhase");
    t.check(isErr(Table.buryKitty(st, ps[0], [], 0), #WrongPhase), "bury in lobby is WrongPhase");
    t.check(isErr(Table.declareTrump(st, ps[0], [1], 0), #WrongPhase), "declare in lobby is WrongPhase");

    // Forced Burying: banker enforcement + size check.
    Table.debugForce(st, #Burying, ?0, 0);
    t.check(isErr(Table.buryKitty(st, ps[1], Card.allIds(), 0), #NotKittyOwner), "non-banker bury rejected");
    t.check(isErr(Table.buryKitty(st, ps[0], [1, 2, 3], 0), #KittySizeMismatch), "bury must be 8 cards");

    // Forced Playing: turn enforcement.
    Table.debugForce(st, #Playing, ?0, 0);
    t.check(isErr(Table.play(st, ps[1], [1], 0), #NotYourTurn), "off-turn play rejected");

    // An open declaration window rejects a play even if the phase says
    // `#Playing` (defensive: the window is part of `#Dealing`).
    let stw = fresh(ps);
    Table.debugForce(stw, #Playing, ?0, 0);
    stw.hands[0] := [1];
    stw.declareDeadline := ?100;
    t.check(
      isErr(Table.play(stw, ps[0], [1], 50), #WrongPhase),
      "play while the declaration window is open is rejected",
    );
  };

  // ── I12: reconnect / late join ─────────────────────────────────────

  func testReconnect(t : Test.Harness, ps : [Principal]) {
    t.suite("M2 I12 reconnect");
    let st = fresh(ps);
    // 5th principal cannot take a seat.
    t.check(isErr(Table.joinTable(st, ps[4], 0, 0), #LobbyFull), "5th join is LobbyFull");
    // ... but can spectate.
    t.check(Table.view(st, ps[4]).mySeat == null, "5th principal is a spectator");

    // A seat that left frees its place.
    t.check(isOk(Table.leave(st, ps[3], null, 0)), "seat 3 may leave in lobby");
    t.check(isOk(Table.joinTable(st, ps[4], 3, 0)), "spectator takes the freed seat");

    // A reconnecting seat replays from afterSeq=0.
    let replay = Table.poll(st, ps[0], 0);
    t.equalNat(replay.events.size(), 6, "reconnect from 0 replays every event");
    t.check(not replay.fullSync, "no fullSync while the window is intact");
    // Its view still points at its own seat only.
    switch (Table.view(st, ps[0]).mySeat) {
      case (?s) { t.equalNat(s, 0, "reconnecting seat keeps its seat") };
      case null { t.check(false, "reconnecting seat keeps its seat") };
    };
  };

  // ── info / lobby fullness ──────────────────────────────────────────

  func testInfo(t : Test.Harness, ps : [Principal]) {
    t.suite("M2 info");
    let st = fresh(ps);
    let info = Table.info(st);
    t.equalNat(info.occupied, 4, "occupied is 4");
    t.check(not info.joinable, "full lobby is not joinable");
    t.equalNat(info.dealNo, 0, "no deals yet");
    // Ready all four -> Dealing.
    ignore Table.ready(st, ps[0], 0);
    ignore Table.ready(st, ps[1], 0);
    ignore Table.ready(st, ps[2], 0);
    ignore Table.ready(st, ps[3], 0);
    t.check(phaseEq(Table.info(st).phase, #Dealing), "all ready starts Dealing");
    t.check(not Table.info(st).joinable, "dealing lobby is not joinable");
    t.equalNat(Table.info(st).dealNo, 1, "first deal is deal 1");
  };

  // ── M2: leaving empties a table, which then ends ─────────────────

  func testLeaveEndsEmpty(t : Test.Harness, ps : [Principal]) {
    t.suite("M2 leave ends empty table");
    let st = fresh(ps);
    // Leaving is allowed in any phase; the table ends only when empty.
    t.check(isOk(Table.leave(st, ps[3], null, 0)), "seat 3 may leave");
    t.check(phaseEq(Table.info(st).phase, #Lobby), "table survives while seats remain");
    t.check(isErr(Table.leave(st, ps[3], null, 0), #NotASeat), "leaving again is NotASeat");
    t.check(isOk(Table.leave(st, ps[0], null, 0)), "seat 0 may leave");
    t.check(isOk(Table.leave(st, ps[1], null, 0)), "seat 1 may leave");
    t.check(phaseEq(Table.info(st).phase, #Lobby), "table still not empty");
    t.check(isOk(Table.leave(st, ps[2], null, 0)), "last seat leaves");
    t.check(phaseEq(Table.info(st).phase, #Ended), "empty table ends");
    t.check(st.endedAt == ?0, "endedAt is recorded");
    t.check(isErr(Table.leave(st, ps[0], null, 0), #NotASeat), "no seat to leave after end");
    let p = Table.poll(st, ps[0], 0);
    var saw = false;
    for (e in p.events.vals()) {
      switch (e.body) { case (#TableEnded(_)) { saw := true }; case _ {} };
    };
    t.check(saw, "TableEnded emitted when the last seat leaves");

    // Leaving mid-game abandons the deal back to the lobby so the vacated seat
    // is joinable again; table-level progress is kept but the per-deal state is
    // cleared.
    let st3 = fresh(ps);
    Table.debugForce(st3, #Playing, ?0, 0);
    st3.trump := ?1;
    st3.kittyRevealed := true;
    st3.hands[0] := [1, 2];
    t.check(isOk(Table.leave(st3, ps[1], null, 1)), "leaving mid-game is allowed");
    t.check(phaseEq(Table.info(st3).phase, #Lobby), "leave abandons the deal to the lobby");
    t.check(Table.info(st3).joinable, "the empty seat reopens the lobby");
    t.check(st3.trump == null, "the abandoned deal's trump is cleared");
    t.check(not st3.kittyRevealed, "the abandoned deal's reveal state is cleared");
    t.equalNat(st3.hands[0].size(), 0, "the abandoned deal's hands are cleared");
    t.check(isOk(Table.joinTable(st3, ps[4], 1, 2)), "a new principal joins the freed seat");

    // Handing the seat to a bot claims it for that principal and keeps the
    // deal alive; the principal can then attach mid-deal.
    let st4 = Table.new(3, Types.defaultConfig, ps[0], 0);
    ignore Table.joinTable(st4, ps[1], 1, 0);
    ignore Table.joinTable(st4, ps[3], 3, 0);
    Table.debugForce(st4, #Playing, ?0, 0);
    st4.hands[1] := [3, 4];
    t.check(isOk(Table.leave(st4, ps[1], ?ps[4], 1)), "leaving and claiming a seat");
    t.check(phaseEq(Table.info(st4).phase, #Playing), "claiming keeps the deal playing");
    t.check(Table.seatOf(st4, ps[4]) == ?1, "the vacated seat is claimed for the target");
    t.check(Table.seatOf(st4, ps[1]) == null, "the leaver no longer holds the seat");
    t.check(isErr(Table.joinTable(st4, ps[2], 1, 2), #LobbyFull), "another principal is rejected");
    t.check(isOk(Table.joinTableWithClient(st4, ps[4], ?"\04", 1, null, 2)), "the claimed principal attaches mid-deal");
  };

  // ── scheduler: derived next wake time ──────────────────────────────

  func testNextTimer(t : Test.Harness, ps : [Principal]) {
    t.suite("M2 next timer");
    // An idle lobby table has no time-critical work, so it schedules nothing:
    // pruning and eviction are lazy and must not arm a timer.
    let st = fresh(ps);
    t.check(Table.nextTimer(st, 0) == null, "an idle lobby table schedules no wake");

    // Game deadlines still wake the scheduler.
    st.phase := #Burying;
    st.buryDeadline := ?500;
    t.check(Table.nextTimer(st, 0) == ?500, "the bury deadline is the earliest wake");
    st.phase := #Lobby;
    st.buryDeadline := null;

    // A pending shuffle is due immediately so the actor can seed the deck.
    st.phase := #Dealing;
    st.deck := [];
    st.dealComplete := false;
    t.check(Table.nextTimer(st, 0) == ?0, "a pending shuffle wakes immediately");
    st.phase := #Lobby;

    // An ended table is not woken for eviction either; `sweepEnded` handles it
    // on the next registry change.
    st.phase := #Ended;
    st.endedAt := ?1000;
    t.check(Table.nextTimer(st, 0) == null, "an ended table schedules no wake");
  };

  func testReservedSeats(t : Test.Harness, ps : [Principal]) {
    t.suite("seat claims and hand-over");
    // A claimed seat is owned by its principal immediately; only that principal
    // may attach to it.
    let st = Table.new(0, Types.defaultConfig, ps[0], 0);
    Table.assignReserved(st, [null, ?ps[1], null, null]);
    t.check(Table.seatOf(st, ps[1]) == ?1, "info exposes the claim as ownership");
    t.check(
      isErr(Table.joinTable(st, ps[4], 1, 0), #LobbyFull),
      "another principal cannot take a claimed seat",
    );
    t.check(Table.seatOf(st, ps[4]) == null, "the rejected join takes no seat");
    t.check(
      isOk(Table.joinTableWithClient(st, ps[1], ?"\01", 1, null, 0)),
      "the claimed principal attaches with its client id",
    );
    t.check(not Table.hasClient(st, ps[1], ?"\01"), "Table.addClient is what attaches the push client");
    Table.addClient(st, ps[1], ?"\01", 1);
    t.check(Table.hasClient(st, ps[1], ?"\01"), "addClient attaches the claimed seat's push client");
    t.equalNat(Table.clientsOf(st).size(), 1, "the attached seat is a push target");

    // Handing a seat over transfers ownership in place; the deal keeps playing
    // and the seat never empties.
    let st2 = Table.new(1, Types.defaultConfig, ps[0], 0);
    ignore Table.joinTable(st2, ps[1], 1, 0);
    ignore Table.joinTable(st2, ps[3], 3, 0);
    Table.debugForce(st2, #Playing, ?0, 1);
    t.check(
      isErr(Table.leaveWithClient(st2, ps[2], null, ?ps[4], 0), #NotASeat),
      "a non-owner cannot hand a seat over",
    );
    t.check(isOk(Table.leaveWithClient(st2, ps[1], null, ?ps[4], 0)), "the owner hands the seat over");
    t.check(Table.seatOf(st2, ps[1]) == null, "the owner no longer holds the seat");
    t.check(Table.seatOf(st2, ps[4]) == ?1, "the target owns the seat immediately");
    t.check(
      Table.seatOfClient(st2, ps[4], null) == ?1,
      "the hand-over leaves the target a bare claim",
    );
    t.check(
      Table.seatOfClient(st2, ps[4], ?"\05") == null,
      "the target has not attached yet",
    );
    var joinsBefore = 0;
    for (e in st2.log.values()) {
      switch (e.body) {
        case (#PlayerJoined(p)) { if (p.seat == 1 and Principal.equal(p.who, ps[4])) { joinsBefore += 1 } };
        case _ {};
      };
    };
    t.equalNat(joinsBefore, 0, "the hand-over does not announce the target");
    t.check(
      isOk(Table.joinTableWithClient(st2, ps[4], ?"\05", 1, null, 0)),
      "the target attaches to the claimed seat",
    );
    t.check(
      Table.seatOfClient(st2, ps[4], ?"\05") == ?1,
      "the attach is the target's announcement",
    );
    var joinsAfter = 0;
    for (e in st2.log.values()) {
      switch (e.body) {
        case (#PlayerJoined(p)) { if (p.seat == 1 and Principal.equal(p.who, ps[4])) { joinsAfter += 1 } };
        case _ {};
      };
    };
    t.equalNat(joinsAfter, 1, "the target's attach announces exactly one join");
    t.check(phaseEq(st2.phase, #Playing), "hand-over does not abandon the deal");
    t.check(Table.filledCount(st2) == 3, "the seat never empties");

    // Handing over the only occupied seat must not end the table: the claim
    // is applied before the empty check.
    let st4 = Table.new(3, Types.defaultConfig, ps[0], 0);
    t.check(isOk(Table.leaveWithClient(st4, ps[0], null, ?ps[4], 0)), "the only seat can be handed over");
    t.check(Table.seatOf(st4, ps[4]) == ?0, "the target owns the only seat");
    t.check(
      not phaseEq(Table.info(st4).phase, #Ended),
      "handing over the last seat does not end the table",
    );
  };

  func testAvatar(t : Test.Harness, ps : [Principal]) {
    t.suite("M2 avatar validation");
    // The creator's avatar is stored at creation and exposed to every client.
    let st = Table.newWithClient(0, Types.defaultConfig, ps[0], null, 0, ?{ preset = "cat"; style = "ocean" });
    switch (Table.view(st, ps[0]).seats[0].avatar) {
      case (?a) { t.check(a.preset == "cat" and a.style == "ocean", "avatar exposed in the view") };
      case null { t.check(false, "avatar exposed in the view") };
    };
    switch (Table.info(st).seats[0].avatar) {
      case (?a) { t.check(a.preset == "cat" and a.style == "ocean", "avatar exposed in TableInfo") };
      case null { t.check(false, "avatar exposed in TableInfo") };
    };
    // The creator's avatar is also in the event log, so past-table records
    // (reconstructed from `PlayerJoined`) keep the chosen style.
    let participants = Table.info(st).participants;
    t.check(
      participants.size() == 1 and participants[0].avatar == ?{ preset = "cat"; style = "ocean" },
      "creator avatar recorded for past-table records",
    );

    // Client text is an attack vector: a join with an empty or oversized avatar
    // is rejected before the seat is taken.
    let long = "this-id-is-way-too-long-for-an-avatar";
    t.check(isErr(Table.joinTableWithAvatar(st, ps[1], 1, ?{ preset = long; style = "ocean" }, 0), #InvalidAvatar), "oversized join avatar rejected");
    t.check(isErr(Table.joinTableWithAvatar(st, ps[1], 1, ?{ preset = "cat"; style = long }, 0), #InvalidAvatar), "oversized join style rejected");
    t.check(isErr(Table.joinTableWithAvatar(st, ps[1], 1, ?{ preset = ""; style = "ocean" }, 0), #InvalidAvatar), "empty join avatar rejected");
    t.check(Table.seatOf(st, ps[1]) == null, "a rejected avatar does not take the seat");
    t.check(isOk(Table.joinTableWithAvatar(st, ps[1], 1, ?{ preset = "fox"; style = "neon" }, 0)), "valid join avatar accepted");
    switch (Table.view(st, ps[1]).seats[1].avatar) {
      case (?a) { t.check(a.preset == "fox", "the joiner's avatar is stored") };
      case null { t.check(false, "the joiner's avatar is stored") };
    };

    // A seat-specific join carries the avatar too, and leaving clears it.
    let st2 = Table.new(1, Types.defaultConfig, ps[0], 0);
    t.check(isOk(Table.joinTableWithAvatar(st2, ps[1], 2, ?{ preset = "owl"; style = "berry" }, 0)), "joinTable avatar accepted");
    switch (Table.view(st2, ps[1]).seats[2].avatar) {
      case (?a) { t.check(a.preset == "owl", "joinTable stores the avatar") };
      case null { t.check(false, "joinTable stores the avatar") };
    };
    ignore Table.leave(st2, ps[1], null, 0);
    t.check(Table.info(st2).seats[2].avatar == null, "leaving clears the avatar");

    // A redundant join refreshes the stored avatar instead of ignoring it.
    let st3 = Table.new(2, Types.defaultConfig, ps[0], 0);
    ignore Table.joinTableWithAvatar(st3, ps[1], 1, ?{ preset = "fox"; style = "neon" }, 0);
    switch (Table.joinTableWithAvatar(st3, ps[1], 1, ?{ preset = "owl"; style = "berry" }, 0)) {
      case (#err(e)) { t.check(e.code == #AlreadyJoined, "a redundant join is AlreadyJoined") };
      case _ { t.check(false, "a redundant join is AlreadyJoined") };
    };
    switch (Table.info(st3).seats[1].avatar) {
      case (?a) { t.check(a.preset == "owl" and a.style == "berry", "the redundant join refreshed the avatar") };
      case null { t.check(false, "the redundant join refreshed the avatar") };
    };
  };

  func testIdle(t : Test.Harness, ps : [Principal]) {
    t.suite("M5 idle table detection");
    let st = fresh(ps);
    let idleAt = Table.IDLE_RETENTION_NANOS;
    // A table is idle only after a full window with no new event.
    t.check(not Table.isIdle(st, idleAt), "not idle at exactly the window");
    t.check(Table.isIdle(st, idleAt + 1), "idle just past the window");
    // A new event resets the clock.
    ignore Table.ready(st, ps[0], idleAt + 1);
    t.check(not Table.isIdle(st, idleAt + 1), "an event clears idleness");
    t.check(Table.isIdle(st, idleAt * 2 + 3), "idle again after the window");
    // endIfIdle ends the table and stamps the sweep time.
    t.check(Table.endIfIdle(st, idleAt * 2 + 3), "endIfIdle ends an idle table");
    t.check(phaseEq(Table.info(st).phase, #Ended), "the table is Ended");
    t.check(st.endedAt == ?(idleAt * 2 + 3), "endedAt is the sweep time");
    t.check(not Table.isIdle(st, idleAt * 4), "an ended table is never idle");
    t.check(not Table.endIfIdle(st, idleAt * 4), "an ended table is not re-ended");

    // An empty log (everything pruned) counts as idle.
    let st2 = fresh(ps);
    st2.cfg := { Types.defaultConfig with eventRetentionSeconds = ?1 };
    Table.prune(st2, idleAt * 2);
    t.check(List.size(st2.log) == 0, "the log is empty after pruning");
    t.check(Table.isIdle(st2, idleAt * 2), "an empty log is idle");

    // A silent human-wait phase is not "over": it has no timer and is waiting
    // on a player. A silent timer-driven phase is stale and counts as over.
    let st3 = fresh(ps);
    Table.debugForce(st3, #Lobby, null, 0);
    t.check(Table.isIdle(st3, idleAt + 1), "a lobby table can be idle");
    t.check(not Table.isOver(st3, idleAt + 1), "an idle lobby table is not over");
    Table.debugForce(st3, #Scoring, null, 0);
    t.check(Table.isIdle(st3, idleAt + 1), "a scoring table can be idle");
    t.check(not Table.isOver(st3, idleAt + 1), "an idle scoring table is not over");
    Table.debugForce(st3, #Playing, null, 0);
    t.check(Table.isOver(st3, idleAt + 1), "an idle playing table is over");
  };

  func testConfig(t : Test.Harness) {
    t.suite("M2 config validation");
    t.check(Types.validConfig(Types.defaultConfig), "the default config is valid");
    // The declaration windows are the requested 15s post-deal / 10s override.
    t.check(Types.defaultConfig.declareSeconds == ?15, "default post-deal window is 15s");
    t.check(Types.defaultConfig.overrideSeconds == ?10, "default override window is 10s");
    // Out-of-range / absurd fields are rejected.
    t.check(not Types.validConfig({ Types.defaultConfig with targetLevel = 1 }), "targetLevel 1 rejected");
    t.check(not Types.validConfig({ Types.defaultConfig with targetLevel = 15 }), "targetLevel 15 rejected");
    t.check(not Types.validConfig({ Types.defaultConfig with firstDealer = 4 }), "firstDealer 4 rejected");
    t.check(not Types.validConfig({ Types.defaultConfig with dealTickSeconds = 3601 }), "huge dealTick rejected");
    t.check(not Types.validConfig({ Types.defaultConfig with playSeconds = ?86_401 }), "huge playSeconds rejected");
    t.check(not Types.validConfig({ Types.defaultConfig with overrideSeconds = ?86_401 }), "huge overrideSeconds rejected");
    t.check(not Types.validConfig({ Types.defaultConfig with eventRetentionSeconds = ?0 }), "zero retention rejected");
    t.check(not Types.validConfig({ Types.defaultConfig with eventRetentionSeconds = ?2_592_001 }), "huge retention rejected");
    // Null timers (wait forever / keep forever) are fine.
    t.check(Types.validConfig({ Types.defaultConfig with playSeconds = null }), "null playSeconds is valid");
    t.check(Types.validConfig({ Types.defaultConfig with eventRetentionSeconds = null }), "null retention is valid");
  };

  // ── ending a table that has no humans left ─────────────────────────

  func testEndWhenAllBots(t : Test.Harness, ps : [Principal]) {
    t.suite("M2 end a bot-only table");
    let isBot = func(p : Principal) : Bool {
      Principal.equal(p, ps[1]) or Principal.equal(p, ps[2]) or Principal.equal(p, ps[3]);
    };
    // A table with a human owner is kept.
    let st = fresh(ps);
    t.check(not Table.endIfNoHumans(st, isBot, 0), "a human seat keeps the table alive");
    // Remove the human: every remaining seat is a whitelisted bot.
    ignore Table.leave(st, ps[0], null, 0);
    t.check(Table.endIfNoHumans(st, isBot, 1), "a bot-only table ends");
    t.check(phaseEq(Table.info(st).phase, #Ended), "the bot-only table is Ended");

    // The config disables the rule for all-bot test tables.
    let st2 = fresh(ps);
    ignore Table.leave(st2, ps[0], null, 0);
    st2.cfg := { Types.defaultConfig with endWhenAllBots = false };
    t.check(not Table.endIfNoHumans(st2, isBot, 1), "endWhenAllBots=false keeps the table");
    t.check(phaseEq(Table.info(st2).phase, #Lobby), "the disabled table stays in the Lobby");

    // An already-ended table is not re-ended.
    let st3 = fresh(ps);
    ignore Table.leave(st3, ps[0], null, 0);
    ignore Table.endIfNoHumans(st3, isBot, 1);
    t.check(not Table.endIfNoHumans(st3, isBot, 2), "an ended table is not re-ended");
  };

  public func run(t : Test.Harness) {
    let ps = principals();
    testCursor(t, ps);
    testPrivacy(t, ps);
    testAuth(t, ps);
    testReconnect(t, ps);
    testInfo(t, ps);
    testLeaveEndsEmpty(t, ps);
    testIdle(t, ps);
    testNextTimer(t, ps);
    testReservedSeats(t, ps);
    testEndWhenAllBots(t, ps);
    testAvatar(t, ps);
    testConfig(t);
  };
}
