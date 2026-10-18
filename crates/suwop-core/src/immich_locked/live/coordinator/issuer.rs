//! Trusted bridge: network facts are issued only after the dedicated guarded pair read.
//! Native receipts are constructed only around the exact outstanding effect response.
use super::super::{
    Authority, ERROR,
    types::{
        ImmichLockedLiveOriginal, ImmichLockedLivePending, ImmichLockedLivePrepared,
        ImmichLockedLivePublication, ImmichLockedLiveRenewed, ImmichLockedLiveRole,
    },
};
use super::{
    Capture, Error, Fingerprint, FixedContract, Identity, InitialProof, Lease, MediaKind,
    NativeJoinReceipt, NativePublicationReceipt, PairCoordinator, PairEvidence, PairProof,
    PairedBudget, Payload, Phase, ProvisionalAccess, Purpose, RenewalCommand, RenewalReceipt,
    Stage, StageReceipt, StageTicket, rounded_successor,
};
use crate::{
    app::Context,
    immich_live_resources::{LiveObservedVisibility, LiveResourceReadFact, LiveResourceRole},
};
use std::{sync::Arc, time::Instant};

#[derive(Debug, Clone)]
pub(in crate::immich_locked::live) struct Observation {
    evidence: PairEvidence,
    sizes: [Option<u64>; 2],
    began_at: Instant,
    observed_at: Instant,
    deadline: Instant,
}
impl Observation {
    pub(in crate::immich_locked::live) fn sizes(&self) -> [Option<u64>; 2] {
        self.sizes
    }
    pub(in crate::immich_locked::live) fn deadline(&self) -> Instant {
        self.deadline
    }
}
pub(in crate::immich_locked::live) async fn observe(
    ctx: &Context,
    authority: &Authority,
    expected: &[LiveResourceReadFact; 2],
) -> Result<Observation, String> {
    let began_at = Instant::now();
    authority.valid()?;
    let before = authority.status(ctx).await?;
    let p = authority
        .json(ctx, &format!("assets/{}", expected[0].key.asset_id))
        .await?;
    let parent = crate::immich_live_resources::fact(
        &p,
        &expected[0].key,
        authority.session.owner(),
        LiveResourceRole::Parent,
    )?;
    if parent != expected[0]
        || parent.visibility != LiveObservedVisibility::Locked
        || crate::immich_live_resources::child(&p)? != expected[1].key.asset_id
    {
        return Err(ERROR.into());
    }
    let m = authority
        .json(ctx, &format!("assets/{}", expected[1].key.asset_id))
        .await?;
    let motion = crate::immich_live_resources::fact(
        &m,
        &expected[1].key,
        authority.session.owner(),
        LiveResourceRole::Motion,
    )?;
    if motion != expected[1] || m.get("livePhotoVideoId") != Some(&serde_json::Value::Null) {
        return Err(ERROR.into());
    }
    let sizes = [
        super::super::policy::expected_size(&p).map_err(|_| ERROR)?,
        super::super::policy::expected_size(&m).map_err(|_| ERROR)?,
    ];
    let after = authority.status(ctx).await?;
    authority.valid()?;
    Ok(Observation {
        evidence: PairEvidence {
            members: [
                Fingerprint {
                    key: parent.key,
                    kind: MediaKind::Image,
                    revision: parent.revision,
                    sha1: parent.checksum,
                    placement: parent.visibility,
                },
                Fingerprint {
                    key: motion.key.clone(),
                    kind: MediaKind::Video,
                    revision: motion.revision,
                    sha1: motion.checksum,
                    placement: motion.visibility,
                },
            ],
            forward_motion: motion.key,
        },
        sizes,
        began_at,
        observed_at: Instant::now(),
        deadline: before.min(after).min(authority.session.hard_deadline),
    })
}
pub(in crate::immich_locked::live) fn start(
    pending: &ImmichLockedLivePending,
    authority: &Authority,
    observed: Observation,
    storage: &super::super::super::video::ImmichLockedVideoStorageFacts,
    budget: PairedBudget,
) -> Result<PairCoordinator, String> {
    let deadline = observed.deadline.min(authority.session.lease_deadline);
    let proof = InitialProof {
        contract: Arc::new(FixedContract {
            identity: Identity {
                request_id: pending.request_id.clone(),
                plan_id: pending.plan_id.clone(),
                scene_id: pending.scene_id.clone(),
                grant_id: pending.grant_id.clone(),
                generation: pending.generation,
            },
            pair_lease_id: storage.lease_id.clone(),
            quote_nonce: storage.measurement_nonce.clone(),
            evidence: observed.evidence,
            budget,
            initial_lease: Lease { id: 1, deadline },
            hardcap: authority.session.hard_deadline,
        }),
        epoch: authority.request_epoch.clone(),
        captured_epoch: authority.request_expected,
        began_at: observed.began_at,
        observed_at: observed.observed_at,
    };
    PairCoordinator::start(proof, Instant::now()).map_err(|_| ERROR.into())
}
pub(in crate::immich_locked::live) async fn proof(
    ctx: &Context,
    authority: &Authority,
    expected: &[LiveResourceReadFact; 2],
    sizes: [Option<u64>; 2],
    capture: Capture,
) -> Result<PairProof, String> {
    let observed = observe(ctx, authority, expected).await?;
    if observed.sizes != sizes {
        return Err(ERROR.into());
    }
    Ok(PairProof {
        capture,
        observed_at: observed.observed_at,
        evidence: observed.evidence,
        status_deadline: observed.deadline,
    })
}
impl PairCoordinator {
    pub(in crate::immich_locked::live) fn publication_matches(
        &self,
        access: &ImmichLockedLivePublication,
    ) -> bool {
        self.lock().is_ok_and(|m|matches!(&m.phase,Phase::Published{publication_id} if publication_id==&access.publication_id))
            && access.pair_lease_id==self.contract.pair_lease_id
            && access.pending.request_id==self.contract.identity.request_id
    }

