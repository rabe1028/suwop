//! Explicit, ephemeral Immich classification reads. Server people never grant
//! access to an asset and are not local face recognition or deletion evidence.
use crate::{
    app::{Context, Event, Model},
    domain::{AssetKey, Provider, ScanAccess, StoredAsset},
    immich::{Asset, OrdinarySessionGuard, Session},
    organization::OrganizationMember,
};
use crux_core::Command;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::{
    collections::{BTreeMap, BTreeSet},
    sync::{
        Arc,
        atomic::{AtomicU64, Ordering},
    },
};

const ASSET_LIMIT: usize = 2000;
const BATCH_SIZE: usize = 100;
const ERROR: &str =
    "人物の情報を確認できませんでした。写真一覧を更新してから再度読み込んでください。";

#[derive(Debug, Clone, Default, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
// Loading state and independent presentation/coverage bounds are separate axes.
#[allow(clippy::struct_excessive_bools)]
pub struct OrganizationPeopleView {
    pub groups: Vec<OrganizationPersonGroup>,
    pub loading: bool,
    pub loaded: bool,
    pub truncated: bool,
    pub partial_coverage: bool,
    pub error: Option<String>,
}
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct OrganizationPersonGroup {
    pub id: String,
    pub scope: String,
    #[serde(rename = "personID")]
    pub person_id: String,
    pub name: String,
    pub members: Vec<OrganizationMember>,
}
#[derive(Debug, Clone)]
pub struct Person {
    id: String,
    name: String,
    hidden: bool,
}
#[derive(Debug, Clone)]
pub struct Observation {
    member: OrganizationMember,
    people: Vec<Person>,
}
#[derive(Debug, Clone)]
pub struct ResultData {
    observations: Vec<Observation>,
    partial: bool,
}
#[derive(Debug, Default)]
pub struct PeopleState {
    epoch: Arc<AtomicU64>,
    active: Option<Active>,
    data: Option<ResultData>,
    error: bool,
}
#[derive(Debug)]
struct Active {
    request: u64,
    ordinary: u64,
    scope: String,
    endpoint: String,
    user: String,
    loading: bool,
}

fn candidates(model: &Model) -> Vec<StoredAsset> {
    let Some(session) = &model.session else {
        return vec![];
    };
    let public = crate::privacy::PublishedLibrary::from_canonical(
        &crate::protection::ordinary_state_view(model),
    );
    let (keys, _) = crate::app::Suwop::ordinary_content_membership(model);
    let allowed: BTreeSet<_> = keys.into_iter().collect();
    let mut records: BTreeMap<AssetKey, Option<&StoredAsset>> = BTreeMap::new();
    for snapshot in &public.snapshots {
        if snapshot.provider != Provider::Immich
            || snapshot.scope != session.scope
            || snapshot.access == ScanAccess::Unavailable
        {
            continue;
        }
        for asset in &snapshot.assets {
            if allowed.contains(&asset.key)
                && asset.key.provider == snapshot.provider
                && asset.key.scope == snapshot.scope
                && !asset.is_offline
                && asset.immich_visibility
                    == Some(crate::immich_visibility::ImmichVisibility::Timeline)
            {
                records
                    .entry(asset.key.clone())
                    .and_modify(|value| *value = None)
                    .or_insert(Some(asset));
            }
        }
    }
    records
        .into_values()
        .flatten()
        .take(ASSET_LIMIT + 1)
        .cloned()
        .collect()
}
fn current(model: &Model, active: &Active) -> bool {
    model.organization_reference.is_some()
        && active.ordinary == model.ordinary_generation.load(Ordering::SeqCst)
        && active.request == model.organization_people.epoch.load(Ordering::SeqCst)
        && model.session.as_ref().is_some_and(|session| {
            session.scope == active.scope
                && session.endpoint == active.endpoint
                && session.user_id == active.user
        })
}
pub fn reconcile(model: &mut Model) {
    if model
        .organization_people
        .active
        .as_ref()
        .is_some_and(|active| !current(model, active))
    {
        clear(model);
    }
}

