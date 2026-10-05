/// Ingress principal classification and the multi-seat admission rule.
///
/// Pure functions so they can be unit-tested without an actor. The actor uses
/// them to decide who may call (canister vs user vs anonymous), who may hold
/// more than one seat in a table, who may skip a private table's auth code, and
/// who may claim a vacated seat for somebody else — the last three are all
/// "whitelisted bots only", resolved against the bot whitelist rather than the
/// caller's principal class.
import Blob "mo:core/Blob";
import Nat8 "mo:core/Nat8";
import Principal "mo:core/Principal";

module {
  /// Principal classes (IC `PrincipalId::class()`): the class is the last byte
  /// of the principal's blob. The empty principal is the management canister.
  public let MANAGEMENT : Nat = 0;
  public let OPAQUE : Nat = 1;
  public let SELF_AUTHENTICATING : Nat = 2;
  public let DERIVED : Nat = 3;
  public let ANONYMOUS : Nat = 4;

  public func principalClass(p : Principal) : Nat {
    let a = Blob.toArray(Principal.toBlob(p));
    if (a.size() == 0) { return MANAGEMENT };
    Nat8.toNat(a[a.size() - 1]);
  };

  /// Canisters are opaque (1) or derived (3); users are self-authenticating (2).
  public func isCanister(p : Principal) : Bool {
    let c = principalClass(p);
    c == OPAQUE or c == DERIVED;
  };

  public func isAnonymous(p : Principal) : Bool {
    principalClass(p) == ANONYMOUS;
  };

  /// A principal may hold one seat per table; a second or later seat requires
  /// the operator whitelist. `alreadySeated` is the table-level check.
  public func mayTakeSeat(whitelisted : Bool, alreadySeated : Bool) : Bool {
    not alreadySeated or whitelisted;
  };

  /// May `joinTable` skip a private table's auth code? Only the trusted bot
  /// canister, and only to attach a seat the table already claims for it (from
  /// `createTable.reserved` or `leaveTable.reserveFor`) — an open seat of a
  /// private table belongs to whoever holds the invitation link, not to a bot.
  ///
  /// Both inputs are table/actor facts, deliberately passed in rather than
  /// derived from the caller's principal *class*: `isCanister` returns true for
  /// any opaque-class principal, and anyone can deploy a canister, so class
  /// alone would open every private table to the first random canister that
  /// probed its id.
  public func maySkipAuthCode(whitelistedBot : Bool, attachesClaimedSeat : Bool) : Bool {
    whitelistedBot and attachesClaimedSeat;
  };

  /// May this `leaveTable` claim the vacated seat for another principal
  /// (`reserveFor`)? A hand-over must have the operator's trusted bot on one
  /// side: either the bot is leaving and passing on a seat it holds, or an
  /// ordinary seat is being handed to the bot so the deal keeps playing.
  ///
  /// What it rejects is a principal naming an arbitrary third party. The target
  /// neither consents nor is notified, yet the seat keeps its hidden hand: the
  /// next principal to attach reads the whole remaining hand through
  /// `PlayerView.myHand`, and a seat claimed for someone who never turns up
  /// blocks `allReady`, so the table can never start. Both flows the feature
  /// exists for survive: the bot handing a replaceable seat to the human who
  /// asked for it, and a human handing their seat to the bot.
  ///
  /// Both inputs are table/actor facts, resolved against the bot whitelist
  /// rather than a principal *class* (see `maySkipAuthCode`).
  public func mayReserveSeat(fromWhitelisted : Bool, targetWhitelisted : Bool) : Bool {
    fromWhitelisted or targetWhitelisted;
  };
}
