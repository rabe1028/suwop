# Transfer lifecycle model

`transfer_lifecycle.qnt` specifies one Copy or explicit Move of two distinct
original resources. `overlapping_moves.qnt` checks two already verified receipts
whose source keys may share a provider/account scope or belong to distinct scopes. The Quint model is translated to TLA+ and checked with TLC.
The check is exhaustive over this finite model, not randomized simulation or
bounded exploration of an infinite system. It checks safety, not liveness under
arbitrary network failures.

Run `make setup`, then `make check-transfer-model`. `make check` and the existing
CI lint job run the same check. Node, Java and Quint are pinned in `mise.toml` /
`mise.lock`; the runner explicitly selects Apalache 0.62.1 for translation and
its bundled TLC. No runtime Rust dependency is added.

The runner writes complete logs and a model/config fingerprint under
`.tools/formal-verification/`. A pass requires TLC to finish with an empty state
queue. Parser, Java, download and timeout errors cannot count as a pass or as an
expected counterexample. Each invocation uses a private translation-server port. If the safe model fails,
controls are skipped so a missing tool or download failure does not repeat nine
times.

## Mapping to the application

| Model action/state | Application obligation |
| --- | --- |
| `persistCopying` | Save the Copy/Move receipt before creating remote media. |
| `persistWrite` / `submitWrite` | For Apple/Immich, reuse the acknowledged receipt checkpoint; Amazon additionally persists each upload journal intent before submission. |
| `completeWrite` | Native completion can store none, one or both resources and can lose its response. |
| `verifyOriginals` | Read back and compare the complete original manifest and actual hashes. |
| `completeCopy` / `persistCopied` | Publish/persist `Copied` only after accepted, attributed creation and verification. |
| `refreshEvidence` | Revalidate source, destination, original signatures, metadata, access and scope. |
| `prepareDeletion` / `persistDeletion` | Only an explicit Move can enter `DeletingSource`; save it before native deletion. |
| `submitDeletion` | Recheck both sides' epochs in Rust; `HttpDeletion` carries Immich Move deletion to the captured native context and locked submission permit. PhotoKit rechecks inside its change transaction. |
| `rollbackUnsubmitted` / `persistRollback` | Only current process proof of non-submission can restore `Copied`; never infer it after restart. |
| `completeDeletion` | A lost or negative response remains uncertain; the native side effect may have occurred. |
| `persistTerminal` | Persist `Moved` or `DeletionUncertain` without returning to a retryable phase. |
| `persistDeletionUnacked` | A save may commit without acknowledgment; only the live process retains proof it has not called deletion. |
| `recoverDeletion` | A restarted durable deletion is uncertain even if no native request was sent. |
| `crash` / `restart` | Restore the durable phase, discard volatile permits, and never reuse old callbacks. |

The phase names intentionally match the Rust `TransferPhase` variants; their
existing camelCase serialization remains unchanged.
The Rust reducer and workflow tests must remain aligned with these obligations;
checking this separate model is not a proof that arbitrary changes to Rust or
Swift refine it. The effect-level tests are responsible for the correspondence
between durable acknowledgments, native submission and the modeled actions.

## Executable correspondence checks

The offline shell harness in
[`tests/suite/workflow.rs`](../crates/suwop-core/tests/suite/workflow.rs) drives the
real Crux workflow and records persistence/native effects. It checks the durable
save before import/deletion, Copy refusal, lost deletion responses, restart with
a saved deletion stage, failed save rollback and access/scope changes. The
[`transfer_lifecycle.rs` tests](../crates/suwop-core/tests/suite/transfer_lifecycle.rs)
exercise verified manifests and receipt binding; the shell tests supply the
independent ordering evidence. Amazon's corresponding fake-service tests live
in [`tests/suite/amazon.rs`](../crates/suwop-core/tests/suite/amazon.rs).

The runner's unit tests also check phase-domain drift between the model and Rust,
specific control properties being included in `safety`, exact empty-queue
recognition and failure/cancellation cleanup. These checks reduce drift; they do
not turn this separate specification into a mechanically checked refinement.

## Safety properties and mutation controls

- Every native write requires its durable checkpoint.
- A copied receipt requires complete original verification.
- Copy, including a legacy receipt defaulted to Copy, cannot delete its source.
- Deletion requires an already durable deletion intent and current authorization.
- An uncertain/in-flight deletion is never retried, including after restart.
- Source removal can only follow the single authorized deletion attempt (a structural constraint: only native deletion completion removes the source).

Eight deliberately unsafe step relations relax protocol guards (one directly
injects a repeated native deletion). The runner
checks the specific intended invariant for each control and requires a real counterexample, so a vacuous model, a skipped
checker or a broken Java installation cannot silently validate the controls.

## Overlapping receipts

A receipt ID alone cannot fence a source deletion: two `Copied` Move receipts can
name the same source. The overlap model serializes workflows, retains remote
requests across crashes, and explores both same-scope and different-scope keys.
An in-flight or uncertain deletion recorded by either receipt blocks another
Move of that source key; Copy stays available in the implementation. The fence
is not cleared automatically, and a confirmed `Moved` receipt is not a fence.

The unsafe overlap control removes that admission guard and must produce a
second native request for the same source key. A separate **positive witness**
checks that two distinct scopes can each submit: this prevents an overbroad fence
from passing merely by disabling all second operations. It is a reachability
query, not a safety invariant. The runner fingerprints and checks both models.

This second model starts with verified `Copied` receipts, using the first model's
original-preservation obligation as an assumption. It does not model restoration
of a successfully deleted source into a new source generation. It checks the
cross-receipt fence, not a mechanical composition/refinement proof.

## Scope and assumptions

- Each resource identifier represents expected original bytes, not just a name.
  Hash correctness, codecs and service format claims are outside this model.
- The original manifest is known, complete and unambiguous. Native observations,
  RAW/Live resource pairing, duplicate detection and metadata comparison are
  independently tested in Rust/native fixtures.
- A pending native operation can finish after a crash. Its old callback cannot
  complete the restarted workflow. Read-only reconciliation does not silently
  convert an unknown upload into an attributed, completed Copy receipt.
- A failed save issues no permit. Volatile phase preparation may remain until a failed persist is rolled back or the workflow stops; only an acknowledged save advances the durable state. For deletion, a save committed with a lost acknowledgment can also retain live
  proof of non-submission until rollback; a crash discards that proof. Other
  lost storage acknowledgments are represented by crashing after persistence.
- Lease/account invalidations represent changes observed by Suwop. Separate
  services offer no cross-provider transaction: an unobservable third-party
  deletion or modification after destination verification is outside the
  guarantee. The model does not claim that a remote original remains available
  forever after verification.
- The model covers the existing three backends' shared transfer protocol, not a
  Google Photos implementation, service availability, actual PhotoKit/iCloud
  behavior, or real-account acceptance.
