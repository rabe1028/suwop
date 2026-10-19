//! Private transition kernel. No HTTP, native CAS, routes, serde or native I/O.
use super::super::video::ImmichLockedVideoAcquisitionLease;
use super::policy::{MemberRole, PairedBudget};
use crate::domain::{AssetKey, FileSignature, Provider};
use std::{
    sync::{
        Arc, Mutex, MutexGuard,
        atomic::{AtomicU64, Ordering},
    },
    time::{Duration, Instant},
};

#[derive(Debug, Clone, PartialEq, Eq)]
struct Identity {
    request_id: String,
    plan_id: String,
    scene_id: String,
    grant_id: String,
    generation: u64,
}
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct Lease {
    id: u64,
    deadline: Instant,
}
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum MediaKind {
    Image,
    Video,
}
#[derive(Debug, Clone, PartialEq, Eq)]
struct Fingerprint {
    key: AssetKey,
    kind: MediaKind,
    revision: String,
    sha1: String,
    placement: crate::immich_live_resources::LiveObservedVisibility,
}
#[derive(Debug, Clone, PartialEq, Eq)]
struct PairEvidence {
    members: [Fingerprint; 2],
    forward_motion: AssetKey,
}
#[derive(Debug)]
struct FixedContract {
    identity: Identity,
    pair_lease_id: String,
    quote_nonce: String,
    evidence: PairEvidence,
    budget: PairedBudget,
    initial_lease: Lease,
    hardcap: Instant,
}
#[derive(Debug, Clone)]
struct Owner(Arc<()>);
impl Owner {
    fn matches(&self, other: &Self) -> bool {
        Arc::ptr_eq(&self.0, &other.0)
    }
}

// Opaque inputs: only the future trusted verifier child module (and cfg(test)
// fixtures) can construct these private fields. None implements serde. An HTTP
// body, public Event, bool or unrelated-session result cannot mint a proof.
#[derive(Debug, Clone)]
pub(super) struct InitialProof {
    contract: Arc<FixedContract>,
    epoch: Arc<AtomicU64>,
    captured_epoch: u64,
    began_at: Instant,
    observed_at: Instant,
}
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum Stage {
    Parent,
    Motion,
    Prepare,
}
impl Stage {
    const fn index(self) -> usize {
        match self {
            Self::Parent => 0,
            Self::Motion => 1,
            Self::Prepare => 2,
        }
    }
}
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Purpose {
    Heartbeat,
    Start(Stage),
    Stage { kind: Stage, operation: u64 },
    Final,
    Publication,
    Display,
}
#[derive(Debug, Clone)]
pub(super) struct Capture {
    owner: Owner,
    epoch: Arc<AtomicU64>,
    captured_epoch: u64,
    contract: Arc<FixedContract>,
    purpose: Purpose,
    acknowledged_lease: u64,
    proof_round: u64,
    began_at: Instant,
}
#[derive(Debug, Clone)]
pub(super) struct PairProof {
    capture: Capture,
    observed_at: Instant,
    evidence: PairEvidence,
    /// Absolute monotonic status deadline from observation, not receipt time.
    status_deadline: Instant,
}
#[derive(Debug, Clone)]
pub(super) struct StageTicket {
    owner: Owner,
    contract: Arc<FixedContract>,
    kind: Stage,
    operation: u64,
    /// Completion may use this lease or a later contiguous successor, never older.
    start_acknowledged_lease: u64,
}
#[derive(Debug, Clone)]
enum Payload {
    Original {
        sha1: String,
        signature: FileSignature,
    },
    Prepared {
        prepared_id: String,
    },
}
#[derive(Debug, Clone)]
pub(super) struct StageReceipt {
    ticket: StageTicket,
    /// Actual native completion lease, never rewritten when held/renewed.
    actual_completion_lease: u64,
    pair_lease_id: String,
    payload: Payload,
}
#[derive(Debug, Clone)]
pub(super) struct RenewalCommand {
    owner: Owner,
    previous: Lease,
    successor: Lease,
    extension_milliseconds: u64,
    issued_wire: ImmichLockedVideoAcquisitionLease,
}
#[derive(Debug)]
pub(super) struct RenewalReceipt {
    command: RenewalCommand,
}
#[cfg(test)]
#[derive(Debug)]
pub(super) struct NativeExpiryReceipt {
    owner: Owner,
    lease_id: u64,
}
#[derive(Debug, Clone)]
pub(super) struct ProvisionalAccess {
    owner: Owner,
    operation: u64,
    /// Exact acknowledged lease expected by native atomic handoff, not lookup-at-receipt.
    lease: Lease,
    prepared_id: String,
}
#[derive(Debug, Clone)]
pub(super) struct NativePublicationReceipt {
    access: ProvisionalAccess,
    publication_id: String,
}
#[derive(Debug)]
pub(super) struct NativeJoinReceipt {
    owner: Owner,
    extent: CleanupExtent,
}

