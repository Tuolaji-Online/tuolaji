/// Unit tests for the one-off timer scheduler's queue operations.
/// The `arm`/`cancel` path needs the `system` capability, so it is exercised
/// by the PocketIC protocol suite instead.
import Scheduler "../src/Scheduler";
import Test "Test";

module {
  public func run(t : Test.Harness) {
    t.suite("Scheduler queue");
    let st = Scheduler.new();
    t.check(Scheduler.earliest(st) == null, "a fresh scheduler has nothing queued");
    t.equalNat(Scheduler.takeDue(st, 100).size(), 0, "nothing is due on an empty queue");

    Scheduler.upsert(st, 1, 50);
    Scheduler.upsert(st, 2, 30);
    Scheduler.upsert(st, 3, 70);
    t.check(Scheduler.earliest(st) == ?30, "earliest is the minimum queued time");

    // Replacing a table's time keeps a single entry.
    Scheduler.upsert(st, 2, 80);
    t.check(Scheduler.earliest(st) == ?50, "replacing a time updates the minimum");

    // Only due entries are drained, and they are removed.
    let due = Scheduler.takeDue(st, 60);
    t.equalNat(due.size(), 1, "only the due table is drained");
    t.check(due[0] == 1, "the drained table is the one that was due");
    t.check(Scheduler.earliest(st) == ?70, "the remaining minimum is the later entry");

    Scheduler.remove(st, 2);
    t.check(Scheduler.earliest(st) == ?70, "removing a later table keeps the minimum");
    Scheduler.remove(st, 3);
    t.check(Scheduler.earliest(st) == null, "removing the last table empties the queue");
    Scheduler.remove(st, 99);
    t.check(Scheduler.earliest(st) == null, "removing an unknown table is a no-op");
  };
};
