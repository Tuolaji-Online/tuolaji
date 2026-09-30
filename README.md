# Tuolaji on the Internet Computer

A Motoko canister that hosts **Tuolaji (升级)** — a four-seat,
partnership, trick-taking card game. One canister hosts many independent tables
and is the sole rule authority: clients send commands and read a caller-scoped
view, and the server validates every move.

## The game

- Four seats in two partnerships (seats 0+2 vs 1+3).
- 108 cards (two decks plus four jokers). Each seat is dealt 25; the last 8
  form the kitty.
- A deal is played at the banking partnership's level: that level's cards rank
  highest, and the declarer names the trump suit (or No-Trump).
- Phases: `Lobby → Dealing → Burying → Playing → Scoring`, then the next deal.
- Declarations, the bank/banker, the kitty bury, lead/follow legality, throw
  penalties, trick points and deal scoring are all adjudicated server-side.

Full rules: [./RULES.md](./RULES.md).

## Trust model

Trust-minimized: the game runs on a blockchain, so the code is law — every move
is validated on-chain and there is no hidden backdoor. The shuffle is
`raw_rand`-seeded Fisher–Yates, and hands and the kitty are hidden by
principal-scoped views.

## The canister

`src/main.mo` is the actor: transport, access control, the timer, the table
registry and stable persistence. `src/Table.mo` owns per-table game state. The
rules live in pure modules that never touch the network — `Card`, `Combo`,
`Lead`, `Follow`, `Trick`, `Scoring`, `Trump`, `Shuffle` — plus `Basic` (the
timeout auto-play policy) and `Scheduler` (timer arming).

One canister holds many tables, bounded by a global and a per-principal cap. The
per-table event log is retained for `eventRetentionSeconds`. A table with no
event for 10 minutes is idle: `listTables` hides it and the next
`createTable`/`joinTable` ends it. Ended tables are kept for 2 days, then
evicted.

## How clients talk to the canister

Commands are **update calls**; reads are **query calls**. There is no socket.

- `poll(tableId, afterSeq)` returns the events with `seq > afterSeq` that the
  caller may see, plus the caller-scoped `PlayerView`. The client keeps a cursor
  and advances it to the response's `seq`. `sync` is the update-call variant,
  guaranteed fresh.
- If the cursor is below the retained log (`lowWater`) or more than 512 events
  are pending, the response sets `fullSync = true`, carries no events, and the
  client resets from `view`.
- `HandUpdated` reaches only its owning seat, and `kitty` is null until
  `KittyRevealed`; everything else is public. Filtered events still advance
  `seq`, so a cursor simply skips them.
- Canister callers may register a **push client** instead: the server sends
  one-way `Push` batches to the caller's `receive` and advances its cursor. The
  client calls `sync` on any gap or `fullSync`.

## Server API

The generated Candid interface (`tractor.did`) is available from the download
section on GitHub.

```candid
type TableId = nat;  type Seq = nat;  type Card = nat;  // 1..108
type Seat = nat;     // 0..3
type Suit = nat;     // 1..4, 5 = No-Trump
type Level = nat;    // 2..14

type Phase = variant { Lobby; Dealing; Burying; Playing; Scoring; Ended };

service : {
  createTable : (CreateTableRequest) -> (CreateResult);
  listTables  : (TableFilter) -> (vec TableInfo) query;
  getTable    : (TableId) -> (opt TableInfo) query;

  joinTable : (JoinTableRequest) -> (ActionResult);
  leaveTable : (LeaveTableRequest) -> (ActionResult);
  ready      : (ReadyRequest) -> (ActionResult);
  declareTrump : (CardsRequest) -> (ActionResult);
  buryKitty    : (CardsRequest) -> (ActionResult);
  play         : (CardsRequest) -> (ActionResult);

  poll : (PollRequest) -> (PollResponse) query;
  sync : (PollRequest) -> (PollResponse);
};
```

`ActionResult` is `#ok { seq; penalized }` or `#err { seq; code; detail }`. An
`#err` never changes game state, and `ok.penalized = true` means a beatable
throw lead was replaced by its first beatable component (reconcile the hand
from the next poll).

## Card encoding

A card is a `nat` id in `1..108`. Two identical 52-card decks occupy ids
`1..104` (deck 1 = `1..52`, deck 2 = `53..104`); the last four ids are jokers —
`105`/`107` small, `106`/`108` big.

For a non-joker id, fold it back into `1..52` with `n = id > 52 ? id - 52 : id`,
then:

- `suitIdx = (n - 1) % 4` over `[♠, ♥, ♣, ♦]` (`0..3`)
- `rankIdx = (n - 1) / 4` over `[3,4,5,6,7,8,9,10,J,Q,K,A,2]`

Ranks are numbers `2..14` (`11=J, 12=Q, 13=K, 14=A`), and the deal's level is
one of them. The wire trump value is `1..4` for a suit (`suitIdx + 1`) and `5`
for No-Trump.

## Table configuration

`createTable` takes an optional `TableConfig`; null uses the defaults.

```candid
type TableConfig = record {
  targetLevel : Level;             // epoch ladder goal (default 14 = A)
  dealTickSeconds : nat;           // one card per seat per tick
  declareSeconds : opt nat;        // post-deal declaration window
  overrideSeconds : opt nat;       // counter-declaration window after a call
  burySeconds : opt nat;           // banker timeout
  playSeconds : opt nat;           // turn timeout -> auto-play
  eventRetentionSeconds : opt nat; // log retention (default 3 days)
  firstDealer : Seat;
  enhancedJokerOverride : bool;
  endWhenAllBots : bool;           // end once no human-owned seat remains
};
```

Defaults: `targetLevel 14`, `dealTickSeconds 1`, `declareSeconds 15`,
`overrideSeconds 10`, `burySeconds 60`, `playSeconds 45`,
`eventRetentionSeconds 259200`, `firstDealer 0`, `enhancedJokerOverride false`,
`endWhenAllBots true`.