#[derive(Debug, Clone)]
enum Slot {
    Empty,
    InFlight(StageTicket),
    Held(StageReceipt),
    Verified(StageReceipt),
}
#[derive(Debug, Clone)]
struct Candidate {
    command: RenewalCommand,
    acknowledge_by: Instant,
}
#[derive(Debug, Clone)]
enum Phase {
    Acquiring,
    AwaitingPublication {
        access: ProvisionalAccess,
        acknowledge_by: Instant,
    },
    Published {
        publication_id: String,
    },
    Terminal,
}
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum CleanupExtent {
    Acquisition,
    PossiblyPublished,
}
#[derive(Debug, Clone)]
pub(super) struct CleanupObligation {
    owner: Owner,
    contract: Arc<FixedContract>,
    extent: CleanupExtent,
}
#[derive(Debug)]
struct Machine {
    phase: Phase,
    current: Lease,
    issued_wire: ImmichLockedVideoAcquisitionLease,
    acknowledged: u64,
    candidate: Option<Candidate>,
    proof_round: u64,
    next_operation: u64,
    slots: [Slot; 3],
    cleanup: Option<CleanupObligation>,
}
#[derive(Debug, Clone)]
pub(super) struct PairCoordinator {
    owner: Owner,
    contract: Arc<FixedContract>,
    epoch: Arc<AtomicU64>,
    captured_epoch: u64,
    machine: Arc<Mutex<Machine>>,
}
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum Error {
    Stale,
    Revoked,
    Expired,
    Terminal,
    Busy,
    OutOfOrder,
    InvalidProof,
    InvalidReceipt,
    Overflow,
    Poisoned,
}

