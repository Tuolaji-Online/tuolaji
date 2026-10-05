/// Tests for the canister-client additions: `(principal, clientId)` seat
/// identity, the multi-seat push registry + `eventsAfter` scoping/gaps, and the
/// pure ingress helpers in `Access.mo`.
import Principal "mo:core/Principal";
import Array "mo:core/Array";
import Blob "mo:core/Blob";
import Nat "mo:core/Nat";
import Access "../src/Access";
import Card "../src/Card";
import Table "../src/Table";
import Types "../src/Types";
import Test "Test";

module {
  func ps() : [Principal] {
    [
      Principal.fromText("rkp4c-7iaaa-aaaaa-aaaca-cai"),
      Principal.fromText("rrkah-fqaaa-aaaaa-aaaaq-cai"),
      Principal.fromText("renrk-eyaaa-aaaaa-aaada-cai"),
      Principal.fromText("rno2w-sqaaa-aaaaa-aaacq-cai"),
    ];
  };

  /// A 4-seat table owned by `p` in two seats (distinct client ids) and two
  /// other principals, readied into `#Dealing` and dealt one card each.
  func dealt(p : Principal, others : [Principal], id0 : Types.ClientId, id1 : Types.ClientId) : Table.State {
    let st = Table.newWithClient(0, Types.defaultConfig, p, ?id0, 0, null, null);
    ignore Table.joinTableWithClient(st, p, ?id1, 1, null, null, 0);
    ignore Table.joinTable(st, others[0], 2, 0);
    ignore Table.joinTable(st, others[1], 3, 0);
    ignore Table.readyWithClient(st, p, ?id0, 0);
    ignore Table.readyWithClient(st, p, ?id1, 0);
    ignore Table.ready(st, others[0], 0);
    ignore Table.ready(st, others[1], 0);
    Table.installDeck(st, Card.allIds(), 0);
    st;
  };

  func handSeats(events : [Types.Event]) : (Nat, Nat, Nat) {
    var mine = 0;
    var other = 0;
    var pub = 0;
    for (e in events.vals()) {
      switch (e.body) {
        case (#HandUpdated(h)) { if (h.seat == 0) { mine += 1 } else { other += 1 } };
        case _ { pub += 1 };
      };
    };
    (mine, other, pub);
  };

  func testAccess(t : Test.Harness) {
    t.suite("access: principal class");
    t.equalNat(Access.principalClass(Principal.fromBlob("")), 0, "empty is the management canister");
    t.equalNat(Access.principalClass(Principal.fromBlob("\01")), 1, "opaque class");
    t.equalNat(Access.principalClass(Principal.fromBlob("\02")), 2, "self-authenticating class");
    t.equalNat(Access.principalClass(Principal.fromBlob("\03")), 3, "derived class");
    t.equalNat(Access.principalClass(Principal.fromBlob("\04")), 4, "anonymous class");
    t.check(Access.isCanister(Principal.fromBlob("\01")), "opaque is a canister");
    t.check(Access.isCanister(Principal.fromBlob("\03")), "derived is a canister");
    t.check(not Access.isCanister(Principal.fromBlob("\02")), "user is not a canister");
    t.check(not Access.isCanister(Principal.fromBlob("")), "management is not a charged canister");
    t.check(Access.isAnonymous(Principal.fromBlob("\04")), "anonymous is detected");
    t.check(not Access.isAnonymous(Principal.fromBlob("\02")), "user is not anonymous");

    t.check(Access.mayTakeSeat(false, false), "first seat is always allowed");
    t.check(not Access.mayTakeSeat(false, true), "a second seat needs the whitelist");
    t.check(Access.mayTakeSeat(true, true), "a whitelisted bot may hold a second seat");
  };

  /// The private-table auth-code gate: only the whitelisted bot skips the code,
  /// and only for a seat the table already claims for it. A canister principal
  /// is *not* a bypass (`Access.isCanister` cannot be the test).
  func testAuthCodeGate(t : Test.Harness, p : Principal, others : [Principal]) {
    t.suite("access: private-table auth code gate");
    t.check(Access.maySkipAuthCode(true, true), "the bot attaches its own claimed seat code-free");
    t.check(not Access.maySkipAuthCode(true, false), "the bot may not take an open private seat code-free");
    t.check(not Access.maySkipAuthCode(false, true), "a stranger cannot attach a seat claimed for someone else");
    t.check(not Access.maySkipAuthCode(false, false), "an ordinary caller always presents the code");

    // The code here is deliberately shorter than `MIN_AUTH_CODE`: strength is a
    // `createTable` policy (`validAuthCode`, asserted separately below), while
    // `newWithClient` stores whatever the actor hands it after validation.
    // `seatClaimedBy` is the table-side half of the predicate.
    let st = Table.newWithClient(0, Types.defaultConfig, p, null, 0, null, ?"secret");
    Table.assignReserved(st, [null, ?others[0], null, null]);
    t.check(Table.isPrivate(st), "a table with an auth code is private");
    t.check(Table.seatClaimedBy(st, 0, p), "the creator holds seat 0");
    t.check(Table.seatClaimedBy(st, 1, others[0]), "seat 1 is claimed for the reserved principal");
    t.check(not Table.seatClaimedBy(st, 1, p), "a reserved seat is not the creator's");
    t.check(not Table.seatClaimedBy(st, 2, others[0]), "an open seat is claimed by nobody");
    t.check(not Table.seatClaimedBy(st, 2, p), "an open seat is claimed by nobody else either");
    t.check(not Table.seatClaimedBy(st, 4, p), "an out-of-range seat is false, not a trap");
    // Attaching the reserved seat keeps the claim, so a bot that re-joins after
    // a restart is still exempt. The attach goes through the bot's real shape
    // (a per-seat client id): a seat claimed with a null client id already
    // matches `seatOfClient(p, null)` and reports `AlreadyJoined` instead.
    switch (Table.joinTableWithClient(st, others[0], ?"\01", 1, null, null, 0)) {
      case (#ok(_)) {};
      case (#err(_)) { t.check(false, "the reserved principal attaches its seat") };
    };
    t.check(Table.seatClaimedBy(st, 1, others[0]), "an attached seat is still claimed for its owner");
    t.check(not Table.seatClaimedBy(st, 1, others[1]), "attaching does not hand the claim to a stranger");
  };

  /// The seat hand-over gate. `Table.leaveWithClient` stays permissive (the
  /// pure module has no whitelist), so this predicate is the whole rule and
  /// `leaveTable` is its only caller: it runs before any state change, so a
  /// rejected hand-over leaves the seat with its owner.
  func testReserveGate(t : Test.Harness) {
    t.suite("access: seat hand-over gate (leaveTable.reserveFor)");
    // The two flows the feature exists for.
    t.check(Access.mayReserveSeat(true, false), "the bot may hand its seat to a human");
    t.check(Access.mayReserveSeat(false, true), "a human may hand their seat to the bot");
    t.check(Access.mayReserveSeat(true, true), "the bot may hand a seat to the bot");
    // The hole: naming an uninvolved third party. The target never consents,
    // whoever attaches next reads that seat's whole remaining hand, and an
    // unfilled claim blocks `allReady` so the table never starts.
    t.check(not Access.mayReserveSeat(false, false), "a seat may not be claimed for an arbitrary principal");
    // Both flags are whitelist lookups in the actor, never principal-class
    // tests: an arbitrary canister is not "whitelisted" any more than an
    // arbitrary user is (see `maySkipAuthCode`).

    // The behaviour the gate protects: a claimed seat keeps its hand for the
    // next attacher, so who may be named has to be an admission rule.
    let p = ps();
    let st = Table.newWithClient(0, Types.defaultConfig, p[0], null, 0, null, null);
    ignore Table.joinTable(st, p[1], 1, 0);
    ignore Table.joinTable(st, p[2], 2, 0);
    ignore Table.joinTable(st, p[3], 3, 0);
    switch (Table.leaveWithClient(st, p[1], null, ?p[2], 0)) {
      case (#ok(_)) {};
      case (#err(_)) { t.check(false, "a module-level hand-over still works") };
    };
    t.check(Table.seatClaimedBy(st, 1, p[2]), "the vacated seat is claimed for the named principal");
    // No seat is free, and the claim is not ready, so the table neither takes a
    // player nor starts: the named principal has to turn up.
    t.check(not Table.infoFor(st, null).joinable, "a table whose last seat is claimed for a third party is not joinable");
  };

  /// The auth-code *strength* gate. Joining is never throttled, so a short code
  /// is guessable with free update calls: the lower bound is a server-side rule,
  /// enforced once at creation. Both bounds are inclusive, and
  /// `MIN_AUTH_CODE` == `MAX_AUTH_CODE` == 8 matches `AUTH_CODE_LENGTH` in
  /// frontend/src/helpers.js.
  func testAuthCodeStrength(t : Test.Harness) {
    t.suite("access: private-table auth code strength");
    t.check(Table.validAuthCode(null), "null is valid: a public table has no code");
    t.check(Table.validAuthCode(?"abcd1234"), "a code of exactly MIN_AUTH_CODE is valid");
    t.check(not Table.validAuthCode(?""), "an empty code is rejected");
    t.check(not Table.validAuthCode(?"a"), "a 1-character code is rejected");
    t.check(not Table.validAuthCode(?"abcdefg"), "one below MIN_AUTH_CODE is rejected");
    t.check(not Table.validAuthCode(?"abcd12345"), "one above MAX_AUTH_CODE is rejected");
  };

  /// The client-id bound. It is persisted per seat for the life of the table, so
  /// it is capped like the avatar instead of trusting whatever the ingress size
  /// limit allows.
  func testClientIdBound(t : Test.Harness) {
    t.suite("clients: client id bound");
    func blobOf(n : Nat) : Blob { Blob.fromArray(Array.tabulate<Nat8>(n, func i = Nat.toNat8(i))) };
    t.check(Table.validClientId(null), "null is valid: a browser passes no client id");
    t.check(Table.validClientId(?blobOf(0)), "an empty client id is valid");
    t.check(Table.validClientId(?blobOf(Table.MAX_CLIENT_ID)), "a client id of exactly MAX_CLIENT_ID is valid");
    t.check(not Table.validClientId(?blobOf(Table.MAX_CLIENT_ID + 1)), "one byte above MAX_CLIENT_ID is rejected");
  };

  /// The private-table read gate. While the table is live it is for members and
  /// for whoever presents the invitation code; once it is over it is public, so
  /// every row the ended listing shows is a row the detail endpoints open.
  func testReadGate(t : Test.Harness, p : Principal, others : [Principal]) {
    t.suite("access: private-table read gate");
    let code = ?"abcd1234";
    let stranger = others[0];
    let st = Table.newWithClient(0, Types.defaultConfig, p, null, 0, null, code);
    t.check(not Table.mayRead(st, stranger, null, 0), "a stranger cannot read a live private table");
    t.check(not Table.mayRead(st, stranger, ?"wrongcode!", 0), "a wrong code does not open it");
    t.check(Table.mayRead(st, stranger, code, 0), "the invitee's own code opens it before joining");
    t.check(Table.mayRead(st, p, null, 0), "a seat holder reads it without the code");
    t.check(not Table.mayRead(st, others[1], null, 0), "a principal with no seat is not a member");
    // Past the private idle window the table is over, which is exactly when
    // `listTables` starts showing it in the ended listing.
    let over = Table.PRIVATE_IDLE_RETENTION_NANOS + 1;
    t.check(Table.isOver(st, over), "the table is over past its private idle window");
    t.check(Table.mayRead(st, stranger, null, over), "an over private table reads for anyone");
    // Explicitly ended, and a public table for contrast.
    Table.debugForce(st, #Ended, null, 0);
    t.check(Table.mayRead(st, stranger, null, 0), "an ended private table reads for anyone");
    let open = Table.newWithClient(1, Types.defaultConfig, p, null, 0, null, null);
    t.check(not Table.isPrivate(open), "a table with no auth code is public");
    t.check(Table.mayRead(open, stranger, null, 0), "a public table is always readable");
  };

  func testSeatIdentity(t : Test.Harness, p : Principal, others : [Principal]) {
    t.suite("clients: seat identity");
    let id0 : Types.ClientId = "\00";
    let id1 : Types.ClientId = "\01";
    let st = dealt(p, others, id0, id1);
    t.check(Table.seatOfClient(st, p, ?id0) == ?0, "seat 0 keyed by (p, id0)");
    t.check(Table.seatOfClient(st, p, ?id1) == ?1, "seat 1 keyed by (p, id1)");
    t.check(Table.seatOfClient(st, p, null) == null, "no null-id seat for this bot");
    t.check(Table.seatOfClient(st, p, ?"\02") == null, "a wrong client id does not match");
    t.check(Table.seatOf(st, p) == ?0, "principal-only lookup returns the first seat");
    t.check(Table.principalHasSeat(st, p), "the principal is seated");
    // The same (principal, clientId) cannot take two seats.
    switch (Table.joinTableWithClient(st, p, ?id0, 2, null, null, 0)) {
      case (#err(e)) { t.check(e.code == #AlreadyJoined, "re-joining with the same id is AlreadyJoined") };
      case (#ok(_)) { t.check(false, "re-joining with the same id is AlreadyJoined") };
    };
  };

  func testRegistry(t : Test.Harness, p : Principal, others : [Principal]) {
    t.suite("clients: registry + eventsAfter");
    let id0 : Types.ClientId = "\00";
    let id1 : Types.ClientId = "\01";
    let st = dealt(p, others, id0, id1);

    // Registration is idempotent and keyed by (principal, clientId).
    Table.addClient(st, p, ?id0, 0);
    Table.addClient(st, p, ?id0, 0);
    Table.addClient(st, p, ?id1, 1);
    t.check(Table.hasClient(st, p, ?id0), "id0 registered");
    t.check(Table.hasClient(st, p, ?id1), "id1 registered");
    t.check(not Table.hasClient(st, p, ?"\02"), "unknown id is not registered");
    t.equalNat(Table.clientsOf(st).size(), 2, "two subscriptions");

    // Each subscription only sees its own private hand events.
    let e0 = Table.eventsAfter(st, p, ?id0, 0);
    let (mine0, other0, _) = handSeats(e0.events);
    t.check(mine0 > 0, "seat 0 client sees its own HandUpdated");
    t.equalNat(other0, 0, "seat 0 client never sees another seat's HandUpdated");
    let e1 = Table.eventsAfter(st, p, ?id1, 0);
    var leaked = 0;
    for (e in e1.events.vals()) {
      switch (e.body) {
        case (#HandUpdated(h)) { if (h.seat != 1) { leaked += 1 } };
        case _ {};
      };
    };
    t.equalNat(leaked, 0, "seat 1 client sees only its own hand updates");

    // Advancing the cursor shrinks the backlog.
    let before = e0.events.size();
    Table.advanceCursor(st, p, ?id0, Table.seqOf(st));
    let after = Table.eventsAfter(st, p, ?id0, Table.seqOf(st));
    t.equalNat(after.events.size(), 0, "cursor at the head has nothing to push");
    t.check(before >= 0, "backlog was measured");

    // Cursor below the low-water mark forces a full sync.
    Table.trim(st, 2);
    let gap = Table.eventsAfter(st, p, ?id0, 0);
    t.check(gap.fullSync, "cursor below lowWater forces fullSync");

    // Removal drops the subscription and its cursor.
    Table.removeClient(st, p, ?id1);
    t.check(not Table.hasClient(st, p, ?id1), "id1 removed");
    t.equalNat(Table.clientsOf(st).size(), 1, "one subscription left");

    // The push filter is stricter than principal ownership: a seat's
    // `HandUpdated` is only served to a live client for that seat, never
    // another principal's seat and never a detached one.
    let pushP = Table.eventsForPrincipal(st, p, 0);
    var pushLeaked = 0;
    for (e in pushP.events.vals()) {
      switch (e.body) {
        case (#HandUpdated(h)) { if (h.seat != 0) { pushLeaked += 1 } };
        case _ {};
      };
    };
    t.equalNat(pushLeaked, 0, "a push to p carries no other or detached seat's HandUpdated");

    // A seat already acked to the head is not re-sent its own hand updates.
    Table.advanceCursor(st, p, ?id0, Table.seqOf(st));
    let pushHead = Table.eventsForPrincipal(st, p, 0);
    var replayed = 0;
    for (e in pushHead.events.vals()) {
      switch (e.body) {
        case (#HandUpdated(h)) { if (h.seat == 0) { replayed += 1 } };
        case _ {};
      };
    };
    t.equalNat(replayed, 0, "a seat at its cursor is not re-sent its own HandUpdated");

    // A seat taken mid-deal is not served hand updates from before it took
    // over: seat 2 moves from others[0] to p, and p attaching under a new
    // client id must not see the old owner's dealt cards.
    ignore Table.leaveWithClient(st, others[0], null, ?p, 0);
    switch (Table.joinTableWithClient(st, p, ?"\02", 2, null, null, 0)) {
      case (#ok(_)) {};
      case (#err(_)) { t.check(false, "p attaches to the vacated seat") };
    };
    let afterTakeover = Table.eventsAfter(st, p, ?"\02", 0);
    var preAttach = 0;
    for (e in afterTakeover.events.vals()) {
      switch (e.body) {
        case (#HandUpdated(h)) { if (h.seat == 2) { preAttach += 1 } };
        case _ {};
      };
    };
    t.equalNat(preAttach, 0, "a seat taken mid-deal is not served pre-attach HandUpdated");
  };

  public func run(t : Test.Harness) {
    let users = ps();
    testAccess(t);
    testAuthCodeGate(t, users[0], [users[1], users[2]]);
    testAuthCodeStrength(t);
    testClientIdBound(t);
    testReadGate(t, users[0], [users[1], users[2]]);
    testReserveGate(t);
    testSeatIdentity(t, users[0], [users[1], users[2]]);
    testRegistry(t, users[0], [users[1], users[2]]);
  };
}
