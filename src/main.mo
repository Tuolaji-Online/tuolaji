/// Canister entry point: table registry, auth, timers, and public API.
import Blob "mo:core/Blob";
import Array "mo:core/Array";
import Cycles "mo:core/Cycles";
import Debug "mo:core/Debug";
import Error "mo:core/Error";
import List "mo:core/List";
import Map "mo:core/Map";
import Nat "mo:core/Nat";
import Prim "mo:prim";
import Principal "mo:core/Principal";
import Random "mo:core/Random";
import Runtime "mo:core/Runtime";
import Set "mo:core/Set";
import Text "mo:core/Text";
import Time "mo:core/Time";
import Access "Access";
import Card "Card";
import Scheduler "Scheduler";
import Table "Table";
import Types "Types";

// The retired stable variables (the constants, `botPrincipals`, `sched`) are
// `transient`; a one-time migration already dropped them from the deployed
// signature, so no migration is needed here any more. The same is true of the
// `participants` migration that seeded `Table.State.participants` from the
// event log: the deployed canister now carries the field, so the migration has
// been removed and a fresh install can self-upgrade again.
persistent actor {
  // ── Reentrancy discipline ──────────────────────────────────────────
  // Every ingress reads and mutates its table synchronously. The only
  // `await`s are `Random.blob()` calls (in `ready` and the timer's seal of a
  // pending shuffle) taken *after* the critical state is committed. Each is
  // followed by `Table.startDeal`, which re-checks `needsShuffle` and is
  // idempotent, so two racing triggers cannot install two decks.

  /// Cap on concurrently-seated tables per principal.
  transient let MAX_TABLES_PER_PRINCIPAL : Nat = 8;

  /// Global cap so the scheduler's per-wake table count stays bounded.
  transient let MAX_TABLES : Nat = 1000;

  /// Ingress cycle floor for canister clients. A canister must
  /// attach at least `MIN_CALL_CYCLES` to every update, and that is the amount
  /// the canister accepts (no exact per-push cost).
  transient let MIN_CALL_CYCLES : Nat = 2_000_000;

  /// Whitelist of bot principals allowed to hold more than one seat in a
  /// single table. One seat per table is always allowed; a second
  /// seat requires membership here. The set is rebuilt at install and on every
  /// upgrade from the deploy environment's `PUBLIC_CANISTER_ID:bot` canister
  /// environment variable (icp-cli sets it automatically for every canister in
  /// the project), so no operator call is needed. `getBotPrincipals` exposes it
  /// for auditing.
  transient let botPrincipals = Set.empty<Principal>();

  /// Seed the bot whitelist from the deploy environment. The variable holds the
  /// `bot` canister's principal text (set by the tooling, so trusted); it is
  /// rebuilt from scratch so a renamed/removed bot cannot linger.
  func seedBotWhitelist<system>() {
    botPrincipals.clear();
    switch (Runtime.envVar<system>("PUBLIC_CANISTER_ID:bot")) {
      case (?text) {
        let p = Principal.fromText(text);
        if (Access.isCanister(p)) { Set.add(botPrincipals, p) };
      };
      case null {};
    };
  };

  seedBotWhitelist<system>();

  /// True when `p` is a trusted bot principal. Used to decide when a table
  /// with no human-owned seat can be ended (see `Table.endIfNoHumans`).
  func isBotPrincipal(p : Principal) : Bool {
    Set.contains(botPrincipals, p);
  };

  /// Does a create request leave at least one seat (1..3) unclaimed for an
  /// invitee? Seat 0 is always the creator; a null or short `reserved` leaves
  /// the remaining seats open.
  func hasOpenSeat(reserved : ?[?Principal]) : Bool {
    switch (reserved) {
      case null { true };
      case (?r) {
        var open = false;
        var i = 1;
        while (i < 4 and not open) {
          let claimed = i < r.size() and r[i] != null;
          if (not claimed) { open := true };
          i += 1;
        };
        open;
      };
    };
  };

  /// A non-bot principal may hold at most one seat per table. Reject a
  /// creation whose reservations claim the same non-bot principal more than
  /// once (seat 0 is the creator's implicit claim). Trusted bots are exempt:
  /// they may hold several seats.
  func reservedSeatsValid(reserved : ?[?Principal], creator : Principal) : Bool {
    let r = switch (reserved) { case (?x) { x }; case null { [] } };
    func at(i : Nat) : ?Principal {
      if (i == 0) { ?creator } else if (i < r.size()) { r[i] } else { null };
    };
    var i = 0;
    while (i < 4) {
      switch (at(i)) {
        case (?p) {
          if (not isBotPrincipal(p)) {
            var j = i + 1;
            while (j < 4) {
              switch (at(j)) {
                case (?q) { if (Principal.equal(p, q)) { return false } };
                case null {};
              };
              j += 1;
            };
          };
        };
        case null {};
      };
      i += 1;
    };
    true;
  };

  /// Number of timer callbacks the scheduler has run, for the metrics snapshot.
  var tickCount : Nat = 0;

  /// Reject obviously oversized ingress before it is scheduled, saving cycles
  /// on abuse. The largest legitimate argument is a card list
  /// (well under 1 KiB); 4 KiB is a generous ceiling.
  system func inspect({ caller : Principal; arg : Blob }) : Bool {
    ignore caller;
    arg.size() <= 4096;
  };

  let tables = Map.empty<Types.TableId, Table.State>();
  var nextTableId : Types.TableId = 0;

  /// Player-filed problem reports, keyed by a monotonically increasing id.
  let reports = Map.empty<Types.ReportId, Types.Report>();
  var nextReportId : Types.ReportId = 0;
  transient let MAX_REPORTS : Nat = 2000;
  transient let MAX_REPORT_TEXT : Nat = 2000;

  /// One-off timer scheduler: each table queues its earliest
  /// deadline and only a single `Timer.setTimer` is armed at a time, so an
  /// idle canister is never woken.
  transient let sched = Scheduler.new();

  /// Recompute a table's single pending wake time from its current state.
  func reschedule(s : Table.State, now : Types.Timestamp) {
    switch (Table.nextTimer(s, now)) {
      case (?at) { Scheduler.upsert(sched, s.id, at) };
      case null { Scheduler.remove(sched, s.id) };
    };
  };

  /// (Re)arm the one-off timer for the earliest queued deadline.
  func rearm<system>(now : Types.Timestamp) {
    Scheduler.arm<system>(sched, now, fire);
  };

  /// Fetch the beacon entropy for a pending shuffle and install the deck. One
  /// 32-byte `raw_rand` blob seeds the ChaCha20 keystream the shuffle draws
  /// from (see `Shuffle.shuffleWithEntropy`); the blob is stored by the table
  /// and revealed once the deal is scored (`#ShuffleRevealed`), so the shuffle
  /// can be replayed and audited.
  func sealDeal(s : Table.State) : async () {
    if (not Table.needsShuffle(s)) { return };
    Table.startDeal(s, await Random.blob(), Time.now());
  };

  /// After an ingress mutates a table: prune its event log
  /// lazily (no timer needed), reschedule it, and re-arm.
  func touch<system>(s : Table.State) : async () {
    let now = Time.now();
    Table.prune(s, now);
    reschedule(s, now);
    rearm<system>(now);
    ignore pushClients(s);
  };

  /// Evict ended tables past their grace period. Swept lazily on registry
  /// changes rather than armed as a timer, so an idle canister keeps no
  /// cleanup timer at all.
  func sweepEnded(now : Types.Timestamp) {
    let stale = List.empty<Types.TableId>();
    for ((id, s) in Map.entries(tables)) {
      switch (s.endedAt) {
        case (?t) { if (now - t > Table.ENDED_RETENTION_NANOS) { stale.add(id) } };
        case null {};
      };
    };
    for (id in stale.values()) {
      Map.remove(tables, id);
      Scheduler.remove(sched, id);
    };
  };

  /// End tables that have emitted no event for `Table.IDLE_RETENTION_NANOS`.
  /// Called before create/join so an abandoned table cannot be joined and its
  /// registry memory is reclaimed. A table ended here also gets its
  /// `TableEnded` pushed to its clients, so a bot holding a seat learns the
  /// table is gone instead of waiting for a sync that may never come.
  func sweepIdle(now : Types.Timestamp) : async () {
    for (s in Map.values(tables)) {
      if (Table.endIfIdle(s, now)) {
        ignore pushClients(s);
      };
    };
  };

  /// Fallback wake for the scheduler's single timer callback, armed by `fire`
  /// before it runs any table's deadline work. See `fire`.
  transient let WAKE_FALLBACK_NANOS : Nat = 5_000_000_000; // 5 seconds

  /// The scheduler's single timer callback: run every table whose deadline is
  /// due, then re-arm. The deadline work is synchronous; only the rare
  /// next-deal shuffle seal awaits, after the state is committed.
  ///
  /// Failure handling here has to be described exactly, because this is the only
  /// thing that advances a table on its own and there are two ways a callback
  /// can die.
  ///
  /// 1. *A rejected future* - a failed `raw_rand`, a failed inter-canister call.
  ///    `try/catch` catches these. The guard is per table, so the tables queued
  ///    behind the failure still run, and the final re-arm (outside every guard)
  ///    installs the real schedule. On the happy path that re-arm cancels the
  ///    fallback and installs the true earliest wake, or nothing at all when no
  ///    table needs one, so an idle canister still keeps no timer. This is the
  ///    common failure and it is fully handled in-process.
  ///
  /// 2. *A Wasm trap* - a bad index, a failed assertion. A trap is not
  ///    catchable by Motoko `try/catch`, and the IC discards the entire call,
  ///    its state changes included. That also discards the fallback wake armed
  ///    below, because a Motoko timer registration is part of the canister's own
  ///    state and is rolled back with everything else. Do not read the fallback
  ///    as covering this case: it is armed as a safety net in case the platform
  ///    ever preserves a wake scheduled by a call that aborts, not as a
  ///    guarantee. What actually recovers a trap is outside this function: the
  ///    schedule is rebuilt from `tables` in `postupgrade`, and any ingress calls
  ///    `touch`, which re-derives `nextTimer` and re-arms. Until one of those
  ///    happens, no table has a wake. A trap here is therefore a bug to fix, not
  ///    a condition to absorb - the per-table guards above do not pretend
  ///    otherwise.
  ///
  /// The fallback interval matches `Table.AUTO_RETRY_NANOS`, the same "retry
  /// loudly rather than stop quietly" policy the stuck auto-play already follows:
  /// a wake that keeps failing is an operator problem, but it announces itself
  /// in the logs instead of looking like an idle canister.
  func fire() : async () {
    let now = Time.now();
    tickCount += 1;
    let due = Scheduler.takeDue(sched, now);
    // Queue the safety-net wake before touching any table state.
    Scheduler.armFallback<system>(sched, WAKE_FALLBACK_NANOS, fire);
    for (id in due.values()) {
      try {
        switch (find(id)) {
          case (?s) {
            ignore Table.dealTick(s, now);
            ignore Table.checkDealWindow(s, now);
            ignore Table.autoBury(s, now);
            ignore Table.autoPlay(s, now);
            Table.prune(s, now);
            ignore pushClients(s);
          };
          case null {};
        };
      } catch e {
        Debug.print(
          "game: deadline work failed for table " # Nat.toText(id) # ": "
          # Error.message(e)
        );
      };
    };
    // A due action may have queued the next deal's shuffle; seal it now. Guarded
    // per table as well: one rejected `raw_rand` must not strand the others.
    let sealFailed = Set.empty<Types.TableId>();
    for (id in due.values()) {
      try {
        switch (find(id)) {
          case (?s) {
            await sealDeal(s);
          };
          case null {};
        };
      } catch e {
        Set.add(sealFailed, id);
        Debug.print(
          "game: shuffle seal failed for table " # Nat.toText(id) # ": "
          # Error.message(e)
        );
      };
    };
    // Re-derive each due table's next wake and re-arm for the earliest of
    // the rest, replacing the fallback wake.
    let after = Time.now();
    for (id in due.values()) {
      switch (find(id)) {
        case (?s) {
          reschedule(s, after);
          // A table whose seal just failed still owes a shuffle, and
          // `nextTimer` reports that as "now" so the deal can start as soon as
          // entropy arrives. Re-arming at zero delay would instead spin the one
          // timer as fast as blocks arrive while `raw_rand` keeps rejecting, so
          // push the retry out by the same backoff a stuck auto-play uses. The
          // next attempt is still triggered immediately by any ingress, because
          // `touch` re-runs `reschedule`.
          if (Set.contains(sealFailed, id) and Table.needsShuffle(s)) {
            Scheduler.upsert(sched, id, after + Table.AUTO_RETRY_NANOS);
          };
        };
        case null {};
      };
    };
    rearm<system>(after);
  };

  system func postupgrade() {
    // The whitelist is derived from the deploy environment, not persisted, so
    // refresh it on every upgrade (a bot canister id may have changed).
    seedBotWhitelist<system>();
    // Timers do not survive upgrades: drop the stale id, rebuild the queue
    // from the persisted tables, and re-arm.
    sched.timer := null;
    sched.entries := Map.empty();
    let now = Time.now();
    for ((id, s) in Map.entries(tables)) {
      switch (Table.nextTimer(s, now)) {
        case (?at) { Scheduler.upsert(sched, id, at) };
        case null {};
      };
    };
    rearm<system>(now);
  };

  system func preupgrade() {
    // Bound stable memory before the state snapshot is written: drop events
    // older than each table's retention window.
    let now = Time.now();
    for (s in Map.values(tables)) {
      Table.prune(s, now);
    };
  };

  func find(id : Types.TableId) : ?Table.State {
    Map.get(tables, id);
  };

  /// The poll response for a table the caller may not see. Deliberately the
  /// same shape as an unknown table, so a refused read never confirms that a
  /// private table exists at that id.
  func noTable(id : Types.TableId) : Types.PollResponse {
    {
      tableId = id;
      seq = 0;
      lowWater = 1;
      fullSync = true;
      phase = #Ended;
      events = [];
      view = emptyView(id);
    };
  };

  func notFound() : Types.ActionResult {
    #err({ seq = 0; code = #TableNotFound; detail = "no such table" });
  };

  // ── ingress gate ───────────────────────────────────────────────────

  /// The caller may take an ingress that creates or joins a seat: users and
  /// anonymous callers are free (anonymous is rejected), canisters must attach
  /// cycles. The caller is not required to be a registered client yet.
  func chargeNewClient<system>(caller : Principal) : ?Types.CheckError {
    if (not Access.isCanister(caller)) {
      if (Access.isAnonymous(caller)) {
        return ?{ code = #NotAuthorized; detail = "anonymous" };
      };
      return null;
    };
    if (Cycles.available() < MIN_CALL_CYCLES) {
      return ?{ code = #InsufficientCycles; detail = "attach cycles" };
    };
    ignore Cycles.accept<system>(MIN_CALL_CYCLES);
    null;
  };

  /// The caller may take an ingress on an existing table: a canister must be a
  /// registered client of this table (`(principal, clientId)`) and pay cycles.
  /// Users are never charged; anonymous callers are rejected.
  func chargeClient<system>(s : Table.State, caller : Principal, id : ?Types.ClientId) : ?Types.CheckError {
    if (not Access.isCanister(caller)) {
      if (Access.isAnonymous(caller)) {
        return ?{ code = #NotAuthorized; detail = "anonymous" };
      };
      return null;
    };
    if (not Table.hasClient(s, caller, id)) {
      return ?{ code = #NotAuthorized; detail = "unknown canister client" };
    };
    if (Cycles.available() < MIN_CALL_CYCLES) {
      return ?{ code = #InsufficientCycles; detail = "attach cycles" };
    };
    let accepted = Cycles.accept<system>(MIN_CALL_CYCLES);
    Table.bumpCycles(s, caller, id, accepted);
    null;
  };

  /// Fire-and-forget pushes to every registered canister client of `s`.
  /// Never awaits: a slow or dead bot cannot hold the game hostage.
  ///
  /// One batch per client canister per table: the new events since the client's
  /// watermark (public events plus its own seats' private `HandUpdated`). The
  /// watermark is the oldest cursor among the client's seats, and all of its
  /// cursors advance together after the push. The client applies the events and
  /// only resyncs on `fullSync` or a gap.
  func pushClients(s : Table.State) : async () {
    let owners = Table.clientsOf(s);
    let seq = Table.seqOf(s);
    let pushed = Set.empty<Principal>();
    for (o in owners.vals()) {
      if (Set.contains(pushed, o.principal)) { continue };
      var watermark : ?Types.Seq = null;
      for (o2 in owners.vals()) {
        if (Principal.equal(o2.principal, o.principal)) {
          switch (o2.client) {
            case null {};
            case (?c) {
              watermark := switch (watermark) {
                case (?w) { ?Nat.min(w, c.cursor) };
                case null { ?c.cursor };
              };
            };
          };
        };
      };
      switch (watermark) {
        case null {};
        case (?w) {
          let batch = Table.eventsForPrincipal(s, o.principal, w);
          if (batch.events.size() == 0 and not batch.fullSync) { continue };
          Set.add(pushed, o.principal);
          let bot : Types.Bot = actor (Principal.toText(o.principal));
          // One-way: never awaited, so a slow/dead bot cannot hold the game
          // hostage. No cycles are attached (the call is charged to this balance).
          ignore bot.receive({ tableId = s.id; seq; fullSync = batch.fullSync; events = batch.events });
          for (o2 in owners.vals()) {
            if (Principal.equal(o2.principal, o.principal)) {
              Table.advanceCursor(s, o2.principal, o2.clientId, seq);
            };
          };
        };
      };
    };
  };

  func tablesFor(p : Principal) : Nat {
    var n = 0;
    for (s in Map.values(tables)) {
      // Ended tables no longer hold a cap slot.
      if (s.phase != #Ended) {
        switch (Table.seatOf(s, p)) {
          case (?_) { n += 1 };
          case null {};
        };
      };
    };
    n;
  };

  /// Tables that are still live (not explicitly ended).
  func liveTables() : Nat {
    var n = 0;
    for (s in Map.values(tables)) {
      if (s.phase != #Ended) { n += 1 };
    };
    n;
  };

  /// Largest legitimate card list in any ingress (a full one-suit hand is 25;
  /// the banker hand is 33). Anything larger is rejected before rule work.
  transient let MAX_CARD_LIST : Nat = 34;

  /// Basic card sanitisation: non-empty, bounded,
  /// unique, in range.
  func sanitize(cards : [Card.Card]) : ?Types.CheckError {
    if (cards.size() > MAX_CARD_LIST) {
      return ?{ code = #PayloadTooLarge; detail = "card list too large" };
    };
    if (cards.size() == 0) {
      return ?{ code = #InvalidCard; detail = "empty card list" };
    };
    var i = 0;
    while (i < cards.size()) {
      if (not Card.isValidId(cards[i])) {
        return ?{ code = #InvalidCard; detail = "card id out of range" };
      };
      var j = i + 1;
      while (j < cards.size()) {
        if (cards[i] == cards[j]) {
          return ?{ code = #DuplicateCard; detail = "duplicate card in play" };
        };
        j += 1;
      };
      i += 1;
    };
    null;
  };

  // ── registry ───────────────────────────────────────────────────────

  /// Create a table. `avatar` is the creator's cosmetic picture, stored with
  /// seat 0. `reserved` optionally claims a principal per seat: only that
  /// principal may attach to it. `cfg` is optional: null uses the canister's
  /// default config; a supplied config is validated and rejected when it is
  /// not sensible.
  public shared(msg) func createTable(req : Types.CreateTableRequest) : async Types.CreateResult {
    switch (chargeNewClient<system>(msg.caller)) {
      case (?e) { return #err(e) };
      case null {};
    };
    let config = switch (req.cfg) {
      case (?c) { c };
      case null { Types.defaultConfig };
    };
    if (not Types.validConfig(config)) {
      return #err({ code = #InvalidConfig; detail = "invalid table config" });
    };
    // A table is private exactly when it has an auth code, so derive the flag
    // from it and only check the request's hint for consistency.
    let isPrivate = req.authCode != null;
    let wantsPrivate = switch (req.isPrivate) { case (?v) { v }; case null { false } };
    if (wantsPrivate != isPrivate) {
      return #err({ code = #InvalidAuthCode; detail = "isPrivate and authCode disagree" });
    };
    // A private table is invite-only, so it must leave a seat open for the
    // invitee: reject a request that pre-claims every seat for bots.
    if (isPrivate and not hasOpenSeat(req.reserved)) {
      return #err({ code = #PrivateNeedsOpenSeat; detail = "a private table needs at least one open seat" });
    };
    // The auth code is the table's only secret and joining is not throttled, so
    // the length is enforced here rather than left to the client (see
    // `Table.MIN_AUTH_CODE`).
    if (not Table.validAuthCode(req.authCode)) {
      return #err({
        code = #InvalidAuthCode;
        detail = "auth code must be " # Nat.toText(Table.MIN_AUTH_CODE) # ".." # Nat.toText(Table.MAX_AUTH_CODE) # " characters";
      });
    };
    await create(config, req.reserved, req.avatar, req.clientId, req.authCode, msg.caller);
  };

  func create(
    cfg : Types.TableConfig,
    reserved : ?[?Principal],
    avatar : ?Types.Avatar,
    clientId : ?Types.ClientId,
    authCode : ?Text,
    caller : Principal,
  ) : async Types.CreateResult {
    // Validate the caller-supplied avatar and client id before touching any
    // state: both are persisted on the seat for the life of the table.
    if (not Table.validAvatar(avatar)) {
      return #err({ code = #InvalidAvatar; detail = "invalid avatar" });
    };
    if (not Table.validClientId(clientId)) {
      return #err({
        code = #PayloadTooLarge;
        detail = "client id must be at most " # Nat.toText(Table.MAX_CLIENT_ID) # " bytes";
      });
    };
    // A non-bot principal may hold at most one seat; reject a reservation set
    // that claims one twice before allocating a table.
    if (not reservedSeatsValid(reserved, caller)) {
      return #err({ code = #NotWhitelisted; detail = "principal reserved for more than one seat" });
    };
    // Reclaim ended tables first so their memory is freed even if the live cap
    // is currently reached (ended tables do not hold a cap slot). Idle tables
    // are ended first, so they stop holding a cap slot too.
    let now = Time.now();
    await sweepIdle(now);
    sweepEnded(now);
    if (liveTables() >= MAX_TABLES) {
      return #err({ code = #TooManyTables; detail = "canister table limit reached" });
    };
    if (tablesFor(caller) >= MAX_TABLES_PER_PRINCIPAL) {
      return #err({ code = #TooManyTables; detail = "too many concurrent tables" });
    };
    let id = nextTableId;
    nextTableId += 1;
    let s = Table.newWithClient(id, cfg, caller, clientId, now, avatar, authCode);
    switch (reserved) {
      case (?r) { Table.assignReserved(s, r) };
      case null {};
    };
    if (Access.isCanister(caller)) { Table.addClient(s, caller, clientId, 0) };
    Map.add(tables, id, s);
    ignore Table.endIfNoHumans(s, isBotPrincipal, now);
    ignore touch<system>(s);
    #ok(id);
  };

  public query (msg) func listTables(filter : Types.TableFilter) : async [Types.TableInfo] {
    // Hard server-side page cap so a caller cannot force an unbounded scan.
    // `afterId` is an exclusive cursor over increasing table ids.
    let now = Time.now();
    let maxPage : Nat = 100;
    let cap = switch (filter.limit) {
      case (?l) { if (l < maxPage) { l } else { maxPage } };
      case null { maxPage };
    };
    let out = List.empty<Types.TableInfo>();
    let showEnded = switch (filter.phase) { case (?#Ended) { true }; case _ { false } };
    var emitted = 0;
    var more = true;
    let it = Map.entries(tables);
    while (more) {
      switch (it.next()) {
        case null { more := false };
        case (?(id, s)) {
          let afterOk = switch (filter.afterId) {
            case (?a) { id > a };
            case null { true };
          };
          if (afterOk and emitted < cap) {
            let info = Table.infoFor(s, ?msg.caller);
            let over = Table.isOver(s, now);
            let phaseOk = switch (filter.phase) {
              case (?p) { if (p == #Ended) { info.phase == p or over } else { info.phase == p } };
              case null { true };
            };
            // A table past its idle deadline (`endingTime`) is over for
            // practical purposes: the live lists drop it, but the ended
            // listing keeps it (it is still swept to `Ended` by the next
            // ingress).
            let live = not Table.isIdle(s, now);
            // An ended table is only listed when it has a report to open: a
            // pruned log or no completed trick leaves nothing to show.
            let reportable = Table.hasTricks(s) and not Table.historyPruned(s);
            // A private table is hidden from the live listing, except to a
            // principal who already holds a seat in it (so their other devices
            // can find it and re-enter). It still appears in the ended listing
            // once it is over: an ended private table is public, which is the
            // same rule `mayRead` applies to the detail endpoints, so every row
            // this lists is a row they can actually open.
            let mine = info.isPrivate and Table.principalHasSeat(s, msg.caller);
            if ((live or showEnded) and (showEnded or not info.isPrivate or mine) and phaseOk and (showEnded or info.phase != #Ended) and (not filter.joinableOnly or info.joinable) and (not showEnded or reportable)) {
              out.add(info);
              emitted += 1;
            };
          } else if (emitted >= cap) {
            more := false;
          };
        };
      };
    };
    out.toArray();
  };

  /// A table's lobby record. Null when the table does not exist *or* the caller
  /// may not see it (see `Table.mayRead`), so a *live* private table is
  /// indistinguishable from a missing one. An ended private table is public, so
  /// its record reads for anyone.
  public query (msg) func getTable(req : Types.GetTableRequest) : async ?Types.TableInfo {
    switch (find(req.id)) {
      case (?s) {
        if (Table.mayRead(s, msg.caller, req.authCode, Time.now())) { ?Table.infoFor(s, ?msg.caller) } else { null };
      };
      case null { null };
    };
  };

  /// Completed tricks of a table in play order, for replay/analysis. Pass a
  /// `?trickId` to return only that trick. Null when the table does not exist or
  /// the caller may not see a still-live private table (see `Table.mayRead`);
  /// only tricks still inside the table's event retention window are returned.
  public query (msg) func getPlayHistory(req : Types.GetPlayHistoryRequest) : async ?[Types.PlaySequence] {
    switch (find(req.id)) {
      case (?s) {
        if (Table.mayRead(s, msg.caller, req.authCode, Time.now())) { ?Table.playHistory(s, req.trickId) } else { null };
      };
      case null { null };
    };
  };

  /// A table's stats plus its completed tricks and scored deals, for the
  /// lobby's ended-table detail dialog. Null when the table does not exist or
  /// the caller may not see a still-live private table (see `mayRead`) - ended
  /// tables, private or not, are the whole point of this call.
  public query (msg) func getTableHistory(req : Types.GetTableHistoryRequest) : async ?Types.TableHistory {
    switch (find(req.id)) {
      case (?s) {
        if (Table.mayRead(s, msg.caller, req.authCode, Time.now())) { ?Table.history(s) } else { null };
      };
      case null { null };
    };
  };

  // ── problem reports ────────────────────────────────────────────────

  /// Only a canister controller may read every report or post admin replies.
  func isAdmin(caller : Principal) : Bool {
    Prim.isController(caller);
  };

  // ── bot whitelist ──────────────────────────────────────────────────

  /// Read-only audit of the trusted bot principals. The whitelist is seeded
  /// from the deploy environment (see `seedBotWhitelist`), not managed at
  /// runtime.
  public query func getBotPrincipals() : async [Principal] {
    Set.toArray(botPrincipals);
  };

  func validReportText(text : Text) : Bool {
    let n = Text.size(text);
    n > 0 and n <= MAX_REPORT_TEXT;
  };

  /// File a problem report against a table (and the deal it was filed from).
  /// Returns the stored report. Any caller may submit.
  public shared(msg) func submitReport(req : Types.SubmitReportRequest) : async Types.ReportResult {
    if (not validReportText(req.text)) { return #err(#InvalidReport) };
    if (Map.size(reports) >= MAX_REPORTS) { return #err(#TooManyReports) };
    let id = nextReportId;
    nextReportId += 1;
    let now = Time.now();
    let report : Types.Report = {
      id;
      tableId = req.tableId;
      dealNo = req.dealNo;
      reporter = msg.caller;
      at = now;
      messages = [{ at = now; admin = false; text = req.text }];
    };
    Map.add(reports, id, report);
    #ok(report);
  };

  /// The caller's own reports, oldest first.
  public shared(msg) func getMyReports() : async [Types.Report] {
    let out = List.empty<Types.Report>();
    for (r in Map.values(reports)) {
      if (Principal.equal(r.reporter, msg.caller)) { out.add(r) };
    };
    out.toArray();
  };

  /// Every report (admin only).
  public shared(msg) func getReports() : async Types.ReportListResult {
    if (not isAdmin(msg.caller)) { return #err(#NotAuthorized) };
    let out = List.empty<Types.Report>();
    for (r in Map.values(reports)) { out.add(r) };
    #ok(out.toArray());
  };

  /// Append an admin follow-up to a report (admin only).
  public shared(msg) func addReportMessage(req : Types.AddReportMessageRequest) : async Types.ReportResult {
    if (not isAdmin(msg.caller)) { return #err(#NotAuthorized) };
    if (not validReportText(req.text)) { return #err(#InvalidReport) };
    switch (Map.get(reports, req.id)) {
      case null { #err(#ReportNotFound) };
      case (?r) {
        let now = Time.now();
        let updated : Types.Report = {
          r with
          messages = Array.concat(r.messages, [{ at = now; admin = true; text = req.text }]);
        };
        Map.add(reports, req.id, updated);
        #ok(updated);
      };
    };
  };

  /// Read-only cost/observability snapshot.
  public query func getMetrics() : async Types.Metrics {
    {
      tables = Map.size(tables);
      nextTableId;
      tickCount;
      cycleBalance = Cycles.balance();
    };
  };

  // ── lobby ──────────────────────────────────────────────────────────

  public shared(msg) func joinTable(req : Types.JoinTableRequest) : async Types.ActionResult {
    switch (chargeNewClient<system>(msg.caller)) {
      case (?e) { return #err({ seq = 0; code = e.code; detail = e.detail }) };
      case null {};
    };
    // The client id is stored on the seat, so bound it here as well as at
    // `createTable`. See `Table.MAX_CLIENT_ID`.
    if (not Table.validClientId(req.clientId)) {
      return #err({
        seq = 0;
        code = #PayloadTooLarge;
        detail = "client id must be at most " # Nat.toText(Table.MAX_CLIENT_ID) # " bytes";
      });
    };
    let now = Time.now();
    await sweepIdle(now);
    switch (find(req.id)) {
      case (?s) {
        // A private table's auth code gates joining (a public table has null,
        // and a join must present null there too). The single bypass is the
        // whitelisted bot attaching a seat the table already claims for it.
        // Principal *class* is deliberately not the test: `Access.isCanister`
        // is true for every opaque-class principal, anyone can deploy a
        // canister, and every private table must keep a seat open for an
        // invitee — so class as authority hands every private table to the
        // first random canister that probes its id.
        let botAttachesOwnSeat = Access.maySkipAuthCode(
          Set.contains(botPrincipals, msg.caller),
          Table.seatClaimedBy(s, req.seat, msg.caller),
        );
        if (not botAttachesOwnSeat and req.authCode != s.authCode) {
          return #err({ seq = Table.seqOf(s); code = #InvalidAuthCode; detail = "auth code mismatch" });
        };
        // One seat per principal per table; a second seat needs the bot
        // whitelist. Attaching to a seat already claimed for this principal is
        // not a second seat.
        if (Table.ownsSeatOtherThan(s, msg.caller, req.seat)) {
          if (not Set.contains(botPrincipals, msg.caller)) {
            return #err({ seq = Table.seqOf(s); code = #NotWhitelisted; detail = "principal already seated in this table" });
          };
        };
        // A caller entitled to the seat may take over a replaceable seat the
        // whitelisted bot is holding. The auth code and one-seat checks above
        // already passed, so this is a real hand-over. The game reassigns the
        // seat here; the bot is then told to drop its local copy, so it never
        // calls back into `leaveTable`. A join by the bot's own principal is
        // left to `joinTableWithClient`, which handles re-attaching.
        let botToDrop = switch (Table.seatOwnerOf(s, req.seat)) {
          case (?o) {
            if (
              Set.contains(botPrincipals, o.principal) and
              o.replaceable and
              not Principal.equal(o.principal, msg.caller)
            ) { ?o.principal } else { null };
          };
          case null { null };
        };
        let r = switch (botToDrop) {
          case (?bot) {
            let taken = Table.takeOverSeat(s, msg.caller, req.clientId, req.seat, req.avatar, req.replaceable, now);
            switch (taken) {
              case (#ok(_)) {
                // One-way: the seat already belongs to the caller, so the bot
                // only needs to drop its local copy. Never awaited.
                let b : Types.Bot = actor (Principal.toText(bot));
                b.handOver({ tableId = req.id; seat = req.seat });
              };
              case (#err(_)) {};
            };
            taken;
          };
          case null {
            Table.joinTableWithClient(s, msg.caller, req.clientId, req.seat, req.avatar, req.replaceable, now);
          };
        };
        switch (r) {
          case (#ok(_)) {
            if (Access.isCanister(msg.caller)) {
              Table.addClient(s, msg.caller, req.clientId, req.seat);
            };
          };
          case _ {};
        };
        ignore Table.endIfNoHumans(s, isBotPrincipal, now);
        ignore touch<system>(s);
        r;
      };
      case null { notFound() };
    };
  };

  public shared(msg) func leaveTable(req : Types.LeaveTableRequest) : async Types.ActionResult {
    switch (find(req.id)) {
      case (?s) {
        switch (chargeClient<system>(s, msg.caller, req.clientId)) {
          case (?e) { return #err({ seq = Table.seqOf(s); code = e.code; detail = e.detail }) };
          case null {};
        };
        // `reserveFor` claims the vacated seat for another principal. Only two
        // hand-overs are admissible (below): the trusted bot passing on a seat,
        // or a seat handed to the bot. A permitted target then takes it under
        // the one-seat-per-table rule, unless it is a trusted bot (which may
        // hold several).
        switch (req.reserveFor) {
          case (?p) {
            // The hand-over must involve the whitelist on one side: the bot
            // passing on a seat of its own, or an ordinary seat handed to the
            // bot to keep the deal playing. A seat claimed for an uninvolved
            // third party is neither: the target never consented, whoever
            // attaches next reads that seat's whole remaining hand through
            // `PlayerView.myHand`, and an unfilled claim stops the table ever
            // starting. Checked before any state changes, so a rejected leave
            // leaves the seat untouched.
            if (not Access.mayReserveSeat(isBotPrincipal(msg.caller), isBotPrincipal(p))) {
              return #err({ seq = Table.seqOf(s); code = #NotWhitelisted; detail = "a seat may only be handed to or by the bot" });
            };
            if (Table.principalHasSeat(s, p) and not isBotPrincipal(p)) {
              return #err({ seq = Table.seqOf(s); code = #NotWhitelisted; detail = "target already seated in this table" });
            };
          };
          case null {};
        };
        let r = Table.leaveWithClient(s, msg.caller, req.clientId, req.reserveFor, Time.now());
        ignore Table.endIfNoHumans(s, isBotPrincipal, Time.now());
        ignore touch<system>(s);
        sweepEnded(Time.now());
        r;
      };
      case null { notFound() };
    };
  };

  public shared(msg) func ready(req : Types.ReadyRequest) : async Types.ActionResult {
    switch (find(req.id)) {
      case (?s) {
        switch (chargeClient<system>(s, msg.caller, req.clientId)) {
          case (?e) { return #err({ seq = Table.seqOf(s); code = e.code; detail = e.detail }) };
          case null {};
        };
        let r = Table.readyWithClient(s, msg.caller, req.clientId, Time.now());
        // A deal was just announced: fetch entropy and shuffle before any
        // client can see a hand. The await happens before the deal state is
        // committed; `startDeal` re-checks the phase.
        await sealDeal(s);
        ignore touch<system>(s);
        switch (r) {
          case (#ok(_)) { #ok({ seq = Table.seqOf(s); penalized = false }) };
          case (#err(e)) { #err(e) };
        };
      };
      case null { notFound() };
    };
  };

  // ── deal actions ───────────────────────────────────────────────────

  public shared(msg) func declareTrump(req : Types.CardsRequest) : async Types.ActionResult {
    switch (find(req.id)) {
      case (?s) {
        switch (chargeClient<system>(s, msg.caller, req.clientId)) {
          case (?e) { return #err({ seq = Table.seqOf(s); code = e.code; detail = e.detail }) };
          case null {};
        };
        switch (sanitize(req.cards)) {
          case (?e) { #err({ seq = Table.seqOf(s); code = e.code; detail = e.detail }) };
          case null { let r = Table.declareTrumpWithClient(s, msg.caller, req.clientId, req.cards, Time.now()); ignore touch<system>(s); r };
        };
      };
      case null { notFound() };
    };
  };

  public shared(msg) func buryKitty(req : Types.CardsRequest) : async Types.ActionResult {
    switch (find(req.id)) {
      case (?s) {
        switch (chargeClient<system>(s, msg.caller, req.clientId)) {
          case (?e) { return #err({ seq = Table.seqOf(s); code = e.code; detail = e.detail }) };
          case null {};
        };
        switch (sanitize(req.cards)) {
          case (?e) { #err({ seq = Table.seqOf(s); code = e.code; detail = e.detail }) };
          case null { let r = Table.buryKittyWithClient(s, msg.caller, req.clientId, req.cards, Time.now()); ignore touch<system>(s); r };
        };
      };
      case null { notFound() };
    };
  };

  public shared(msg) func play(req : Types.CardsRequest) : async Types.ActionResult {
    switch (find(req.id)) {
      case (?s) {
        switch (chargeClient<system>(s, msg.caller, req.clientId)) {
          case (?e) { return #err({ seq = Table.seqOf(s); code = e.code; detail = e.detail }) };
          case null {};
        };
        switch (sanitize(req.cards)) {
          case (?e) { #err({ seq = Table.seqOf(s); code = e.code; detail = e.detail }) };
          case null {
            let r = Table.playWithClient(s, msg.caller, req.clientId, req.cards, Time.now());
            ignore touch<system>(s);
            switch (r) {
              case (#ok(okr)) { #ok({ seq = Table.seqOf(s); penalized = okr.penalized }) };
              case (#err(e)) { #err({ seq = Table.seqOf(s); code = e.code; detail = e.detail }) };
            };
          };
        };
      };
      case null { notFound() };
    };
  };

  // ── reads ──────────────────────────────────────────────────────────

  public shared query(msg) func poll(req : Types.PollRequest) : async Types.PollResponse {
    switch (find(req.tableId)) {
      // An unknown table, or a private one the caller may not read, gets the
      // same empty response; clients treat a missing table separately via
      // getTable/listTables.
      case (?s) {
        if (Table.mayRead(s, msg.caller, req.authCode, Time.now())) { Table.pollWithClient(s, msg.caller, req.clientId, req.afterSeq) } else { noTable(req.tableId) };
      };
      case null { noTable(req.tableId) };
    };
  };

  public shared(msg) func sync(req : Types.PollRequest) : async Types.PollResponse {
    switch (find(req.tableId)) {
      case (?s) {
        if (not Table.mayRead(s, msg.caller, req.authCode, Time.now())) { return noTable(req.tableId) };
        // Only a principal holding a seat has a cursor worth catching up on.
        // A spectator reads through `poll`, which is a query and so costs the
        // canister no consensus; serving the event stream here to a non-member
        // is what let any authenticated caller force a log scan on the update
        // path. The view is still returned, because it is exactly the public
        // state `poll` already answers for free, and a client needs it to render
        // a table it is watching.
        if (not Table.principalHasSeat(s, msg.caller)) {
          return viewOnly(req.tableId, s, msg.caller, req.clientId);
        };
        switch (chargeClient<system>(s, msg.caller, req.clientId)) {
          case (?_) {
            // Charge failure (unknown client or no cycles): hand back the
            // caller-scoped view with no events, never claim the table ended.
            // The caller is seated, so this is not an unauthenticated read; only
            // the event stream it has not paid for is withheld.
            return viewOnly(req.tableId, s, msg.caller, req.clientId);
          };
          case null {};
        };
        Table.pollWithClient(s, msg.caller, req.clientId, req.afterSeq);
      };
      case null { noTable(req.tableId) };
    };
  };

  /// A `sync` response carrying the caller-scoped view but no events: the answer
  /// for a caller with no cursor to serve (a spectator) or whose charge to serve
  /// one failed. Deliberately keeps the table's real `phase`, so a client never
  /// mistakes a refused read for an ended table.
  func viewOnly(
    id : Types.TableId,
    s : Table.State,
    caller : Principal,
    clientId : ?Types.ClientId,
  ) : Types.PollResponse {
    {
      tableId = id;
      seq = Table.seqOf(s);
      lowWater = 1;
      fullSync = true;
      phase = s.phase;
      events = [];
      view = Table.viewWithClient(s, caller, clientId);
    };
  };

  func emptyView(id : Types.TableId) : Types.PlayerView {
    {
      tableId = id;
      dealNo = 0;
      epoch = 1;
      endingTime = 0;
      lastActivity = 0;
      phase = #Ended;
      level = 2;
      trump = null;
      decl = null;
      config = Types.defaultConfig;
      isPrivate = false;
      authCode = null;
      banker = null;
      prospectiveBanker = null;
      dealer = 0;
      mySeat = null;
      myHand = [];
      seats = [];
      score = { bankerPoints = 0; attackerPoints = 0; bankerLevel = 2; attackerLevel = 2 };
      actingSeat = null;
      trick = [];
      lastTrick = null;
      kitty = null;
      deadline = null;
      declareTotal = null;
    };
  };
}
