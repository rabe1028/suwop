use super::{
    Authority, Context, ERROR, Prepared, SavedLibrary, durable, fresh_graph, issued_id, prepare,
};
use crate::{
    immich::HttpResponse,
    immich_live_writes::{
        Accepted204, Media, NoSubmissionRecord, Outcome, Placement, PostFacts, Role,
        original_continuation_open, post_digest, validate_transition,
    },
};

#[derive(Debug, Clone)]
pub(super) struct Finished {
    pub(super) state: Option<SavedLibrary>,
    pub(super) uncertain: bool,
    pub(super) status: String,
}
/// Only this executor can construct a permit. Public journal values and UI replies
/// cannot instantiate a request, and every use rechecks the live private epoch.
pub(crate) struct Submission {
    authority: Authority,
    key: crate::domain::AssetKey,
    destination: Placement,
    step_id: String,
}
impl Submission {
    pub(crate) fn verify(
        &self,
        session: &crate::immich_locked::VisibilitySession,
    ) -> Result<(), String> {
        self.authority.valid()?;
        if session.grant_id != self.authority.session.grant_id
            || session.expected != self.authority.session.expected
            || session.scene_id != self.authority.session.scene_id
            || session.scope() != self.key.scope
        {
            return Err(ERROR.into());
        }
        Ok(())
    }
    pub(crate) fn key(&self) -> &crate::domain::AssetKey {
        &self.key
    }
    pub(crate) fn destination(&self) -> Placement {
        self.destination
    }
    pub(crate) fn step_id(&self) -> &str {
        &self.step_id
    }
}
pub(crate) enum SubmissionResult {
    NotSubmitted,
    Response(Result<HttpResponse, String>),
}
fn finish(state: Option<SavedLibrary>, uncertain: bool, status: &str) -> Finished {
    Finished {
        state,
        uncertain,
        status: status.into(),
    }
}
async fn saved(
    ctx: &Context,
    authority: &Authority,
    before: &SavedLibrary,
    desired: &SavedLibrary,
) -> Result<SavedLibrary, Finished> {
    durable::save(ctx, before, desired)
        .await
        .inspect(|state| super::publish_durable(ctx, authority, state))
        .map_err(|failure| {
            finish(
                failure.state,
                failure.uncertain,
                "変更記録の保存を確認できません。書込みは再送しません。",
            )
        })
}
pub(super) async fn execute(ctx: &Context, prepared: Prepared) -> Finished {
    let authority = &prepared.authority;
    if authority.valid().is_err()
        || authority.session.verify_write_contract(ctx).await.is_err()
        || fresh_graph(ctx, authority, &prepared.batch).await.is_err()
    {
        return finish(None, false, ERROR);
    }
    let mut desired = authority.baseline.as_ref().clone();
    desired.immich_live_operations.push(prepared.batch.clone());
    let mut durable = match saved(ctx, authority, &authority.baseline, &desired).await {
        Ok(state) => state,
        Err(result) => return result,
    };
    let Some(batch_index) = durable
        .immich_live_operations
        .iter()
        .position(|b| b.id == prepared.batch.id)
    else {
        return finish(Some(durable), true, ERROR);
    };
    let count = prepared.batch.steps.len();
    for index in 0..count {
        // NotStarted transitions are explicit new durable intents, after the
        // preceding Applied/readback has committed in its own transaction.
        if index > 0 {
            durable = match next_intent(ctx, &prepared, durable, batch_index, index).await {
                Ok(state) => state,
                Err(result) => return result,
            };
        }

        let batch = &durable.immich_live_operations[batch_index];
        let step = &batch.steps[index];
        let Outcome::Unknown {
            attempt_id,
            accepted: None,
        } = &step.outcome
        else {
            return finish(Some(durable), true, ERROR);
        };
        let attempt_id = attempt_id.clone();
        let Some(resource) = batch
            .intent
            .resources
            .iter()
            .find(|r| r.id == step.resource_id)
        else {
            return finish(Some(durable), true, ERROR);
        };
        let resource = resource.clone();
        let step_id = step.id.clone();
        // Nothing that follows this preflight can implicitly replay the call.
        let response = submit(ctx, authority, batch, &resource, &step_id).await;
        if matches!(response, SubmissionResult::NotSubmitted) {
            return not_submitted(ctx, &prepared, durable, batch_index, index).await;
        }

        let accepted = matches!(response,SubmissionResult::Response(Ok(ref response)) if response.status==204 && response.body.is_null() && response.path.is_none());
        if !accepted {
            return finish(
                Some(durable),
                false,
                "変更結果が不明です。自動再送せず、現在の状態を確認してください。",
            );
        }
        let receipt = Accepted204 {
            batch_id: prepared.batch.id.clone(),
            step_id: step_id.clone(),
            attempt_id: attempt_id.clone(),
            key: resource.initial.key.clone(),
            intent_digest: prepared.batch.intent.digest.clone(),
        };
        let mut acknowledged = durable.clone();
        acknowledged.immich_live_operations[batch_index].steps[index].outcome = Outcome::Unknown {
            attempt_id: attempt_id.clone(),
            accepted: Some(receipt.clone()),
        };
        durable = match saved(ctx, authority, &durable, &acknowledged).await {
            Ok(state) => state,
            Err(result) => return result,
        };
        durable = match verified_post(ctx, &prepared, durable, batch_index, index, receipt).await {
            Ok(state) => state,
            Err(result) => return result,
        };
    }
    finish(
        Some(durable),
        false,
        "選択した関連原本の表示先を確認しました。通常表示へ戻すには現在のペアを読み直してください。",
    )
}

