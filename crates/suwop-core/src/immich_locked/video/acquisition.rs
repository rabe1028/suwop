use super::{
    Asset, AssetKey, Command, Context, ERROR, Event, ImmichLockedVideoPending,
    ImmichLockedVideoPhase, ImmichLockedVideoPrepared, ImmichLockedVideoResult,
    ImmichLockedVideoStorageFacts, ImmichLockedVideoTicket, Model, ShellOperation, Value,
    VideoAcquisition, denied, eligible, epoch, io, pending_current, policy, release, stop,
    visibility_session,
};
pub(super) async fn metadata(
    ctx: &Context,
    acquisition: &VideoAcquisition,
    measured: Option<u64>,
) -> Result<(), String> {
    let cap = acquisition.current_capability()?;
    cap.status(ctx).await?;
    let raw = cap
        .json(
            ctx,
            &format!("assets/{}", acquisition.pending.key.asset_id),
            "GET",
            None,
        )
        .await?;
    let (revision, sha1, bytes) = identity(&raw, &acquisition.pending.key, cap.owner())?;
    if revision != acquisition.revision
        || sha1 != acquisition.sha1
        || acquisition.bytes.is_some_and(|n| Some(n) != bytes)
        || measured.is_some_and(|n| bytes.is_some_and(|expected| n != expected))
    {
        return Err(ERROR.into());
    }
    cap.status(ctx).await?;
    cap.valid()
}
fn identity(
    raw: &Value,
    key: &AssetKey,
    owner: &str,
) -> Result<(String, String, Option<u64>), String> {
    let asset: Asset = serde_json::from_value(raw.clone()).map_err(|_| ERROR)?;
    if asset.id != key.asset_id
        || asset.owner_id != owner
        || asset.media_type != "VIDEO"
        || asset.visibility.as_deref() != Some("locked")
        || asset.is_offline
        || asset.is_trashed
        || asset.updated_at.is_empty()
    {
        return Err(ERROR.into());
    }
    let sha1 = crate::domain::normalize_sha1(Some(&asset.checksum)).ok_or(ERROR)?;
    Ok((
        asset.record(&key.scope, None, None).revision,
        sha1,
        policy::size(raw)?,
    ))
}
pub(super) fn request(
    model: &mut Model,
    entry_id: String,
    grant_id: String,
    scene_id: String,
    request_id: String,
) -> Command<crate::app::Effect, Event> {
    if model.immich_locked.video.retired.len() >= super::cleanup::CAPACITY - 1 {
        return Command::done();
    }
    let Some(capability) = visibility_session(model, &grant_id, &scene_id) else {
        return Command::done();
    };
    if crate::immich::valid_id(&request_id).is_err()
        || !model.immich_locked.used_ids.insert(request_id.clone())
    {
        return Command::done();
    }
    let Some(entry) = model
        .immich_locked
        .entries
        .iter()
        .find(|e| e.id == entry_id && !denied(model, &e.asset.key) && eligible(&e.asset))
        .cloned()
    else {
        return Command::done();
    };
    let Some(original) = entry
        .asset
        .originals()
        .find(|r| r.id == entry.asset.key.asset_id && r.role == crate::domain::ResourceRole::Video)
    else {
        return Command::done();
    };
    let Some(sha1) = crate::domain::normalize_sha1(original.sha1.as_deref()) else {
        return Command::done();
    };
    let cleanup = stop(model);
    // Video supersedes a still preview; native joins the old consumer before acquisition.
    model.immich_locked.image = None;
    model.immich_locked.pending = None;
    let pending = ImmichLockedVideoPending {
        request_id,
        entry_id,
        grant_id,
        scene_id,
        generation: epoch(&model.immich_locked),
        key: entry.asset.key.clone(),
        phase: ImmichLockedVideoPhase::Checking,
    };
    model.immich_locked.video.pending = Some(pending.clone());
    let acquisition = VideoAcquisition {
        pending,
        capability: capability.clone(),
        revision: entry.asset.revision.clone(),
        sha1,
        bytes: None,
        lease: super::renewal::SharedLease::new(capability.lease_deadline),
    };
    model.immich_locked.video.binding = Some(acquisition.clone());
    cleanup.and(Command::new(move |ctx| async move {
        let storage = async {
            let cap = &acquisition.capability;
            cap.status(&ctx).await?;
            let raw = cap
                .json(
                    &ctx,
                    &format!("assets/{}", acquisition.pending.key.asset_id),
                    "GET",
                    None,
                )
                .await?;
            let (revision, sha1, bytes) = identity(&raw, &acquisition.pending.key, cap.owner())?;
            if revision != acquisition.revision || sha1 != acquisition.sha1 {
                return Err(ERROR.into());
            }
            let facts: ImmichLockedVideoStorageFacts = io(
                &ctx,
                ShellOperation::InspectImmichLockedVideoStorage {
                    pending: acquisition.pending.clone(),
                },
            )
            .await?;
            Ok::<_, String>((facts, bytes))
        }
        .await;
        ctx.send_event(Event::ImmichLockedVideoPlanned {
            acquisition,
            storage,
        });
    }))
}
fn initial_lease(
    acquisition: &VideoAcquisition,
    deadline: u64,
) -> super::ImmichLockedVideoAcquisitionLease {
    super::ImmichLockedVideoAcquisitionLease {
        lease_id: 1,
        deadline_unix_milliseconds: deadline,
        remaining_milliseconds: u64::try_from(
            acquisition
                .capability
                .lease_deadline
                .min(acquisition.capability.hard_deadline)
                .saturating_duration_since(std::time::Instant::now())
                .as_millis(),
        )
        .unwrap_or(0),
        extension_milliseconds: 0,
    }
}

