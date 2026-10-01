/// Canonical card model for the Tractor canister.
///
/// One card-ID mapping is used everywhere (engine, API, tests, client):
/// the rank-major layout implemented by `tractor.js:cardToString`.
///
///   id 1..52   -> deck 1, id 53..104 -> deck 2 (map `id-52`)
///   suitIdx = (id-1) mod 4 over [spades, hearts, clubs, diamonds]
///   rankIdx = (id-1) / 4 over [3,4,5,6,7,8,9,10,J,Q,K,A,2]
///   105,107 = small joker; 106,108 = big joker
///
/// Ranks are represented as numbers 2..14 with 11=J, 12=Q, 13=K, 14=A.
/// The current level is one of those rank numbers.
import Array "mo:core/Array";
import List "mo:core/List";
import Nat "mo:core/Nat";
import VarArray "mo:core/VarArray";
import Util "Util";

module {
  /// A card identity, 1..108.
  public type Card = Nat;

  public let MIN_ID : Nat = 1;
  public let MAX_ID : Nat = 108;

  // Physical suit indices, matching the JS engine's `suitIdx`.
  public let SPADES : Nat = 0;
  public let HEARTS : Nat = 1;
  public let CLUBS : Nat = 2;
  public let DIAMONDS : Nat = 3;

  // Wire trump value: 1..4 select a suit (suitIdx + 1); 5 means No-Trump.
  public let NT : Nat = 5;

  // Rank numbers.
  public let RANK_2 : Nat = 2;
  public let RANK_3 : Nat = 3;
  public let RANK_5 : Nat = 5;
  public let RANK_10 : Nat = 10;
  public let RANK_J : Nat = 11;
  public let RANK_Q : Nat = 12;
  public let RANK_K : Nat = 13;
  public let RANK_A : Nat = 14;

  /// Context needed to classify cards: current level and trump suit.
  public type Game = {
    level : Nat; // 2..14
    trump : Nat; // 1..4, 5 = No-Trump
  };

  /// Decoded identity of a card. `suit`/`rank` are null for jokers.
  public type CardInfo = {
    id : Nat;
    suit : ?Nat; // 0..3
    rank : ?Nat; // 2..14
    isJoker : Bool;
    isSmallJoker : Bool;
    isBigJoker : Bool;
  };

  /// Logical suit used by the rule engine.
  public type Category = { #Trump; #Side : Nat }; // Side carries suit 0..3

  /// Identity used for pairing. Jokers never pair across ranks; level cards
  /// pair only within the same physical suit (encoded in #Normal).
  public type PairKey = {
    #Joker : Bool; // true = big joker
    #Normal : (Nat, Nat); // (suit 0..3, rank 2..14)
  };

  let allRanks : [Nat] = [2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14];
  let rankByIndex : [Nat] = [3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 2];
  let rankText : [Text] = [
    "3", "4", "5", "6", "7", "8", "9", "10", "J", "Q", "K", "A", "2",
  ];
  let suitText : [Text] = ["♠", "♥", "♣", "♦"];

  // Implicit equality for `Array.indexOf`.
  let equal = Nat.equal;

  /// True when `id` is a valid card identity.
  public func isValidId(id : Nat) : Bool {
    id >= MIN_ID and id <= MAX_ID
  };

  /// All 108 card IDs, in canonical order.
  public func allIds() : [Card] {
    Array.tabulate<Card>(108, func i = i + 1)
  };

  public func isSmallJoker(id : Card) : Bool {
    id == 105 or id == 107
  };

  public func isBigJoker(id : Card) : Bool {
    id == 106 or id == 108
  };

  public func isJoker(id : Card) : Bool {
    isSmallJoker(id) or isBigJoker(id)
  };

  /// Decode a card into its suit/rank/joker identity.
  public func cardInfo(id : Card) : CardInfo {
    if (isSmallJoker(id)) {
      {
        id;
        suit = null;
        rank = null;
        isJoker = true;
        isSmallJoker = true;
        isBigJoker = false;
      }
    } else if (isBigJoker(id)) {
      {
        id;
        suit = null;
        rank = null;
        isJoker = true;
        isSmallJoker = false;
        isBigJoker = true;
      }
    } else {
      let n = if (id >= 53) { Nat.sub(id, 52) } else { id };
      let suit = Nat.sub(n, 1) % 4;
      let rankIdx = Nat.sub(n, 1) / 4;
      {
        id;
        suit = ?suit;
        rank = ?rankByIndex[rankIdx];
        isJoker = false;
        isSmallJoker = false;
        isBigJoker = false;
      }
    }
  };

  /// Physical suit (0..3) for non-jokers; null for jokers.
  public func suitOf(id : Card) : ?Nat {
    if (isJoker(id)) { null } else {
      let n = if (id >= 53) { Nat.sub(id, 52) } else { id };
      ?(Nat.sub(n, 1) % 4)
    }
  };

  /// Rank (2..14) for non-jokers; null for jokers.
  public func rankOf(id : Card) : ?Nat {
    if (isJoker(id)) { null } else {
      let n = if (id >= 53) { Nat.sub(id, 52) } else { id };
      ?rankByIndex[Nat.sub(n, 1) / 4]
    }
  };

  /// Card ID for a (deck, suit, rank) triple. Deck is 1 or 2.
  public func makeId(deck : Nat, suit : Nat, rank : Nat) : Card {
    let rankIdx = if (rank == 2) { 12 } else { Nat.sub(rank, 3) };
    let local = rankIdx * 4 + suit + 1;
    if (deck == 2) { local + 52 } else { local }
  };

  /// The rank number of the current level.
  public func levelToRank(level : Nat) : Nat {
    level
  };

  /// The player-facing name of a card, matching `tractor.js:cardToString`.
  public func cardToString(id : Card) : Text {
    if (isSmallJoker(id)) {
      "🃟"
    } else if (isBigJoker(id)) {
      "🃏"
    } else {
      let info = cardInfo(id);
      let s = switch (info.suit) { case (?s) s; case null 0 };
      let r = switch (info.rank) { case (?r) r; case null 0 };
      let rIdx = if (r == 2) { 12 } else { Nat.sub(r, 3) };
      suitText[s] # rankText[rIdx]
    }
  };

  /// True when the card's rank equals the level.
  public func isLevel(id : Card, game : Game) : Bool {
    rankOf(id) == ?game.level
  };

  /// True when the card is trump under `game`.
  public func isTrump(id : Card, game : Game) : Bool {
    if (isJoker(id)) {
      true
    } else if (isLevel(id, game)) {
      true
    } else if (game.trump != NT and suitOf(id) == ?Nat.sub(game.trump, 1)) {
      true
    } else {
      false
    }
  };

  /// Logical suit of the card.
  public func category(id : Card, game : Game) : Category {
    if (isTrump(id, game)) { #Trump } else {
      switch (suitOf(id)) {
        case (?s) { #Side(s) };
        case null { #Trump };
      }
    }
  };

  /// Ranks in the side chain with the level removed.
  public func baseOrder(level : Nat) : [Nat] {
    Array.filter<Nat>(allRanks, func r = r != level)
  };

  /// Magnitude of a card within its logical suit. Only meaningful when
  /// comparing two cards of the same `Category`.
  public func rankValue(id : Card, game : Game) : Nat {
    if (isSmallJoker(id)) {
      if (game.trump == NT) { 1 } else { 14 }
    } else if (isBigJoker(id)) {
      if (game.trump == NT) { 2 } else { 15 }
    } else {
      let order = baseOrder(game.level);
      switch (rankOf(id)) {
        case (?r) {
          switch (order.indexOf(r)) {
            case (?idx) { idx };
            case null {
              // Level card: off-suit below on-suit; in NT all levels tie low.
              if (game.trump == NT) { 0 } else if (suitOf(id) == ?Nat.sub(game.trump, 1)) {
                13
              } else {
                12
              }
            };
          }
        };
        case null { 0 };
      }
    }
  };

  /// Pair identity of a card.
  public func pairKey(id : Card) : PairKey {
    if (isJoker(id)) {
      #Joker(isBigJoker(id))
    } else {
      switch (suitOf(id), rankOf(id)) {
        case (?s, ?r) { #Normal(s, r) };
        case _ { #Joker(false) };
      }
    }
  };

  /// Compact numeric pairing key in 0..53, suitable for array indexing:
  /// 0..51 = (suit * 13 + rankIdx), 52 = small joker, 53 = big joker.
  public func pairKeyId(id : Card) : Nat {
    if (isSmallJoker(id)) {
      52
    } else if (isBigJoker(id)) {
      53
    } else {
      let s = switch (suitOf(id)) { case (?s) s; case null 0 };
      let r = switch (rankOf(id)) { case (?r) r; case null 0 };
      let rankIdx = if (r == 2) { 12 } else { Nat.sub(r, 3) };
      s * 13 + rankIdx
    }
  };

  /// Number of distinct pair identities (index range of `pairKeyId`).
  public let PAIR_KEY_COUNT : Nat = 54;

  /// Face identity of a card (suit+rank, or joker), independent of deck.
  /// Identical to `pairKeyId` for valid IDs, but tolerates out-of-range IDs
  /// the way `tractor.js:cardToString` does (rank wraps mod 13), so the
  /// two-deck integrity guard can be exercised with fabricated copies.
  public func faceKey(id : Card) : Nat {
    if (isSmallJoker(id)) {
      52
    } else if (isBigJoker(id)) {
      53
    } else {
      let n = if (id >= 53 and id <= 104) { Nat.sub(id, 52) } else { id };
      let m = Nat.sub(n, 1);
      let suit = m % 4;
      let cardsIdx = (m / 4 + 1) % 13; // index into ["2","3",...,"A"]
      let rankIdx = if (cardsIdx == 0) { 12 } else { Nat.sub(cardsIdx, 1) };
      suit * 13 + rankIdx
    }
  };

  /// Points contributed by the card: 5 -> 5, 10/K -> 10, else 0.
  public func pointValue(id : Card) : Nat {
    switch (rankOf(id)) {
      case (?5) { 5 };
      case (?10) { 10 };
      case (?13) { 10 };
      case _ { 0 };
    }
  };

  /// Canonical order for a stored play: trumps first, then descending rank,
  /// then pair key and raw id. Deterministic, so a client's card order never
  /// leaks into the state or the event log.
  public func sortPlay(cards : [Card], game : Game) : [Card] {
    Util.sortBy<Card>(cards, func(a, b) = playCompare(a, b, game));
  };

  /// Three-way form of `sortPlay`'s order: positive when `a` belongs after
  /// `b`, negative when before, zero when equal.
  func playCompare(a : Card, b : Card, game : Game) : Int {
    let ta = isTrump(a, game);
    let tb = isTrump(b, game);
    if (ta != tb) { return if (tb) { 1 } else { -1 } };
    let ra = rankValue(a, game);
    let rb = rankValue(b, game);
    if (ra != rb) { return Util.cmpNat(rb, ra) };
    let ka = pairKeyId(a);
    let kb = pairKeyId(b);
    if (ka != kb) { return Util.cmpNat(ka, kb) };
    Util.cmpNat(a, b);
  };

  // ── card-list helpers shared by the rule modules ───────────────────

  /// True when `c` is an element of `hand`.
  public func contains(hand : [Card], c : Card) : Bool {
    var found = false;
    for (x in hand.vals()) { if (x == c) { found := true } };
    found;
  };

  /// True when the same physical card appears more than once in `cards`.
  public func hasDuplicate(cards : [Card]) : Bool {
    var i = 0;
    while (i < cards.size()) {
      var j = i + 1;
      while (j < cards.size()) {
        if (cards[i] == cards[j]) { return true };
        j += 1;
      };
      i += 1;
    };
    false;
  };

  /// Multiset difference `hand - remove`, preserving `hand` order. Each
  /// element of `remove` cancels at most one matching element of `hand`.
  public func difference(hand : [Card], remove : [Card]) : [Card] {
    let used = VarArray.repeat(false, remove.size());
    let out = List.empty<Card>();
    for (c in hand.vals()) {
      var removed = false;
      var i = 0;
      while (i < remove.size() and not removed) {
        if (not used[i] and remove[i] == c) {
          used[i] := true;
          removed := true;
        };
        i += 1;
      };
      if (not removed) { out.add(c) };
    };
    out.toArray();
  };
}
