/// Shared wire/protocol types and the error taxonomy.
import Card "Card";

module {
  public type TableId = Nat;
  public type Seq = Nat;
  public type Seat = Nat; // 0..3
  public type Suit = Nat; // 1..4, 5 = NT
  public type Level = Nat; // 2..14
  public type Timestamp = Int; // Time.now()

  /// A player's cosmetic avatar: preset art id + color style id. Stored per
  /// table seat so every client renders the same picture for a seat. Uploaded
  /// pictures are a future paid feature and are not accepted server-side.
  public type Avatar = {
    preset : Text;
    style : Text;
  };

  /// A client-supplied routing label. A browser passes `null`; a bot canister
  /// passes a per-seat id so it can hold several seats in one table. The game
  /// treats it as opaque and never publishes it (it is a private bus address).
  public type ClientId = Blob;

  /// A canister client's push subscription. `cursor` is the last sequence
  /// number pushed to this client; `cycles` totals the ingress cycles it has
  /// paid (observability only).
  public type ClientSub = {
    cursor : Seq;
    cycles : Nat;
  };

  /// A table seat. `principal` owns it, `clientId` is the private routing
  /// label it registered (null for a browser), and `takenAt` is the sequence
  /// when this owner took the seat. A canister-held seat starts *claimed*
  /// (`client == null`, before the canister has registered) and becomes
  /// *attached* once `client` is set. Uniqueness within a table is
  /// `(principal, clientId)`, so a whitelisted canister can hold up to four
  /// seats while a user (clientId = null) holds one.
  public type SeatOwner = {
    principal : Principal;
    clientId : ?ClientId;
    client : ?ClientSub;
    takenAt : Seq;
    // A canister-held seat a human may take over. Set when the bot attaches;
    // false for human-run seats.
    replaceable : Bool;
  };

  /// The events a client has not seen, plus a flag telling it to fetch an
  /// authoritative `PlayerView` (a gap or a cap truncation).
  public type EventBatch = {
    events : [Event];
    fullSync : Bool;
  };

  // ── error taxonomy (Appendix C) ────────────────────────────────────

  public type ErrorCode = {
    #NotASeat;
    #NotInLobby;
    #LobbyFull;
    #AlreadyJoined;
    #TableNotFound;
    #TableEnded;
    #WrongPhase;
    #NotYourTurn;
    #NotKittyOwner;
    #KittySizeMismatch;
    #DuplicateCommand;
    #InvalidCard;
    #InvalidAvatar;
    #InvalidConfig;
    #CardNotInHand;
    #DuplicateCard;
    #IllegalLead;
    #IllegalStructure;
    #IllegalFollow;
    #IllegalDeclaration;
    #TooManyTables;
    #PayloadTooLarge;
    #InsufficientCycles;
    #NotWhitelisted;
    #NotAuthorized;
    // createTable rejected: a private table must leave at least one seat open
    // (not pre-claimed for a bot), so the invitation link has somewhere to land.
    #PrivateNeedsOpenSeat;
  };

  public type CheckError = { code : ErrorCode; detail : Text };

  // ── phases / config ────────────────────────────────────────────────

  public type Phase = {
    #Lobby;
    #Dealing;
    #Burying;
    #Playing;
    #Scoring;
    #Ended;
  };

  public type TableConfig = {
    targetLevel : Level;
    dealTickSeconds : Nat;
    declareSeconds : ?Nat; // post-deal declaration window; null = lock as soon as the deck is out
    overrideSeconds : ?Nat; // counter-declaration window after a call; null = lock immediately
    burySeconds : ?Nat; // banker kitty timeout; null = wait indefinitely
    playSeconds : ?Nat; // turn timeout -> auto-play; null = wait indefinitely
    eventRetentionSeconds : ?Nat; // event-log retention; null = keep forever
    firstDealer : Seat;
    enhancedJokerOverride : Bool;
    // End the table as soon as no human-owned seat remains (every occupied seat
    // is a whitelisted bot, or none are occupied). Tests that run all-bot
    // tables set this false to keep them alive.
    endWhenAllBots : Bool;
  };

  public let defaultConfig : TableConfig = {
    targetLevel = 14;
    dealTickSeconds = 1;
    declareSeconds = ?15;
    overrideSeconds = ?10;
    burySeconds = ?60;
    playSeconds = ?45;
    eventRetentionSeconds = ?259200; // 3 days
    firstDealer = 0;
    enhancedJokerOverride = false;
    endWhenAllBots = true;
  };

  /// Caps for client-supplied config values, so a create cannot schedule work
  /// absurdly far out or retain events forever.
  public let MAX_TICK_SECONDS : Nat = 3600; // 1 hour between deal ticks
  public let MAX_PHASE_SECONDS : Nat = 86_400; // 1 day for a declare/bury/play timer
  public let MAX_RETENTION_SECONDS : Nat = 2_592_000; // 30 days of event history

  func validTimeout(t : ?Nat) : Bool {
    switch (t) {
      case null { true };
      case (?s) { s <= MAX_PHASE_SECONDS };
    };
  };

  func validRetention(t : ?Nat) : Bool {
    switch (t) {
      case null { true };
      case (?s) { s > 0 and s <= MAX_RETENTION_SECONDS };
    };
  };

  /// Reject a client-supplied config that is not sensible: the level and dealer
  /// must be in range, timers must be bounded, and a retention window (when
  /// given) must be positive and bounded. `null` fields mean "wait forever"
  /// (or, for retention, "keep forever") and are always allowed.
  public func validConfig(cfg : TableConfig) : Bool {
    cfg.targetLevel >= 2 and cfg.targetLevel <= 14 and
    cfg.firstDealer < 4 and
    cfg.dealTickSeconds <= MAX_TICK_SECONDS and
    validTimeout(cfg.declareSeconds) and
    validTimeout(cfg.overrideSeconds) and
    validTimeout(cfg.burySeconds) and
    validTimeout(cfg.playSeconds) and
    validRetention(cfg.eventRetentionSeconds);
  };

  public type SeatInfo = {
    principal : ?Principal;
    // The human's chosen avatar for this table (null for empty seats).
    avatar : ?Avatar;
    ready : Bool;
    handCount : Nat;
    // True once the seat has an owner (a claimed canister seat counts as
    // connected before it attaches a push client).
    connected : Bool;
    // Whether a canister-held seat may be taken over by a human. The single
    // source of truth for the lobby and table hints; false for empty/human
    // seats.
    replaceable : Bool;
  };

  /// A principal that has taken a seat at the table (whether or not it still
  /// holds one), with the avatar it joined with, for the ended-table stats.
  public type Participant = {
    principal : Principal;
    avatar : ?Avatar;
  };

  /// A seat's participant at a point in time, for the per-deal report.
  public type SeatSnapshot = {
    principal : ?Principal;
    avatar : ?Avatar;
  };

  public type TableInfo = {
    tableId : TableId;
    phase : Phase;
    occupied : Nat;
    // One entry per seat, mirroring `PlayerView.seats`, so the lobby can
    // render owners and avatars from a single list.
    seats : [SeatInfo];
    level : Level;
    dealNo : Nat;
    epoch : Nat;
    // Server time by which the table is idle and should be treated as ended.
    // Every event extends it, so a client can decide locally that the table is
    // over once its own clock passes this value.
    endingTime : Timestamp;
    joinable : Bool;
    // The prospective banker (declarer, else the rotating dealer) once a bank
    // is decided, so the lobby can mark the seat before the deal starts. Null
    // while the first bank is still undecided.
    banker : ?Seat;
    // The game configuration this table was created with.
    config : TableConfig;
    // Whether the table was created private (see `CreateTableRequest.isPrivate`).
    isPrivate : Bool;
    // When the table was created, and when it ended (null while still live),
    // so the lobby can show a start time and duration for ended tables.
    startedAt : Timestamp;
    endedAt : ?Timestamp;
    // Every principal that has taken a seat (deduplicated, so a bot canister
    // holding several seats appears once), including those who have left.
    participants : [Participant];
  };

  public type TableFilter = {
    phase : ?Phase;
    joinableOnly : Bool;
    afterId : ?TableId; // cursor: only tables with id > afterId
    limit : ?Nat; // page size, capped server-side
  };

  // ── action results ─────────────────────────────────────────────────

  public type ActionResult = {
    #ok : { seq : Seq; penalized : Bool };
    #err : { seq : Seq; code : ErrorCode; detail : Text };
  };

  /// `createTable` returns the new id, or an error (`TooManyTables`).
  public type CreateResult = {
    #ok : TableId;
    #err : CheckError;
  };

  // ── combinations / plays ───────────────────────────────────────────

  public type ComboInfo = {
    #Single : Card.Card;
    #Pair : [Card.Card];
    #Tractor : [[Card.Card]];
    #Throw : {
      tractors : [[Card.Card]];
      pairs : [Card.Card];
      singles : [Card.Card];
    };
  };

  public type PlayRecord = {
    seat : Seat;
    cards : [Card.Card];
    combo : ComboInfo;
  };

  public type TrickRecord = {
    winner : Seat;
    points : Nat;
    plays : [PlayRecord];
  };

  /// One completed trick in deal/trick order, for replaying a table's play
  /// history. `trickId` is a stable, table-unique id (the `TrickWon` event
  /// sequence); `trickNo` is 0-based within its deal; `points` includes the
  /// kitty scoop on a deal's final trick.
  public type PlaySequence = {
    trickId : Nat;
    dealNo : Nat;
    trickNo : Nat;
    winner : Seat;
    points : Nat;
    plays : [PlayRecord];
  };

  public type Team = { #Bankers; #Attackers };

  /// One scored deal in a table's history, reconstructed from the retained
  /// event log for the ended-table report.
  public type DealOutcome = {
    dealNo : Nat;
    attackerPoints : Nat;
    winner : Team;
    gain : Nat;
    bankerLevel : Level;
    attackerLevel : Level;
    // The partnership (seat % 2) that owns the bank after this deal.
    bankTeam : Nat;
    // Wire trump for the deal: 1..4 select a suit, 5 is No-Trump.
    trump : Nat;
    // The banker's avatar when the deal started (the declarer, else the
    // dealer).
    bankerAvatar : ?Avatar;
    // The seat that banked the deal (the declarer, else the dealer).
    bankerSeat : ?Seat;
    // Per seat, the participant when the deal ended (null for an empty seat).
    seats : [SeatSnapshot];
    // Per seat, whether the participant changed during the deal, so a seat
    // level can flag a takeover with the end-of-deal avatar.
    changed : [Bool];
    // The buried kitty, revealed when the deal ended, in the game-trace
    // format (`buried_kitty` in games/*.json).
    buriedKitty : [Card.Card];
  };

  /// Why a table moved to `#Ended`: every seat emptied (`#Empty`) or it went
  /// quiet past the idle window (`#Idle`).
  public type TableEndReason = { #Empty; #Idle };

  public type DealResult = {
    points : Nat;
    winner : Team;
    gain : Nat; // levels the winning team rises
  };

  public type DeclareKind = { #Single; #Pair; #SmallJokerPair; #BigJokerPair };

  public type Declaration = {
    seat : Seat;
    kind : DeclareKind;
    suit : Suit;
    value : Nat;
  };

  // ── events (Appendix B) ────────────────────────────────────────────

  public type EventBody = {
    #PlayerJoined : { seat : Seat; who : Principal; avatar : ?Avatar };
    #PlayerLeft : { seat : Seat };
    #PlayerReady : { seat : Seat };
    #DealStarted : { dealNo : Nat; dealer : Seat; level : Level };
    #ShuffleRevealed : { entropy : Blob }; // deal entropy, published once the deal is scored
    #DealTick : { dealt : Nat; toSeat : Seat };
    #HandUpdated : { seat : Seat; added : [Card.Card]; hand : [Card.Card] }; // private
    #TrumpDeclared : { seat : Seat; kind : DeclareKind; suit : Suit };
    #DealEnded : {};
    #KittyReceived : { dealer : Seat; count : Nat };
    #KittyBuried : { dealer : Seat; count : Nat; auto : Bool };
    #TurnStarted : { seat : Seat; lead : ?ComboInfo; deadline : ?Int };
    #AutoPlayed : { seat : Seat; cards : [Card.Card] };
    #CardsPlayed : { seat : Seat; cards : [Card.Card]; combo : ComboInfo };
    #ThrowPenalized : { seat : Seat; forced : [Card.Card]; returned : [Card.Card] };
    #TrickWon : { seat : Seat; points : Nat; plays : [PlayRecord] };
    #KittyRevealed : { dealer : Seat; cards : [Card.Card] };
    #DealScored : {
      attackerPoints : Nat;
      result : DealResult;
      bankerLevel : Level;
      attackerLevel : Level;
      nextBanker : ?Seat;
      nextDealer : Seat;
      // Stable id of the deal's final trick (see `PlaySequence.trickId`), so a
      // client can anchor a problem report to the trick it just watched.
      trickId : Nat;
    };
    #TableEnded : { winner : Team; bankerLevel : Level; attackerLevel : Level; reason : TableEndReason };
    #EpochEnded : { winner : Team; epoch : Nat };
  };

  public type Event = {
    seq : Seq;
    at : Timestamp;
    body : EventBody;
  };

  /// The one-way push the game canister sends a subscribed canister. It is the
  /// same shape as a `PollResponse` minus the view: the bot folds `events` into
  /// its own view, and calls `sync` when `fullSync` is set or it detects a gap.
  /// A table-scoped push from the game canister: the new events since this
  /// client's watermark, for every seat the client holds at `tableId` (public
  /// events plus that client's private `HandUpdated`). One batch per client
  /// canister, not per seat.
  public type Push = {
    tableId : TableId;
    seq : Seq;
    fullSync : Bool;
    events : [Event];
  };

  /// The interface the game canister calls to push to a bot. A mismatch in this
  /// shape must drop the subscription, never trap the game canister.
  /// Note that it's return type is () instead of async () because this is supposed
  /// to be a best-effort one-way call, and the caller doesn't expect a response.
  public type Bot = actor {
    receive : (Push) -> ();
  };

  // ── views ──────────────────────────────────────────────────────────

  public type Score = {
    bankerPoints : Nat;
    attackerPoints : Nat;
    bankerLevel : Level;
    attackerLevel : Level;
  };

  public type PlayerView = {
    tableId : TableId;
    dealNo : Nat;
    epoch : Nat;
    // Server time by which the table is idle and should be treated as ended;
    // see `TableInfo.endingTime`.
    endingTime : Timestamp;
    phase : Phase;
    level : Level;
    trump : ?Suit;
    decl : ?Declaration;
    config : TableConfig;
    // Whether the table is private. A private table is not ended by leaving, so
    // the client keeps the seat hand-over choice and hands it to a bot rather
    // than freeing it.
    isPrivate : Bool;
    banker : ?Seat;
    // The prospective banker (declarer, else rotating dealer) once a bank is
    // decided, so the UI can mark the seat before the deal starts. Null while
    // the first bank is still undecided.
    prospectiveBanker : ?Seat;
    dealer : Seat;
    mySeat : ?Seat;
    myHand : [Card.Card];
    seats : [SeatInfo];
    score : Score;
    actingSeat : ?Seat;
    trick : [PlayRecord];
    lastTrick : ?TrickRecord;
    kitty : ?[Card.Card];
    deadline : ?Timestamp;
    // Seconds of the currently armed declaration window (Dealing only), so the
    // client can size the countdown ring even when a call extended the window.
    declareTotal : ?Nat;
  };

  /// Read-only cost/observability snapshot.
  public type Metrics = {
    tables : Nat;
    nextTableId : TableId;
    tickCount : Nat;
    cycleBalance : Nat;
  };

  public type PollRequest = {
    tableId : TableId;
    afterSeq : Seq;
    clientId : ?ClientId;
  };

  public type PollResponse = {
    tableId : TableId;
    seq : Seq;
    lowWater : Seq;
    fullSync : Bool;
    phase : Phase;
    events : [Event];
    view : PlayerView;
  };

  // ── problem reports ────────────────────────────────────────────────

  public type ReportId = Nat;

  public type ReportMessage = {
    at : Timestamp;
    admin : Bool; // true = follow-up from the admin, false = the reporter
    text : Text;
  };

  /// A player-filed problem report, anchored to a table and the deal it was
  /// filed against (reports are filed from the end-of-deal summary).
  /// `messages` is the thread: the reporter's original text followed by any
  /// admin replies.
  public type Report = {
    id : ReportId;
    tableId : TableId;
    dealNo : ?Nat;
    reporter : Principal;
    at : Timestamp;
    messages : [ReportMessage];
  };

  public type ReportError = {
    #NotAuthorized;
    #ReportNotFound;
    #InvalidReport;
    #TooManyReports;
  };

  public type ReportResult = {
    #ok : Report;
    #err : ReportError;
  };

  public type ReportListResult = {
    #ok : [Report];
    #err : ReportError;
  };

  // ── request records ────────────────────────────────────────────────
  //
  // Public entry points take a single record so fields can be added later
  // without changing the method arity and breaking older clients.

  public type CreateTableRequest = {
    cfg : ?TableConfig;
    // Per-seat initial owners. Entry `i` claims seat `i` for that principal:
    // only a caller whose principal equals the entry may attach to it. Seat 0
    // is always the creator and is ignored. A short vector (or `null` entry)
    // leaves the remaining seats open. Null (an omitted field) claims none.
    reserved : ?[?Principal];
    avatar : ?Avatar;
    clientId : ?ClientId;
    // A private table is hidden from the live `listTables` listings (it only
    // appears once ended), so it is reachable only by its id — the invitation
    // link. It keeps a 48-hour idle window and is never ended merely because
    // no human is seated, since an invitee may still arrive.
    isPrivate : ?Bool;
  };

  public type GetPlayHistoryRequest = {
    id : TableId;
    trickId : ?Nat;
  };

  public type GetTableHistoryRequest = {
    id : TableId;
  };

  /// A table's full history for the lobby's ended-table detail dialog: the
  /// stats (`info`), the completed tricks in play order, and the scored deals.
  public type TableHistory = {
    info : TableInfo;
    tricks : [PlaySequence];
    deals : [DealOutcome];
  };

  public type SubmitReportRequest = {
    tableId : TableId;
    dealNo : ?Nat;
    text : Text;
  };

  public type AddReportMessageRequest = {
    id : ReportId;
    text : Text;
  };

  public type JoinTableRequest = {
    id : TableId;
    seat : Seat;
    avatar : ?Avatar;
    clientId : ?ClientId;
    // Canister-only hint: whether the attached seat may later be taken over by
    // a human. Omitted by human clients (defaults to false).
    replaceable : ?Bool;
  };

  public type ReadyRequest = {
    id : TableId;
    clientId : ?ClientId;
  };

  public type LeaveTableRequest = {
    id : TableId;
    // null leaves the seat open (an in-progress deal is abandoned); `?p` claims
    // the vacated seat for `p`, who then attaches to it. `p` may be the trusted
    // bot principal (taking over) or a human (replacing the seat).
    reserveFor : ?Principal;
    clientId : ?ClientId;
  };

  /// Shared request for the card-taking deal actions (`declareTrump`,
  /// `buryKitty`, `play`).
  public type CardsRequest = {
    id : TableId;
    cards : [Card.Card];
    clientId : ?ClientId;
  };
}
