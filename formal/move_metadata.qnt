// Metadata labels represent exact-match equivalence classes. Numeric tolerance
// boundaries, missing/nonfinite values and byte verification remain Rust tests.
module move_metadata {
  type State = {
    sourceA: int, sourceB: int, targetX: int, targetY: int,
    originalsX: Set[int], originalsY: Set[int], authorized: bool
  }
  var s: State
  val originals = Set(0, 1)

  action init = {
    nondet a = Set(0, 1, 2, 3, 4).oneOf()
    nondet b = Set(0, 1, 2, 3, 4).oneOf()
    nondet x = Set(0, 1, 2, 3, 4).oneOf()
    nondet y = Set(0, 1, 2, 3, 4).oneOf()
    nondet rx = originals.powerset().oneOf()
    nondet ry = originals.powerset().oneOf()
    s' = { sourceA: a, sourceB: b, targetX: x, targetY: y,
      originalsX: rx, originalsY: ry, authorized: false }
  }

  // domain.rs: union checksums from destinations with this source's metadata.
  def preserved(metadata: int): Set[int] =
    (if (s.targetX == metadata) s.originalsX else Set())
      .union(if (s.targetY == metadata) s.originalsY else Set())
  val byteCoverage = originals.subseteq(s.originalsX.union(s.originalsY))
  val checked = Set(0).subseteq(preserved(s.sourceA)) and
                Set(1).subseteq(preserved(s.sourceB))
  action step = all {
    byteCoverage, checked,
    s' = { ...s, authorized: true }
  }
  // Old first-source-only verifier accepts merged or split wrong metadata.
  action unsafeFirstSourceStep = all {
    byteCoverage,
    s.originalsX == Set() or s.targetX == s.sourceA,
    s.originalsY == Set() or s.targetY == s.sourceA,
    s' = { ...s, authorized: true }
  }

  val everyOriginalPreserved = not(s.authorized) or all {
    (s.originalsX.contains(0) and s.targetX == s.sourceA) or
      (s.originalsY.contains(0) and s.targetY == s.sourceA),
    (s.originalsX.contains(1) and s.targetX == s.sourceB) or
      (s.originalsY.contains(1) and s.targetY == s.sourceB)
  }
  // A counterexample here is a positive witness: differing sources can move
  // when separate destinations actually preserve their individual metadata.
  val differingSourcesNeverAuthorized = not(s.authorized and s.sourceA != s.sourceB)
}
