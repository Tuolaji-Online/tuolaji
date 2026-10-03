/// RFC 8439 known-answer tests for the vendored ChaCha20 CSPRNG, plus a couple
/// of behaviour checks. Ported from the upstream `temokoki/IC_CSPRNG` test.
import Array "mo:core/Array";
import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";
import Nat32 "mo:core/Nat32";
import ChaCha20 "../src/ChaCha20";
import Test "Test";

module {
  // RFC 8439 shared ascending key (bytes 00..1f).
  let ASC_KEY_BYTES : [Nat8] = [
    0x00,0x01,0x02,0x03,0x04,0x05,0x06,0x07,
    0x08,0x09,0x0a,0x0b,0x0c,0x0d,0x0e,0x0f,
    0x10,0x11,0x12,0x13,0x14,0x15,0x16,0x17,
    0x18,0x19,0x1a,0x1b,0x1c,0x1d,0x1e,0x1f,
  ];
  let RFC_NONCE_BYTES : [Nat8] = [0x00,0x00,0x00,0x09,0x00,0x00,0x00,0x4a,0x00,0x00,0x00,0x00];
  let RFC_SEC24_NONCE_BYTES : [Nat8] = [0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x4a,0x00,0x00,0x00,0x00];

  // The i-th little-endian 32-bit word of a 64-byte block.
  func wordLE(bytes : [Nat8], i : Nat) : Nat32 {
    let base = i * 4;
    let b0 = Nat8.toNat(bytes[base]);
    let b1 = Nat8.toNat(bytes[base + 1]);
    let b2 = Nat8.toNat(bytes[base + 2]);
    let b3 = Nat8.toNat(bytes[base + 3]);
    Nat.toNat32(b0 + b1 * 256 + b2 * 65536 + b3 * 16777216);
  };

  func blockMatches(block : [Nat8], expected : [Nat32]) : Bool {
    var ok = true;
    var i = 0;
    while (i < 16) {
      if (wordLE(block, i) != expected[i]) { ok := false };
      i += 1;
    };
    ok;
  };

  public func run(t : Test.Harness) {
    t.suite("ChaCha20 RFC 8439");
    let ascKey = Array.toBlob(ASC_KEY_BYTES);
    let rfcNonce = Array.toBlob(RFC_NONCE_BYTES);
    let rfcSec24Nonce = Array.toBlob(RFC_SEC24_NONCE_BYTES);

    // Section 2.3.2: a single block with counter 1.
    let expected232 : [Nat32] = [
      0xe4e7f110,0x15593bd1,0x1fdd0f50,0xc47120a3,
      0xc7f4d1c7,0x0368c033,0x9aaa2204,0x4e6cd4c3,
      0x466482d2,0x09aa9f07,0x05d7c214,0xa2028bd9,
      0xd19c12b5,0xb94e16de,0xe883d0cb,0x4e3c50a2,
    ];
    let rng = ChaCha20.RNG(ascKey, rfcNonce, 20);
    t.check(blockMatches(rng.getBlockBytes(), expected232), "Section 2.3.2 block vector");

    // Section 2.4: the first two blocks (counters 1 and 2).
    let expected1 : [Nat32] = [
      0xf3514f22,0xe1d91b40,0x6f27de2f,0xed1d63b8,
      0x821f138c,0xe2062c3d,0xecca4f7e,0x78cff39e,
      0xa30a3b8a,0x920a6072,0xcd7479b5,0x34932bed,
      0x40ba4c79,0xcd343ec6,0x4c2c21ea,0xb7417df0,
    ];
    let expected2 : [Nat32] = [
      0x9f74a669,0x410f633f,0x28feca22,0x7ec44dec,
      0x6d34d426,0x738cb970,0x3ac5e9f3,0x45590cc4,
      0xda6e8b39,0x892c831a,0xcdea67c1,0x2b7e1d90,
      0x037463f3,0xa11a2073,0xe8bcfb88,0xedc49139,
    ];
    let rng2 = ChaCha20.RNG(ascKey, rfcSec24Nonce, 20);
    t.check(blockMatches(rng2.getBlockBytes(), expected1), "Section 2.4 block 1");
    t.check(blockMatches(rng2.getBlockBytes(), expected2), "Section 2.4 block 2");

    // Determinism: the same (key, nonce) reproduces the stream.
    let a = ChaCha20.RNG(ascKey, rfcNonce, 20).getRandomBytes(32);
    let b = ChaCha20.RNG(ascKey, rfcNonce, 20).getRandomBytes(32);
    var same = true;
    var i = 0;
    while (i < 32) {
      if (a[i] != b[i]) { same := false };
      i += 1;
    };
    t.check(same, "the same key and nonce reproduce the stream");

    // Range sampling stays in [min, max).
    let r = ChaCha20.RNG(ascKey, rfcNonce, 20);
    var j = 0;
    var inRange = true;
    while (j < 200) {
      if (r.getRandomNumber(0, 108) >= 108) { inRange := false };
      j += 1;
    };
    t.check(inRange, "getRandomNumber stays below the exclusive bound");
  };
};