    pub(in crate::immich_locked::live) fn renewal_acknowledgement_deadline(
        &self,
        proof: &PairProof,
    ) -> Result<Instant, Error> {
        let current = self.lock()?.current;
        rounded_successor(
            current.deadline,
            proof.status_deadline.min(self.contract.hardcap),
        )
        .map(|(deadline, _)| deadline)
    }
    pub(in crate::immich_locked::live) fn leases(
        &self,
    ) -> Result<(ImmichLockedVideoAcquisitionLease, u64), String> {
        let state = self.lock().map_err(|_| ERROR)?;
        Ok((state.issued_wire.clone(), state.acknowledged))
    }
    pub(in crate::immich_locked::live) fn current_deadline(&self) -> Result<Instant, String> {
        Ok(self.lock().map_err(|_| ERROR)?.current.deadline)
    }
    pub(in crate::immich_locked::live) fn is_published(&self) -> bool {
        self.lock()
            .is_ok_and(|m| matches!(m.phase, Phase::Published { .. }))
    }
    pub(in crate::immich_locked::live) fn publication_proof(
        &self,
        proof: PairProof,
    ) -> Result<(), String> {
        let mut machine = self.lock().map_err(|_| ERROR)?;
        let now = Instant::now();
        self.live(&mut machine, now).map_err(|_| ERROR)?;
        self.consume_proof(&mut machine, proof, Purpose::Publication, now)
            .map(|_| ())
            .map_err(|_| ERROR.into())
    }
    pub(in crate::immich_locked::live) fn original_receipt(
        &self,
        ticket: StageTicket,
        result: &ImmichLockedLiveOriginal,
    ) -> Result<StageReceipt, String> {
        let role = match ticket.kind {
            Stage::Parent => ImmichLockedLiveRole::Parent,
            Stage::Motion => ImmichLockedLiveRole::Motion,
            Stage::Prepare => return Err(ERROR.into()),
        };
        if result.request_id != self.contract.identity.request_id || result.role != role {
            return Err(ERROR.into());
        }
        Ok(StageReceipt {
            ticket,
            actual_completion_lease: result.acquisition_lease_id,
            pair_lease_id: result.pair_lease_id.clone(),
            payload: Payload::Original {
                sha1: result.sha1.clone(),
                signature: result.signature.clone(),
            },
        })
    }
    pub(in crate::immich_locked::live) fn prepared_receipt(
        &self,
        ticket: StageTicket,
        result: &ImmichLockedLivePrepared,
    ) -> Result<StageReceipt, String> {
        if result.request_id != self.contract.identity.request_id || ticket.kind != Stage::Prepare {
            return Err(ERROR.into());
        }
        Ok(StageReceipt {
            ticket,
            actual_completion_lease: result.acquisition_lease_id,
            pair_lease_id: result.pair_lease_id.clone(),
            payload: Payload::Prepared {
                prepared_id: result.prepared_id.clone(),
            },
        })
    }
    pub(in crate::immich_locked::live) fn publication(
        &self,
        pending: ImmichLockedLivePending,
        access: &ProvisionalAccess,
    ) -> Result<ImmichLockedLivePublication, String> {
        // Stable UUID operation identity derived without exposing private Owner.
        let id = super::super::fresh_id()?;
        Ok(ImmichLockedLivePublication {
            pending,
            pair_lease_id: self.contract.pair_lease_id.clone(),
            prepared_id: access.prepared_id.clone(),
            publication_id: id,
            expected_acquisition_lease_id: access.lease.id,
        })
    }
    pub(in crate::immich_locked::live) fn publication_receipt(
        access: ProvisionalAccess,
        expected: &ImmichLockedLivePublication,
        actual: &ImmichLockedLivePublication,
    ) -> Result<NativePublicationReceipt, String> {
        if expected != actual {
            return Err(ERROR.into());
        }
        Ok(NativePublicationReceipt {
            access,
            publication_id: actual.publication_id.clone(),
        })
    }
    pub(in crate::immich_locked::live) fn renewal_wire(
        command: &RenewalCommand,
    ) -> (u64, ImmichLockedVideoAcquisitionLease) {
        (command.previous.id, command.issued_wire.clone())
    }
    pub(in crate::immich_locked::live) fn renewal_receipt(
        &self,
        command: RenewalCommand,
        result: &ImmichLockedLiveRenewed,
    ) -> Result<RenewalReceipt, String> {
        if result.request_id != self.contract.identity.request_id
            || result.pair_lease_id != self.contract.pair_lease_id
            || result.previous_lease_id != command.previous.id
            || result.lease_id != command.successor.id
        {
            return Err(ERROR.into());
        }
        Ok(RenewalReceipt { command })
    }
    pub(in crate::immich_locked::live) fn joined(&self) -> Result<(), String> {
        let obligation = self.cleanup_obligation().map_err(|_| ERROR)?.ok_or(ERROR)?;
        self.acknowledge_join(NativeJoinReceipt {
            owner: self.owner.clone(),
            extent: obligation.extent,
        })
        .map_err(|_| ERROR.into())
    }
}
use super::super::super::video::ImmichLockedVideoAcquisitionLease;

/// Mint once with the monotonic lease; views and outstanding effects only clone this observation.
pub(super) fn issue_wire(
    lease: Lease,
    extension: u64,
) -> Result<ImmichLockedVideoAcquisitionLease, Error> {
    let remaining = u64::try_from(
        lease
            .deadline
            .saturating_duration_since(Instant::now())
            .as_millis(),
    )
    .map_err(|_| Error::Overflow)?;
    if remaining == 0 {
        return Err(Error::Expired);
    }
    let now = super::super::now_ms().map_err(|_| Error::Overflow)?;
    Ok(ImmichLockedVideoAcquisitionLease {
        lease_id: lease.id,
        deadline_unix_milliseconds: now.checked_add(remaining).ok_or(Error::Overflow)?,
        remaining_milliseconds: remaining,
        extension_milliseconds: extension,
    })
}