impl PairCoordinator {
    pub(super) fn start(proof: InitialProof, now: Instant) -> Result<Self, Error> {
        validate_initial(&proof, now)?;
        let lease = proof.contract.initial_lease;
        let issued_wire = issuer::issue_wire(lease, 0)?;
        Ok(Self {
            owner: Owner(Arc::new(())),
            contract: proof.contract,
            epoch: proof.epoch,
            captured_epoch: proof.captured_epoch,
            machine: Arc::new(Mutex::new(Machine {
                phase: Phase::Acquiring,
                current: lease,
                issued_wire,
                acknowledged: lease.id,
                candidate: None,
                proof_round: 0,
                next_operation: 0,
                slots: [Slot::Empty, Slot::Empty, Slot::Empty],
                cleanup: None,
            })),
        })
    }
    fn lock(&self) -> Result<MutexGuard<'_, Machine>, Error> {
        self.machine.lock().map_err(|_| Error::Poisoned)
    }
    fn terminate(&self, machine: &mut Machine) {
        let extent = if matches!(
            machine.phase,
            Phase::AwaitingPublication { .. } | Phase::Published { .. }
        ) {
            CleanupExtent::PossiblyPublished
        } else {
            CleanupExtent::Acquisition
        };
        if machine.cleanup.is_none() && !matches!(machine.phase, Phase::Terminal) {
            machine.cleanup = Some(CleanupObligation {
                owner: self.owner.clone(),
                contract: self.contract.clone(),
                extent,
            });
        }
        machine.phase = Phase::Terminal;
        machine.candidate = None;
        machine.slots = [Slot::Empty, Slot::Empty, Slot::Empty];
    }
    fn live(&self, machine: &mut Machine, now: Instant) -> Result<(), Error> {
        if matches!(machine.phase, Phase::Terminal) {
            return Err(Error::Terminal);
        }
        if self.epoch.load(Ordering::SeqCst) != self.captured_epoch {
            self.terminate(machine);
            return Err(Error::Revoked);
        }
        if now >= self.contract.hardcap {
            self.terminate(machine);
            return Err(Error::Expired);
        }
        let receipt_overdue = match &machine.phase {
            Phase::AwaitingPublication { acknowledge_by, .. } => now >= *acknowledge_by,
            _ => machine
                .candidate
                .as_ref()
                .is_some_and(|candidate| now >= candidate.acknowledge_by),
        };
        if receipt_overdue
            || (!matches!(machine.phase, Phase::Published { .. })
                && now >= machine.current.deadline)
        {
            self.terminate(machine);
            return Err(Error::Expired);
        }
        Ok(())
    }
    fn capture(&self, machine: &Machine, purpose: Purpose, now: Instant) -> Capture {
        Capture {
            owner: self.owner.clone(),
            epoch: self.epoch.clone(),
            captured_epoch: self.captured_epoch,
            contract: self.contract.clone(),
            purpose,
            acknowledged_lease: machine.acknowledged,
            proof_round: machine.proof_round,
            began_at: now,
        }
    }
    pub(super) fn capture_heartbeat(&self, now: Instant) -> Result<Capture, Error> {
        let mut machine = self.lock()?;
        self.live(&mut machine, now)?;
        if !matches!(machine.phase, Phase::Acquiring) || machine.candidate.is_some() {
            return Err(Error::Busy);
        }
        Ok(self.capture(&machine, Purpose::Heartbeat, now))
    }
    /// Consume the issued proof's owned fields; only its checked deadline leaves this verifier.
    fn consume_proof(
        &self,
        machine: &mut Machine,
        proof: PairProof,
        purpose: Purpose,
        now: Instant,
    ) -> Result<Instant, Error> {
        let PairProof {
            capture,
            observed_at,
            evidence,
            status_deadline,
        } = proof;
        if !self.owner.matches(&capture.owner)
            || !Arc::ptr_eq(&self.epoch, &capture.epoch)
            || self.captured_epoch != capture.captured_epoch
            || !Arc::ptr_eq(&self.contract, &capture.contract)
        {
            return Err(Error::Stale);
        }
        if capture.purpose != purpose
            || capture.acknowledged_lease != machine.acknowledged
            || capture.proof_round != machine.proof_round
            || machine.candidate.is_some()
        {
            return Err(Error::Stale);
        }
        if observed_at < capture.began_at
            || observed_at > now
            || status_deadline <= now
            // The native controller can extend, not shrink. Do not continue
            // using its longer issued lease after observing shorter authority.
            || (purpose != Purpose::Display && status_deadline < machine.current.deadline)
            || evidence != self.contract.evidence
        {
            self.terminate(machine);
            return Err(Error::InvalidProof);
        }
        Ok(status_deadline)
    }
    pub(super) fn propose_successor(
        &self,
        proof: PairProof,
        acknowledge_by: Instant,
        now: Instant,
    ) -> Result<RenewalCommand, Error> {
        let mut machine = self.lock()?;
        self.live(&mut machine, now)?;
        if !matches!(machine.phase, Phase::Acquiring) || machine.candidate.is_some() {
            return Err(Error::Busy);
        }
        let deadline = self.consume_proof(&mut machine, proof, Purpose::Heartbeat, now)?;
        let bound = deadline.min(self.contract.hardcap);
        let (deadline, extension_milliseconds) =
            rounded_successor(machine.current.deadline, bound)?;
        if extension_milliseconds == 0 {
            return Err(Error::InvalidProof);
        }
        if acknowledge_by <= now || acknowledge_by > deadline {
            return Err(Error::InvalidProof);
        }
        let id = machine.current.id.checked_add(1).ok_or(Error::Overflow)?;
        let issued_wire = issuer::issue_wire(Lease { id, deadline }, extension_milliseconds)?;
        let command = RenewalCommand {
            owner: self.owner.clone(),
            previous: machine.current,
            successor: Lease { id, deadline },
            extension_milliseconds,
            issued_wire: issued_wire.clone(),
        };
        machine.current = command.successor;
        machine.issued_wire = issued_wire;
        machine.candidate = Some(Candidate {
            command: command.clone(),
            acknowledge_by,
        });
        Ok(command)
    }
    pub(super) fn acknowledge_successor(
        &self,
        receipt: RenewalReceipt,
        now: Instant,
    ) -> Result<(), Error> {
        let RenewalReceipt { command } = receipt;
        if !self.owner.matches(&command.owner) {
            return Err(Error::Stale);
        }
        let mut machine = self.lock()?;
        self.live(&mut machine, now)?;
        let candidate = machine.candidate.as_ref().ok_or(Error::Stale)?;
        if candidate.command.previous != command.previous
            || candidate.command.successor != command.successor
            || candidate.command.extension_milliseconds != command.extension_milliseconds
            || machine.current != command.successor
        {
            self.terminate(&mut machine);
            return Err(Error::InvalidReceipt);
        }
        machine.acknowledged = command.successor.id;
        machine.proof_round = if let Some(round) = machine.proof_round.checked_add(1) {
            round
        } else {
            self.terminate(&mut machine);
            return Err(Error::Overflow);
        };
        machine.candidate = None;
        // Held receipts retain their actual completion lease IDs. No advancement
        // occurs here; each held slot must obtain a proof captured AFTER this ACK.
        Ok(())
    }
    pub(super) fn capture_stage_start(&self, kind: Stage, now: Instant) -> Result<Capture, Error> {
        let mut machine = self.lock()?;
        self.live(&mut machine, now)?;
        if !matches!(machine.phase, Phase::Acquiring) || machine.candidate.is_some() {
            return Err(Error::Busy);
        }
        if !matches!(machine.slots[kind.index()], Slot::Empty)
            || (kind == Stage::Prepare && !originals_verified(&machine))
        {
            return Err(Error::OutOfOrder);
        }
        Ok(self.capture(&machine, Purpose::Start(kind), now))
    }
    pub(super) fn begin_stage(&self, proof: PairProof, now: Instant) -> Result<StageTicket, Error> {
        let Purpose::Start(kind) = proof.capture.purpose else {
            return Err(Error::InvalidProof);
        };
        let mut machine = self.lock()?;
        self.live(&mut machine, now)?;
        self.consume_proof(&mut machine, proof, Purpose::Start(kind), now)?;
        if !matches!(machine.phase, Phase::Acquiring) || machine.candidate.is_some() {
            return Err(Error::Busy);
        }
        if !matches!(machine.slots[kind.index()], Slot::Empty) {
            return Err(Error::OutOfOrder);
        }
        if kind == Stage::Prepare && !originals_verified(&machine) {
            return Err(Error::OutOfOrder);
        }
        machine.next_operation = machine
            .next_operation
            .checked_add(1)
            .ok_or(Error::Overflow)?;
        let ticket = StageTicket {
            owner: self.owner.clone(),
            contract: self.contract.clone(),
            kind,
            operation: machine.next_operation,
            start_acknowledged_lease: machine.acknowledged,
        };
        machine.slots[kind.index()] = Slot::InFlight(ticket.clone());
        Ok(ticket)
    }
    pub(super) fn receive_stage(&self, receipt: StageReceipt, now: Instant) -> Result<(), Error> {
        if !self.owner.matches(&receipt.ticket.owner)
            || !Arc::ptr_eq(&self.contract, &receipt.ticket.contract)
        {
            return Err(Error::Stale);
        }
        let mut machine = self.lock()?;
        self.live(&mut machine, now)?;
        let kind = receipt.ticket.kind;
        let Slot::InFlight(ticket) = &machine.slots[kind.index()] else {
            return Err(Error::OutOfOrder);
        };
        if ticket.operation != receipt.ticket.operation
            || ticket.start_acknowledged_lease != receipt.ticket.start_acknowledged_lease
        {
            return Err(Error::Stale);
        }
        if receipt.actual_completion_lease < ticket.start_acknowledged_lease
            || receipt.actual_completion_lease > machine.current.id
            || receipt.pair_lease_id != self.contract.pair_lease_id
            || !valid_payload(&self.contract, &receipt)
            || !valid_received_total(
                &machine,
                &receipt,
                self.contract.budget.total_max_received_bytes,
            )
        {
            self.terminate(&mut machine);
            return Err(Error::InvalidReceipt);
        }
        machine.slots[kind.index()] = Slot::Held(receipt);
        Ok(())
    }
    pub(super) fn capture_stage_check(&self, kind: Stage, now: Instant) -> Result<Capture, Error> {
        let mut machine = self.lock()?;
        self.live(&mut machine, now)?;
        if machine.candidate.is_some() {
            return Err(Error::Busy);
        }
        let Slot::Held(receipt) = &machine.slots[kind.index()] else {
            return Err(Error::OutOfOrder);
        };
        Ok(self.capture(
            &machine,
            Purpose::Stage {
                kind,
                operation: receipt.ticket.operation,
            },
            now,
        ))
    }
    pub(super) fn accept_stage_check(&self, proof: PairProof, now: Instant) -> Result<(), Error> {
        let Purpose::Stage { kind, operation } = proof.capture.purpose else {
            return Err(Error::InvalidProof);
        };
        let mut machine = self.lock()?;
        self.live(&mut machine, now)?;
        self.consume_proof(&mut machine, proof, Purpose::Stage { kind, operation }, now)?;
        let Slot::Held(receipt) = &machine.slots[kind.index()] else {
            return Err(Error::OutOfOrder);
        };
        if receipt.ticket.operation != operation
            || receipt.actual_completion_lease > machine.acknowledged
        {
            return Err(Error::Stale);
        }
        machine.slots[kind.index()] = Slot::Verified(receipt.clone());
        Ok(())
    }
    pub(super) fn capture_final_check(&self, now: Instant) -> Result<Capture, Error> {
        let mut machine = self.lock()?;
        self.live(&mut machine, now)?;
        if !matches!(machine.phase, Phase::Acquiring) || machine.candidate.is_some() {
            return Err(Error::Busy);
        }
        if !machine
            .slots
            .iter()
            .all(|slot| matches!(slot, Slot::Verified(_)))
        {
            return Err(Error::OutOfOrder);
        }
        Ok(self.capture(&machine, Purpose::Final, now))
    }
    pub(super) fn provisional_access(
        &self,
        proof: PairProof,
        acknowledge_by: Instant,
        now: Instant,
    ) -> Result<ProvisionalAccess, Error> {
        let mut machine = self.lock()?;
        self.live(&mut machine, now)?;
        self.consume_proof(&mut machine, proof, Purpose::Final, now)?;
        if !matches!(machine.phase, Phase::Acquiring)
            || !machine
                .slots
                .iter()
                .all(|slot| matches!(slot, Slot::Verified(_)))
        {
            return Err(Error::OutOfOrder);
        }
        if acknowledge_by <= now || acknowledge_by > machine.current.deadline {
            return Err(Error::InvalidProof);
        }
        let Slot::Verified(prepared) = &machine.slots[Stage::Prepare.index()] else {
            return Err(Error::OutOfOrder);
        };
        let Payload::Prepared { prepared_id } = &prepared.payload else {
            return Err(Error::InvalidReceipt);
        };
        let prepared_id = prepared_id.clone();
        machine.next_operation = machine
            .next_operation
            .checked_add(1)
            .ok_or(Error::Overflow)?;
        let access = ProvisionalAccess {
            owner: self.owner.clone(),
            operation: machine.next_operation,
            lease: machine.current,
            prepared_id,
        };
        machine.phase = Phase::AwaitingPublication {
            access: access.clone(),
            acknowledge_by,
        };
        Ok(access)
    }
    pub(super) fn capture_publication_check(&self, now: Instant) -> Result<Capture, Error> {
        let mut machine = self.lock()?;
        self.live(&mut machine, now)?;
        if !matches!(machine.phase, Phase::AwaitingPublication { .. }) {
            return Err(Error::OutOfOrder);
        }
        Ok(self.capture(&machine, Purpose::Publication, now))
    }
    pub(super) fn capture_display_check(&self, now: Instant) -> Result<Capture, Error> {
        let mut machine = self.lock()?;
        self.live(&mut machine, now)?;
        if !matches!(machine.phase, Phase::Published { .. }) {
            return Err(Error::OutOfOrder);
        }
        Ok(self.capture(&machine, Purpose::Display, now))
    }
    pub(super) fn accept_display_check(&self, proof: PairProof, now: Instant) -> Result<(), Error> {
        let mut machine = self.lock()?;
        self.live(&mut machine, now)?;
        if !matches!(machine.phase, Phase::Published { .. }) {
            return Err(Error::OutOfOrder);
        }
        // Published display has current C1 authority, not an acquisition extension.
        self.consume_proof(&mut machine, proof, Purpose::Display, now)
            .map(|_| ())
    }
    pub(super) fn acknowledge_publication(
        &self,
        receipt: NativePublicationReceipt,
        now: Instant,
    ) -> Result<(), Error> {
        if !self.owner.matches(&receipt.access.owner) {
            return Err(Error::Stale);
        }
        let mut machine = self.lock()?;
        self.live(&mut machine, now)?;
        let Phase::AwaitingPublication { access, .. } = &machine.phase else {
            return Err(Error::OutOfOrder);
        };
        if access.operation != receipt.access.operation
            || access.lease != receipt.access.lease
            || access.prepared_id != receipt.access.prepared_id
            || crate::immich::valid_id(&receipt.publication_id).is_err()
        {
            self.terminate(&mut machine);
            return Err(Error::InvalidReceipt);
        }
        machine.phase = Phase::Published {
            publication_id: receipt.publication_id,
        };
        Ok(())
    }
    /// Only a validated exact native-controller EXPIRY-WON receipt may use this.
    /// A scheduler firing is not such a receipt and must not mint one.
    #[cfg(test)]
    pub(super) fn native_expiry_won(&self, receipt: NativeExpiryReceipt) -> Result<(), Error> {
        let NativeExpiryReceipt { owner, lease_id } = receipt;
        if !self.owner.matches(&owner) {
            return Err(Error::Stale);
        }
        let mut machine = self.lock()?;
        if matches!(machine.phase, Phase::Published { .. } | Phase::Terminal) {
            return Err(Error::Stale);
        }
        let old_candidate = machine
            .candidate
            .as_ref()
            .is_some_and(|candidate| candidate.command.previous.id == lease_id);
        if lease_id != machine.current.id && !old_candidate {
            return Err(Error::Stale);
        }
        self.terminate(&mut machine);
        Ok(())
    }
    pub(super) fn poll_deadlines(&self, now: Instant) -> Result<(), Error> {
        let mut machine = self.lock()?;
        self.live(&mut machine, now)
    }
    pub(super) fn stop(&self) -> Result<(), Error> {
        let mut machine = self.lock()?;
        self.terminate(&mut machine);
        Ok(())
    }
    pub(super) fn cleanup_obligation(&self) -> Result<Option<CleanupObligation>, Error> {
        Ok(self.lock()?.cleanup.clone())
    }
    pub(super) fn acknowledge_join(&self, receipt: NativeJoinReceipt) -> Result<(), Error> {
        let NativeJoinReceipt { owner, extent } = receipt;
        if !self.owner.matches(&owner) {
            return Err(Error::Stale);
        }
        let mut machine = self.lock()?;
        if !matches!(machine.phase, Phase::Terminal) || machine.cleanup.is_none() {
            return Err(Error::OutOfOrder);
        }
        let obligation = machine.cleanup.as_ref().ok_or(Error::OutOfOrder)?;
        if !self.owner.matches(&obligation.owner)
            || !Arc::ptr_eq(&self.contract, &obligation.contract)
            || extent != obligation.extent
        {
            return Err(Error::InvalidReceipt);
        }
        machine.cleanup = None;
        Ok(())
    }
}

