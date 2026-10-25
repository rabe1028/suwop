// Two already verified receipts. Each names one source key in scope 0 or 1.
// The detailed original verification protocol is checked separately. Workflows
// are serialized, but an old native request may finish after a process crash.
module overlapping_moves {
  type State = {
    phaseA: str, phaseB: str, durableA: str, durableB: str,
    intentA: str, intentB: str, scopeA: int, scopeB: int,
    permitA: bool, permitB: bool, pendingA: bool, pendingB: bool,
    ownerA: bool, ownerB: bool, busy: str, alive: bool,
    present0: bool, present1: bool, requests0: int, requests1: int
  }
  var s: State
  val blocking = Set("DeletingSource", "DeletionUncertain")
  val terminal = Set("Moved", "DeletionUncertain")

  action init = {
    nondet scopeA = Set(0, 1).oneOf()
    nondet scopeB = Set(0, 1).oneOf()
    nondet intentA = Set("Copy", "Move").oneOf()
    nondet intentB = Set("Copy", "Move").oneOf()
    s' = {
      phaseA: "Copied", phaseB: "Copied", durableA: "Copied", durableB: "Copied",
      scopeA: scopeA, scopeB: scopeB, intentA: intentA, intentB: intentB,
      permitA: false, permitB: false, pendingA: false, pendingB: false,
      ownerA: false, ownerB: false, busy: "None", alive: true,
      present0: true, present1: true, requests0: 0, requests1: 0
    }
  }

  action beginAChecked(requireFence: bool): bool = all {
    s.alive, s.busy == "None", s.phaseA == "Copied", s.intentA == "Move",
    if (s.scopeA == 0) s.present0 else s.present1,
    not(requireFence) or not(s.scopeA == s.scopeB and blocking.contains(s.durableB)),
    s' = { ...s, phaseA: "DeletingSource", busy: "A" }
  }
  action beginBChecked(requireFence: bool): bool = all {
    s.alive, s.busy == "None", s.phaseB == "Copied", s.intentB == "Move",
    if (s.scopeB == 0) s.present0 else s.present1,
    not(requireFence) or not(s.scopeA == s.scopeB and blocking.contains(s.durableA)),
    s' = { ...s, phaseB: "DeletingSource", busy: "B" }
  }
  action persistA = all {
    s.alive, s.busy == "A", s.phaseA == "DeletingSource", s.durableA == "Copied",
    s' = { ...s, durableA: "DeletingSource", permitA: true }
  }
  action persistB = all {
    s.alive, s.busy == "B", s.phaseB == "DeletingSource", s.durableB == "Copied",
    s' = { ...s, durableB: "DeletingSource", permitB: true }
  }
  action submitA = all {
    s.alive, s.busy == "A", s.permitA,
    if (s.scopeA == 0) (s.present0 and s.requests0 < 2) else (s.present1 and s.requests1 < 2),
    s' = { ...s, permitA: false, pendingA: true, ownerA: true,
      requests0: s.requests0 + (if (s.scopeA == 0) 1 else 0),
      requests1: s.requests1 + (if (s.scopeA == 1) 1 else 0) }
  }
  action submitB = all {
    s.alive, s.busy == "B", s.permitB,
    if (s.scopeB == 0) (s.present0 and s.requests0 < 2) else (s.present1 and s.requests1 < 2),
    s' = { ...s, permitB: false, pendingB: true, ownerB: true,
      requests0: s.requests0 + (if (s.scopeB == 0) 1 else 0),
      requests1: s.requests1 + (if (s.scopeB == 1) 1 else 0) }
  }
  action completeA = {
    nondet applied = Set(false, true).oneOf()
    nondet received = Set(false, true).oneOf()
    all {
      s.pendingA,
      s' = { ...s, pendingA: false,
        present0: s.present0 and not(applied and s.scopeA == 0),
        present1: s.present1 and not(applied and s.scopeA == 1),
        phaseA: if (s.alive and s.ownerA) {
          if (applied and received) "Moved" else "DeletionUncertain"
        } else s.phaseA }
    }
  }
  action completeB = {
    nondet applied = Set(false, true).oneOf()
    nondet received = Set(false, true).oneOf()
    all {
      s.pendingB,
      s' = { ...s, pendingB: false,
        present0: s.present0 and not(applied and s.scopeB == 0),
        present1: s.present1 and not(applied and s.scopeB == 1),
        phaseB: if (s.alive and s.ownerB) {
          if (applied and received) "Moved" else "DeletionUncertain"
        } else s.phaseB }
    }
  }
  action finishA = all {
    s.alive, s.busy == "A", terminal.contains(s.phaseA),
    s' = { ...s, durableA: s.phaseA, busy: "None" }
  }
  action finishB = all {
    s.alive, s.busy == "B", terminal.contains(s.phaseB),
    s' = { ...s, durableB: s.phaseB, busy: "None" }
  }
  action crash = all {
    s.alive,
    s' = { ...s, alive: false, busy: "None", phaseA: s.durableA, phaseB: s.durableB,
      permitA: false, permitB: false, ownerA: false, ownerB: false }
  }
  action restart = all { not(s.alive), s' = { ...s, alive: true } }
  action failSave = all { s.alive, s' = s }

  action step = any {
    beginAChecked(true), beginBChecked(true), persistA, persistB, submitA, submitB,
    completeA, completeB, finishA, finishB, crash, restart, failSave
  }
  val typeOK = all {
    Set("Copied", "DeletingSource", "Moved", "DeletionUncertain").contains(s.phaseA),
    Set("Copied", "DeletingSource", "Moved", "DeletionUncertain").contains(s.phaseB),
    Set("Copied", "DeletingSource", "Moved", "DeletionUncertain").contains(s.durableA),
    Set("Copied", "DeletingSource", "Moved", "DeletionUncertain").contains(s.durableB),
    Set("None", "A", "B").contains(s.busy),
    s.requests0 >= 0, s.requests0 <= 2, s.requests1 >= 0, s.requests1 <= 2
  }
  // Counts belong to full source keys, not to receipt IDs or bare asset IDs.
  val noOverlappingDeletion = s.requests0 <= 1 and s.requests1 <= 1
  val safety = all { typeOK, noOverlappingDeletion }
  action unsafeOverlapStep = any { step, beginAChecked(false), beginBChecked(false) }
  // A counterexample with the SAFE step is a positive reachability witness:
  // independent account/scope keys can both submit. This is not an invariant.
  val independentScopesNeverBothSubmitted = not(s.requests0 == 1 and s.requests1 == 1)
}
