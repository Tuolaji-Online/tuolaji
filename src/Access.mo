/// Ingress principal classification and the multi-seat admission rule.
///
/// Pure functions so they can be unit-tested without an actor. The actor uses
/// them to decide who may call (canister vs user vs anonymous) and who may
/// hold more than one seat in a table (whitelisted bots only).
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
}
