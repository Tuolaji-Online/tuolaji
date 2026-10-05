/// Canister-wide one-off timer scheduler.
///
/// Instead of a `recurringTimer` that wakes every 250 ms even when nothing is
/// happening, each table contributes at most one pending wake time — its
/// earliest future deadline (`Table.nextTimer`). The scheduler stores those in
/// a map and arms a single one-off `Timer.setTimer` for the earliest one. When
/// it fires, `main` drains the due tables, applies their deadline work, and
/// re-arms. With nothing pending no timer is installed at all, so an idle
/// canister is not woken.
///
/// `State` is an enhanced-orthogonal-persistence stable type: a mutable `Map`
/// of `Nat -> Int` plus an optional `Nat` timer id. Timers themselves do not
/// survive upgrades, so `main` resets `timer` and re-arms in `postupgrade`.
import List "mo:core/List";
import Map "mo:core/Map";
import Nat "mo:core/Nat";
import Int "mo:core/Int";
import Timer "mo:core/Timer";
import Types "Types";

module {
  public type State = {
    var entries : Map.Map<Types.TableId, Types.Timestamp>;
    var timer : ?Timer.TimerId;
  };

  public func new() : State {
    { var entries = Map.empty(); var timer = null };
  };

  /// Record (or replace) a table's earliest pending wake time.
  public func upsert(st : State, id : Types.TableId, at : Types.Timestamp) {
    Map.add(st.entries, id, at);
  };

  /// Forget a table's pending wake time (idle, ended, or evicted).
  public func remove(st : State, id : Types.TableId) {
    Map.remove(st.entries, id);
  };

  /// Earliest queued wake time, or null when nothing is pending.
  public func earliest(st : State) : ?Types.Timestamp {
    var min : ?Types.Timestamp = null;
    for ((_, at) in Map.entries(st.entries)) {
      switch (min) {
        case null { min := ?at };
        case (?m) { if (at < m) { min := ?at } };
      };
    };
    min;
  };

  /// Drain (and remove) every table whose wake time is at or before `now`.
  public func takeDue(st : State, now : Types.Timestamp) : [Types.TableId] {
    let due = List.empty<Types.TableId>();
    for ((id, at) in Map.entries(st.entries)) {
      if (at <= now) { due.add(id) };
    };
    for (id in due.values()) { Map.remove(st.entries, id) };
    due.toArray();
  };

  /// Cancel the armed timer, if any. Cancelling an id whose timer has already
  /// fired is a no-op, which is the usual case once the callback has run.
  func cancelArmed(st : State) {
    switch (st.timer) {
      case (?id) { Timer.cancelTimer(id) };
      case null {};
    };
    st.timer := null;
  };

  /// Cancel any armed timer and install a fresh one-off for the earliest
  /// queued event (or leave none armed when the queue is empty). Past-due
  /// entries arm with a zero delay so the callback runs on the next tick.
  public func arm<system>(st : State, now : Types.Timestamp, job : () -> async ()) {
    cancelArmed(st);
    switch (earliest(st)) {
      case null {};
      case (?at) {
        let delay = if (at > now) { Int.toNat(at - now) } else { 0 };
        st.timer := ?Timer.setTimer<system>(#nanoseconds delay, job);
      };
    };
  };

  /// Arm a one-off fallback wake `delay` nanoseconds out, replacing whatever was
  /// armed; `arm` then replaces it with the real schedule. Because `arm`
  /// installs nothing when the queue is empty, a fallback armed by a wake that
  /// turns out to need nothing does not survive it, and an idle canister still
  /// keeps no timer.
  ///
  /// This is a best-effort safety net, not a guarantee. It only helps where a
  /// callback aborts *without* discarding the state change that scheduled it -
  /// `Scheduler.State` is the caller's own state, so a Wasm trap that rolls the
  /// call back takes the fallback with it. See `main.fire` for what actually
  /// recovers that case (a rebuild in `postupgrade`, or the next ingress's
  /// `touch`).
  public func armFallback<system>(st : State, delay : Nat, job : () -> async ()) {
    cancelArmed(st);
    st.timer := ?Timer.setTimer<system>(#nanoseconds delay, job);
  };
};