pub fn clear(model: &mut Model) {
    model
        .organization_people
        .epoch
        .fetch_add(1, Ordering::SeqCst);
    model.organization_people.active = None;
    model.organization_people.data = None;
    model.organization_people.error = false;
}
pub fn update(event: &Event, model: &mut Model) -> Option<Command<crate::app::Effect, Event>> {
    match event {
        Event::BrowseOrganizationPeople => Some(start(model)),
        Event::OrganizationPeopleFinished { request, result } => {
            let accepts = model
                .organization_people
                .active
                .as_ref()
                .is_some_and(|active| active.request == *request && current(model, active));
            if accepts {
                if let Some(active) = &mut model.organization_people.active {
                    active.loading = false;
                }
                model.organization_people.error = result.is_err();
                model.organization_people.data = result.clone().ok();
            }
            Some(Command::done())
        }
        Event::EndOrganizationBrowse | Event::Disconnect | Event::Configure { .. } => {
            clear(model);
            None
        }
        _ => None,
    }
}
fn start(model: &mut Model) -> Command<crate::app::Effect, Event> {
    clear(model);
    let Some(mut session) = model
        .session
        .clone()
        .filter(|session| session.version.uses_cursor())
    else {
        model.organization_people.error = true;
        return Command::done();
    };
    if model.organization_reference.is_none()
        || model.protection.membership_uncertain
        || model.immich_visibility.persistence_uncertain
    {
        return Command::done();
    }
    let mut expected = candidates(model);
    let partial = expected.len() > ASSET_LIMIT;
    expected.truncate(ASSET_LIMIT);
    let request = model.organization_people.epoch.load(Ordering::SeqCst);
    let ordinary = model.ordinary_generation.load(Ordering::SeqCst);
    session.ordinary_content_guard = Some(OrdinarySessionGuard {
        generation: model.ordinary_generation.clone(),
        expected: ordinary,
    });
    model.organization_people.active = Some(Active {
        request,
        ordinary,
        scope: session.scope.clone(),
        endpoint: session.endpoint.clone(),
        user: session.user_id.clone(),
        loading: true,
    });
    let epoch = model.organization_people.epoch.clone();
    Command::new(move |ctx| async move {
        let result = observe(&ctx, &session, &expected, &epoch, request, partial).await;
        ctx.send_event(Event::OrganizationPeopleFinished { request, result });
    })
}

fn checked_people(value: &Value) -> Result<Vec<Person>, String> {
    let values = value
        .as_array()
        .filter(|values| values.len() <= 100)
        .ok_or(ERROR)?;
    let mut result = Vec::new();
    for value in values {
        let id = value.get("id").and_then(Value::as_str).ok_or(ERROR)?;
        crate::immich::valid_id(id).map_err(|_| ERROR)?;
        let hidden = value
            .get("isHidden")
            .and_then(Value::as_bool)
            .ok_or(ERROR)?;
        let name = if hidden {
            ""
        } else {
            value
                .get("name")
                .and_then(Value::as_str)
                .filter(|name| {
                    name.len() <= 1024
                        && name.chars().count() <= 256
                        && !name.chars().any(char::is_control)
                })
                .ok_or(ERROR)?
        };
        result.push(Person {
            id: id.into(),
            name: name.into(),
            hidden,
        });
    }
    Ok(result)
}
fn check(session: &Session, epoch: &AtomicU64, request: u64) -> Result<(), String> {
    if epoch.load(Ordering::SeqCst) != request || session.check_content_guard().is_err() {
        return Err(ERROR.into());
    }
    Ok(())
}

