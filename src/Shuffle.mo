/// Seeded Fisher–Yates shuffle and deck construction.
///
/// The deal shuffle is deliberately isolated from the network: `newDeck` and
/// `shuffle` are pure, so tests can replay a deal from a fixed seed and the
/// canister can feed in `Random.blob()` entropy at deal creation.
import Array "mo:core/Array";
import Blob "mo:core/Blob";
import Nat8 "mo:core/Nat8";
import Nat32 "mo:core/Nat32";
import Nat64 "mo:core/Nat64";
import Random "mo:core/Random";
import VarArray "mo:core/VarArray";
import Card "Card";

module {
  /// A fresh, ordered deck: the 108 canonical card IDs (1..108).
  public func newDeck() : [Card.Card] {
    Array.tabulate<Card.Card>(108, func i = i + 1)
  };

  /// Derive a 64-bit PRNG seed from an entropy blob (FNV-1a over the bytes,
  /// with wrapping 64-bit arithmetic). Deterministic: the same blob always
  /// yields the same seed, which is what T10 (determinism) relies on.
  public func seedFromBlob(b : Blob) : Nat64 {
    let bytes = Blob.toArray(b);
    var acc : Nat64 = 0xcbf29ce484222325;
    let prime : Nat64 = 0x100000001b3;
    for (byte in bytes.vals()) {
      let x = Nat64.bitxor(acc, Nat32.toNat64(Nat8.toNat32(byte)));
      acc := Nat64.mulWrap(x, prime);
    };
    acc;
  };

  /// Seeded Fisher–Yates shuffle. Returns a permutation of `deck` containing
  /// every element exactly once; the same `(deck, seed)` always returns the
  /// same permutation.
  public func shuffle(deck : [Card.Card], seed : Nat64) : [Card.Card] {
    let rng = Random.seed(seed);
    let arr = Array.toVarArray<Card.Card>(deck);
    var i = arr.size();
    while (i > 1) {
      i -= 1;
      let j = rng.natRange(0, i + 1);
      let tmp = arr[i];
      arr[i] := arr[j];
      arr[j] := tmp;
    };
    VarArray.toArray<Card.Card>(arr);
  };
}
