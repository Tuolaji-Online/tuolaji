/// Small generic helpers shared by the rule modules: a stable insertion sort
/// and a three-way Nat comparator. Keeping them in one place gives the rule
/// code a single auditable implementation — notably the throw-penalty scan
/// order in `Lead`.
import Array "mo:core/Array";
import VarArray "mo:core/VarArray";

module {
  /// Three-way comparison of two naturals.
  public func cmpNat(a : Nat, b : Nat) : Int {
    if (a < b) { -1 } else if (a > b) { 1 } else { 0 };
  };

  /// Stable insertion sort. `cmp(a, b) < 0` means `a` sorts before `b`.
  /// Hands and leads are small, so the O(n^2) bound is irrelevant.
  public func sortBy<T>(arr : [T], cmp : (T, T) -> Int) : [T] {
    let out = Array.toVarArray<T>(arr);
    var i = 1;
    while (i < out.size()) {
      let key = out[i];
      var j = i;
      while (j > 0 and cmp(out[j - 1], key) > 0) {
        out[j] := out[j - 1];
        j -= 1;
      };
      out[j] := key;
      i += 1;
    };
    VarArray.toArray<T>(out);
  };
}
