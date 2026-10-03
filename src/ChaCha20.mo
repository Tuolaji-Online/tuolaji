/// Ported from https://github.com/temokoki/IC_CSPRNG (MIT License, Copyright
/// (c) 2024 Temo_Koki) to the `mo:core` standard library. The algorithm is
/// unchanged; only the imports and a few `mo:base` -> `mo:core` API calls
/// differ.
///
/// ChaCha-based cryptographically secure pseudo-random number generator.
///
/// This implementation follows RFC 8439 (ChaCha20 & Poly1305 for IETF Protocols):
/// - 32-byte key (256-bit)
/// - 12-byte nonce (96-bit)
/// - 32-bit block counter (word 12) starting at 1 (counter=0 can be reserved for Poly1305 key gen)
/// - 20, 12 or 8 rounds selectable (ChaCha20 / ChaCha12 / ChaCha8). Default recommended is 20.
/// - Little-endian word assembly & serialization (canonical ChaCha convention).
///
/// NOTE: This is a breaking change vs earlier versions (<2.0.0) which used a non-standard
/// big-endian word assembly / serialization. Keystreams produced by previous versions will
/// NOT match those from this canonical version for the same (key, nonce, counter).
///
/// Security considerations:
/// - Nonce MUST be unique per key (never reuse the same (key, nonce)).
/// - Maximum bytes per (key, nonce) limited by 2^32 blocks * 64 bytes = ~256 GiB; exceeding this
///   risks keystream reuse. We enforce a guard and trap on counter wrap.
/// - For very large streams, change nonce or re-seed before the guard triggers.
/// - The random number functions use rejection sampling to avoid modulo bias.
///
/// Additional API:
/// - fill(buf)        : fills a mutable byte buffer in place (no allocation)
/// - reseed(key,nonce): reset internal state & counter
/// - setCounter(c)    : set the 32-bit block counter (advanced usage; ensure no overlap)
/// - getBlockBytes()  : returns next raw 64-byte keystream block (aligned) (utility)
///
/// Random number helpers optimize power-of-two ranges by masking (no rejection loop required).
///
/// Implementation notes:
/// - Rotations use Motoko's '<<>=' operator on Nat32 (rotate-left).
/// - State words are updated per block by copying base constants+key+nonce and inserting counter.
/// - Keystream block generation reuses a single working array to reduce allocation churn.

import Blob "mo:core/Blob";
import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";
import Nat32 "mo:core/Nat32";
import Nat64 "mo:core/Nat64";
import Array "mo:core/Array";
import Iter "mo:core/Iter";
import VarArray "mo:core/VarArray";

