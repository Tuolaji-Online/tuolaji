/// Table state and the lobby/deal protocol surface.
///
/// M2 added the registry entry, lobby (join/leave/ready), the event log with
/// cursor/full-sync semantics, and the principal-scoped `PlayerView`.
/// M3 adds the dealing tick loop, trump declarations, and bury/kitty handling;
/// M4 adds the trick play loop, trick resolution, kitty scoop, scoring, level
/// progression, and the next-deal transition.
///
/// Persistence (M5/B6): `State` is an enhanced-orthogonal-persistence stable
/// type — every field is a primitive, a `var`, an array/tuple, an option, a
/// variant, a `List`, or a `Combo.Lead`, none of which carry closures or
/// references. The actor therefore persists tables across upgrades without
/// an explicit `TableInternal` mirror.
import Array "mo:core/Array";
import Blob "mo:core/Blob";
import Debug "mo:core/Debug";
import List "mo:core/List";
import Nat "mo:core/Nat";
import Principal "mo:core/Principal";
import Text "mo:core/Text";
import VarArray "mo:core/VarArray";
import Card "Card";
import Basic "Basic";
import Combo "Combo";
import Follow "Follow";
import Lead "Lead";
import Scoring "Scoring";
import Shuffle "Shuffle";
import Trick "Trick";
import Trump "Trump";
import Types "Types";

