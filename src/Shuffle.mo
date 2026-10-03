/// Seeded Fisher–Yates shuffle and deck construction.
///
/// The deal shuffle is deliberately isolated from the network: `newDeck` and
/// `shuffle` are pure, so tests can replay a deal from a fixed seed and the
/// canister can feed in `Random.blob()` entropy at deal creation.
import Array "mo:core/Array";
import Blob "mo:core/Blob";
import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";
import Nat32 "mo:core/Nat32";
import Nat64 "mo:core/Nat64";
import Random "mo:core/Random";
import VarArray "mo:core/VarArray";
import ChaCha20 "ChaCha20";
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

  /// The ChaCha20 key for a deal: exactly 32 bytes, derived from the beacon
  /// entropy. The canister passes one 32-byte `Random.blob()`, so this is the
  /// identity; shorter input is zero-padded and longer input folded in, so the
  /// shuffle stays total and a pure function of the entropy.
  func keyFromEntropy(entropy : Blob) : Blob {
    let bytes = Blob.toArray(entropy);
    let key = VarArray.repeat<Nat8>(0, 32);
    var i = 0;
    while (i < bytes.size()) {
      key[i % 32] ^= bytes[i];
      i += 1;
    };
    Array.toBlob(VarArray.toArray(key));
  };

  /// Fisher–Yates driven by a ChaCha20 keystream keyed by the beacon entropy,
  /// so every draw comes from real beacon randomness and the distribution is
  /// uniform (no modulo bias). The caller retains the entropy
  /// (`Table.dealEntropy`) and reveals it once the deal is scored, so anyone
  /// can replay the shuffle. The nonce is fixed because the key is unique per
  /// deal (a fresh beacon blob).
  public func shuffleWithEntropy(deck : [Card.Card], entropy : Blob) : [Card.Card] {
    if (entropy.size() == 0) { return deck };
    let rng = ChaCha20.RNG(
      keyFromEntropy(entropy),
      Array.toBlob(Array.repeat<Nat8>(0, 12)),
      20,
    );
    let arr = Array.toVarArray<Card.Card>(deck);
    var i = arr.size();
    while (i > 1) {
      i -= 1;
      let j = Nat64.toNat(rng.getRandomNumber(0, Nat.toNat64(i + 1)));
      let tmp = arr[i];
      arr[i] := arr[j];
      arr[j] := tmp;
    };
    VarArray.toArray<Card.Card>(arr);
  };
}