module {
  /// `mo:core/Iter` has no `range`; keep the source's inclusive-range call
  /// sites by adapting to `Nat.range` (exclusive end).
  func range(from : Nat, toInclusive : Nat) : Iter.Iter<Nat> = Nat.range(from, toInclusive + 1);

  /// RFC 8439 compliant ChaCha-based cryptographically secure pseudo-random number generator.
  ///
  /// Creates a new ChaCha RNG instance with the specified key, nonce, and round count.
  ///
  /// Example:
  /// ```motoko
  /// import ChaChaRNG "mo:ic-csprng";
  /// import Random "mo:core/Random";
  ///
  /// let key = await Random.blob();      // 32 bytes
  /// let nonce = await Random.blob();    // 12 bytes (truncate if needed)
  /// let rng = ChaChaRNG.RNG(key, nonce, 20);
  ///
  /// let randomBytes = rng.getRandomBytes(64);
  /// let randomNumber = rng.getRandomNumber(0, 1000);
  /// ```
  ///
  /// Parameters:
  /// - `keyBlob`: Exactly 32 bytes of cryptographic key material
  /// - `nonceBlob`: Exactly 12 bytes of nonce (must be unique per key)
  /// - `roundCount`: Number of ChaCha rounds (8, 12, or 20). 20 recommended for security.
  public class RNG(keyBlob : Blob, nonceBlob : Blob, roundCount : Nat) {
    // Validate inputs (exact size)
    assert keyBlob.size() == 32;
    assert nonceBlob.size() == 12;
    assert (roundCount == 20) or (roundCount == 12) or (roundCount == 8);

    // Internal working state buffers reused per block (avoid allocations)
    let workingState : [var Nat32] = VarArray.repeat<Nat32>(0, 16);
    let originalState : [var Nat32] = VarArray.repeat<Nat32>(0, 16);
    let byteBuffer : [var Nat8] = VarArray.repeat<Nat8>(0, 64);
    var bufferIndex : Nat = 64; // forces first refill
    var stateCounter : Nat32 = 1; // starting counter (1 consistent with RFC examples)
    var preWrapGuard : Bool = false; // optional stricter guard: block before 0xFFFFFFFF
    var zeroizeOnReseed : Bool = true; // allow disabling for performance benchmarking

    // Convert Blob -> array of little-endian 32-bit words
    func blobToWordsLE(b : Blob) : [Nat32] {
      let bytes = Blob.toArray(b);
      let length = bytes.size() / 4;
      Array.tabulate<Nat32>(length, func(i) {
        let idx = i * 4;
        Nat.toNat32(Nat8.toNat(bytes[idx])) +
        (Nat.toNat32(Nat8.toNat(bytes[idx + 1])) << 8) +
        (Nat.toNat32(Nat8.toNat(bytes[idx + 2])) << 16) +
        (Nat.toNat32(Nat8.toNat(bytes[idx + 3])) << 24)
      });
    };

    // Store key and nonce in mutable var arrays for reseed.
    let keyWords = blobToWordsLE(keyBlob);
    let nonceWords = blobToWordsLE(nonceBlob);
    let key : [var Nat32] = VarArray.tabulate<Nat32>(8, func(i) { keyWords[i] });
    let nonce : [var Nat32] = VarArray.tabulate<Nat32>(3, func(i) { nonceWords[i] });

    // Base immutable words (constants + key + nonce placeholders inserted during block build)
    let constants : [Nat32] = [0x61707865, 0x3320646E, 0x79622D32, 0x6B206574];

    // Quarter round (rotations via rotate-left)
    func quarterRound(state: [var Nat32], a: Nat, b: Nat, c: Nat, d: Nat) {
      state[a] +%= state[b]; state[d] ^= state[a]; state[d] := state[d] <<> 16;
      state[c] +%= state[d]; state[b] ^= state[c]; state[b] := state[b] <<> 12;
      state[a] +%= state[b]; state[d] ^= state[a]; state[d] := state[d] <<> 8;
      state[c] +%= state[d]; state[b] ^= state[c]; state[b] := state[b] <<> 7;
    };

    // Prepare workingState with current counter, then run rounds & feed-forward.
    func chachaBlock() {
      // Optional pre-wrap guard (refuse to emit final block with counter 0xFFFFFFFF)
      if (preWrapGuard and stateCounter == 0xFFFFFFFF) {
        assert false;
      };
      // Guard against counter wrap (keystream reuse) AFTER increment would wrap to 0
      if (stateCounter == 0) {
        assert false; // Critical security violation - counter has wrapped
      };

      // Load initial state
      workingState[0] := constants[0];
      workingState[1] := constants[1];
      workingState[2] := constants[2];
      workingState[3] := constants[3];
      workingState[4] := key[0];
      workingState[5] := key[1];
      workingState[6] := key[2];
      workingState[7] := key[3];
      workingState[8] := key[4];
      workingState[9] := key[5];
      workingState[10] := key[6];
      workingState[11] := key[7];
      workingState[12] := stateCounter; // counter (LE)
      workingState[13] := nonce[0];
      workingState[14] := nonce[1];
      workingState[15] := nonce[2];

      // Snapshot
      for (i in range(0,15)) { originalState[i] := workingState[i]; };
      // Increment counter for next block
      stateCounter +%= 1;
      // Rounds
      for (_ in range(0, (roundCount / 2) - 1)) {
        // Column rounds
        quarterRound(workingState,0,4,8,12);
        quarterRound(workingState,1,5,9,13);
        quarterRound(workingState,2,6,10,14);
        quarterRound(workingState,3,7,11,15);
        // Diagonal rounds
        quarterRound(workingState,0,5,10,15);
        quarterRound(workingState,1,6,11,12);
        quarterRound(workingState,2,7,8,13);
        quarterRound(workingState,3,4,9,14);
      };
      // Feed-forward and serialize (little-endian)
      var bi = 0;
      for (i in range(0,15)) {
        workingState[i] +%= originalState[i];
        let v = workingState[i];
        // little-endian store
        byteBuffer[bi] := Nat8.fromIntWrap(Nat32.toNat(v)); bi += 1;
        byteBuffer[bi] := Nat8.fromIntWrap(Nat32.toNat(v >> 8)); bi += 1;
        byteBuffer[bi] := Nat8.fromIntWrap(Nat32.toNat(v >> 16)); bi += 1;
        byteBuffer[bi] := Nat8.fromIntWrap(Nat32.toNat(v >> 24)); bi += 1;
      };
    };

    // Internal keystream byte consumption helpers (avoid per-call allocations for numbers)
    func refillIfNeeded() { if (bufferIndex >= 64) { chachaBlock(); bufferIndex := 0; } };
    func takeByte() : Nat8 { refillIfNeeded(); let b = byteBuffer[bufferIndex]; bufferIndex += 1; b };

    func readAccum(byteCount : Nat) : Nat64 {
      var acc : Nat64 = 0;
      if (byteCount == 0) return 0;
      for (i in range(0, byteCount - 1)) {
        acc := acc | (Nat.toNat64(Nat8.toNat(takeByte())) << Nat.toNat64(8 * i));
      };
      acc
    };

    /// Fill caller-provided mutable buffer with cryptographically secure random bytes.
    ///
    /// This is the most efficient method for generating random data as it writes
    /// directly to your buffer without allocations.
    ///
    /// Example:
    /// ```motoko
    /// let buffer : [var Nat8] = VarArray.repeat<Nat8>(0, 64);
    /// rng.fill(buffer);
    /// // buffer now contains 64 random bytes
    /// ```
    ///
    /// - `buf`: Mutable array to fill with random bytes
    public func fill(buf : [var Nat8]) {
      let n = buf.size();
      var written : Nat = 0;

      while (written < n) {
        if (bufferIndex >= 64) { chachaBlock(); bufferIndex := 0; };
        let available : Nat = Nat.sub(64, bufferIndex); // bufferIndex < 64 here
        let need : Nat = Nat.sub(n, written); // written < n ensured by loop condition
        let take = if (need < available) need else available;
        for (i in range(0, take - 1)) { buf[written + i] := byteBuffer[bufferIndex + i]; };
        bufferIndex += take; written += take;
      };
    };

    /// Generate and return an array of cryptographically secure random bytes.
    ///
    /// Example:
    /// ```motoko
    /// let randomData = rng.getRandomBytes(32);  // 32 random bytes
    /// let empty = rng.getRandomBytes(0);        // empty array
    /// ```
    ///
    /// - `byteCount`: Number of random bytes to generate
    /// - Returns: Array of random bytes
    public func getRandomBytes(byteCount : Nat) : [Nat8] {
      if (byteCount == 0) return [];
      let out : [var Nat8] = VarArray.repeat<Nat8>(0, byteCount);
      fill(out);
      VarArray.toArray(out)
    };

    /// Generate a cryptographically secure random number in the range [min, max).
    ///
    /// Uses rejection sampling to ensure uniform distribution without modulo bias.
    /// Optimized for power-of-two ranges using bit masking.
    ///
    /// Example:
    /// ```motoko
    /// let dice = rng.getRandomNumber(1, 7);      // 1-6 (dice roll)
    /// let percent = rng.getRandomNumber(0, 100); // 0-99 (percentage)
    /// let coin = rng.getRandomNumber(0, 2);      // 0-1 (coin flip)
    /// ```
    ///
    /// - `min`: Inclusive lower bound
    /// - `max`: Exclusive upper bound (must be > min)
    /// - Returns: Random number in range [min, max)
    public func getRandomNumber(min : Nat64, max : Nat64) : Nat64 {
      assert (max > min);
      let span = max - min; // size of interval
      if (span == 1) return min;
      if ((span & (span - 1)) == 0) { // power-of-two span length
        let bitCount = 64 - Nat64.bitcountLeadingZero(span - 1);
        let byteCount = Nat64.toNat((bitCount + 7) >> 3);
        let acc = readAccum(byteCount);
        return min + (acc & (span - 1));
      };
      let (byteCount, bitMask) = calculateByteCountBitMask(span - 1);
      min + generateNumberStreaming(span - 1, byteCount, bitMask)
    };

    /// Generate multiple random numbers in the range [min, max) efficiently.
    ///
    /// More efficient than calling getRandomNumber() multiple times for large batches.
    ///
    /// Example:
    /// ```motoko
    /// let numbers = rng.getRandomNumbers(0, 100, 10);  // 10 numbers from 0-99
    /// let empty = rng.getRandomNumbers(0, 10, 0);      // empty array
    /// ```
    ///
    /// - `min`: Inclusive lower bound
    /// - `max`: Exclusive upper bound (must be > min)
    /// - `count`: Number of random numbers to generate
    /// - Returns: Array of random numbers in range [min, max)
    public func getRandomNumbers(min : Nat64, max : Nat64, count : Nat) : [Nat64] {
      if (count == 0) return [];
      assert (max > min);
      let span = max - min;
      if (span == 1) return Array.tabulate<Nat64>(count, func _ { min });
      if ((span & (span - 1)) == 0) {
        let bitCount = 64 - Nat64.bitcountLeadingZero(span - 1);
        let byteCount = Nat64.toNat((bitCount + 7) >> 3);
        return Array.tabulate<Nat64>(count, func _ {
          let acc = readAccum(byteCount);
          min + (acc & (span - 1))
        });
      };
      let (byteCount, bitMask) = calculateByteCountBitMask(span - 1);
      Array.tabulate<Nat64>(count, func _ { min + generateNumberStreaming(span - 1, byteCount, bitMask) })
    };

    /// Generate the next 64 random bits as a Nat64 value.
    ///
    /// Efficient method for getting 8 bytes of randomness as a single value.
    ///
    /// Example:
    /// ```motoko
    /// let randomU64 = rng.nextU64();
    /// let randomBits = rng.nextU64() & 0xFFFF;  // Use only lower 16 bits
    /// ```
    ///
    /// - Returns: 64-bit random value
    public func nextU64() : Nat64 { readAccum(8) };

    /// Check if the pre-wrap guard is enabled.
    ///
    /// The pre-wrap guard prevents generating the final block before counter wraps to 0,
    /// providing additional security margin.
    ///
    /// - Returns: true if pre-wrap guard is enabled
    public func isPreWrapGuardEnabled() : Bool { preWrapGuard };

    /// Enable the pre-wrap guard for additional security.
    ///
    /// When enabled, the RNG will trap before generating a block with counter 0xFFFFFFFF,
    /// preventing potential keystream reuse after counter wrap.
    ///
    /// Example:
    /// ```motoko
    /// rng.enablePreWrapGuard();
    /// // Now RNG will trap before counter reaches 0xFFFFFFFF
    /// ```
    public func enablePreWrapGuard() { preWrapGuard := true };

    /// Disable automatic zeroization during reseed operations.
    ///
    /// By default, sensitive state is zeroized before overwriting with new values.
    /// This can be disabled for performance benchmarking.
    ///
    /// Example:
    /// ```motoko
    /// rng.disableZeroizeOnReseed();  // For performance testing only
    /// ```
    public func disableZeroizeOnReseed() { zeroizeOnReseed := false };

    /// Enable automatic zeroization during reseed operations (default).
    ///
    /// Ensures old key/nonce material is securely erased before new values are set.
    ///
    /// Example:
    /// ```motoko
    /// rng.enableZeroizeOnReseed();  // Re-enable if previously disabled
    /// ```
    public func enableZeroizeOnReseed() { zeroizeOnReseed := true };

    /// Securely destroy the RNG by zeroizing all sensitive state.
    ///
    /// After calling destroy(), this RNG instance should not be used.
    /// This provides defense-in-depth by clearing cryptographic material from memory.
    ///
    /// Example:
    /// ```motoko
    /// rng.destroy();  // Clear all sensitive state
    /// // RNG should not be used after this point
    /// ```
    public func destroy() {
      for (i in range(0,7)) { key[i] := 0 };
      for (i in range(0,2)) { nonce[i] := 0 };
      for (i in range(0,15)) { workingState[i] := 0; originalState[i] := 0 };
      for (i in range(0,63)) { byteBuffer[i] := 0 };
      stateCounter := 0;
      bufferIndex := 64;
    };

    /// Re-seed the RNG with new cryptographic material and reset internal state.
    ///
    /// This allows reusing the same RNG instance with fresh entropy, resetting
    /// the block counter to 1 and clearing buffers.
    ///
    /// Example:
    /// ```motoko
    /// let newKey = await Random.blob();    // 32 bytes
    /// let newNonce = await Random.blob();  // 12 bytes
    /// rng.reseed(newKey, newNonce);
    /// // RNG now generates a completely different sequence
    /// ```
    ///
    /// - `newKey`: Exactly 32 bytes of new key material
    /// - `newNonce`: Exactly 12 bytes of new nonce (must be unique per key)
    public func reseed(newKey : Blob, newNonce : Blob) {
      assert newKey.size() == 32; assert newNonce.size() == 12;
      // Optional zeroization of existing key/nonce material before overwrite (defense in depth)
      if (zeroizeOnReseed) {
        for (i in range(0,7)) { key[i] := 0 };
        for (i in range(0,2)) { nonce[i] := 0 };
        // Also zeroize working buffers for better security hygiene
        for (i in range(0,15)) { workingState[i] := 0; originalState[i] := 0 };
        for (i in range(0,63)) { byteBuffer[i] := 0 };
      };
      let k = blobToWordsLE(newKey); let n = blobToWordsLE(newNonce);
      for (i in range(0,7)) { key[i] := k[i]; };
      for (i in range(0,2)) { nonce[i] := n[i]; };
      stateCounter := 1; bufferIndex := 64; // force refill
    };

    /// Set explicit 32-bit block counter value (advanced usage).
    ///
    /// ⚠️  **DANGER**: Avoid overlapping with previously generated blocks to prevent
    /// keystream reuse. Only use if you understand the security implications.
    ///
    /// Example:
    /// ```motoko
    /// rng.setCounter(1000);  // Skip to block 1000
    /// // Ensure blocks 1-999 were never generated with this (key,nonce)
    /// ```
    ///
    /// - `c`: New counter value
    public func setCounter(c : Nat32) { stateCounter := c; bufferIndex := 64; };

    /// Return the next aligned 64-byte ChaCha keystream block.
    ///
    /// This advances the internal counter and returns raw ChaCha output.
    /// Useful for applications that need block-aligned data or ChaCha primitive access.
    ///
    /// Example:
    /// ```motoko
    /// let block = rng.getBlockBytes();  // 64 bytes of raw ChaCha keystream
    /// assert block.size() == 64;
    /// ```
    ///
    /// - Returns: Array of exactly 64 bytes from ChaCha keystream
    public func getBlockBytes() : [Nat8] {
      chachaBlock(); bufferIndex := 64; // mark buffer consumed
      Array.tabulate<Nat8>(64, func(i) { byteBuffer[i] })
    };

    // Internal helpers for range sampling.
    func calculateByteCountBitMask(rangeSize : Nat64) : (Nat, Nat64) {
      let bitCount = 64 - Nat64.bitcountLeadingZero(rangeSize);
      let byteCount = Nat64.toNat((bitCount + 7) >> 3);
      let bitMask : Nat64 = if (bitCount == 64) {
        0xFFFFFFFFFFFFFFFF
      } else {
        (1 : Nat64 << bitCount) - 1 : Nat64
      };
      (byteCount, bitMask)
    };

  // Streaming variant (no temporary array allocation)
    func generateNumberStreaming(rangeSize : Nat64, byteCount : Nat, bitMask : Nat64) : Nat64 {
      loop {
        let acc0 = readAccum(byteCount) & bitMask;
        if (acc0 <= rangeSize) return acc0;
      }
    };
  };
};