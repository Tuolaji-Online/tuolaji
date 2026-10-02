/// Canister entry point: table registry, auth, timers, and public API.
import Blob "mo:core/Blob";
import Array "mo:core/Array";
import Cycles "mo:core/Cycles";
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

persistent actor {
  // ── Reentrancy discipline ──────────────────────────────────────────
  // Every ingress reads and mutates its table synchronously. The only
  // `await`s are `Random.blob()` calls (in `ready` and the timer's seal of a
  // pending shuffle) taken *after* the critical state is committed. Each is
  // followed by `Table.startDeal`, which re-checks `needsShuffle` and is
  // idempotent, so two racing triggers cannot install two decks.

  /// Cap on concurrently-seated tables per principal.
  let MAX_TABLES_PER_PRINCIPAL : Nat = 8;

  /// Global cap so the scheduler's per-wake table count stays bounded.
  let MAX_TABLES : Nat = 1000;

  /// Ingress cycle floor for canister clients. A canister must
  /// attach at least `MIN_CALL_CYCLES` to every update, and that is the amount
  /// the canister accepts (no exact per-push cost).
  let MIN_CALL_CYCLES : Nat = 2_000_000;

  /// Whitelist of bot principals allowed to hold more than one seat in a
  /// single table. One seat per table is always allowed; a second
  /// seat requires membership here. The set is rebuilt at install and on every
  /// upgrade from the deploy environment's `PUBLIC_CANISTER_ID:bot` canister
  /// environment variable (icp-cli sets it automatically for every canister in
  /// the project), so no operator call is needed. `getBotPrincipals` exposes it
  /// for auditing.
  let botPrincipals = Set.empty<Principal>();

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
  let MAX_REPORTS : Nat = 2000;
  let MAX_REPORT_TEXT : Nat = 2000;

  /// One-off timer scheduler: each table queues its earliest
  /// deadline and only a single `Timer.setTimer` is armed at a time, so an
  /// idle canister is never woken.
  let sched = Scheduler.new();

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

  /// Number of independent `raw_rand` blobs concatenated into one deal's
  /// entropy. One 32-byte blob is not enough for 108 Fisher–Yates draws; a
  /// handful guarantees the draws come from real beacon entropy.
  let ENTROPY_BLOBS : Nat = 8;

  /// Fetch the beacon entropy for a pending shuffle and install the deck. The
  /// concatenated blob is stored by the table and revealed once the deal is
  /// scored (`#ShuffleRevealed`), so the shuffle can be replayed and audited.
  func sealDeal(s : Table.State) : async () {
    if (not Table.needsShuffle(s)) { return };
    var bytes : [Nat8] = [];
    var i = 0;
    while (i < ENTROPY_BLOBS) {
      bytes := Array.concat<Nat8>(bytes, Blob.toArray(await Random.blob()));
      i += 1;
    };
    Table.startDeal(s, Array.toBlob(bytes), Time.now());
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

  /// The scheduler's single timer callback: run every table whose deadline is
  /// due, then re-arm. The deadline work is synchronous; only the rare
  /// next-deal shuffle seal awaits, after the state is committed.
  func fire() : async () {
    let now = Time.now();
    tickCount += 1;
    let due = Scheduler.takeDue(sched, now);
    for (id in due.values()) {
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
    };
    // A due action may have queued the next deal's shuffle; seal it now.
    for (id in due.values()) {
      switch (find(id)) {
        case (?s) {
          await sealDeal(s);
        };
        case null {};
      };
    };
    // Re-derive each due table's next wake and re-arm for the earliest of
    // the rest.
    let after = Time.now();
    for (id in due.values()) {
      switch (find(id)) {
        case (?s) { reschedule(s, after) };
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
  let MAX_CARD_LIST : Nat = 34;

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
    await create(config, req.reserved, req.avatar, req.clientId, msg.caller);
  };

  func create(
    cfg : Types.TableConfig,
    reserved : ?[?Principal],
    avatar : ?Types.Avatar,
    clientId : ?Types.ClientId,
    caller : Principal,
  ) : async Types.CreateResult {
    // Validate the caller-supplied avatar before touching any state.
    if (not Table.validAvatar(avatar)) {
      return #err({ code = #InvalidAvatar; detail = "invalid avatar" });
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
    let s = Table.newWithClient(id, cfg, caller, clientId, now, avatar);
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

  public query func listTables(filter : Types.TableFilter) : async [Types.TableInfo] {
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
            let info = Table.info(s);
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
            if ((live or showEnded) and phaseOk and (showEnded or info.phase != #Ended) and (not filter.joinableOnly or info.joinable) and (not showEnded or reportable)) {
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

  public query func getTable(id : Types.TableId) : async ?Types.TableInfo {
    switch (find(id)) {
      case (?s) { ?Table.info(s) };
      case null { null };
    };
  };

  /// Completed tricks of a table in play order, for replay/analysis. Pass a
  /// `?trickId` to return only that trick. Null when the table does not exist;
  /// only tricks still inside the table's event retention window are returned.
  public query func getPlayHistory(req : Types.GetPlayHistoryRequest) : async ?[Types.PlaySequence] {
    switch (find(req.id)) {
      case (?s) { ?Table.playHistory(s, req.trickId) };
      case null { null };
    };
  };

  /// A table's stats plus its completed tricks and scored deals, for the
  /// lobby's ended-table detail dialog. Null when the table does not exist.
  public query func getTableHistory(req : Types.GetTableHistoryRequest) : async ?Types.TableHistory {
    switch (find(req.id)) {
      case (?s) { ?Table.history(s) };
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
    let now = Time.now();
    await sweepIdle(now);
    switch (find(req.id)) {
      case (?s) {
        // One seat per principal per table; a second seat needs the bot
        // whitelist. Attaching to a seat already claimed for this principal is
        // not a second seat.
        if (Table.ownsSeatOtherThan(s, msg.caller, req.seat)) {
          if (not Set.contains(botPrincipals, msg.caller)) {
            return #err({ seq = Table.seqOf(s); code = #NotWhitelisted; detail = "principal already seated in this table" });
          };
        };
        let r = Table.joinTableWithClient(s, msg.caller, req.clientId, req.seat, req.avatar, req.replaceable, now);
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
        // `reserveFor` claims the vacated seat for another principal: the
        // trusted bot taking over, or a human replacing the seat. The target
        // takes the seat under the one-seat-per-table rule, unless it is a
        // trusted bot (which may hold several).
        switch (req.reserveFor) {
          case (?p) {
            if (Table.principalHasSeat(s, p) and not Set.contains(botPrincipals, p)) {
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
      case (?s) { Table.pollWithClient(s, msg.caller, req.clientId, req.afterSeq) };
      case null {
        // Return an empty response for an unknown table; clients treat a
        // missing table separately via getTable/listTables.
        {
          tableId = req.tableId;
          seq = 0;
          lowWater = 1;
          fullSync = true;
          phase = #Ended;
          events = [];
          view = emptyView(req.tableId);
        };
      };
    };
  };

  public shared(msg) func sync(req : Types.PollRequest) : async Types.PollResponse {
    switch (find(req.tableId)) {
      case (?s) {
        switch (chargeClient<system>(s, msg.caller, req.clientId)) {
          case (?_) {
            // Charge failure (unknown client or no cycles): hand back the
            // caller-scoped view with no events, never claim the table ended.
            return {
              tableId = req.tableId;
              seq = Table.seqOf(s);
              lowWater = 1;
              fullSync = true;
              phase = s.phase;
              events = [];
              view = Table.viewWithClient(s, msg.caller, req.clientId);
            };
          };
          case null {};
        };
        Table.pollWithClient(s, msg.caller, req.clientId, req.afterSeq);
      };
      case null {
        {
          tableId = req.tableId;
          seq = 0;
          lowWater = 1;
          fullSync = true;
          phase = #Ended;
          events = [];
          view = emptyView(req.tableId);
        };
      };
    };
  };

  func emptyView(id : Types.TableId) : Types.PlayerView {
    {
      tableId = id;
      dealNo = 0;
      epoch = 1;
      endingTime = 0;
      phase = #Ended;
      level = 2;
      trump = null;
      decl = null;
      config = Types.defaultConfig;
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