// Floor relative to the previous deadline, never round the absolute bound up.
// The native CAS extension and caller's ACK bound consume this same result.
fn rounded_successor(previous: Instant, bound: Instant) -> Result<(Instant, u64), Error> {
    let extension = bound
        .checked_duration_since(previous)
        .ok_or(Error::InvalidProof)?;
    let milliseconds = u64::try_from(extension.as_millis()).map_err(|_| Error::Overflow)?;
    let deadline = previous
        .checked_add(Duration::from_millis(milliseconds))
        .ok_or(Error::Overflow)?;
    Ok((deadline, milliseconds))
}

fn originals_verified(machine: &Machine) -> bool {
    matches!(machine.slots[0], Slot::Verified(_)) && matches!(machine.slots[1], Slot::Verified(_))
}
fn validate_initial(proof: &InitialProof, now: Instant) -> Result<(), Error> {
    let fixed = &proof.contract;
    if proof.epoch.load(Ordering::SeqCst) != proof.captured_epoch {
        return Err(Error::Revoked);
    }
    if proof.observed_at < proof.began_at
        || proof.observed_at > now
        || now >= fixed.initial_lease.deadline
        || fixed.initial_lease.deadline > fixed.hardcap
        || fixed.initial_lease.id != 1
        || fixed.evidence.members[0].key == fixed.evidence.members[1].key
    {
        return Err(Error::InvalidProof);
    }
    let [parent, motion] = &fixed.evidence.members;
    if parent.kind != MediaKind::Image
        || motion.kind != MediaKind::Video
        || parent.placement != crate::immich_live_resources::LiveObservedVisibility::Locked
        || parent.key.provider != Provider::Immich
        || motion.key.provider != Provider::Immich
        || parent.key.scope != motion.key.scope
        || fixed.evidence.forward_motion != motion.key
    {
        return Err(Error::InvalidProof);
    }
    for (index, fingerprint) in fixed.evidence.members.iter().enumerate() {
        if fingerprint.revision.is_empty()
            || crate::domain::normalize_sha1(Some(&fingerprint.sha1)).as_deref()
                != Some(fingerprint.sha1.as_str())
            || fixed.budget.members[index].key != fingerprint.key
        {
            return Err(Error::InvalidProof);
        }
    }
    if fixed.budget.members[0].role != MemberRole::Parent
        || fixed.budget.members[1].role != MemberRole::Motion
    {
        return Err(Error::InvalidProof);
    }
    for id in [
        &fixed.identity.request_id,
        &fixed.identity.scene_id,
        &fixed.identity.grant_id,
    ] {
        crate::immich::valid_id(id).map_err(|_| Error::InvalidProof)?;
    }
    if !(fixed.identity.plan_id.len() == 32
        && fixed
            .identity
            .plan_id
            .bytes()
            .all(|b| b.is_ascii_hexdigit() && !b.is_ascii_uppercase()))
        && crate::immich::valid_id(&fixed.identity.plan_id).is_err()
    {
        return Err(Error::InvalidProof);
    }
    crate::immich::valid_id(&fixed.pair_lease_id).map_err(|_| Error::InvalidProof)?;
    crate::immich::valid_id(&fixed.quote_nonce).map_err(|_| Error::InvalidProof)?;
    Ok(())
}
fn valid_payload(contract: &FixedContract, receipt: &StageReceipt) -> bool {
    match (&receipt.ticket.kind, &receipt.payload) {
        (Stage::Prepare, Payload::Prepared { prepared_id }) => {
            crate::immich::valid_id(prepared_id).is_ok()
        }
        (Stage::Parent | Stage::Motion, Payload::Original { sha1, signature }) => {
            let index = receipt.ticket.kind.index();
            let member = &contract.budget.members[index];
            signature.valid()
                && *sha1 == contract.evidence.members[index].sha1
                && signature.bytes <= member.max_received_bytes
                && member
                    .expected_bytes
                    .is_none_or(|bytes| signature.bytes == bytes)
        }
        _ => false,
    }
}

fn valid_received_total(machine: &Machine, incoming: &StageReceipt, total: u64) -> bool {
    let bytes = |receipt: &StageReceipt| match &receipt.payload {
        Payload::Original { signature, .. } => signature.bytes,
        Payload::Prepared { .. } => 0,
    };
    let mut sum = bytes(incoming);
    for (index, slot) in machine.slots.iter().enumerate().take(2) {
        if index == incoming.ticket.kind.index() {
            continue;
        }
        if let Slot::Held(receipt) | Slot::Verified(receipt) = slot {
            let Some(next) = sum.checked_add(bytes(receipt)) else {
                return false;
            };
            sum = next;
        }
    }
    sum <= total
}

#[cfg(test)]
#[path = "coordinator_tests.rs"]
mod tests;

mod issuer;
pub(super) use issuer::*;
