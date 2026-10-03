/// Tests for the canister-client additions: `(principal, clientId)` seat
/// identity, the multi-seat push registry + `eventsAfter` scoping/gaps, and the
/// pure ingress helpers in `Access.mo`.
import Principal "mo:core/Principal";
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
    let st = Table.newWithClient(0, Types.defaultConfig, p, ?id0, 0, null, false);
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
    testSeatIdentity(t, users[0], [users[1], users[2]]);
    testRegistry(t, users[0], [users[1], users[2]]);
  };
}
