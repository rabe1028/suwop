// One transfer of two original resources. Remote completions survive a crash.
// Scope/lease invalidation models changes that have been observed by Suwop;
// unobservable third-party changes across providers are not a transaction.
module transfer_lifecycle {
  type State = {
    phase: str, durable: str, intent: str, alive: bool,
    writeCheckpoint: str, writeFence: bool, writeDurable: bool, writePermit: bool,
    writeWasDurable: bool,
    writePending: bool, writeAccepted: bool, writeOwnerCurrent: bool, writes: int,
    stored: Set[int], verified: bool, copiedEvidence: bool,
    sourcePresent: bool, fresh: bool, lease: bool, sameAccount: bool,
    deletePermit: bool, unsubmitted: bool, deletePending: bool, deleteOwnerCurrent: bool, deletes: int,
    deleteWasDurable: bool, deleteWasAuthorized: bool
  }
  var s: State
  val originals = Set(0, 1)

  action init = {
    nondet intent = Set("Copy", "Move").oneOf()
    nondet checkpoint = Set("Receipt", "Journal").oneOf()
    s' = {
      phase: "Copying", durable: "None", intent: intent, alive: true,
      writeCheckpoint: checkpoint, writeFence: false, writeDurable: false, writePermit: false,
      writeWasDurable: false,
      writePending: false, writeAccepted: false, writeOwnerCurrent: false, writes: 0,
      stored: Set(), verified: false, copiedEvidence: false,
      sourcePresent: true, fresh: false, lease: true, sameAccount: true,
      deletePermit: false, unsubmitted: false, deletePending: false, deleteOwnerCurrent: false, deletes: 0,
      deleteWasDurable: false, deleteWasAuthorized: false
    }
  }

  action persistCopying = all {
    s.alive, s.phase == "Copying", s.durable == "None",
    s' = { ...s, durable: "Copying",
      writeDurable: s.writeCheckpoint == "Receipt",
      writePermit: s.writeCheckpoint == "Receipt" }
  }
  action prepareWrite = all {
    s.alive, s.phase == "Copying", s.durable == "Copying",
    s.writeCheckpoint == "Journal", not(s.writeFence), s.writes == 0,
    s' = { ...s, writeFence: true }
  }
  action persistWrite = all {
    s.alive, s.writeFence, not(s.writeDurable),
    s' = { ...s, writeDurable: true, writePermit: true }
  }
  action submitWriteChecked(requireDurable: bool): bool = all {
    s.alive, (not(requireDurable) or (s.writePermit and s.writeDurable)),
    s.phase == "Copying", s.lease, s.sameAccount,
    s.writes == 0,
    s' = { ...s, writes: s.writes + 1, writePermit: false, writePending: true,
      writeOwnerCurrent: true,
      writeWasDurable: s.writeDurable and s.durable == "Copying" }
  }
  action submitWrite = submitWriteChecked(true)
  // Neither receiving no response nor restarting proves that nothing was stored.
  action completeWrite = {
    nondet stored = Set(Set(), Set(0), originals).oneOf()
    nondet responseReceived = Set(false, true).oneOf()
    all {
      s.writePending,
      s' = { ...s, stored: stored, writePending: false,
        writeAccepted: s.alive and s.writeOwnerCurrent and responseReceived and stored == originals }
    }
  }
  action verifyOriginals = all {
    s.alive, s.phase == "Copying", s.stored == originals,
    s.lease, s.sameAccount,
    s' = { ...s, verified: true }
  }
  // Read-only reconciliation of an unknown upload does not finish a Copy receipt.
  action completeCopyChecked(requireVerification: bool, requireAttribution: bool): bool = all {
    s.alive, s.phase == "Copying", not(requireAttribution) or s.writeAccepted,
    not(requireVerification) or s.verified,
    s.lease, s.sameAccount,
    s' = { ...s, phase: "Copied", copiedEvidence: s.writeAccepted and s.verified }
  }
  action completeCopy = completeCopyChecked(true, true)
  action persistCopied = all {
    s.alive, s.phase == "Copied", s.durable == "Copying",
    s' = { ...s, durable: "Copied" }
  }
  action refreshEvidence = all {
    s.alive, s.phase == "Copied", s.durable == "Copied",
    s.sourcePresent, s.stored == originals, s.lease, s.sameAccount,
    s' = { ...s, fresh: true }
  }
  action prepareDeletionChecked(requireMove: bool): bool = all {
    s.alive, s.phase == "Copied", s.durable == "Copied", not(requireMove) or s.intent == "Move",
    s.fresh, s.lease, s.sameAccount, s.copiedEvidence,
    s' = { ...s, phase: "DeletingSource", unsubmitted: true }
  }
  action prepareDeletion = prepareDeletionChecked(true)
  action persistDeletion = all {
    s.alive, s.phase == "DeletingSource", s.durable == "Copied",
    s' = { ...s, durable: "DeletingSource", deletePermit: true }
  }
  // Storage may commit while its acknowledgment is lost in a live process.
  // The live operation still knows it has not called native deletion.
  action persistDeletionUnacked = all {
    s.alive, s.phase == "DeletingSource", s.durable == "Copied", s.unsubmitted,
    s' = { ...s, durable: "DeletingSource", deletePermit: false }
  }
  action submitDeletionChecked(requireDurable: bool, requireMove: bool, requireAuthority: bool): bool = all {
    s.alive, s.phase == "DeletingSource",
    not(requireDurable) or (s.durable == "DeletingSource" and s.deletePermit),
    s.deletes < 2, not(requireMove) or s.intent == "Move",
    not(requireAuthority) or (s.fresh and s.lease and s.sameAccount),
    s.copiedEvidence,
    s' = { ...s, deletes: s.deletes + 1, deletePermit: false, unsubmitted: false,
      deletePending: true, deleteOwnerCurrent: true,
      deleteWasDurable: s.durable == "DeletingSource" and s.deletePermit,
      deleteWasAuthorized: s.fresh and s.lease and s.sameAccount }
  }
  action submitDeletion = submitDeletionChecked(true, true, true)
  // Only current process knowledge can prove non-submission, including
  // after a failed/lost save acknowledgment. It is lost on crash.
  // A restarted operation or a sent request has no such proof.
  action rollbackUnsubmittedChecked(requireProof: bool): bool = all {
    s.alive, s.phase == "DeletingSource",
    Set("Copied", "DeletingSource").contains(s.durable),
    not(requireProof) or (s.unsubmitted and not(s.deletePending)),
    s' = { ...s, phase: "Copied", deletePermit: false, unsubmitted: false, fresh: false }
  }
  action rollbackUnsubmitted = rollbackUnsubmittedChecked(true)
  action persistRollback = all {
    s.alive, s.phase == "Copied", s.durable == "DeletingSource",
    s' = { ...s, durable: "Copied" }
  }
  // Restart loses the proof of non-submission even if no request was sent.
  action recoverDeletion = all {
    s.alive, s.phase == "DeletingSource", s.durable == "DeletingSource",
    not(s.deletePermit), not(s.unsubmitted), not(s.deleteOwnerCurrent),
    s' = { ...s, phase: "DeletionUncertain" }
  }
  action completeDeletion = {
    nondet applied = Set(false, true).oneOf()
    nondet responseReceived = Set(false, true).oneOf()
    all {
      s.deletePending,
      s' = { ...s, deletePending: false, sourcePresent: not(applied),
        phase: if (s.alive and s.deleteOwnerCurrent) {
          if (applied and responseReceived) "Moved" else "DeletionUncertain"
        } else s.phase }
    }
  }
  action persistTerminal = all {
    s.alive, Set("Moved", "DeletionUncertain").contains(s.phase),
    s.durable == "DeletingSource",
    s' = { ...s, durable: s.phase }
  }
  // Failing a persist does not mint a permit; crashing before/after any persist
  // explores both possible durable outcomes of a lost storage response.
  action failPersist = all { s.alive, s' = s }
  action invalidate = all {
    s.lease, s' = { ...s, lease: false, fresh: false }
  }
  action switchAccount = all {
    s.sameAccount, s' = { ...s, sameAccount: false, fresh: false }
  }
  action crash = all {
    s.alive,
    s' = { ...s, alive: false,
      phase: if (s.durable == "None") "Copying" else s.durable,
      writeFence: s.writeDurable, writePermit: false, writeAccepted: false,
      writeOwnerCurrent: false, deleteOwnerCurrent: false,
      verified: false, fresh: false, deletePermit: false, unsubmitted: false }
  }
  action restart = all { not(s.alive), s' = { ...s, alive: true } }

  action step = any {
    persistCopying, prepareWrite, persistWrite, submitWrite, completeWrite,
    verifyOriginals, completeCopy, persistCopied, refreshEvidence,
    prepareDeletion, persistDeletion, persistDeletionUnacked, submitDeletion, rollbackUnsubmitted,
    persistRollback, recoverDeletion, completeDeletion,
    persistTerminal, failPersist, invalidate, switchAccount, crash, restart
  }

  val typeOK = all {
    Set("Copying", "Copied", "DeletingSource", "Moved", "DeletionUncertain").contains(s.phase),
    Set("None", "Copying", "Copied", "DeletingSource", "Moved", "DeletionUncertain").contains(s.durable),
    Set("Copy", "Move").contains(s.intent),
    Set("Receipt", "Journal").contains(s.writeCheckpoint),
    s.writes >= 0, s.writes <= 1, s.deletes >= 0, s.deletes <= 2,
    s.stored.subseteq(originals)
  }
  val copiedRequiresOriginals =
    (s.phase != "Copying") implies s.copiedEvidence
  val durableBeforeWrite = (s.writes > 0) implies s.writeWasDurable
  val noCopyDeletion = (s.deletes > 0) implies (s.intent == "Move")
  val durableBeforeDeletion = (s.deletes > 0) implies s.deleteWasDurable
  val authorizedBeforeDeletion = (s.deletes > 0) implies s.deleteWasAuthorized
  val noDeletionRetry = s.deletes <= 1
  val sourceOnlyRemovedByDeletion = not(s.sourcePresent) implies (s.deletes == 1)
  val safety = all {
    typeOK, copiedRequiresOriginals, durableBeforeWrite, noCopyDeletion, durableBeforeDeletion,
    authorizedBeforeDeletion, noDeletionRetry, sourceOnlyRemovedByDeletion
  }

  // Mutation controls: each must produce an actual invariant counterexample.
  action retryDeletion = all {
    s.alive, s.deletes == 1,
    Set("DeletingSource", "DeletionUncertain").contains(s.durable),
    s' = { ...s, deletes: 2 }
  }
  action unsafePersistStep = any { step, submitDeletionChecked(false, true, true) }
  action unsafeCopyStep = any { step, prepareDeletionChecked(false),
    submitDeletionChecked(true, false, true) }
  action unsafeRetryStep = any { step, retryDeletion }
  action unsafeVerificationStep = any { step, completeCopyChecked(false, true) }
  action unsafeAuthorityStep = any { step, submitDeletionChecked(true, true, false) }
  action unsafeAttributionStep = any { step, completeCopyChecked(true, false) }
  action unsafeWriteStep = any { step, submitWriteChecked(false) }
  action unsafeRollbackStep = any { step, rollbackUnsubmittedChecked(false) }
}