pub(super) fn planned(
    model: &mut Model,
    mut acquisition: VideoAcquisition,
    storage: Result<(ImmichLockedVideoStorageFacts, Option<u64>), String>,
) -> Command<crate::app::Effect, Event> {
    let Ok((storage, bytes)) = storage else {
        if pending_current(model, &acquisition.pending) {
            model.immich_locked.error = Some("動画の取得条件を確認できません。".into());
            return stop(model);
        }
        return Command::done();
    };
    if pending_current(model, &acquisition.pending) {
        // Retain the exact returned quote before a policy/expiry guard can stop this request.
        model.immich_locked.video.lease =
            Some((acquisition.pending.clone(), storage.lease_id.clone()));
    }
    let rejected = |model: &mut Model| release(model, &acquisition.pending);
    if !pending_current(model, &acquisition.pending) || acquisition.capability.valid().is_err() {
        return rejected(model);
    }
    let Ok(maximum) = policy::budget(&storage, bytes) else {
        let command = rejected(model);
        model.immich_locked.error = Some("動画を取得する空き容量を確認してください。".into());
        return stop(model).and(command);
    };
    let Ok(deadline) = acquisition.capability.visibility_deadline() else {
        return stop(model).and(rejected(model));
    };
    acquisition.bytes = bytes;
    model.immich_locked.video.binding = Some(acquisition.clone());
    acquisition.pending.phase = ImmichLockedVideoPhase::Acquiring;
    model.immich_locked.video.pending = Some(acquisition.pending.clone());
    model.immich_locked.video.lease = Some((acquisition.pending.clone(), storage.lease_id.clone()));
    let initial_lease = initial_lease(&acquisition, deadline);
    let mut ticket = ImmichLockedVideoTicket {
        pending: acquisition.pending.clone(),
        acquisition_lease: initial_lease.clone(),
        initial_acquisition_lease: initial_lease,
        display_lease_id: model.immich_locked.lease_id,
        deadline_unix_milliseconds: deadline,
        expected_revision: acquisition.revision.clone(),
        expected_sha1: acquisition.sha1.clone(),
        expected_bytes: bytes,
        commitment_mode: policy::commitment_mode(bytes),
        storage,
        max_received_bytes: maximum,
        minimum_remaining_bytes: policy::PRIVATE_VIDEO_HEADROOM_BYTES,
        request: acquisition.capability.session.request(
            &format!(
                "assets/{}/original?edited=false",
                acquisition.pending.key.asset_id
            ),
            "GET",
            None,
        ),
    };
    ticket
        .request
        .headers
        .insert("Accept-Encoding".into(), "identity".into());
    model.immich_locked.video.renewal.ticket = Some(ticket.clone());
    let expiry = super::renewal::schedule(ticket.pending.clone(), ticket.acquisition_lease.clone());
    expiry.and(Command::new(move |ctx| async move {
        let result = async {
            metadata(&ctx, &acquisition, None).await?;
            if acquisition.current_capability().is_err() {
                return Err(ERROR.into());
            }
            let result: ImmichLockedVideoResult = io(
                &ctx,
                ShellOperation::ReadImmichLockedVideo {
                    ticket: ticket.clone(),
                },
            )
            .await?;
            if result.request_id != ticket.pending.request_id
                || result.staged_id != ticket.storage.lease_id
                || !result.signature.valid()
                || result.signature.bytes > ticket.max_received_bytes
                || ticket
                    .expected_bytes
                    .is_some_and(|n| n != result.signature.bytes)
                || crate::domain::normalize_sha1(Some(&result.sha1)).as_ref()
                    != Some(&ticket.expected_sha1)
            {
                return Err(ERROR.into());
            }
            metadata(&ctx, &acquisition, Some(result.signature.bytes)).await?;
            Ok::<_, String>(result)
        }
        .await;
        ctx.send_event(Event::ImmichLockedVideoRead {
            acquisition,
            ticket: Box::new(ticket),
            result,
        });
    }))
}
pub(super) fn read(
    model: &mut Model,
    acquisition: VideoAcquisition,
    mut ticket: ImmichLockedVideoTicket,
    result: Result<ImmichLockedVideoResult, String>,
) -> Command<crate::app::Effect, Event> {
    let result = match result {
        Ok(result)
            if pending_current(model, &ticket.pending)
                && super::renewal::completion_current(
                    model,
                    &ticket,
                    result.acquisition_lease_id,
                ) =>
        {
            result
        }
        _ => {
            let cleanup = if pending_current(model, &ticket.pending) {
                model.immich_locked.error =
                    Some("動画を確認できません。もう一度選んでください。".into());
                stop(model)
            } else {
                Command::done()
            };
            return cleanup.and(release(model, &ticket.pending));
        }
    };
    model.immich_locked.video.measured_bytes = Some(result.signature.bytes);
    if let Some(current) = model.immich_locked.video.renewal.ticket.as_ref() {
        ticket.acquisition_lease = current.acquisition_lease.clone();
        ticket.deadline_unix_milliseconds = current.deadline_unix_milliseconds;
    }
    ticket.pending.phase = ImmichLockedVideoPhase::Preparing;
    model.immich_locked.video.pending = Some(ticket.pending.clone());
    Command::new(move |ctx| async move {
        let approved = async {
            metadata(&ctx, &acquisition, Some(result.signature.bytes)).await?;
            if acquisition.current_capability().is_err() {
                return Err(ERROR.into());
            }
            let prepared: ImmichLockedVideoPrepared = io(
                &ctx,
                ShellOperation::PrepareImmichLockedVideo {
                    ticket: ticket.clone(),
                    staged_id: ticket.storage.lease_id.clone(),
                },
            )
            .await?;
            if prepared.request_id != ticket.pending.request_id
                || prepared.staged_id != ticket.storage.lease_id
            {
                return Err(ERROR.into());
            }
            metadata(&ctx, &acquisition, Some(result.signature.bytes)).await?;
            if acquisition.current_capability().is_err() {
                return Err(ERROR.into());
            }
            Ok::<_, String>(prepared.acquisition_lease_id)
        }
        .await;
        let acquisition_lease_id = approved.as_ref().copied().unwrap_or(0);
        ctx.send_event(Event::ImmichLockedVideoPrepared {
            ticket,
            approved: approved.is_ok(),
            acquisition_lease_id,
        });
    })
}
