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

  /// SplitMix64: a fast deterministic mixer used only to extend an exhausted
  /// entropy blob, so the shuffle stays a pure function of the revealed bytes.
  func splitmix64(z0 : Nat64) : Nat64 {
    var z = z0 +% 0x9E3779B97F4A7C15;
    z := (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
    z := (z ^ (z >> 27)) *% 0x94D049BB133111EB;
    z ^ (z >> 31);
  };

  /// Fisher–Yates driven directly by the beacon entropy blob, using rejection
  /// sampling so every permutation is reachable and the distribution is
  /// uniform. The caller retains the entropy (`Table.dealEntropy`) and reveals
  /// it once the deal is scored, so anyone can replay the shuffle.
  ///
  /// The blob is consumed byte by byte. If it is exhausted (the beacon returns
  /// 32 bytes, which is not always enough for 108 draws) the stream is extended
  /// deterministically from the same entropy.
  public func shuffleWithEntropy(deck : [Card.Card], entropy : Blob) : [Card.Card] {
    let seedBytes = Blob.toArray(entropy);
    if (seedBytes.size() == 0) { return deck };
    let arr = Array.toVarArray<Card.Card>(deck);
    var cursor = 0;
    var counter : Nat64 = 0;
    let seed = seedFromBlob(entropy);
    func nextByte() : Nat {
      if (cursor < seedBytes.size()) {
        let b = Nat8.toNat(seedBytes[cursor]);
        cursor += 1;
        return b;
      };
      counter +%= 1;
      Nat64.toNat(splitmix64(seed +% counter)) % 256;
    };
    // Uniform index in [0, bound) by rejection sampling over 16-bit draws.
    func nextBelow(bound : Nat) : Nat {
      let limit = 65536 - (65536 % bound);
      var v = nextByte() * 256 + nextByte();
      while (v >= limit) { v := nextByte() * 256 + nextByte() };
      v % bound;
    };
    var i = arr.size();
    while (i > 1) {
      i -= 1;
      let j = nextBelow(i + 1);
      let tmp = arr[i];
      arr[i] := arr[j];
      arr[j] := tmp;
    };
    VarArray.toArray<Card.Card>(arr);
  };
}