module {
  /// How long an explicitly ended table is kept in the registry before
  /// `sweepEnded` removes it: long enough for players to review past games via
  /// `getPlayHistory`, while still freeing the per-principal cap slot and
  /// registry memory.
  public let ENDED_RETENTION_NANOS : Int = 172_800_000_000_000; // 2 days

  /// How long a table may go without emitting an event before it is considered
  /// idle. Idle tables are hidden from `listTables` and ended by the next
  /// `createTable`/`joinTable`, so abandoned tables cannot be joined or linger.
  public let IDLE_RETENTION_NANOS : Int = 600_000_000_000; // 10 minutes

  /// The idle window for a private table: an invitation link may be opened long
  /// after the table was created, so it is kept for 48 hours rather than 10
  /// minutes. See `idleRetention`.
  public let PRIVATE_IDLE_RETENTION_NANOS : Int = 172_800_000_000_000; // 48 hours

  /// How often the timer retries an auto-play whose heuristic move was
  /// rejected, so a bug cannot leave a turn with no armed deadline.
  public let AUTO_RETRY_NANOS : Int = 5_000_000_000; // 5 seconds

  /// Short deadline armed for a seat that has no owner (a leaver mid-deal),
  /// so the timer drives its turns and bury instead of waiting forever on a
  /// config with null timeouts.
  public let EMPTY_SEAT_NANOS : Int = 1_000_000_000; // 1 second

  /// Longest avatar id string accepted from a client. Client text is an attack
  /// vector, so the canister bounds each field tightly (20 chars is far more
  /// than any preset/style id) and rejects anything empty or longer.
  public let MAX_AVATAR_FIELD : Nat = 20;

  /// Longest accepted auth code. Short enough to read off an invitation link.
  public let MAX_AUTH_CODE : Nat = 8;

  public type State = {
    id : Types.TableId;
    var phase : Types.Phase;
    var cfg : Types.TableConfig;
    var seq : Types.Seq;
    var log : List.List<Types.Event>;
    var lowWater : Types.Seq;
    var seats : [var ?Types.SeatOwner];
    // Cosmetic avatar chosen by each seat's human, for consistent rendering.
    var avatars : [var ?Types.Avatar];
    var ready : [var Bool];
    var dealNo : Nat;
    var level : Types.Level;
    var teamLevel : [var Types.Level]; // per-partnership levels, indexed by seat % 2
    var teamEpoch : [var Nat]; // per-partnership epochs, indexed by seat % 2
    var bankTeam : ?Nat; // partnership (seat % 2) that owns the bank; null until decided
    var banker : ?Types.Seat;
    var lastBanker : [var ?Types.Seat]; // last banker per partnership, for alternation
    var dealer : Types.Seat; // who first receives dealt cards, rotate between 4 seats.
    var trump : ?Types.Suit;
    var decl : ?Types.Declaration;
    var hands : [var [Card.Card]];
    var kitty : [Card.Card];
    var deck : [Card.Card];
    var dealEntropy : Blob;
    var dealIdx : Nat;
    var dealComplete : Bool;
    var declareDeadline : ?Types.Timestamp;
    // Length in seconds of the currently armed declaration window, so the
    // client can render the countdown ring against the right total.
    var declareTotal : ?Nat;
    var firstSeat : Types.Seat;
    var nextDealAt : ?Types.Timestamp;
    var buryDeadline : ?Types.Timestamp;
    var nextSeat : Types.Seat;
    var deadline : ?Types.Timestamp;
    var trick : List.List<Trick.Play>;
    var lead : ?Combo.Lead;
    var leadCards : [Card.Card];
    var trickNo : Nat;
    var bankerPoints : Nat;
    var attackerPoints : Nat;
    // Per-deal count of each pair key (0..53) already played. Tracked and
    // persisted for the table's own accounting; the basic auto-play ignores it.
    // Reset at the start of every deal.
    var played : [Nat];
    // Per-deal void table (`seat * 5 + category`, four side suits + trump),
    // inferred from off-suit follows. Tracked and persisted; the basic
    // auto-play ignores it. Reset at the start of every deal.
    var voids : [Bool];
    var kittyRevealed : Bool;
    var startedAt : Types.Timestamp;
    // Set once at creation. A private table is hidden from the live listings,
    // keeps a 48-hour idle window and never auto-ends with no humans. A table
    // is private exactly when this is non-null (see `isPrivate`).
    authCode : ?Text;
    // Server time by which the table is idle (no event since
    // `endingTime - idleRetention(id)`) and should be treated as ended.
    // Extended to `now + idleRetention(id)` on every event, so clients can
    // decide locally that the table is over.
    var endingTime : Types.Timestamp;
    var endedAt : ?Types.Timestamp;
    var lastTrick : ?Types.TrickRecord;
  };

  // ── helpers ────────────────────────────────────────────────────────

  /// Match a seat by principal only (any client id). Used where the caller is
  /// a user, a legacy test, or a principal-membership check. Multi-seat clients
  /// use `seatOfClient`.
  public func seatOf(st : State, who : Principal) : ?Types.Seat {
    var i = 0;
    var found : ?Types.Seat = null;
    while (i < 4 and found == null) {
      switch (st.seats[i]) {
        case (?o) { if (Principal.equal(o.principal, who)) { found := ?i } };
        case null {};
      };
      i += 1;
    };
    found;
  };

  /// Match a seat by `(principal, clientId)`. This is the exact identity a
  /// browser (clientId = null) or a bot canister (clientId = a per-seat label)
  /// registers with, so one principal can own several seats.
  public func seatOfClient(st : State, who : Principal, clientId : ?Types.ClientId) : ?Types.Seat {
    var i = 0;
    var found : ?Types.Seat = null;
    while (i < 4 and found == null) {
      switch (st.seats[i]) {
        case (?o) {
          if (Principal.equal(o.principal, who) and o.clientId == clientId) { found := ?i };
        };
        case null {};
      };
      i += 1;
    };
    found;
  };

  /// True when the principal already owns any seat in this table, regardless of
  /// client id. Used to enforce the one-seat-per-table rule for non-bots.
  public func principalHasSeat(st : State, who : Principal) : Bool {
    seatOf(st, who) != null;
  };

  /// A table is private exactly when it has an auth code. The flag is derived
  /// rather than stored, so the two can never disagree.
  public func isPrivate(st : State) : Bool {
    st.authCode != null;
  };

  /// True when `who` owns an occupied seat other than `seat`. Lets a principal
  /// attach to a seat already claimed for it without tripping the
  /// one-seat-per-table rule.
  public func ownsSeatOtherThan(st : State, who : Principal, seat : Types.Seat) : Bool {
    var i = 0;
    var found = false;
    while (i < 4 and not found) {
      if (i != seat) {
        switch (st.seats[i]) {
          case (?o) { if (Principal.equal(o.principal, who)) { found := true } };
          case null {};
        };
      };
      i += 1;
    };
    found;
  };

  // ── canister client registry ─────────────────────────────────────

  /// Index of the seat owned by `(principal, clientId)`, if any.
  func clientIndexOf(st : State, principal : Principal, clientId : ?Types.ClientId) : ?Nat {
    var i = 0;
    var found : ?Nat = null;
    while (i < 4 and found == null) {
      switch (st.seats[i]) {
        case (?o) {
          if (Principal.equal(o.principal, principal) and o.clientId == clientId) { found := ?i };
        };
        case null {};
      };
      i += 1;
    };
    found;
  };

  /// True when `(principal, clientId)` has an attached push client.
  public func hasClient(st : State, principal : Principal, clientId : ?Types.ClientId) : Bool {
    switch (clientIndexOf(st, principal, clientId)) {
      case (?i) { switch (st.seats[i]) { case (?o) { o.client != null }; case null { false } } };
      case null { false };
    };
  };

  /// Attach a push client to the seat owned by `(principal, clientId)`,
  /// seeding its cursor at the current sequence so it only receives events
  /// after the seat is taken. Idempotent; `seat` is accepted for call-site
  /// compatibility but the seat is derived from the owner key.
  public func addClient(st : State, principal : Principal, clientId : ?Types.ClientId, seat : Types.Seat) {
    ignore seat;
    switch (clientIndexOf(st, principal, clientId)) {
      case (?i) {
        switch (st.seats[i]) {
          case (?o) {
            if (o.client == null) {
              st.seats[i] := ?{ o with client = ?{ cursor = st.seq; cycles = 0 } };
            };
          };
          case null {};
        };
      };
      case null {};
    };
  };

  /// Detach the push client for `(principal, clientId)`, keeping the seat.
  public func removeClient(st : State, principal : Principal, clientId : ?Types.ClientId) {
    switch (clientIndexOf(st, principal, clientId)) {
      case (?i) {
        switch (st.seats[i]) {
          case (?o) { st.seats[i] := ?{ o with client = null } };
          case null {};
        };
      };
      case null {};
    };
  };

  func updateClient(
    st : State,
    principal : Principal,
    clientId : ?Types.ClientId,
    f : Types.ClientSub -> Types.ClientSub,
  ) {
    switch (clientIndexOf(st, principal, clientId)) {
      case (?i) {
        switch (st.seats[i]) {
          case (?o) {
            switch (o.client) {
              case (?c) { st.seats[i] := ?{ o with client = ?f(c) } };
              case null {};
            };
          };
          case null {};
        };
      };
      case null {};
    };
  };

  /// Record a successful push up to `cursor`.
  public func advanceCursor(st : State, principal : Principal, clientId : ?Types.ClientId, cursor : Types.Seq) {
    updateClient(st, principal, clientId, func(c) { { c with cursor } });
  };

  /// Accumulate the ingress cycles accepted for a subscription.
  public func bumpCycles(st : State, principal : Principal, clientId : ?Types.ClientId, cycles : Nat) {
    updateClient(st, principal, clientId, func(c) { { c with cycles = c.cycles + cycles } });
  };

  /// The seats with an attached push client, for the actor's push loop.
  public func clientsOf(st : State) : [Types.SeatOwner] {
    let out = List.empty<Types.SeatOwner>();
    var i = 0;
    while (i < 4) {
      switch (st.seats[i]) {
        case (?o) { if (o.client != null) { out.add(o) } };
        case null {};
      };
      i += 1;
    };
    out.toArray();
  };

  /// The events after `cursor` visible to `(principal, clientId)`, with a
  /// `fullSync` flag raised when the cursor predates the retained log or the
  /// per-push cap truncates (mirrors `poll`'s 512-event cap).
  /// Events after `watermark` that `principal` can see: public events plus
  /// `HandUpdated` for the seats it holds a client for, each only after that
  /// seat's own cursor. One batch per client canister, used for the
  /// table-scoped push.
  public func eventsForPrincipal(st : State, principal : Principal, watermark : Types.Seq) : Types.EventBatch {
    let maxEvents : Nat = 512;
    var count = 0;
    let events = List.empty<Types.Event>();
    for (e in st.log.values()) {
      if (e.seq > watermark and visibleToPrincipal(st, principal, e)) {
        count += 1;
        if (count <= maxEvents) { events.add(e) };
      };
    };
    let truncated = count > maxEvents;
    let gap = watermark + 1 < st.lowWater;
    {
      events = if (truncated) { [] } else { events.toArray() };
      fullSync = gap or truncated;
    };
  };

  /// A push to `principal` may carry a private `HandUpdated` only for a seat
  /// its own client registration covers, and only for events after that
  /// seat's cursor: a seat the principal merely owns (e.g. a seat claimed for
  /// it but not yet joined) is not pushed, and a newly attached client never
  /// sees hand updates from before it attached. Every other event is public.
  func visibleToPrincipal(st : State, principal : Principal, e : Types.Event) : Bool {
    switch (e.body) {
      case (#HandUpdated(p)) {
        switch (st.seats[p.seat]) {
          case (?o) {
            Principal.equal(o.principal, principal) and
            (switch (o.client) {
              case (?c) { e.seq > c.cursor };
              case null { false };
            });
          };
          case null { false };
        };
      };
      case _ { true };
    };
  };

  public func eventsAfter(
    st : State,
    principal : Principal,
    clientId : ?Types.ClientId,
    cursor : Types.Seq,
  ) : Types.EventBatch {
    let maxEvents : Nat = 512;
    var count = 0;
    let events = List.empty<Types.Event>();
    for (e in st.log.values()) {
      if (e.seq > cursor and isVisible(st, principal, clientId, e)) {
        count += 1;
        if (count <= maxEvents) { events.add(e) };
      };
    };
    let truncated = count > maxEvents;
    let gap = cursor + 1 < st.lowWater;
    {
      events = if (truncated) { [] } else { events.toArray() };
      fullSync = gap or truncated;
    };
  };

  public func occupied(st : State) : Nat {
    filledCount(st);
  };

  /// A seat is filled when a principal owns it.
  public func filledCount(st : State) : Nat {
    var n = 0;
    var i = 0;
    while (i < 4) {
      if (st.seats[i] != null) { n += 1 };
      i += 1;
    };
    n;
  };

  /// True when a seat is completely free for a plain join.
  func hasEmptySeat(st : State) : Bool {
    var i = 0;
    while (i < 4) {
      if (st.seats[i] == null) { return true };
      i += 1;
    };
    false;
  };

  /// Clear every seat's readiness. Called when a deal is abandoned so each
  /// seat has to ready again.
  func resetReady(st : State) {
    var i = 0;
    while (i < 4) {
      st.ready[i] := false;
      i += 1;
    };
  };

  /// Install creation-time seat claims. Entry `i` claims seat `i` for a
  /// principal that will attach to it later; seat 0 is the creator and is
  /// ignored, as is any entry past the vector. A null entry leaves the seat
  /// open.
  public func assignReserved(st : State, reserved : [?Principal]) {
    var i = 1;
    while (i < 4 and i < reserved.size()) {
      switch (reserved[i]) {
        case (?p) {
          if (st.seats[i] == null) {
            st.seats[i] := ?{ principal = p; clientId = null; client = null; takenAt = st.seq; replaceable = false };
          };
        };
        case null {};
      };
      i += 1;
    };
  };

  func append(st : State, now : Types.Timestamp, body : Types.EventBody) : Types.Seq {
    st.seq += 1;
    st.log.add({ seq = st.seq; at = now; body });
    // Any event is activity: push the idle deadline out.
    st.endingTime := now + idleRetention(isPrivate(st));
    st.seq;
  };

  /// The idle window before a table is swept to `Ended`: private tables are
  /// kept for 48 hours (an invitee may be slow), public tables for 10 minutes.
  func idleRetention(privateTable : Bool) : Int {
    if (privateTable) { PRIVATE_IDLE_RETENTION_NANOS } else { IDLE_RETENTION_NANOS };
  };

  func ok(st : State) : Types.ActionResult {
    #ok({ seq = st.seq; penalized = false });
  };

  func err(st : State, code : Types.ErrorCode, detail : Text) : Types.ActionResult {
    #err({ seq = st.seq; code; detail });
  };

  /// A join hint: an explicit replaceable flag, else false (a human seat).
  func replaceableOf(b : ?Bool) : Bool {
    switch (b) { case (?v) { v }; case null { false } };
  };

  func allReady(st : State) : Bool {
    if (filledCount(st) != 4) { return false };
    var i = 0;
    var all = true;
    while (i < 4) {
      if (not st.ready[i]) { all := false };
      i += 1;
    };
    all;
  };

  // ── construction ───────────────────────────────────────────────────

  public func new(
    id : Types.TableId,
    cfg : Types.TableConfig,
    creator : Principal,
    now : Types.Timestamp,
  ) : State {
    newWithClient(id, cfg, creator, null, now, null, null)
  };

  public func newWithClient(
    id : Types.TableId,
    cfg : Types.TableConfig,
    creator : Principal,
    clientId : ?Types.ClientId,
    now : Types.Timestamp,
    avatar : ?Types.Avatar,
    authCode : ?Text,
  ) : State {
    let st : State = {
      id;
      var phase = #Lobby;
      var cfg;
      var seq = 0;
      var log = List.empty();
      var lowWater = 1;
      var seats = [var ?{ principal = creator; clientId; client = null; takenAt = 0; replaceable = false }, null, null, null];
      var avatars = [var avatar, null, null, null];
      var ready = [var false, false, false, false];
      var dealNo = 0;
      var level = 2;
      var teamLevel = [var 2, 2];
      var teamEpoch = [var 1, 1];
      var bankTeam = null;
      var banker = null;
      var lastBanker = [var null, null];
      var dealer = cfg.firstDealer;
      var trump = null;
      var decl = null;
      var hands = [var [], [], [], []];
      var kitty = [];
      var deck = [];
      var dealEntropy = "";
      var dealIdx = 0;
      var dealComplete = false;
      var declareDeadline = null;
      var declareTotal = null;
      var firstSeat = (cfg.firstDealer + 1) % 4;
      var nextDealAt = null;
      var buryDeadline = null;
      var nextSeat = cfg.firstDealer;
      var deadline = null;
      var trick = List.empty<Trick.Play>();
      var lead = null;
      var leadCards = [];
      var trickNo = 0;
      var bankerPoints = 0;
      var attackerPoints = 0;
      var played = Basic.emptyPlayed();
      var voids = Basic.emptyVoids();
      var kittyRevealed = false;
      var startedAt = now;
      authCode;
      var endingTime = now + idleRetention(authCode != null);
      var endedAt = null;
      var lastTrick = null;
    };
    // Record the creator's avatar in the log so past-table records (which
    // reconstruct participants from `PlayerJoined`) keep the chosen style.
    ignore append(st, now, #PlayerJoined({ seat = 0; who = creator; avatar }));
    st;
  };

  // ── lobby ──────────────────────────────────────────────────────────

  /// Take a specific seat (the lobby seat picker). An open seat can only be
  /// taken in the lobby; a claimed seat only by its principal.
  public func joinTable(
    st : State,
    caller : Principal,
    seat : Types.Seat,
    now : Types.Timestamp,
  ) : Types.ActionResult {
    joinTableWithClient(st, caller, null, seat, null, null, now);
  };

  /// Take a specific seat, storing the caller's avatar with it.
  public func joinTableWithAvatar(
    st : State,
    caller : Principal,
    seat : Types.Seat,
    avatar : ?Types.Avatar,
    now : Types.Timestamp,
  ) : Types.ActionResult {
    joinTableWithClient(st, caller, null, seat, avatar, null, now);
  };

  /// Client-id-aware join. Uniqueness is `(principal, clientId)`, so a canister
  /// client can take several seats (the actor enforces the operator whitelist
  /// before calling this).
  ///
  /// A seat is *open* (`null`), *claimed* (owned by a principal with no push
  /// client yet), or *attached* (owned with a push client). An open seat can
  /// only be taken in the lobby; a claimed seat can only be attached by the
  /// principal it is claimed for, at any phase, so a canister can take over a
  /// seat mid-deal.
  public func joinTableWithClient(
    st : State,
    caller : Principal,
    clientId : ?Types.ClientId,
    seat : Types.Seat,
    avatar : ?Types.Avatar,
    replaceable : ?Bool,
    now : Types.Timestamp,
  ) : Types.ActionResult {
    if (seat >= 4) { return err(st, #NotASeat, "invalid seat") };
    switch (seatOfClient(st, caller, clientId)) {
      case (?s) {
        // Already seated under this identity. Accept a refreshed avatar so a
        // client that took the seat over can set it on its follow-up join, but
        // still report AlreadyJoined.
        if (s == seat) {
          if (not validAvatar(avatar)) { return err(st, #InvalidAvatar, "invalid avatar") };
          st.avatars[s] := avatar;
          switch (replaceable) {
            case (?v) { switch (st.seats[s]) { case (?o) { st.seats[s] := ?{ o with replaceable = v } }; case null {} } };
            case null {};
          };
        };
        return err(st, #AlreadyJoined, "already seated");
      };
      case null {};
    };
    if (st.phase == #Ended) { return err(st, #TableEnded, "table has ended") };
    if (not validAvatar(avatar)) { return err(st, #InvalidAvatar, "invalid avatar") };
    switch (st.seats[seat]) {
      case null {
        // An open seat can be taken in the lobby, in `#Scoring` so a seat that
        // emptied mid-deal is refilled before the next deal, or mid-deal in a
        // private table — invite-only, so the invitee may take over the
        // abandoned, auto-played seat.
        if (st.phase != #Lobby and st.phase != #Scoring and not isPrivate(st)) {
          return err(st, #NotInLobby, "not in lobby");
        };
        st.seats[seat] := ?{ principal = caller; clientId; client = null; takenAt = st.seq; replaceable = replaceableOf(replaceable) };
        st.ready[seat] := false;
        st.avatars[seat] := avatar;
        ignore append(st, now, #PlayerJoined({ seat; who = caller; avatar }));
        ok(st);
      };
      case (?o) {
        // A claimed seat can only be attached by its principal, and only while
        // no client is attached yet.
        if (not Principal.equal(o.principal, caller)) {
          return err(st, #LobbyFull, "seat taken");
        };
        switch (o.client) {
          case (?_) { return err(st, #LobbyFull, "seat taken") };
          case null {
            let flag = switch (replaceable) { case (?v) { v }; case null { o.replaceable } };
            st.seats[seat] := ?{ o with clientId; takenAt = st.seq; replaceable = flag };
            st.avatars[seat] := avatar;
            ignore append(st, now, #PlayerJoined({ seat; who = caller; avatar }));
            ok(st);
          };
        };
      };
    };
  };

  /// Leave the table in any live phase; when the last seat empties the table
  /// ends (freeing the per-principal cap) and emits `TableEnded`. `reserveFor`
  /// controls what happens to the vacated seat:
  ///
  /// - `?p`: the seat is claimed for `p` (e.g. the trusted bot principal) and
  ///   the deal keeps playing (the seat's hand is kept), so `p` can attach and
  ///   take over mid-deal. The claim is silent; `p`'s own join announces it.
  /// - `null`: the seat is left open but an in-progress deal keeps playing —
  ///   the timer auto-plays the empty seat, so leaving cannot dodge the deal's
  ///   result. The deal is scored normally; the seat can be rejoined in the
  ///   lobby or the next `#Scoring` phase.
  public func leave(
    st : State,
    caller : Principal,
    reserveFor : ?Principal,
    now : Types.Timestamp,
  ) : Types.ActionResult {
    leaveWithClient(st, caller, null, reserveFor, now);
  };

  public func leaveWithClient(
    st : State,
    caller : Principal,
    clientId : ?Types.ClientId,
    reserveFor : ?Principal,
    now : Types.Timestamp,
  ) : Types.ActionResult {
    switch (seatOfClient(st, caller, clientId)) {
      case null { err(st, #NotASeat, "not seated") };
      case (?s) {
        if (st.phase == #Ended) { return err(st, #TableEnded, "table has ended") };
        st.seats[s] := null;
        st.avatars[s] := null;
        removeClient(st, caller, clientId);
        ignore append(st, now, #PlayerLeft({ seat = s }));
        switch (reserveFor) {
          case (?p) {
            // Claim the seat in place and keep the deal playing; the hand is
            // preserved, so timeout auto-play covers the gap until `p`
            // attaches. Claiming before the empty check is what keeps a
            // hand-over from ending the table.
            st.seats[s] := ?{ principal = p; clientId = null; client = null; takenAt = st.seq; replaceable = false };
            st.ready[s] := false;
          };
          case null {
            st.ready[s] := false;
            ensureEmptySeatProgress(st, s, now);
          };
        };
        // A private table stays open when it empties: an invitee may still
        // arrive through its link inside the 48-hour window. A public table
        // that has lost every player is finished.
        if (filledCount(st) == 0 and not isPrivate(st)) {
          finishTable(st, now, #Empty);
        };
        ok(st);
      };
    };
  };

  /// A null avatar is fine; otherwise both ids must be non-empty and bounded.
  /// Client text is an attack vector, so the canister rejects anything empty or
  /// longer than `MAX_AVATAR_FIELD`.
  public func validAvatar(avatar : ?Types.Avatar) : Bool {
    switch (avatar) {
      case null { true };
      case (?a) {
        let p = Text.size(a.preset);
        let s = Text.size(a.style);
        p > 0 and p <= MAX_AVATAR_FIELD and s > 0 and s <= MAX_AVATAR_FIELD;
      };
    };
  };

  /// A valid auth code is null (a public table) or 1..MAX_AUTH_CODE characters.
  public func validAuthCode(code : ?Text) : Bool {
    switch (code) {
      case null { true };
      case (?c) { let n = Text.size(c); n > 0 and n <= MAX_AUTH_CODE };
    };
  };

  /// Mark a table ended (every player left, or it went idle). This is what
  /// releases the table from the per-principal and global caps.
  func finishTable(st : State, now : Types.Timestamp, reason : Types.TableEndReason) {
    if (st.phase == #Ended) { return };
    st.phase := #Ended;
    st.endedAt := ?now;
    st.deadline := null;
    st.buryDeadline := null;
    st.nextDealAt := null;
    let bt = bankTeamOf(st);
    let winner : Types.Team = if (st.teamLevel[bt] >= st.teamLevel[otherTeam(bt)]) { #Bankers } else { #Attackers };
    ignore append(st, now, #TableEnded({
      winner;
      bankerLevel = st.teamLevel[bt];
      attackerLevel = st.teamLevel[otherTeam(bt)];
      reason;
    }));
  };

  /// End the table when no human-owned seat remains: every occupied seat is
  /// owned by a whitelisted bot (an empty table is already ended by `leave`).
  /// `isBot` classifies a seat owner against the actor's bot whitelist. The
  /// table config's `endWhenAllBots` gates the check so all-bot test tables can
  /// keep running. Returns true when it ended the table.
  public func endIfNoHumans(
    st : State,
    isBot : Principal -> Bool,
    now : Types.Timestamp,
  ) : Bool {
    // A private table is never ended for want of humans: its seats may still be
    // filled through invitation links.
    if (isPrivate(st)) { return false };
    if (not st.cfg.endWhenAllBots) { return false };
    if (st.phase == #Ended) { return false };
    var noHumans = true;
    var i = 0;
    while (i < 4 and noHumans) {
      switch (st.seats[i]) {
        case (?o) { if (not isBot(o.principal)) { noHumans := false } };
        case null {};
      };
      i += 1;
    };
    if (noHumans) {
      finishTable(st, now, #Empty);
      true;
    } else {
      false;
    };
  };

  /// True when the table has reached its idle deadline (`endingTime`) and has
  /// not already ended. `endingTime` is extended on every event, so this is a
  /// stored value both the server and its clients can compare against.
  public func isIdle(st : State, now : Types.Timestamp) : Bool {
    if (st.phase == #Ended) { return false };
    now > st.endingTime;
  };

  /// True when the lobby listing should treat the table as over: it has reached
  /// its idle deadline. Used to bucket it with the ended tables; it is swept to
  /// `#Ended` by the next registry change.
  public func isOver(st : State, now : Types.Timestamp) : Bool {
    isIdle(st, now);
  };

  /// End a table that has gone idle. Returns true when it was ended.
  public func endIfIdle(st : State, now : Types.Timestamp) : Bool {
    if (not isIdle(st, now)) { return false };
    finishTable(st, now, #Idle);
    true;
  };

  public func ready(st : State, caller : Principal, now : Types.Timestamp) : Types.ActionResult {
    readyWithClient(st, caller, null, now);
  };

  public func readyWithClient(
    st : State,
    caller : Principal,
    clientId : ?Types.ClientId,
    now : Types.Timestamp,
  ) : Types.ActionResult {
    switch (seatOfClient(st, caller, clientId)) {
      case null { return err(st, #NotASeat, "not seated") };
      case (?s) {
        if (st.phase != #Lobby and st.phase != #Scoring) {
          return err(st, #NotInLobby, "not in lobby");
        };
        if (not st.ready[s]) {
          st.ready[s] := true;
          ignore append(st, now, #PlayerReady({ seat = s }));
        };
        if (allReady(st)) { beginDeal(st) };
        ok(st);
      };
    };
  };

  // ── dealing ────────────────────────────────────────────────────────

  /// Reset per-deal state and enter `#Dealing`. The deck is installed by a
  /// later `startDeal` (actor, after `Random.blob()`) or `installDeck` (tests).
  func beginDeal(st : State) {
    st.phase := #Dealing;
    st.dealNo += 1;
    st.deck := [];
    st.dealEntropy := "";
    // The deal is played at the banking team's own level. A brand-new
    // table (bank not yet decided) starts at level 2 for both teams.
    st.level := switch (st.bankTeam) { case (?bt) { st.teamLevel[bt] }; case null { 2 } };
    st.dealIdx := 0;
    st.dealComplete := false;
    st.declareDeadline := null;
    st.declareTotal := null;
    st.hands := [var [], [], [], []];
    st.kitty := [];
    st.banker := null;
    st.trump := null;
    st.decl := null;
    st.firstSeat := (st.dealer + 1) % 4;
    st.nextSeat := st.dealer;
    st.nextDealAt := null;
    st.buryDeadline := null;
    st.deadline := null;
    st.trick := List.empty();
    st.lead := null;
    st.leadCards := [];
    st.trickNo := 0;
    st.bankerPoints := 0;
    st.attackerPoints := 0;
    st.played := Basic.emptyPlayed();
    st.voids := Basic.emptyVoids();
    st.kittyRevealed := false;
    st.lastTrick := null;
  };

  /// True once a deal has begun but no shuffle has been installed yet. The
  /// actor awaits `Random.blob()` while this is true, then calls `startDeal`.
  public func needsShuffle(st : State) : Bool {
    st.phase == #Dealing and st.deck.size() == 0
  };

  func secondsToNanos(seconds : Nat) : Int {
    Nat.toInt(seconds) * 1_000_000_000
  };

  func gameOf(st : State) : Card.Game {
    {
      level = st.level;
      trump = switch (st.trump) { case (?t) t; case null Card.NT };
    }
  };

  /// The empty seat's hand is played by the timer. If the config would leave
  /// the current turn or bury without a deadline, arm a short one so the
  /// scheduler does not stall on a seat that can no longer act.
  func ensureEmptySeatProgress(st : State, s : Types.Seat, now : Types.Timestamp) {
    let tick = now + EMPTY_SEAT_NANOS;
    if (st.phase == #Playing and st.nextSeat == s and st.deadline == null) {
      st.deadline := ?tick;
    };
    if (st.phase == #Burying and st.banker == ?s and st.buryDeadline == null) {
      st.buryDeadline := ?tick;
    };
  };

  /// Begin `seat`'s turn and record the configured deadline for display; the
  /// scheduler auto-plays the seat if the deadline passes. An ownerless seat
  /// always gets a deadline so the timer keeps the deal moving.
  func startTurn(st : State, seat : Types.Seat, now : Types.Timestamp) {
    st.nextSeat := seat;
    st.deadline := if (st.cfg.playSeconds > 0) {
      ?(now + secondsToNanos(st.cfg.playSeconds))
    } else if (st.seats[seat] == null) {
      ?(now + EMPTY_SEAT_NANOS)
    } else {
      null
    };
  };

  /// Arm or extend the declaration deadline. The deadline only ever moves
  /// later, so an early declaration cannot shorten the initial
  /// `declareSeconds` window, and every declaration still guarantees at least
  /// `overrideSeconds` from the call.
  func armDeclareDeadline(st : State, seconds : Nat, now : Types.Timestamp) {
    if (seconds == 0) {
      // No window: lock the trump as soon as the deck is out (or immediately
      // after a call).
      st.declareDeadline := null;
      st.declareTotal := null;
    } else {
      let proposed = now + secondsToNanos(seconds);
      switch (st.declareDeadline) {
        case (?cur) {
          if (proposed > cur) {
            st.declareDeadline := ?proposed;
            st.declareTotal := ?seconds;
          };
        };
        case null {
          st.declareDeadline := ?proposed;
          st.declareTotal := ?seconds;
        };
      };
    };
  };

  /// Install a shuffled deck and start dealing. Idempotent.
  public func startDeal(st : State, entropy : Blob, now : Types.Timestamp) {
    if (not needsShuffle(st)) { return };
    // Keep the entropy so the shuffle can be replayed and audited once the
    // deal is scored (`#ShuffleRevealed`).
    st.dealEntropy := entropy;
    installDeck(st, Shuffle.shuffleWithEntropy(Shuffle.newDeck(), entropy), now);
  };

  /// Install an explicit deck (tests / deterministic replay) and emit
  /// `DealStarted` followed by the first dealing packet.
  public func installDeck(st : State, deck : [Card.Card], now : Types.Timestamp) {
    if (not needsShuffle(st)) { return };
    st.deck := deck;
    st.dealIdx := 0;
    st.nextDealAt := null;
    ignore append(st, now, #DealStarted({ dealNo = st.dealNo; dealer = st.dealer; level = st.level }));
    // Deal the first packet immediately so a poll right after `ready` sees cards.
    ignore dealTick(st, now);
  };

  /// Deal one card to each seat, wrapping every 4 cards starting at the seat
  /// after the dealer. Returns true when the state advanced.
  public func dealTick(st : State, now : Types.Timestamp) : Bool {
    if (st.phase != #Dealing) { return false };
    if (st.deck.size() == 0) { return false };
    switch (st.nextDealAt) {
      case (?t) { if (now < t) { return false } };
      case null {};
    };
    var dealt = 0;
    while (dealt < 4 and st.dealIdx < 100) {
      let seat = (st.firstSeat + st.dealIdx) % 4;
      let card = st.deck[st.dealIdx];
      st.hands[seat] := Array.concat(st.hands[seat], [card]);
      ignore append(st, now, #DealTick({ dealt = st.dealIdx + 1; toSeat = seat }));
      ignore append(st, now, #HandUpdated({ seat; added = [card]; hand = st.hands[seat] }));
      st.dealIdx += 1;
      dealt += 1;
    };
    if (st.dealIdx >= 100) {
      st.nextDealAt := null;
      if (not st.dealComplete) {
        st.dealComplete := true;
        // The declaration timer only starts once every card is out. A call
        // made while the deck is still running leaves no window behind; the
        // deck end arms the counter-declaration window for it. With no call
        // at all, the longer post-deal window opens. A call that nothing can
        // answer (a No-Trump joker pair, or any pair when enhanced joker
        // override is off) needs no window, so drop it and let the check
        // below go straight to the kitty.
        switch (st.decl) {
          case null { armDeclareDeadline(st, st.cfg.declareSeconds, now) };
          case (?d) {
            if (Trump.isTerminal(d, st.cfg.enhancedJokerOverride)) {
              st.declareDeadline := null;
              st.declareTotal := null;
            } else {
              armDeclareDeadline(st, st.cfg.overrideSeconds, now);
            };
          };
        };
      };
      ignore checkDealWindow(st, now);
    } else {
      st.nextDealAt := ?(now + secondsToNanos(st.cfg.dealTickSeconds));
    };
    true;
  };

  /// Once the deck is exhausted, wait out the declaration window before
  /// locking the trump and moving to `#Burying`. Returns true when finalised.
  public func checkDealWindow(st : State, now : Types.Timestamp) : Bool {
    if (st.phase != #Dealing or not st.dealComplete) { return false };
    switch (st.declareDeadline) {
      case (?d) { if (now < d) { return false } };
      case null {};
    };
    finalizeDeal(st, now);
    true;
  };

  func finalizeDeal(st : State, now : Types.Timestamp) {
    // Nobody declared: default to No-Trump.
    if (st.decl == null) { st.trump := ?Card.NT };
    // The bank is only decided here. In a new table the winning
    // declaration's team takes it; with no declaration at all, seats 0 and 2
    // (team 0) are the bankers.
    let bankUndecided = st.bankTeam == null;
    let bt = switch (st.bankTeam) {
      case (?b) { b };
      case null {
        let b = switch (st.decl) {
          case (?d) { d.seat % 2 };
          case null { 0 };
        };
        st.bankTeam := ?b;
        b;
      };
    };
    // The last 8 cards of the deck are the kitty; the banker receives them.
    let kitty = Array.tabulate<Card.Card>(8, func i = st.deck[100 + i]);
    // Each partnership alternates its banker between its own two seats. A team
    // banking for the first time starts on its lower seat; a takeover resumes
    // that team's own alternation from its own last banker. On the very first
    // bank (before any team owns the bank), the winning declarer takes the seat;
    // with no declaration, team 0 starts on seat 0.
    let bankerSeat = if (bankUndecided) {
      switch (st.decl) {
        case (?d) { d.seat };
        case null { 0 };
      };
    } else {
      switch (st.lastBanker[bt]) {
        case (?pb) { partnerOf(pb) };
        case null { bt };
      };
    };
    st.lastBanker[bt] := ?bankerSeat;
    st.level := st.teamLevel[bt];
    st.banker := ?bankerSeat;
    st.hands[bankerSeat] := Array.concat(st.hands[bankerSeat], kitty);
    st.kitty := kitty;
    st.nextDealAt := null;
    st.declareDeadline := null;
    st.declareTotal := null;
    st.phase := #Burying;
    st.buryDeadline := if (st.cfg.burySeconds > 0) {
      ?(now + secondsToNanos(st.cfg.burySeconds))
    } else if (st.seats[bankerSeat] == null) {
      ?(now + EMPTY_SEAT_NANOS)
    } else {
      null
    };
    st.deadline := st.buryDeadline;
    ignore append(st, now, #KittyReceived({ dealer = bankerSeat; count = 8 }));
    ignore append(st, now, #HandUpdated({ seat = bankerSeat; added = kitty; hand = st.hands[bankerSeat] }));
    ignore append(st, now, #DealEnded({}));
  };

  // ── declare ────────────────────────────────────────────────────────

  public func declareTrump(
    st : State,
    caller : Principal,
    cards : [Card.Card],
    now : Types.Timestamp,
  ) : Types.ActionResult {
    declareTrumpWithClient(st, caller, null, cards, now);
  };

  public func declareTrumpWithClient(
    st : State,
    caller : Principal,
    clientId : ?Types.ClientId,
    cards : [Card.Card],
    now : Types.Timestamp,
  ) : Types.ActionResult {
    switch (seatOfClient(st, caller, clientId)) {
      case null { err(st, #NotASeat, "not seated") };
      case (?s) { applyDeclare(st, s, cards, now) };
    };
  };

  /// Declare for a known seat (used by the public entry point and bot driver).
  func applyDeclare(
    st : State,
    s : Types.Seat,
    cards : [Card.Card],
    now : Types.Timestamp,
  ) : Types.ActionResult {
    if (st.phase != #Dealing) { return err(st, #WrongPhase, "not dealing") };
    if (Card.hasDuplicate(cards)) { return err(st, #DuplicateCard, "duplicate declaration card") };
    // Declarations stay open for the whole deal. Only once the deck is
    // exhausted does the counter-declaration window gate them (it is
    // armed at deck end and re-armed by each accepted declaration), so
    // the trump is final a full window after the last call — except after
    // a call nothing can answer, which needs no window at all.
    switch (st.declareDeadline) {
      case (?d) {
        if (st.dealComplete and now >= d) {
          return err(st, #IllegalDeclaration, "declaration window closed");
        };
      };
      case null {};
    };
    // Declarations are judged against the current deal level and only
    // select the trump suit. The bank team is decided in `finalizeDeal`
    // (the winning declarer's team, or seats 0/2 when nobody declares in
    // a new table).
    switch (Trump.declareTrump(cards, st.hands[s], gameOf(st), s, true, st.decl, st.cfg.enhancedJokerOverride)) {
      case (#Ok(d)) {
        st.decl := ?d;
        st.trump := ?d.suit;
        // Arm the counter-declaration window only once the deck is out; while
        // cards are still being dealt, declarations stay open with no timer.
        // A call nothing can answer needs no window at all. The deadline only
        // extends, so an early call cannot shorten the initial window.
        let terminal = Trump.isTerminal(d, st.cfg.enhancedJokerOverride);
        if (terminal or not st.dealComplete) {
          st.declareDeadline := null;
          st.declareTotal := null;
        } else {
          armDeclareDeadline(st, st.cfg.overrideSeconds, now);
        };
        ignore append(st, now, #TrumpDeclared({ seat = s; kind = d.kind; suit = d.suit }));
        // An unanswerable call once the deck is dealt locks the deal on the
        // spot: the banker picks up the kitty without waiting anyone out.
        if (terminal and st.dealComplete) {
          finalizeDeal(st, now);
        };
        ok(st);
      };
      case (#Reject(e)) { err(st, e.code, e.detail) };
    };
  };

  // ── bury ───────────────────────────────────────────────────────────

  /// The banker's basic bury (`Basic.buryMove`): the 8 least valuable cards,
  /// preferring 0-point cards and non-trumps.
  func autoBuryCards(hand : [Card.Card], game : Card.Game) : [Card.Card] {
    Basic.buryMove(hand, game);
  };

  func placeBury(st : State, seat : Types.Seat, cards : [Card.Card], auto : Bool, now : Types.Timestamp) {
    st.hands[seat] := Card.difference(st.hands[seat], cards);
    st.kitty := cards;
    st.buryDeadline := null;
    st.phase := #Playing;
    startTurn(st, seat, now);
    ignore append(st, now, #KittyBuried({ dealer = seat; count = 8; auto }));
    // Re-emit the banker's hand after the bury (private to that seat). A bury
    // the server auto-plays on timeout otherwise leaves a push-based client
    // (the bot) holding the eight buried cards, so every later play is
    // rejected as "card not in hand". The buried cards stay hidden: only the
    // remaining hand is sent, and only to the banker.
    ignore append(st, now, #HandUpdated({ seat; added = []; hand = st.hands[seat] }));
    ignore append(st, now, #TurnStarted({ seat; lead = null; deadline = st.deadline }));
  };

  public func buryKitty(
    st : State,
    caller : Principal,
    cards : [Card.Card],
    now : Types.Timestamp,
  ) : Types.ActionResult {
    buryKittyWithClient(st, caller, null, cards, now);
  };

  public func buryKittyWithClient(
    st : State,
    caller : Principal,
    clientId : ?Types.ClientId,
    cards : [Card.Card],
    now : Types.Timestamp,
  ) : Types.ActionResult {
    switch (seatOfClient(st, caller, clientId)) {
      case null { return err(st, #NotASeat, "not seated") };
      case (?s) {
        if (st.phase != #Burying) { return err(st, #WrongPhase, "not burying") };
        switch (st.banker) {
          case (?b) { if (b != s) { return err(st, #NotKittyOwner, "not the banker") } };
          case null { return err(st, #NotKittyOwner, "no banker") };
        };
        if (cards.size() != 8) { return err(st, #KittySizeMismatch, "must bury 8 cards") };
        if (Card.hasDuplicate(cards)) { return err(st, #DuplicateCard, "duplicate buried card") };
        for (c in cards.vals()) {
          if (not Card.contains(st.hands[s], c)) {
            return err(st, #CardNotInHand, "buried card not in hand");
          };
        };
        placeBury(st, s, cards, false, now);
        ok(st);
      };
    };
  };

  /// If a bury deadline is configured and has passed, bury the deterministic
  /// lowest-value 8 cards. Returns true when an auto-bury happened.
  public func autoBury(st : State, now : Types.Timestamp) : Bool {
    if (st.phase != #Burying) { return false };
    switch (st.buryDeadline) {
      case null { return false };
      case (?d) { if (now < d) { return false } };
    };
    let bankerSeat = switch (st.banker) { case (?b) b; case null { return false } };
    let pick = autoBuryCards(st.hands[bankerSeat], gameOf(st));
    placeBury(st, bankerSeat, pick, true, now);
    true;
  };

  // ── play ───────────────────────────────────────────────────────────

  func otherHands(st : State, seat : Types.Seat) : [[Card.Card]] {
    let out = List.empty<[Card.Card]>();
    var i = 0;
    while (i < 4) {
      if (i != seat) { out.add(st.hands[i]) };
      i += 1;
    };
    out.toArray();
  };

  func allHandsEmpty(st : State) : Bool {
    var empty = true;
    var i = 0;
    while (i < 4) {
      if (st.hands[i].size() > 0) { empty := false };
      i += 1;
    };
    empty;
  };

  func partnerOf(seat : Types.Seat) : Types.Seat {
    (seat + 2) % 4;
  };

  func bankerSeat(st : State) : Types.Seat {
    switch (st.banker) { case (?b) { b }; case null { st.dealer } };
  };

  /// The banker for this deal, knowable during `#Dealing`: the banking team's
  /// next seat in its alternation, its lower seat the first time it banks, or
  /// the winning declarer while a new table's bank is still being decided.
  /// Mirrors the banker choice in `finalizeDeal` so the UI can tag it early.
  /// Until the first bank is decided (no prior owner and no declaration) the
  /// seat is genuinely unknown, so this reports null rather than guessing
  /// seat 0 — the UI must not tag a banker before the banking team exists.
  func prospectiveBanker(st : State) : ?Types.Seat {
    switch (st.banker) {
      case (?b) { ?b };
      case null {
        if (st.bankTeam == null) {
          // No bank yet: only a declaration fixes the first banker.
          switch (st.decl) {
            case (?d) { ?d.seat };
            case null { null };
          };
        } else {
          let bt = switch (st.bankTeam) { case (?b) { b }; case null { 0 } };
          switch (st.lastBanker[bt]) {
            case (?pb) { ?partnerOf(pb) };
            case null { ?bt };
          };
        };
      };
    };
  };

  /// The partnership that owns the bank; the dealer's team while undecided.
  func bankTeamOf(st : State) : Nat {
    switch (st.bankTeam) { case (?b) { b }; case null { st.dealer % 2 } };
  };

  /// The other fixed partnership.
  func otherTeam(bt : Nat) : Nat {
    if (bt == 0) { 1 } else { 0 };
  };

  func isAttackerTeam(st : State, seat : Types.Seat) : Bool {
    let b = bankerSeat(st);
    seat != b and seat != partnerOf(b);
  };

  func comboOf(cards : [Card.Card], game : Card.Game) : Types.ComboInfo {
    switch (Combo.determineLeadType(cards, game)) {
      case (?l) { Combo.toInfo(l) };
      case null { #Throw({ tractors = []; pairs = []; singles = cards }) };
    };
  };

  func playRecords(plays : [Trick.Play], game : Card.Game) : [Types.PlayRecord] {
    Array.map<Trick.Play, Types.PlayRecord>(
      plays,
      func(p) { { seat = p.seat; cards = p.cards; combo = comboOf(p.cards, game) } },
    );
  };

  func leadInfo(st : State) : ?Types.ComboInfo {
    switch (st.lead) { case (?l) { ?Combo.toInfo(l) }; case null { null } };
  };

  /// Resolve a completed trick: winner, points, kitty scoop, and then either
  /// start the next turn or score the deal.
  func resolveTrick(st : State, now : Types.Timestamp) {
    let game = gameOf(st);
    let lead = switch (st.lead) { case (?l) { l }; case null { return } };
    let plays = st.trick.toArray();
    let winner = Trick.determineTrickWinner(plays, lead, game);
    let records = playRecords(plays, game);
    var points = 0;
    for (p in plays.vals()) {
      for (c in p.cards.vals()) { points += Card.pointValue(c) };
    };
    let isFinal = allHandsEmpty(st);
    if (isFinal and isAttackerTeam(st, winner)) {
      // Kitty scoop: only when the attackers win the final trick.
      points += Scoring.kittyMultiplier(lead) * Scoring.pointsOf(st.kitty);
    };
    if (isAttackerTeam(st, winner)) {
      st.attackerPoints += points;
    } else {
      st.bankerPoints += points;
    };
    let trickId = append(st, now, #TrickWon({ seat = winner; points; plays = records }));
    st.lastTrick := ?{ winner; points; plays = records };
    st.trick := List.empty();
    st.lead := null;
    st.leadCards := [];
    st.trickNo += 1;
    if (isFinal) {
      finishDeal(st, now, trickId);
    } else {
      startTurn(st, winner, now);
      ignore append(st, now, #TurnStarted({ seat = winner; lead = null; deadline = st.deadline }));
    };
  };

  /// Score the deal, progress levels, then wait for every seat to ready up
  /// again before the next deal (which `ready` starts once all are ready).
  func finishDeal(st : State, now : Types.Timestamp, finalTrickId : Nat) {
    st.phase := #Scoring;
    // No timer is live while players ready up for the next deal. Clear the
    // last turn's deadline so the view does not advertise a stale countdown
    // (clients would otherwise keep ticking through the deal summary).
    st.deadline := null;
    st.declareDeadline := null;
    st.declareTotal := null;
    st.buryDeadline := null;
    st.nextDealAt := null;
    st.kittyRevealed := true;
    let b = bankerSeat(st);
    ignore append(st, now, #KittyRevealed({ dealer = b; cards = st.kitty }));
    // Publish the deal entropy now that the deal is over, so anyone can replay
    // the Fisher–Yates shuffle and verify the deal was not manipulated.
    ignore append(st, now, #ShuffleRevealed({ entropy = st.dealEntropy }));

    let outcome = Scoring.compute(st.attackerPoints);
    // The deal was played at the current banking team's level. Advancing that
    // team is what "wins" the levels; a takeover moves the bank to the other
    // partnership without touching the first team's level.
    let playedLevel = st.level;
    let bt = bankTeamOf(st);
    switch (outcome.winner) {
      case (#Bankers) {
        st.teamLevel[bt] := Scoring.advanceLevel(st.teamLevel[bt], outcome);
      };
      case (#Attackers) {
        let nbt = otherTeam(bt);
        st.bankTeam := ?nbt;
        st.teamLevel[nbt] := Scoring.advanceLevel(st.teamLevel[nbt], outcome);
      };
    };
    let newBankerLevel = st.teamLevel[bankTeamOf(st)];
    let newAttackerLevel = st.teamLevel[otherTeam(bankTeamOf(st))];
    st.level := newBankerLevel;

    let nextDealer = (st.dealer + 1) % 4;
    // The deal was played at the bankers' pre-deal level. Only winning *while
    // already at `targetLevel` completes the epoch; reaching A from K merely
    // queues the A deal. On completion only the winning partnership advances:
    // its epoch increments and its level wraps past A by the levels gained
    // this deal, so a 0-point hold at A starts the next epoch at 4. The other
    // partnership keeps its own epoch and level.
    let reachedTarget = outcome.winner == #Bankers and playedLevel >= st.cfg.targetLevel;
    ignore append(st, now, #DealScored({
      attackerPoints = st.attackerPoints;
      result = { points = outcome.points; winner = outcome.winner; gain = outcome.gain };
      bankerLevel = newBankerLevel;
      attackerLevel = newAttackerLevel;
      // The next banker is whoever declares during the next deal; the
      // rotating dealer is only the fallback when nobody declares.
      nextBanker = null;
      nextDealer;
      trickId = finalTrickId;
    }));
    st.dealer := nextDealer;
    if (reachedTarget) {
      // Only the winning partnership wraps: its epoch advances and its level
      // continues from the played level by the gained levels, wrapping past A
      // (A +1 -> 2, +2 -> 3, +3 -> 4). The other partnership keeps its own
      // epoch and level untouched.
      let wt = bankTeamOf(st);
      let finishedEpoch = st.teamEpoch[wt];
      st.teamEpoch[wt] += 1;
      st.teamLevel[wt] := Scoring.nextEpochLevel(playedLevel, outcome.gain);
      st.level := st.teamLevel[wt];
      ignore append(st, now, #EpochEnded({ winner = outcome.winner; epoch = finishedEpoch }));
    };
    // Require a fresh ready from every seat before the next deal. The phase is
    // already #Scoring; `ready` starts the next deal once all seats are ready.
    resetReady(st);
  };

  /// Apply a play for `seat` (already validated for phase/turn/sanitisation).
  /// `auto` marks a server auto-play and emits `AutoPlayed`.
  func applyPlay(
    st : State,
    s : Types.Seat,
    cards : [Card.Card],
    now : Types.Timestamp,
    auto : Bool,
  ) : Types.ActionResult {
    let game = gameOf(st);
    let hand = st.hands[s];
    let isFollow = st.trick.size() > 0;
    var played : [Card.Card] = [];
    var penalized = false;
    var comboInfo : Types.ComboInfo = #Single(0);
    if (st.trick.size() == 0) {
      switch (Lead.checkLeadPlay(cards, hand, game, otherHands(st, s))) {
        case (#Reject(e)) { return err(st, e.code, e.detail) };
        case (#Penalty(p)) { played := p.forced; penalized := true };
        case (#Ok(_)) { played := cards };
      };
    } else {
      switch (Follow.checkPlay(st.leadCards, hand, cards, game)) {
        case (?e) { return err(st, e.code, e.detail) };
        case null { played := cards };
      };
    };
    // Canonicalise the order after validation: the client's card order must not
    // leak into `st.trick`, `st.leadCards`, or the event log (all store `cards`
    // verbatim). The combo is then re-derived from the sorted play.
    played := Card.sortPlay(played, game);
    if (isFollow) {
      comboInfo := comboOf(played, game);
    } else {
      switch (Combo.determineLeadType(played, game)) {
        case (?l) { comboInfo := Combo.toInfo(l); st.lead := ?l; st.leadCards := played };
        case null { return err(st, #IllegalStructure, "cannot classify lead") };
      };
    };

    // A player who plays off-suit while following was void in the lead
    // category; the follow rules force them to exhaust it first.
    if (isFollow) {
      switch (st.lead) {
        case (?lead) {
          var offSuit = false;
          for (c in played.vals()) {
            if (Card.category(c, game) != lead.category) { offSuit := true };
          };
          if (offSuit) { st.voids := Basic.markVoid(st.voids, s, lead.category) };
        };
        case null {};
      };
    };
    st.hands[s] := Card.difference(hand, played);
    let playedCounts = Array.toVarArray<Nat>(st.played);
    for (c in played.vals()) { playedCounts[Card.pairKeyId(c)] += 1 };
    st.played := VarArray.toArray<Nat>(playedCounts);
    st.trick.add({ seat = s; cards = played; handBefore = hand });
    if (auto) {
      ignore append(st, now, #AutoPlayed({ seat = s; cards = played }));
    };
    if (penalized) {
      ignore append(st, now, #ThrowPenalized({
        seat = s;
        forced = played;
        returned = Card.sortPlay(Card.difference(cards, played), game);
      }));
    };
    ignore append(st, now, #CardsPlayed({ seat = s; cards = played; combo = comboInfo }));

    if (st.trick.size() < 4) {
      startTurn(st, (s + 1) % 4, now);
      ignore append(st, now, #TurnStarted({ seat = st.nextSeat; lead = leadInfo(st); deadline = st.deadline }));
    } else {
      resolveTrick(st, now);
    };
    #ok({ seq = st.seq; penalized });
  };

  public func play(
    st : State,
    caller : Principal,
    cards : [Card.Card],
    now : Types.Timestamp,
  ) : Types.ActionResult {
    playWithClient(st, caller, null, cards, now);
  };

  public func playWithClient(
    st : State,
    caller : Principal,
    clientId : ?Types.ClientId,
    cards : [Card.Card],
    now : Types.Timestamp,
  ) : Types.ActionResult {
    switch (seatOfClient(st, caller, clientId)) {
      case null { return err(st, #NotASeat, "not seated") };
      case (?s) {
        if (st.phase != #Playing) { return err(st, #WrongPhase, "not playing") };
        // Belt-and-braces: the declaration window is part of `#Dealing`, so a
        // play that somehow arrives while it is still open is rejected rather
        // than treated as a legal move.
        if (st.declareDeadline != null) {
          return err(st, #WrongPhase, "declaration window still open");
        };
        if (st.nextSeat != s) { return err(st, #NotYourTurn, "not your turn") };
        if (cards.size() == 0) { return err(st, #InvalidCard, "empty play") };
        if (Card.hasDuplicate(cards)) { return err(st, #DuplicateCard, "duplicate cards in play") };
        applyPlay(st, s, cards, now, false);
      };
    };
  };

  /// Idle timeout: when the acting seat's deadline has
  /// passed, play the lowest legal move for it. Returns true when it acted.
  public func autoPlay(st : State, now : Types.Timestamp) : Bool {
    if (st.phase != #Playing) { return false };
    switch (st.deadline) {
      case null { return false };
      case (?d) { if (now < d) { return false } };
    };
    playAuto(st, st.nextSeat, now);
  };

  /// Play the auto-chosen move for a seat, regardless of any deadline.
  func playAuto(st : State, s : Types.Seat, now : Types.Timestamp) : Bool {
    let game = gameOf(st);
    let hand = st.hands[s];
    let trick = st.trick.toArray();
    let move = if (st.trick.size() == 0) {
      Basic.leadingMove(hand, st.played, st.voids, game, s);
    } else {
      switch (st.lead) {
        case (?lead) { Basic.followMove(hand, st.played, st.voids, lead, trick, game, s) };
        case null { Basic.leadingMove(hand, st.played, st.voids, game, s) };
      };
    };
    switch (applyPlay(st, s, move, now, true)) {
      case (#ok(_)) { true };
      case (#err(e)) {
        // The heuristic should always produce a legal move; if it ever does
        // not, fall back to the first card, which is always a legal lead, so a
        // lead turn cannot wedge. A follow's `Basic` move is legal in the
        // tested corpus; if one ever is not, clear the deadline so the
        // scheduler does not hot-loop on it and a client can still act.
        var recovered = false;
        if (st.trick.size() == 0 and hand.size() > 0) {
          switch (applyPlay(st, s, [hand[0]], now, true)) {
            case (#ok(_)) { recovered := true };
            case (#err(_)) {};
          };
        };
        if (recovered) { return true };
        // A follow's `Basic` move is legal in the tested corpus; if one ever is
        // not, do not wedge the table. Re-arm the turn a few seconds out so the
        // scheduler retries (and a client can still act), instead of leaving no
        // timer armed until the idle sweep ends the table.
        st.deadline := ?(now + AUTO_RETRY_NANOS);
        Debug.print(
          "tractor: auto-play retry for table " # Nat.toText(st.id)
          # " seat " # Nat.toText(s) # ": " # e.detail
        );
        false;
      };
    };
  };

  // ── log / poll ─────────────────────────────────────────────────────

  /// Whether `(caller, clientId)` may see `e`. A private hand update is scoped
  /// to the seat's current owner and only from when that owner took the seat,
  /// so a client that attaches (or re-attaches) mid-deal is never served hand
  /// updates from before it attached. Every other event is public.
  func isVisible(st : State, caller : Principal, clientId : ?Types.ClientId, e : Types.Event) : Bool {
    switch (e.body) {
      case (#HandUpdated(p)) {
        switch (seatOfClient(st, caller, clientId)) {
          case (?s) {
            if (s != p.seat) { false } else {
              switch (st.seats[s]) {
                case (?o) { e.seq > o.takenAt };
                case null { false };
              };
            };
          };
          case null { false };
        };
      };
      case _ { true };
    };
  };

  /// Drop all but the last `keepLast` events, advancing the low-water mark.
  public func trim(st : State, keepLast : Nat) {
    let n = st.log.size();
    if (n <= keepLast) { return };
    let drop = Nat.sub(n, keepLast);
    let kept = List.empty<Types.Event>();
    var i = 0;
    for (e in st.log.values()) {
      if (i >= drop) { kept.add(e) };
      i += 1;
    };
    st.log := kept;
    switch (kept.first()) {
      case (?e) { st.lowWater := e.seq };
      case null { st.lowWater := st.seq + 1 };
    };
  };

  /// Drop events older than the configured retention window. The full
  /// history is kept for the retention period; nothing is trimmed by count.
  public func prune(st : State, now : Types.Timestamp) {
    // Retention is validated positive, so the log is always bounded.
    let retention = secondsToNanos(st.cfg.eventRetentionSeconds);
    let cutoff = now - retention;
    // Events are appended in time order, so the first one decides.
    switch (st.log.first()) {
      case null { return };
      case (?first) { if (first.at >= cutoff) { return } };
    };
    let kept = List.empty<Types.Event>();
    for (e in st.log.values()) {
      if (e.at >= cutoff) { kept.add(e) };
    };
    st.log := kept;
    switch (kept.first()) {
      case (?e) { st.lowWater := e.seq };
      case null { st.lowWater := st.seq + 1 };
    };
  };

  /// The earliest future time this table needs a timer callback, or null when
  /// it is fully idle. Derived entirely from the current state, so the actor
  /// can rebuild its schedule after any mutation. Covers only time-critical
  /// game events: the dealing tick, the declaration window, bury/play timeouts,
  /// and a pending next-deal shuffle (armed immediately so the actor can seed
  /// it). A table contributes at most one wake — the earliest of the above —
  /// and `nextTimer` is re-derived after each callback.
  ///
  /// Idleness is deliberately *not* here: it is stored in `endingTime` and
  /// checked by `isIdle` on ingress; an idle table therefore schedules no timer
  /// at all, and clients decide locally that it is over once their clock passes
  /// `endingTime`. Event-log pruning and ended-table eviction are likewise lazy.
  public func nextTimer(st : State, now : Types.Timestamp) : ?Types.Timestamp {
    var next : ?Types.Timestamp = null;
    func consider(t : Types.Timestamp) {
      switch (next) {
        case null { next := ?t };
        case (?n) { if (t < n) { next := ?t } };
      };
    };
    // A deal waiting on entropy must be sealed as soon as possible.
    if (needsShuffle(st)) { consider(now) };
    if (st.phase == #Dealing) {
      if (st.dealComplete) {
        switch (st.declareDeadline) { case (?d) { consider(d) }; case null {} };
      } else {
        switch (st.nextDealAt) { case (?t) { consider(t) }; case null {} };
      };
    };
    if (st.phase == #Burying) {
      switch (st.buryDeadline) { case (?d) { consider(d) }; case null {} };
    };
    if (st.phase == #Playing) {
      switch (st.deadline) { case (?d) { consider(d) }; case null {} };
    };
    next;
  };

  /// True when the table has at least one completed trick in its retained log.
  /// A table that never got past the lobby (or was abandoned before a trick
  /// finished) has nothing to show, so the ended-table listing omits it.
  public func hasTricks(st : State) : Bool {
    var found = false;
    label scan for (e in st.log.values()) {
      switch (e.body) {
        case (#TrickWon(_)) { found := true; break scan };
        case _ {};
      };
    };
    found;
  };

  /// Completed tricks in play order, reconstructed from the retained event log.
  /// `trickNo` resets on each `DealStarted` so callers can group by deal; the
  /// `trickId` is the `TrickWon` event sequence (stable across pruning). Pass a
  /// `?trickId` to return only that trick. Only tricks still inside the
  /// retention window are returned.
  public func playHistory(st : State, onlyTrick : ?Nat) : [Types.PlaySequence] {
    let out = List.empty<Types.PlaySequence>();
    var dealNo = 0;
    var trickNo = 0;
    for (e in st.log.values()) {
      switch (e.body) {
        case (#DealStarted(d)) { dealNo := d.dealNo; trickNo := 0 };
        case (#TrickWon(t)) {
          if (onlyTrick == null or onlyTrick == ?e.seq) {
            out.add({
              trickId = e.seq;
              dealNo;
              trickNo;
              winner = t.seat;
              points = t.points;
              plays = t.plays;
            });
          };
          trickNo += 1;
        };
        case _ {};
      };
    };
    out.toArray();
  };

  /// Distinct principals that have taken a seat, in join order, with the avatar
  /// they joined with. Reconstructed from the retained `PlayerJoined` events;
  /// a table whose log has been pruned is not offered for an ended-table report.
  func participantList(st : State) : [Types.Participant] {
    let out = List.empty<Types.Participant>();
    for (e in st.log.values()) {
      switch (e.body) {
        case (#PlayerJoined(p)) {
          var seen = false;
          for (q in out.values()) { if (Principal.equal(q.principal, p.who)) { seen := true } };
          if (not seen) { out.add({ principal = p.who; avatar = p.avatar }) };
        };
        case _ {};
      };
    };
    out.toArray();
  };

  /// True once the event log has been trimmed, so its history is incomplete.
  public func historyPruned(st : State) : Bool { st.lowWater > 1 };

  /// Scored deals in deal order, reconstructed from the retained event log.
  func dealHistory(st : State) : [Types.DealOutcome] {
    let out = List.empty<Types.DealOutcome>();
    var dealNo = 0;
    // Track the partnership that owns the bank: the first declaration decides
    // it, and each deal flips it only when the attackers win.
    var bankTeam = 0;
    var decided = false;
    var trump = Card.NT;
    // The seat that banked the current deal, from the log's `KittyReceived`.
    var banker : ?Types.Seat = null;
    // The current deal's buried kitty, from its `KittyRevealed`.
    var buriedKitty : [Card.Card] = [];
    // Team levels as of the current deal's start. The deal is played at the
    // bank's pre-deal level, so the report shows those, not the post-deal ones.
    let teamLevel = [var 2, 2];
    var startBankerLevel = 2;
    var startAttackerLevel = 2;
    var startBankTeam = 0;
    // Per-seat participant now, at the start of the current deal (so a seat
    // that changed hands mid-deal can flag it), and the last occupant seen
    // during the deal (so a seat that emptied mid-deal still reports who was
    // there).
    let seats = VarArray.repeat<?Types.SeatSnapshot>(null, 4);
    let startSeats = VarArray.repeat<?Types.SeatSnapshot>(null, 4);
    let dealSeats = VarArray.repeat<?Types.SeatSnapshot>(null, 4);
    let changed = VarArray.repeat<Bool>(false, 4);
    for (e in st.log.values()) {
      switch (e.body) {
        case (#DealStarted(d)) {
          dealNo := d.dealNo;
          trump := Card.NT;
          buriedKitty := [];
          teamLevel[bankTeam] := d.level;
          startBankerLevel := teamLevel[bankTeam];
          startAttackerLevel := teamLevel[1 - bankTeam];
          startBankTeam := bankTeam;
          var i = 0;
          while (i < 4) {
            startSeats[i] := seats[i];
            dealSeats[i] := seats[i];
            changed[i] := false;
            i += 1;
          };
        };
        case (#TrumpDeclared(d)) {
          // The bank belongs to the last accepted declaration's team until the
          // first deal is scored (`finalizeDeal` fixes it there), so a deal-1
          // override flips it too.
          if (not decided) { bankTeam := d.seat % 2 };
          trump := d.suit;
        };
        case (#KittyReceived(k)) {
          // Exactly one per deal, carrying the seat that banks it.
          banker := ?k.dealer;
        };
        case (#KittyRevealed(k)) {
          // The buried cards become public when the deal ends.
          buriedKitty := k.cards;
        };
        case (#PlayerJoined(p)) {
          let snap = ?{ principal = ?p.who; avatar = p.avatar };
          seats[p.seat] := snap;
          // A seat may change hands mid-deal; the deal reports the last one.
          dealSeats[p.seat] := snap;
          changed[p.seat] := true;
        };
        case (#PlayerLeft(l)) {
          seats[l.seat] := null;
          changed[l.seat] := true;
        };
        case (#DealScored(s)) {
          let post = if (s.result.winner == #Bankers) { bankTeam } else { 1 - bankTeam };
          // The banker's avatar is the deal-start participant of the seat that
          // banked the deal (tracked from the log's `KittyReceived`).
          let bankerAvatar = switch (banker) {
            case (?b) { switch (startSeats[b]) { case (?snap) { snap.avatar }; case null { null } } };
            case null { null };
          };
          out.add({
            dealNo;
            attackerPoints = s.attackerPoints;
            winner = s.result.winner;
            gain = s.result.gain;
            bankerLevel = startBankerLevel;
            attackerLevel = startAttackerLevel;
            bankTeam = startBankTeam;
            trump;
            bankerAvatar;
            bankerSeat = banker;
            seats = Array.map<?Types.SeatSnapshot, Types.SeatSnapshot>(
              VarArray.toArray(dealSeats),
              func(sn) = switch (sn) { case (?x) { x }; case null { { principal = null; avatar = null } } },
            );
            changed = VarArray.toArray(changed);
            buriedKitty;
          });
          // Roll the team levels forward for the next deal.
          teamLevel[post] := s.bankerLevel;
          teamLevel[1 - post] := s.attackerLevel;
          bankTeam := post;
          decided := true;
        };
        case _ {};
      };
    };
    out.toArray();
  };

  /// A table's full history for the ended-table detail dialog: stats, the
  /// completed tricks in play order, and the scored deals. Only what is still
  /// inside the retention window is returned.
  public func history(st : State) : Types.TableHistory {
    {
      info = info(st);
      tricks = playHistory(st, null);
      deals = dealHistory(st);
    };
  };

  /// One `SeatInfo` per seat. Shared by `view` (players) and `info` (lobby) so
  /// both expose the same seat shape.
  func seatInfos(st : State) : [Types.SeatInfo] {
    Array.tabulate<Types.SeatInfo>(
      4,
      func(i) {
        {
          principal = switch (st.seats[i]) { case (?o) { ?o.principal }; case null { null } };
          avatar = st.avatars[i];
          ready = st.ready[i];
          handCount = st.hands[i].size();
          connected = st.seats[i] != null;
          replaceable = switch (st.seats[i]) { case (?o) { o.replaceable }; case null { false } };
        };
      },
    );
  };

  public func view(st : State, caller : Principal) : Types.PlayerView {
    viewWithClient(st, caller, null);
  };

  public func viewWithClient(st : State, caller : Principal, clientId : ?Types.ClientId) : Types.PlayerView {
    let mySeat = seatOfClient(st, caller, clientId);
    let seats = seatInfos(st);
    {
      tableId = st.id;
      dealNo = st.dealNo;
      // A seated viewer sees their own partnership's epoch; observers see the
      // epoch of the partnership that owns the bank (whose level is in play).
      epoch = switch (mySeat) {
        case (?s) { st.teamEpoch[s % 2] };
        case null { st.teamEpoch[bankTeamOf(st)] };
      };
      endingTime = st.endingTime;
      // The last event time, independent of the idle window: `endingTime` is
      // always `lastActivity + window`, so this recovers it without a new
      // stable field. A client uses it to tell a quiet table from an active
      // one regardless of the 10-minute / 48-hour window.
      lastActivity = st.endingTime - idleRetention(isPrivate(st));
      phase = st.phase;
      level = st.level;
      trump = st.trump;
      decl = st.decl;
      config = st.cfg;
      isPrivate = isPrivate(st);
      // Only a seated viewer gets the auth code; a spectator or observer sees
      // null and cannot build an invitation link.
      authCode = switch (mySeat) { case (?_) { st.authCode }; case null { null } };
      // During dealing the banker is the deterministic prospect; otherwise it
      // is the decided seat (null in the lobby).
      banker = switch (st.phase) {
        case (#Dealing) { prospectiveBanker(st) };
        case _ { st.banker };
      };
      prospectiveBanker = prospectiveBanker(st);
      dealer = st.dealer;
      mySeat;
      myHand = switch (mySeat) { case (?s) st.hands[s]; case null [] };
      seats;
      score = {
        bankerPoints = st.bankerPoints;
        attackerPoints = st.attackerPoints;
        bankerLevel = st.teamLevel[bankTeamOf(st)];
        attackerLevel = st.teamLevel[otherTeam(bankTeamOf(st))];
      };
      actingSeat = switch (st.phase) {
        case (#Burying) { st.banker };
        case (#Playing) { ?st.nextSeat };
        case _ { null };
      };
      trick = playRecords(st.trick.toArray(), gameOf(st));
      lastTrick = st.lastTrick;
      // The buried kitty is public once revealed at deal end; while playing it
      // is visible only to the banker who buried it. Enforced here so other
      // seats never receive the cards.
      kitty = if (
        st.kittyRevealed or (
          st.phase == #Playing and mySeat != null and mySeat == st.banker
        )
      ) {
        ?st.kitty
      } else {
        null
      };
      deadline = switch (st.phase) {
        // During dealing the deadline the client cares about is the
        // declaration window, so it can render a countdown.
        case (#Dealing) { st.declareDeadline };
        case _ { st.deadline };
      };
      declareTotal = switch (st.phase) {
        case (#Dealing) { st.declareTotal };
        case _ { null };
      };
    };
  };

  public func poll(st : State, caller : Principal, afterSeq : Types.Seq) : Types.PollResponse {
    pollWithClient(st, caller, null, afterSeq);
  };

  public func pollWithClient(
    st : State,
    caller : Principal,
    clientId : ?Types.ClientId,
    afterSeq : Types.Seq,
  ) : Types.PollResponse {
    // Bound the response size: if a caller asks for more than
    // `maxEvents` visible events, force a full reset from `view` instead.
    let maxEvents : Nat = 512;
    var count = 0;
    let events = List.empty<Types.Event>();
    for (e in st.log.values()) {
      if (e.seq > afterSeq and isVisible(st, caller, clientId, e)) {
        count += 1;
        if (count <= maxEvents) { events.add(e) };
      };
    };
    let truncated = count > maxEvents;
    let fullSync = afterSeq + 1 < st.lowWater or truncated;
    {
      tableId = st.id;
      seq = st.seq;
      lowWater = st.lowWater;
      fullSync;
      phase = st.phase;
      events = if (truncated) { [] } else { events.toArray() };
      view = viewWithClient(st, caller, clientId);
    };
  };

  public func info(st : State) : Types.TableInfo {
    infoFor(st, null);
  };

  /// Like `info`, but reveals the auth code when `caller` holds a seat.
  public func infoFor(st : State, caller : ?Principal) : Types.TableInfo {
    // The auth code is a secret: only a principal who holds a seat may see it.
    let member = switch (caller) {
      case (?p) { principalHasSeat(st, p) };
      case null { false };
    };
    {
      tableId = st.id;
      phase = st.phase;
      occupied = filledCount(st);
      seats = seatInfos(st);
      level = st.level;
      dealNo = st.dealNo;
      // The next deal is played at the bank's level, so the bank's epoch is the
      // one the lobby should show.
      epoch = st.teamEpoch[bankTeamOf(st)];
      endingTime = st.endingTime;
      // See `viewWithClient`: recover the last event time from `endingTime`.
      lastActivity = st.endingTime - idleRetention(isPrivate(st));
      // A truly empty seat makes a table joinable; in `#Scoring` the next
      // deal has not started, so a seat that emptied mid-deal can be refilled.
      // A private table is joinable in any live phase, so an invitation link
      // can refill a seat the last player abandoned mid-deal.
      joinable = (st.phase == #Lobby or st.phase == #Scoring or isPrivate(st)) and hasEmptySeat(st);
      banker = prospectiveBanker(st);
      config = st.cfg;
      isPrivate = isPrivate(st);
      authCode = if (member) { st.authCode } else { null };
      startedAt = st.startedAt;
      // A table that is not explicitly ended has no `endedAt`; let the duration
      // run through the last activity instead of showing nothing (the idle
      // tables in the ended listing are effectively over).
      endedAt = switch (st.endedAt) {
        case (?t) { ?t };
        case null { switch (st.log.last()) { case (?e) { ?e.at }; case null { null } } };
      };
      participants = participantList(st);
    };
  };

  /// Test/dev hook: run the scoring transition with the current level and
  /// `attackerPoints`. Not exposed by the actor.
  public func debugFinishDeal(st : State, now : Types.Timestamp) {
    finishDeal(st, now, 0);
  };

  /// Test/dev hook: force a phase (and banker/turn) to exercise auth checks
  /// that are otherwise unreachable until M3/M4. Not exposed by the actor.
  public func debugForce(st : State, phase : Types.Phase, banker : ?Types.Seat, nextSeat : Types.Seat) {
    st.phase := phase;
    st.banker := banker;
    st.nextSeat := nextSeat;
  };

  /// Test/dev helper: natural text for a result (used in assertions).
  public func seqOf(st : State) : Types.Seq {
    st.seq;
  };
}
