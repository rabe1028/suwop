//! Each async operation carries its private owner; reducers never look up a new owner.
use super::{
    Active, Binding, Command, Completion, Context, ERROR, Event, ImmichLockedLiveMember,
    ImmichLockedLiveOriginal, ImmichLockedLivePrepared, ImmichLockedLivePublication,
    ImmichLockedLiveRead, ImmichLockedLiveReleased, ImmichLockedLiveRole,
    ImmichLockedLiveStorageFacts, ImmichLockedLiveTicket, Instant, Model, Retired, ShellOperation,
    Stage, Step, coordinator, io, lifecycle, now_ms, phase, policy, stop,
};
use coordinator::{Capture, PairProof, ProvisionalAccess, StageReceipt};
use policy::{MemberRole, MemberSize, Representation};
#[derive(Debug, Clone)]
pub(super) enum Outcome {
    Retry,
    Planned(Result<(coordinator::Observation, ImmichLockedLiveStorageFacts, u64), String>),
    Stage(Result<(StageReceipt, Option<ImmichLockedLiveOriginal>), String>),
    Checked(Result<PairProof, String>),
    Final(Result<(ProvisionalAccess, ImmichLockedLivePublication), String>),
    Published(Result<(coordinator::NativePublicationReceipt, PairProof), String>),
    Joined(
        crate::private_media_cleanup::Attempt,
        Result<ImmichLockedLiveReleased, String>,
    ),
}
type Work = std::pin::Pin<Box<dyn std::future::Future<Output = Outcome> + Send>>;
fn emit(
    binding: Binding,
    run: impl FnOnce(Context, Binding) -> Work + Send + 'static,
) -> Command<crate::app::Effect, Event> {
    Command::new(move |ctx| async move {
        let owner = binding.owner.clone();
        let retained = binding.clone();
        let outcome = run(ctx.clone(), binding).await;
        ctx.send_event(Event::ImmichLockedLiveCompleted {
            completion: Box::new(Completion {
                owner,
                binding: retained,
                outcome,
            }),
        });
    })
}
pub(super) fn initial(binding: Binding) -> Command<crate::app::Effect, Event> {
    emit(binding, |ctx, b| {
        Box::pin(async move {
            let result = async {
                let a = b.authority()?;
                let observed = coordinator::observe(&ctx, &a, &b.expected).await?;
                a.valid()?;
                let quote_deadline = now_ms()?
                    .checked_add(
                        u64::try_from(
                            observed
                                .deadline()
                                .min(a.session.lease_deadline)
                                .saturating_duration_since(Instant::now())
                                .as_millis(),
                        )
                        .map_err(|_| ERROR)?,
                    )
                    .ok_or(ERROR)?;
                let storage: ImmichLockedLiveStorageFacts = io(
                    &ctx,
                    ShellOperation::InspectImmichLockedLiveStorage {
                        pending: b.pending.clone(),
                        quote_deadline_unix_milliseconds: quote_deadline,
                    },
                )
                .await?;
                // Return every quote, even if invalidated meanwhile: the reducer must
                // retain its exact native cleanup identity rather than dropping it.
                Ok((observed, storage, quote_deadline))
            }
            .await;
            Outcome::Planned(result)
        })
    })
}
fn ticket(b: &Binding) -> Result<ImmichLockedLiveTicket, String> {
    let mut t = b.ticket.clone().ok_or(ERROR)?;
    t.pending = b.pending.clone();
    t.acquisition_lease = b.kernel.as_ref().ok_or(ERROR)?.leases()?.0;
    Ok(t)
}
fn capture(a: &Active) -> Result<Capture, coordinator::Error> {
    let k = a
        .binding
        .kernel
        .as_ref()
        .ok_or(coordinator::Error::InvalidProof)?;
    match a.step {
        Step::Start(s) => k.capture_stage_start(s, Instant::now()),
        Step::Check(s) => k.capture_stage_check(s, Instant::now()),
        Step::Final => k.capture_final_check(Instant::now()),
        Step::Publish => k.capture_publication_check(Instant::now()),
        _ => Err(coordinator::Error::OutOfOrder),
    }
}
pub(super) fn advance(model: &mut Model) -> Command<crate::app::Effect, Event> {
    if !lifecycle::active_current(model) {
        return stop(model);
    }
    let Some(active) = model.immich_locked.live.active.as_ref() else {
        return Command::done();
    };
    if active.working || active.step == Step::Done {
        return Command::done();
    }
    let captured = match capture(active) {
        Ok(c) => c,
        Err(coordinator::Error::Busy) => return Command::done(),
        Err(_) => return stop(model),
    };
    let step = active.step;
    let mut b = active.binding.clone();
    b.pending.phase = phase(step);
    let originals = active.originals.clone();
    let provisional = active.provisional.clone();
    if let Some(a) = model.immich_locked.live.active.as_mut() {
        a.working = true;
        a.binding.pending.phase = phase(step);
    }
    emit(b, move |ctx, b| {
        Box::pin(async move {
            match step {
                Step::Start(stage) => start_stage(&ctx, &b, captured, stage, originals).await,
                Step::Check(_) => Outcome::Checked(
                    async {
                        let a = b.authority()?;
                        coordinator::proof(&ctx, &a, &b.expected, b.sizes, captured).await
                    }
                    .await,
                ),
                Step::Final => Outcome::Final(
                    async {
                        let k = b.kernel.as_ref().ok_or(ERROR)?;
                        let a = b.authority()?;
                        let proof =
                            coordinator::proof(&ctx, &a, &b.expected, b.sizes, captured).await?;
                        let deadline = k.current_deadline()?;
                        let access = k
                            .provisional_access(proof, deadline, Instant::now())
                            .map_err(|_| ERROR)?;
                        let publication = k.publication(b.pending.clone(), &access)?;
                        Ok((access, publication))
                    }
                    .await,
                ),
                Step::Publish => Outcome::Published(
                    async {
                        let k = b.kernel.as_ref().ok_or(ERROR)?;
                        let (access, expected) = provisional.ok_or(ERROR)?;
                        b.authority()?.valid()?;
                        let actual: ImmichLockedLivePublication = io(
                            &ctx,
                            ShellOperation::PublishImmichLockedLive {
                                ticket: Box::new(ticket(&b)?),
                                publication: expected.clone(),
                            },
                        )
                        .await?;
                        let receipt = coordinator::PairCoordinator::publication_receipt(
                            access, &expected, &actual,
                        )?;
                        // Native handoff is not visible authority. Acquire a new capture
                        // AFTER its receipt, never reuse the pre-publication proof.
                        let after = k
                            .capture_publication_check(Instant::now())
                            .map_err(|_| ERROR)?;
                        let a = b.authority()?;
                        let proof =
                            coordinator::proof(&ctx, &a, &b.expected, b.sizes, after).await?;
                        Ok((receipt, proof))
                    }
                    .await,
                ),
                _ => Outcome::Checked(Err(ERROR.into())),
            }
        })
    })
}
async fn start_stage(
    ctx: &Context,
    b: &Binding,
    captured: Capture,
    stage: Stage,
    originals: [Option<ImmichLockedLiveOriginal>; 2],
) -> Outcome {
    let result = async {
        let k = b.kernel.as_ref().ok_or(ERROR)?;
        let a = b.authority()?;
        let proof = coordinator::proof(ctx, &a, &b.expected, b.sizes, captured).await?;
        let stage_ticket = match k.begin_stage(proof, Instant::now()) {
            Ok(t) => t,
            Err(coordinator::Error::Busy | coordinator::Error::Stale) => return Ok(None),
            Err(_) => return Err(ERROR.to_string()),
        };
        let t = ticket(b)?;
        a.valid()?;
        if stage == Stage::Prepare {
            let originals = [
                originals[0].clone().ok_or(ERROR)?,
                originals[1].clone().ok_or(ERROR)?,
            ];
            let result: ImmichLockedLivePrepared = io(
                ctx,
                ShellOperation::PrepareImmichLockedLive {
                    ticket: Box::new(t),
                    originals,
                },
            )
            .await?;
            Ok(Some((k.prepared_receipt(stage_ticket, &result)?, None)))
        } else {
            let index = usize::from(stage != Stage::Parent);
            let mut request = a.session.session.request(
                &format!(
                    "assets/{}/original?edited=false",
                    b.expected[index].key.asset_id
                ),
                "GET",
                None,
            );
            request
                .headers
                .insert("Accept-Encoding".into(), "identity".into());
            let role = if index == 0 {
                ImmichLockedLiveRole::Parent
            } else {
                ImmichLockedLiveRole::Motion
            };
            let result: ImmichLockedLiveOriginal = io(
                ctx,
                ShellOperation::ReadImmichLockedLiveMember {
                    read: Box::new(ImmichLockedLiveRead {
                        ticket: t,
                        role,
                        request,
                    }),
                },
            )
            .await?;
            Ok(Some((
                k.original_receipt(stage_ticket, &result)?,
                Some(result),
            )))
        }
    }
    .await;
    match result {
        Ok(Some(value)) => Outcome::Stage(Ok(value)),
        Ok(None) => Outcome::Retry,
        Err(e) => Outcome::Stage(Err(e)),
    }
}
fn planned(
    b: &mut Binding,
    observed: coordinator::Observation,
    facts: ImmichLockedLiveStorageFacts,
    quote_deadline: u64,
) -> Result<(), String> {
    b.authority.valid()?;
    if facts.storage.deadline_unix_milliseconds > quote_deadline {
        return Err(ERROR.into());
    }
    let sizes = observed.sizes();
    let members = [
        MemberSize {
            role: MemberRole::Parent,
            key: b.pending.parent_key.clone(),
            expected_bytes: sizes[0],
        },
        MemberSize {
            role: MemberRole::Motion,
            key: b.pending.motion_key.clone(),
            expected_bytes: sizes[1],
        },
    ];
    let representations = facts
        .representations
        .iter()
        .map(|r| Representation {
            name: r.name.clone(),
            maximum_bytes: r.maximum_bytes,
        })
        .collect::<Vec<_>>();
    let budget = policy::construct_budget(&facts.storage, now_ms()?, members, &representations)
        .map_err(|_| ERROR)?;
    let kernel = coordinator::start(
        &b.pending,
        &b.authority,
        observed,
        &facts.storage,
        budget.clone(),
    )?;
    let lease = kernel.leases()?.0;
    let wire_members = std::array::from_fn(|index| {
        let m = &budget.members[index];
        let f = &b.expected[index];
        ImmichLockedLiveMember {
            role: if index == 0 {
                ImmichLockedLiveRole::Parent
            } else {
                ImmichLockedLiveRole::Motion
            },
            key: m.key.clone(),
            expected_revision: f.revision.clone(),
            expected_sha1: f.checksum.clone(),
            expected_bytes: m.expected_bytes,
            commitment_mode: m.commitment_mode,
            max_received_bytes: m.max_received_bytes,
            initial_claim_bytes: m.initial_claim_bytes,
        }
    });
    b.sizes = sizes;
    b.ticket = Some(ImmichLockedLiveTicket {
        pending: b.pending.clone(),
        storage: facts.storage,
        members: wire_members,
        representations: facts.representations,
        acquisition_lease: lease.clone(),
        initial_acquisition_lease: lease,
        display_lease_id: b.display_lease_id,
        pair_disk_ceiling_bytes: budget.pair_disk_ceiling_bytes,
        representation_reservation_bytes: budget.representation_reservation_bytes,
        total_max_received_bytes: budget.total_max_received_bytes,
        minimum_remaining_bytes: budget.minimum_remaining_bytes,
    });
    b.kernel = Some(kernel);
    Ok(())
}
fn guard_completion(
    model: &mut Model,
    completion: &Completion,
) -> Option<Command<crate::app::Effect, Event>> {
    let matching = model
        .immich_locked
        .live
        .active
        .as_ref()
        .is_some_and(|a| a.binding.owner.same(&completion.owner));
    if !matching {
        if let Outcome::Planned(Ok((_, facts, _))) = &completion.outcome {
            return Some(lifecycle::late_quote(
                model,
                &completion.binding,
                facts.storage.lease_id.clone(),
            ));
        }
        return Some(Command::done());
    }
    // Keep quote identity before any guard may fail, so cleanup covers invalid
    // policy/epoch/initial proof as well as successfully started coordinators.
    if let Outcome::Planned(Ok((_, facts, _))) = &completion.outcome
        && let Some(a) = model.immich_locked.live.active.as_mut()
    {
        a.binding.quote_id = Some(facts.storage.lease_id.clone());
    }
    if !lifecycle::active_current(model) {
        return Some(stop(model));
    }
    None
}
pub(super) fn completed(
    model: &mut Model,
    completion: Completion,
) -> Command<crate::app::Effect, Event> {
    if let Outcome::Joined(attempt, result) = &completion.outcome {
        return lifecycle::joined(model, &completion.owner, Some(attempt), result.clone());
    }
    if let Some(command) = guard_completion(model, &completion) {
        return command;
    }
    let Some(active) = model.immich_locked.live.active.as_mut() else {
        return Command::done();
    };
    active.working = false;
    let result: Result<(), String> = match completion.outcome {
        Outcome::Planned(Ok((observed, facts, deadline))) => {
            planned(&mut active.binding, observed, facts, deadline).map(|()| {
                active.step = Step::Start(Stage::Parent);
            })
        }
        Outcome::Stage(Ok((receipt, original))) => {
            let stage = match active.step {
                Step::Start(s) => Some(s),
                _ => None,
            };
            active
                .binding
                .kernel
                .as_ref()
                .ok_or_else(|| ERROR.to_string())
                .and_then(|k| {
                    k.receive_stage(receipt, Instant::now())
                        .map_err(|_| ERROR.into())
                })
                .and_then(|()| {
                    let s = stage.ok_or(ERROR)?;
                    if let Some(original) = original {
                        let index = usize::from(s != Stage::Parent);
                        active.originals[index] = Some(original);
                    }
                    active.step = Step::Check(s);
                    Ok(())
                })
        }
        Outcome::Retry => Ok(()),
        Outcome::Checked(Ok(proof)) => {
            let result = active
                .binding
                .kernel
                .as_ref()
                .ok_or(coordinator::Error::InvalidProof)
                .and_then(|k| k.accept_stage_check(proof, Instant::now()));
            match result {
                Ok(()) => {
                    active.step = match active.step {
                        Step::Check(Stage::Parent) => Step::Start(Stage::Motion),
                        Step::Check(Stage::Motion) => Step::Start(Stage::Prepare),
                        _ => Step::Final,
                    };
                    Ok(())
                }
                Err(coordinator::Error::Stale | coordinator::Error::Busy) => Ok(()),
                Err(_) => Err(ERROR.into()),
            }
        }
        Outcome::Final(Ok(pair)) => {
            active.provisional = Some(pair);
            active.step = Step::Publish;
            Ok(())
        }
        Outcome::Published(Ok((receipt, proof))) => active
            .binding
            .kernel
            .as_ref()
            .ok_or_else(|| ERROR.to_string())
            .and_then(|k| {
                k.publication_proof(proof)?;
                k.acknowledge_publication(receipt, Instant::now())
                    .map_err(|_| ERROR.into())
            })
            .map(|()| {
                active.access = active.provisional.as_ref().map(|p| p.1.clone());
                active.step = Step::Done;
            }),
        _ => Err(ERROR.into()),
    };
    if result.is_err() {
        return stop(model);
    }
    let schedule = schedule(&active.binding);
    schedule.and(advance(model))
}
pub(super) fn schedule(b: &Binding) -> Command<crate::app::Effect, Event> {
    let Some(k) = &b.kernel else {
        return Command::done();
    };
    if k.is_published() {
        return Command::done();
    }
    let Ok((lease, _)) = k.leases() else {
        return Command::done();
    };
    let pending = b.pending.clone();
    Command::new(move |ctx| async move {
        let _: Result<serde_json::Value, _> = io(
            &ctx,
            ShellOperation::ScheduleImmichLockedLiveAcquisitionExpiry { pending, lease },
        )
        .await;
    })
}
pub(super) fn release(
    retired: Retired,
    retry_cleanup: bool,
    attempt: crate::private_media_cleanup::Attempt,
) -> Command<crate::app::Effect, Event> {
    emit(retired.binding, move |ctx, b| {
        Box::pin(async move {
            Outcome::Joined(
                attempt,
                io(
                    &ctx,
                    ShellOperation::ReleaseImmichLockedLive {
                        pending: b.pending,
                        pair_lease_id: retired.lease_id,
                        retry_cleanup,
                    },
                )
                .await,
            )
        })
    })
}
