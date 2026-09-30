/// Trump declaration and override precedence (RULES.md 亮主规则).
import Card "Card";
import Types "Types";

module {
  public type DeclareKind = Types.DeclareKind;

  public type Declaration = Types.Declaration;

  public type DeclareResult = {
    #Ok : Declaration;
    #Reject : Types.CheckError;
  };

  public func declaredValue(kind : DeclareKind) : Nat {
    switch (kind) {
      case (#Single) { 1 };
      case (#Pair) { 2 };
      case (#SmallJokerPair) { 3 };
      case (#BigJokerPair) { 4 };
    };
  };

  /// Classify a declaration's cards: one level card, a level-card pair, or a
  /// joker pair. Returns (kind, wire trump suit).
  public func classify(cards : [Card.Card], game : Card.Game) : ?(DeclareKind, Nat) {
    if (cards.size() == 1) {
      let c = cards[0];
      if (Card.isLevel(c, game)) {
        switch (Card.suitOf(c)) {
          case (?s) { ?(#Single, s + 1) };
          case null { null };
        };
      } else {
        null;
      };
    } else if (cards.size() == 2) {
      let a = cards[0];
      let b = cards[1];
      if (Card.isSmallJoker(a) and Card.isSmallJoker(b)) {
        ?(#SmallJokerPair, Card.NT);
      } else if (Card.isBigJoker(a) and Card.isBigJoker(b)) {
        ?(#BigJokerPair, Card.NT);
      } else if (
        Card.isLevel(a, game) and Card.isLevel(b, game) and
        Card.suitOf(a) == Card.suitOf(b)
      ) {
        switch (Card.suitOf(a)) {
          case (?s) { ?(#Pair, s + 1) };
          case null { null };
        };
      } else {
        null;
      };
    } else {
      null;
    };
  };

  /// Is `current` a No-Trump call (a joker pair)? No-Trump sits at the top of
  /// the ladder and is final: nothing can override it.
  func isNoTrump(current : Declaration) : Bool {
    current.suit == Card.NT;
  };

  /// Can `next` override `current`? A No-Trump call is final. Otherwise a pair
  /// is terminal unless `enhancedJokerOverride` is on, in which case a joker
  /// pair may still override a level-card pair.
  public func canOverride(next : Declaration, current : ?Declaration, enhanced : Bool) : Bool {
    switch (current) {
      case null { true };
      case (?cur) {
        if (isNoTrump(cur) or (cur.value >= 2 and not enhanced)) {
          false;
        } else {
          next.value > cur.value;
        };
      };
    };
  };

  /// Is `current` a call that nothing can answer? A No-Trump call (joker pair)
  /// is always final. Otherwise a pair already blocks every counter-declaration
  /// unless `enhancedJokerOverride` is on, in which case a joker pair can still
  /// override a level-card pair. A single level card can always be outbid by a
  /// pair. This is what tells the table it may skip the counter-declaration
  /// window.
  public func isTerminal(current : Declaration, enhanced : Bool) : Bool {
    isNoTrump(current) or (
      current.value >= 2 and (
        not enhanced or current.value >= declaredValue(#BigJokerPair)
      )
    );
  };

  /// Validate and build a declaration.
  public func declareTrump(
    cards : [Card.Card],
    hand : [Card.Card],
    game : Card.Game,
    seat : Nat,
    inDealing : Bool,
    current : ?Declaration,
    enhanced : Bool,
  ) : DeclareResult {
    if (not inDealing) {
      return #Reject({ code = #IllegalDeclaration; detail = "not in dealing phase" });
    };
    for (c in cards.vals()) {
      var found = false;
      for (h in hand.vals()) { if (h == c) { found := true } };
      if (not found) {
        return #Reject({ code = #IllegalDeclaration; detail = "declaration card not held" });
      };
    };
    switch (classify(cards, game)) {
      case null {
        #Reject({ code = #IllegalDeclaration; detail = "cards do not form a declaration" });
      };
      case (?(kind, suit)) {
        let decl : Declaration = {
          seat;
          kind;
          suit;
          value = declaredValue(kind);
        };
        if (canOverride(decl, current, enhanced)) {
          #Ok(decl);
        } else {
          #Reject({ code = #IllegalDeclaration; detail = "declaration does not override current" });
        };
      };
    };
  };
}
