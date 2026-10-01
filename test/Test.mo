/// Tiny assertion harness for the pure `moc -r` test suite.
///
/// Instantiate once in `Run.mo` and pass it to each test group. Equality is
/// supplied by the caller: comparing a type parameter directly (`==`) would
/// widen it to `Any` and silently mis-compare variant payloads, so callers use
/// the typed convenience methods or pass an explicit comparator.
import Debug "mo:core/Debug";
import Nat "mo:core/Nat";
import Text "mo:core/Text";

module {
  public class Harness() {
    var passed : Nat = 0;
    var failed : Nat = 0;
    var currentSuite : Text = "";

    /// Set the group name used to prefix failure messages.
    public func suite(name : Text) {
      currentSuite := name;
    };

    func pass() { passed += 1 };
    func fail(msg : Text) {
      failed += 1;
      Debug.print("  ✗ [" # currentSuite # "] " # msg);
    };

    /// Record a boolean assertion.
    public func check(cond : Bool, msg : Text) {
      if (cond) { pass() } else { fail(msg) };
    };

    /// Assert equality using an explicit comparator.
    public func equalBy<T>(eq : (T, T) -> Bool, actual : T, expected : T, msg : Text) {
      if (eq(actual, expected)) { pass() } else { fail(msg) };
    };

    /// Assert inequality using an explicit comparator.
    public func notEqualBy<T>(eq : (T, T) -> Bool, actual : T, expected : T, msg : Text) {
      if (not eq(actual, expected)) { pass() } else { fail(msg) };
    };

    public func equalNat(actual : Nat, expected : Nat, msg : Text) {
      equalBy<Nat>(Nat.equal, actual, expected, msg);
    };

    public func equalText(actual : Text, expected : Text, msg : Text) {
      equalBy<Text>(Text.equal, actual, expected, msg);
    };

    /// Print the summary and trap on any failure so `moc -r` exits non-zero.
    public func summary() {
      Debug.print("─────────────────────────────");
      Debug.print("Passed: " # Nat.toText(passed) # "  Failed: " # Nat.toText(failed));
      Debug.print("─────────────────────────────");
      assert failed == 0;
    };
  };
}