async fn read_page(
    ctx: &Context,
    session: &Session,
    batch: &[StoredAsset],
    body: Value,
) -> Result<Value, String> {
    let mut request = session.request("search/metadata", "POST", Some(body));
    if let Some(guard) = &session.ordinary_content_guard {
        request.ordinary_content_authorization =
            Some(crate::immich::OrdinaryContentAuthorization {
                source_keys: batch.iter().map(|asset| asset.key.clone()).collect(),
                expected_revision: crate::app::ordinary_revision(
                    Some(&session.scope),
                    guard.expected,
                ),
                purpose: crate::immich::OrdinaryContentPurpose::Read,
            });
    }
    let response: crate::immich::HttpResponse =
        crate::app::io(ctx, crate::app::ShellOperation::Http(request))
            .await
            .map_err(|_| ERROR)?;
    crate::immich::check_status(response.status).map_err(|_| ERROR)?;
    Ok(response.body)
}

/// Query IDs come only from captured ordinary records, never from response names.
/// The OR/eq filters are common to the pinned 3.2.4 and 3.3.3 schemas.
pub async fn observe(
    ctx: &Context,
    session: &Session,
    expected: &[StoredAsset],
    epoch: &AtomicU64,
    request: u64,
    mut partial: bool,
) -> Result<ResultData, String> {
    if expected.len() > ASSET_LIMIT {
        return Err(ERROR.into());
    }
    let mut observed = BTreeMap::new();
    for batch in expected.chunks(BATCH_SIZE) {
        let wanted: BTreeSet<_> = batch
            .iter()
            .map(|asset| asset.key.asset_id.as_str())
            .collect();
        for id in &wanted {
            crate::immich::valid_id(id).map_err(|_| ERROR)?;
        }
        let mut cursor = None;
        let mut seen = BTreeSet::new();
        for page in 0..3 {
            check(session, epoch, request)?;
            let mut body = json!({"size":100,"withPeople":true,"withExif":true,"withStacked":true,"filter":{"or":wanted.iter().map(|id| json!({"id":{"eq":id}})).collect::<Vec<_>>(),"visibility":{"eq":"timeline"},"trashedAt":{"eq":null}}});
            if let Some(cursor) = &cursor {
                body["cursor"] = json!(cursor);
            }
            let response = read_page(ctx, session, batch, body).await?;
            check(session, epoch, request)?;
            let envelope = response.get("assets").ok_or(ERROR)?;
            let items = envelope
                .get("items")
                .and_then(Value::as_array)
                .filter(|items| items.len() <= BATCH_SIZE)
                .ok_or(ERROR)?;
            for item in items {
                let asset: Asset = serde_json::from_value(item.clone()).map_err(|_| ERROR)?;
                if !wanted.contains(asset.id.as_str())
                    || observed.contains_key(&asset.id)
                    || asset.owner_id != session.user_id
                    || asset.is_trashed
                    || asset.is_offline
                    || asset.visibility.as_deref() != Some("timeline")
                {
                    return Err(ERROR.into());
                }
                let people = checked_people(item.get("people").ok_or(ERROR)?)?;
                observed.insert(asset.id.clone(), (asset, people));
            }
            let next = envelope.get("nextCursor").ok_or(ERROR)?;
            if next.is_null() {
                break;
            }
            let next = next
                .as_str()
                .filter(|next| !next.is_empty() && next.len() <= 8192)
                .ok_or(ERROR)?;
            if page == 2 || !seen.insert(next.to_owned()) {
                return Err(ERROR.into());
            }
            cursor = Some(next.to_owned());
        }
    }
    let mut observations = Vec::new();
    for source in expected {
        let Some((asset, people)) = observed.get(&source.key.asset_id) else {
            partial = true;
            continue;
        };
        let companion = asset
            .live_photo_video_id
            .as_ref()
            .and_then(|id| observed.get(id))
            .map(|(asset, _)| asset);
        if !matches_parent_observation(source, asset, companion, &session.scope) {
            partial = true;
            continue;
        }
        observations.push(Observation {
            member: source.into(),
            people: people.clone(),
        });
    }
    Ok(ResultData {
        observations,
        partial,
    })
}