async fn next_intent(
    ctx: &Context,
    prepared: &Prepared,
    durable: SavedLibrary,
    batch_index: usize,
    index: usize,
) -> Result<SavedLibrary, Finished> {
    let authority = &prepared.authority;

    let batch = &durable.immich_live_operations[batch_index];
    if authority.valid().is_err()
        || !original_continuation_open(&durable, &batch.id)
        || authority.session.verify_write_contract(ctx).await.is_err()
        || fresh_graph(ctx, authority, batch).await.is_err()
    {
        return Err(finish(
            Some(durable),
            false,
            "残りの原本は変更していません。新しい確認または現在の状態の保持を選んでください。",
        ));
    }
    let mut next = durable.clone();
    let step = &mut next.immich_live_operations[batch_index].steps[index];
    step.outcome = Outcome::Unknown {
        attempt_id: issued_id(&prepared.batch.id, &format!("attempt:{}", step.id)),
        accepted: None,
    };
    saved(ctx, authority, &durable, &next).await
}

async fn not_submitted(
    ctx: &Context,
    prepared: &Prepared,
    durable: SavedLibrary,
    batch_index: usize,
    index: usize,
) -> Finished {
    let authority = &prepared.authority;
    let batch = &durable.immich_live_operations[batch_index];
    let step = &batch.steps[index];
    let Outcome::Unknown {
        attempt_id,
        accepted: None,
    } = &step.outcome
    else {
        return finish(Some(durable), true, ERROR);
    };
    let attempt_id = attempt_id.clone();
    let step_id = step.id.clone();
    let Some(resource) = batch
        .intent
        .resources
        .iter()
        .find(|resource| resource.id == step.resource_id)
        .cloned()
    else {
        return finish(Some(durable), true, ERROR);
    };

    let mut next = durable.clone();
    next.immich_live_operations[batch_index].steps[index].outcome = Outcome::NotApplied {
        attempt_id: attempt_id.clone(),
        no_submission: NoSubmissionRecord {
            batch_id: prepared.batch.id.clone(),
            step_id,
            attempt_id,
            key: resource.initial.key,
            intent_digest: prepared.batch.intent.digest.clone(),
        },
    };
    match saved(ctx, authority, &durable, &next).await {
        Ok(state) => finish(
            Some(state),
            false,
            "送信前に条件が失効しました。残りの原本は変更していません。",
        ),
        Err(result) => result,
    }
}

async fn verified_post(
    ctx: &Context,
    prepared: &Prepared,
    durable: SavedLibrary,
    batch_index: usize,
    index: usize,
    receipt: Accepted204,
) -> Result<SavedLibrary, Finished> {
    let authority = &prepared.authority;
    let attempt_id = receipt.attempt_id.clone();
    let step_id = receipt.step_id.clone();
    // ACK remains durable even if cancellation prevents the post-read. It
    // does not become Applied merely because a later Inspect matches.
    if authority.valid().is_err() {
        return Err(finish(
            Some(durable),
            false,
            "応答を記録しました。結果の再確認が必要です。",
        ));
    }
    let mut observed = Vec::new();
    for member in &prepared.batch.intent.resources {
        let role = if member.initial.media == Media::Image {
            Role::Parent
        } else {
            Role::Motion
        };
        match prepare::observe(ctx, authority, &member.initial.key, role).await {
            Ok((fact, _)) => observed.push(fact),
            Err(_) => {
                return Err(finish(
                    Some(durable),
                    false,
                    "保存後の関連原本を確認できません。結果の記録を保持しています。",
                ));
            }
        }
    }
    let mut post = PostFacts {
        encoding_version: 1,
        batch_id: prepared.batch.id.clone(),
        step_id,
        attempt_id: attempt_id.clone(),
        intent_digest: prepared.batch.intent.digest.clone(),
        resources: observed,
        digest: String::new(),
    };
    post.digest = match post_digest(&post) {
        Ok(value) => value,
        Err(_) => return Err(finish(Some(durable), false, ERROR)),
    };
    let mut verified = durable.clone();
    verified.immich_live_operations[batch_index].steps[index].outcome = Outcome::Applied {
        attempt_id,
        accepted: receipt,
        verified_post: Box::new(post),
    };
    if validate_transition(&durable, &verified).is_err() || authority.valid().is_err() {
        return Err(finish(
            Some(durable),
            false,
            "関連原本の状態が変わりました。以降の変更は開始しません。",
        ));
    }
    saved(ctx, authority, &durable, &verified).await
}

async fn submit(
    ctx: &Context,
    authority: &Authority,
    batch: &crate::immich_live_writes::Batch,
    resource: &crate::immich_live_writes::Resource,
    step_id: &str,
) -> SubmissionResult {
    let preflight = async {
        authority.valid()?;
        authority.session.verify_write_contract(ctx).await?;
        fresh_graph(ctx, authority, batch).await?;
        authority.valid()
    }
    .await;
    if preflight.is_ok() {
        let permit = Submission {
            authority: authority.clone(),
            key: resource.initial.key.clone(),
            destination: resource.destination,
            step_id: step_id.into(),
        };
        authority.session.submit_live_visibility(ctx, &permit).await
    } else {
        SubmissionResult::NotSubmitted
    }
}