fn matches_parent_observation(
    source: &StoredAsset,
    asset: &Asset,
    companion: Option<&Asset>,
    scope: &str,
) -> bool {
    let fresh = asset.record(scope, companion, None);
    // The parent fence comes directly from the provider observation. Never parse
    // full revision or infer a parent fence from editable catalog metadata.
    source.immich_parent_revision.as_ref().map_or_else(
        || fresh.revision == source.revision,
        |parent| fresh.immich_parent_revision.as_ref() == Some(parent),
    )
}

#[must_use]
pub fn view(model: &Model) -> OrganizationPeopleView {
    let mut result = OrganizationPeopleView::default();
    let Some(active) = model
        .organization_people
        .active
        .as_ref()
        .filter(|active| current(model, active))
    else {
        if model.organization_people.error {
            result.error = Some(ERROR.into());
        }
        return result;
    };
    result.loading = active.loading;
    result.loaded = !active.loading && !model.organization_people.error;
    if model.organization_people.error {
        result.error = Some(ERROR.into());
    }
    let Some(data) = &model.organization_people.data else {
        return result;
    };
    result.partial_coverage = data.partial;
    let current: BTreeMap<_, _> = candidates(model)
        .into_iter()
        .map(|asset| (asset.key.clone(), asset.revision))
        .collect();
    let mut groups: BTreeMap<String, (Option<String>, BTreeMap<AssetKey, OrganizationMember>)> =
        BTreeMap::new();
    for observation in &data.observations {
        if current.get(&observation.member.key) != Some(&observation.member.revision) {
            continue;
        }
        for person in &observation.people {
            let entry = groups
                .entry(person.id.clone())
                .or_insert_with(|| (Some(person.name.clone()), BTreeMap::new()));
            if person.hidden || entry.0.as_ref().is_some_and(|name| name != &person.name) {
                entry.0 = None;
            }
            entry
                .1
                .insert(observation.member.key.clone(), observation.member.clone());
        }
    }
    for (person_id, (name, members)) in groups {
        let Some(name) = name else {
            continue;
        };
        if result.groups.len() == 100 {
            result.truncated = true;
            break;
        }
        if members.len() > 100 {
            result.truncated = true;
        }
        result.groups.push(OrganizationPersonGroup {
            id: serde_json::to_string(&(&active.scope, &person_id)).unwrap_or_default(),
            scope: active.scope.clone(),
            person_id,
            name,
            members: members.into_values().take(100).collect(),
        });
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{
        app::{Effect, SavedLibrary, ShellOperation, ShellResponse, Suwop},
        domain::LibrarySnapshot,
        immich::{HttpResponse, Version},
        organization::OrganizationDate,
    };
    use crux_core::{App, Core};
    const ID: &str = "11111111-1111-4111-8111-111111111111";
    const PERSON: &str = "22222222-2222-4222-8222-222222222222";
    const USER: &str = "33333333-3333-4333-8333-333333333333";
    fn raw() -> Value {
        json!({"id":ID,"ownerId":USER,"type":"IMAGE","originalFileName":"generated.png","checksum":"a".repeat(40),"fileCreatedAt":"2026-01-01T00:00:00Z","fileModifiedAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z","isFavorite":false,"isOffline":false,"isTrashed":false,"visibility":"timeline","people":[{"id":PERSON,"name":"Generated person","isHidden":false}]})
    }
    fn model() -> Result<Model, String> {
        let asset: Asset = serde_json::from_value(raw()).map_err(|error| error.to_string())?;
        Ok(Model {
            ready: true,
            session: Some(Session {
                ordinary_content_guard: None,
                ordinary_content_context: None,
                endpoint: "https://fixture.invalid/api".into(),
                key: "generated-key".into(),
                user_id: USER.into(),
                scope: "fixture".into(),
                version: Version {
                    major: 3,
                    minor: 2,
                    patch: 4,
                },
            }),
            organization_reference: Some(OrganizationDate {
                year: 2026,
                month: 10,
                day: 28,
                time_zone: "UTC".into(),
            }),
            state: SavedLibrary {
                schema_version: crate::immich_live_writes::CURRENT_SCHEMA_VERSION,
                snapshots: vec![LibrarySnapshot {
                    provider: Provider::Immich,
                    scope: "fixture".into(),
                    assets: vec![asset.record("fixture", None, None)],
                    access: ScanAccess::Full,
                    scanned_at: Some(1.0),
                }],
                ..SavedLibrary::default()
            },
            ..Model::default()
        })
    }
    fn reply(
        core: &Core<Suwop>,
        effect: Effect,
        items: Vec<Value>,
        next: Value,
    ) -> Result<Vec<Effect>, String> {
        let Effect::Io(mut request) = effect;
        let mut body = json!({"assets":{}});
        body["assets"]["items"] = Value::Array(items);
        body["assets"]["nextCursor"] = next;
        core.resolve(
            &mut request,
            ShellResponse {
                value: Some(
                    serde_json::to_value(HttpResponse {
                        status: 200,
                        body,
                        path: None,
                    })
                    .map_err(|error| error.to_string())?,
                ),
                error: None,
            },
        )
        .map_err(|error| error.to_string())
    }
    #[test]
    fn people_requires_explicit_request_and_exact_authorized_search_then_clears_on_leave()
    -> Result<(), String> {
        let core = Core::new_with(Suwop, model()?);
        assert!(!core.view().organization.people.loaded);
        assert!(
            core.process_event(Event::Browse {
                options: crate::browser::BrowserOptions::default()
            })
            .is_empty()
        );
        let effect = core
            .process_event(Event::BrowseOrganizationPeople)
            .pop()
            .ok_or("people query")?;
        let Effect::Io(request) = &effect;
        let ShellOperation::Http(http) = &request.operation else {
            return Err("expected read".into());
        };
        assert_eq!(http.method, "POST");
        assert_eq!(
            http.body.as_ref().ok_or("query")?["filter"]["or"],
            json!([{"id":{"eq":ID}}])
        );
        assert_eq!(
            http.ordinary_content_authorization
                .as_ref()
                .ok_or("authority")?
                .source_keys[0]
                .asset_id,
            ID
        );
        assert!(reply(&core, effect, vec![raw()], Value::Null)?.is_empty());
        assert_eq!(
            core.view().organization.people.groups[0].name,
            "Generated person"
        );
        core.process_event(Event::EndOrganizationBrowse);
        assert!(core.view().organization.people.groups.is_empty());
        Ok(())
    }
    #[test]
    fn stale_generation_and_late_cancelled_completion_never_install_names() -> Result<(), String> {
        for cancel in [false, true] {
            let model = model()?;
            let generation = model.ordinary_generation.clone();
            let core = Core::new_with(Suwop, model);
            let effect = core
                .process_event(Event::BrowseOrganizationPeople)
                .pop()
                .ok_or("query")?;
            if cancel {
                core.process_event(Event::EndOrganizationBrowse);
            } else {
                generation.fetch_add(1, Ordering::SeqCst);
            }
            reply(&core, effect, vec![raw()], Value::Null)?;
            assert!(core.view().organization.people.groups.is_empty());
            assert!(!core.view().organization.people.loaded);
        }
        Ok(())
    }
    #[test]
    fn returned_foreign_ids_or_owners_and_oversized_names_fail_with_fixed_error()
    -> Result<(), String> {
        for property in ["id", "ownerId", "name"] {
            let core = Core::new_with(Suwop, model()?);
            let effect = core
                .process_event(Event::BrowseOrganizationPeople)
                .pop()
                .ok_or("query")?;
            let mut response = raw();
            if property == "name" {
                response["people"][0]["name"] = json!("sensitive".repeat(200));
            } else {
                response[property] = json!("44444444-4444-4444-8444-444444444444");
            }
            reply(&core, effect, vec![response], Value::Null)?;
            let view = core.view();
            assert!(view.organization.people.groups.is_empty());
            assert_eq!(view.organization.people.error.as_deref(), Some(ERROR));
        }
        Ok(())
    }
    #[test]
    fn hidden_people_and_conflicting_names_fail_closed_per_person_group() -> Result<(), String> {
        for hidden in [false, true] {
            let core = Core::new_with(Suwop, model()?);
            let effect = core
                .process_event(Event::BrowseOrganizationPeople)
                .pop()
                .ok_or("query")?;
            let mut response = raw();
            response["people"]
                .as_array_mut()
                .ok_or("people")?
                .push(json!({"id":PERSON,"name":"Other generated name","isHidden":hidden}));
            reply(&core, effect, vec![response], Value::Null)?;
            assert!(core.view().organization.people.loaded);
            assert!(core.view().organization.people.groups.is_empty());
        }
        Ok(())
    }
    #[test]
    fn metadata_revision_mismatch_has_explicit_partial_coverage() -> Result<(), String> {
        let core = Core::new_with(Suwop, model()?);
        let effect = core
            .process_event(Event::BrowseOrganizationPeople)
            .pop()
            .ok_or("query")?;
        let mut response = raw();
        response["updatedAt"] = json!("2026-01-02T00:00:00Z");
        reply(&core, effect, vec![response], Value::Null)?;
        assert!(core.view().organization.people.partial_coverage);
        assert!(core.view().organization.people.groups.is_empty());
        Ok(())
    }
    #[test]
    fn repeated_pagination_cursor_is_rejected() -> Result<(), String> {
        let core = Core::new_with(Suwop, model()?);
        let effect = core
            .process_event(Event::BrowseOrganizationPeople)
            .pop()
            .ok_or("query")?;
        let next = reply(&core, effect, vec![], json!("cursor"))?
            .pop()
            .ok_or("next page")?;
        reply(&core, next, vec![], json!("cursor"))?;
        assert_eq!(
            core.view().organization.people.error.as_deref(),
            Some(ERROR)
        );
        Ok(())
    }
    #[test]
    fn protected_revision_changed_and_other_session_data_are_never_published() -> Result<(), String>
    {
        for mode in 0..4 {
            let mut model = model()?;
            let _command = start(&mut model);
            let member: OrganizationMember = (&model.state.snapshots[0].assets[0]).into();
            model
                .organization_people
                .active
                .as_mut()
                .ok_or("active")?
                .loading = false;
            model.organization_people.data = Some(ResultData {
                observations: vec![Observation {
                    member: member.clone(),
                    people: vec![Person {
                        id: PERSON.into(),
                        name: "Generated person".into(),
                        hidden: false,
                    }],
                }],
                partial: false,
            });
            match mode {
                0 => {
                    model.protection.denied.insert(member.key);
                }
                1 => model.state.snapshots[0].assets[0].revision = "changed".into(),
                2 => model.session.as_mut().ok_or("session")?.scope = "other".into(),
                _ => model.session.as_mut().ok_or("session")?.user_id = "other".into(),
            }
            assert!(Suwop.view(&model).organization.people.groups.is_empty());
        }
        Ok(())
    }
    #[test]
    fn leave_reopen_and_new_request_ignore_old_page_without_followup_reads() -> Result<(), String> {
        let core = Core::new_with(Suwop, model()?);
        let old = core
            .process_event(Event::BrowseOrganizationPeople)
            .pop()
            .ok_or("old query")?;
        core.process_event(Event::EndOrganizationBrowse);
        core.process_event(Event::BrowseOrganization {
            reference: OrganizationDate {
                year: 2026,
                month: 10,
                day: 28,
                time_zone: "UTC".into(),
            },
        });
        let new = core
            .process_event(Event::BrowseOrganizationPeople)
            .pop()
            .ok_or("new query")?;
        let mut old_page = raw();
        old_page["people"][0]["name"] = json!("Old generated name");
        assert!(reply(&core, old, vec![old_page], json!("old-next-page"))?.is_empty());
        assert!(core.view().organization.people.loading);
        assert!(core.view().organization.people.groups.is_empty());
        let mut new_page = raw();
        new_page["people"][0]["name"] = json!("New generated name");
        assert!(reply(&core, new, vec![new_page], Value::Null)?.is_empty());
        assert_eq!(
            core.view().organization.people.groups[0].name,
            "New generated name"
        );
        Ok(())
    }

    fn exported_live_parent_fixture() -> Result<(Model, Value), String> {
        let mut parent_json = raw();
        let motion_id = "55555555-5555-4555-8555-555555555555";
        parent_json["livePhotoVideoId"] = json!(motion_id);
        let parent: Asset =
            serde_json::from_value(parent_json.clone()).map_err(|error| error.to_string())?;
        let mut motion_json = raw();
        motion_json["id"] = json!(motion_id);
        motion_json["type"] = json!("VIDEO");
        motion_json["visibility"] = json!("hidden");
        motion_json["updatedAt"] = json!("2026-01-02T00:00:00Z");
        let motion: Asset =
            serde_json::from_value(motion_json).map_err(|error| error.to_string())?;
        let exported = parent.record("fixture", Some(&motion), None);
        let listed = parent.record("fixture", None, None);
        assert_ne!(exported.revision, listed.revision);
        assert_eq!(
            exported.immich_parent_revision,
            listed.immich_parent_revision
        );
        assert!(exported.immich_parent_revision.is_some());
        let mut model = model()?;
        model.state.snapshots[0].assets = vec![exported];
        Ok((model, parent_json))
    }

    fn assert_parent_only_query(effect: &Effect) -> Result<(), String> {
        let Effect::Io(request) = effect;
        let ShellOperation::Http(http) = &request.operation else {
            return Err("expected metadata query".into());
        };
        assert_eq!(
            http.body.as_ref().ok_or("body")?["filter"]["or"],
            json!([{"id":{"eq":ID}}])
        );
        assert_eq!(
            http.ordinary_content_authorization
                .as_ref()
                .ok_or("authority")?
                .source_keys
                .len(),
            1
        );
        assert_eq!(
            http.ordinary_content_authorization
                .as_ref()
                .ok_or("authority")?
                .source_keys[0]
                .asset_id,
            ID
        );
        Ok(())
    }

    #[test]
    fn exported_live_parent_people_does_not_require_hidden_motion_query() -> Result<(), String> {
        let (model, parent_json) = exported_live_parent_fixture()?;
        let expected_full_revision = model.state.snapshots[0].assets[0].revision.clone();
        let core = Core::new_with(Suwop, model);
        let effect = core
            .process_event(Event::BrowseOrganizationPeople)
            .pop()
            .ok_or("parent query")?;
        assert_parent_only_query(&effect)?;
        assert!(reply(&core, effect, vec![parent_json], Value::Null)?.is_empty());
        let view = core.view();
        assert!(!view.organization.people.partial_coverage);
        assert_eq!(view.organization.people.groups.len(), 1);
        assert_eq!(
            view.organization.people.groups[0].members[0].revision,
            expected_full_revision
        );
        Ok(())
    }

    #[test]
    fn live_parent_updates_link_changes_and_revocation_still_reject_people() -> Result<(), String> {
        for change in ["updatedAt", "livePhotoVideoId", "permission"] {
            let (model, mut parent_json) = exported_live_parent_fixture()?;
            let generation = model.ordinary_generation.clone();
            let core = Core::new_with(Suwop, model);
            let effect = core
                .process_event(Event::BrowseOrganizationPeople)
                .pop()
                .ok_or("parent query")?;
            assert_parent_only_query(&effect)?;
            match change {
                "updatedAt" => parent_json[change] = json!("2026-01-03T00:00:00Z"),
                "livePhotoVideoId" => {
                    parent_json[change] = json!("66666666-6666-4666-8666-666666666666");
                }
                _ => {
                    generation.fetch_add(1, Ordering::SeqCst);
                }
            }
            assert!(reply(&core, effect, vec![parent_json], Value::Null)?.is_empty());
            assert!(core.view().organization.people.groups.is_empty());
        }
        Ok(())
    }

    #[test]
    fn legacy_live_record_without_parent_token_fails_closed_until_normal_refresh()
    -> Result<(), String> {
        let (mut state_model, parent_json) = exported_live_parent_fixture()?;
        let exported = &state_model.state.snapshots[0].assets[0];
        let mut saved = serde_json::to_value(exported).map_err(|error| error.to_string())?;
        saved
            .as_object_mut()
            .ok_or("saved record")?
            .remove("immichParentRevision");
        let legacy: StoredAsset =
            serde_json::from_value(saved).map_err(|error| error.to_string())?;
        assert!(legacy.immich_parent_revision.is_none());
        assert_eq!(legacy.revision, exported.revision);
        state_model.state.snapshots[0].assets = vec![legacy];
        let core = Core::new_with(Suwop, state_model);
        let effect = core
            .process_event(Event::BrowseOrganizationPeople)
            .pop()
            .ok_or("legacy query")?;
        assert_parent_only_query(&effect)?;
        reply(&core, effect, vec![parent_json.clone()], Value::Null)?;
        assert!(core.view().organization.people.partial_coverage);
        assert!(core.view().organization.people.groups.is_empty());
        // A normal provider enumeration creates the token without reading hidden motion.
        let parent: Asset =
            serde_json::from_value(parent_json.clone()).map_err(|error| error.to_string())?;
        let mut refreshed = model()?;
        refreshed.state.snapshots[0].assets = vec![parent.record("fixture", None, None)];
        let fresh_core = Core::new_with(Suwop, refreshed);
        let effect = fresh_core
            .process_event(Event::BrowseOrganizationPeople)
            .pop()
            .ok_or("refreshed query")?;
        assert_parent_only_query(&effect)?;
        reply(&fresh_core, effect, vec![parent_json], Value::Null)?;
        assert_eq!(fresh_core.view().organization.people.groups.len(), 1);
        assert!(!fresh_core.view().organization.people.partial_coverage);
        Ok(())
    }

    #[test]
    fn legacy_upload_intent_ignores_only_derived_parent_token_not_full_evidence()
    -> Result<(), String> {
        let (model, _) = exported_live_parent_fixture()?;
        let session = model.session.as_ref().ok_or("session")?;
        let fresh = model.state.snapshots[0].assets[0].clone();
        let mut source_json = serde_json::to_value(&fresh).map_err(|error| error.to_string())?;
        source_json
            .as_object_mut()
            .ok_or("saved source")?
            .remove("immichParentRevision");
        let source: StoredAsset =
            serde_json::from_value(source_json).map_err(|error| error.to_string())?;
        assert!(source.immich_parent_revision.is_none());
        let intent = crate::immich::UploadIntent {
            scope: session.scope.clone(),
            token: "legacy-intent".into(),
            source,
            resource: fresh.resources[0].clone(),
            signature: crate::domain::FileSignature {
                sha256: "1".repeat(64),
                bytes: 12,
            },
            live_id: None,
        };
        let restored: crate::immich::UploadIntent = serde_json::from_value(
            serde_json::to_value(&intent).map_err(|error| error.to_string())?,
        )
        .map_err(|error| error.to_string())?;
        let file = crate::domain::TransferFile {
            resource: fresh.resources[0].clone(),
            signature: restored.signature.clone(),
            path: "generated-only".into(),
        };
        assert!(restored.matches(session, &file, &fresh, None));
        let mut changed = fresh.clone();
        changed.revision.push_str("changed");
        assert!(!restored.matches(session, &file, &changed, None));
        let mut changed = fresh;
        changed.resources[0].sha1 = Some("b".repeat(40));
        assert!(!restored.matches(session, &file, &changed, None));
        Ok(())
    }
}
