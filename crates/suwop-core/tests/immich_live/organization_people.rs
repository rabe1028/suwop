//! Manual face associations on generated pixel fixtures; no recognition or personal data.
use super::*;
use crux_core::Core;
use suwop_core::{
    app::{Model, Suwop},
    organization::OrganizationDate,
};

pub(super) async fn exercise(
    ctx: &Context,
    session: &Session,
    ids: &[String],
) -> Result<(), String> {
    let first = ids.first().ok_or("missing generated fixture")?;
    let second = ids.get(1).ok_or("missing second generated fixture")?;
    let (first, protected) = setup(ctx, session, first, second).await?;
    let mut model = Model {
        ready: true,
        session: Some(session.clone()),
        organization_reference: Some(OrganizationDate {
            year: 2026,
            month: 10,
            day: 28,
            time_zone: "UTC".into(),
        }),
        ..Model::default()
    };
    model.protection.denied.insert(protected.key.clone());
    model.state.schema_version = suwop_core::immich_live_writes::CURRENT_SCHEMA_VERSION;
    model.state.snapshots.push(LibrarySnapshot {
        provider: Provider::Immich,
        scope: session.scope.clone(),
        assets: vec![first.clone(), protected],
        access: ScanAccess::Full,
        scanned_at: Some(1.0),
    });
    let core = Core::new_with(Suwop, model);
    let mut effects = core.process_event(Event::BrowseOrganizationPeople);
    let mut reads = 0;
    while let Some(effect) = effects.pop() {
        let Effect::Io(mut request) = effect;
        let ShellOperation::Http(http) = &request.operation else {
            return Err("people read produced non-HTTP effect".into());
        };
        assert_eq!(http.method, "POST");
        assert_eq!(http.url, format!("{}/search/metadata", session.endpoint));
        let body = http.body.as_ref().ok_or("missing people query")?;
        assert_eq!(body["withPeople"], true);
        assert_eq!(
            body["filter"]["or"],
            json!([{"id":{"eq":first.key.asset_id}}])
        );
        assert_eq!(
            http.ordinary_content_authorization
                .as_ref()
                .ok_or("missing read authority")?
                .source_keys,
            vec![first.key.clone()]
        );
        reads += 1;
        let response: HttpResponse =
            suwop_core::app::io(ctx, ShellOperation::Http(http.clone())).await?;
        let queried = response.body["assets"]["items"]
            .as_array()
            .and_then(|items| items.iter().find(|asset| asset["id"] == first.key.asset_id))
            .ok_or("Generated people search omitted the canonical source")?;
        let observed: suwop_core::immich::Asset = serde_json::from_value(queried.clone())
            .map_err(|_| "invalid queried generated asset")?;
        assert_eq!(
            observed.record(&session.scope, None, None).revision,
            first.revision,
            "Generated source must remain stable across the people read"
        );
        effects.extend(
            core.resolve(
                &mut request,
                ShellResponse {
                    value: Some(serde_json::to_value(response).map_err(|_| "people response")?),
                    error: None,
                },
            )
            .map_err(|_| "people effect resolve")?,
        );
    }
    assert!(reads > 0);
    let view = core.view();
    assert!(view.organization.people.loaded);
    assert!(view.organization.people.error.is_none());
    assert!(
        !view.organization.people.partial_coverage,
        "Generated people source must be observed without metadata drift"
    );
    assert_eq!(view.organization.people.groups.len(), 1);
    assert_eq!(
        view.organization.people.groups[0].name,
        "Generated visible person"
    );
    assert_eq!(view.organization.people.groups[0].members[0].key, first.key);
    assert_eq!(view.organization.people.groups[0].members.len(), 1);
    Ok(())
}

async fn setup(
    ctx: &Context,
    session: &Session,
    first: &str,
    second: &str,
) -> Result<(StoredAsset, StoredAsset), String> {
    let mut visible_person = String::new();
    for (name, hidden, id) in [
        ("Generated visible person", false, first),
        ("Generated hidden person", true, first),
        ("Generated protected-only person", false, second),
    ] {
        let person: Value = session
            .json(
                ctx,
                "people",
                "POST",
                Some(json!({"name":name,"isHidden":hidden})),
            )
            .await?;
        let person_id = person
            .get("id")
            .and_then(Value::as_str)
            .ok_or("missing fixture person")?;
        if !hidden && id == first {
            visible_person = person_id.into();
        }
        let _: Value = session.json(ctx,"faces","POST",Some(json!({"assetId":id,"personId":person_id,"imageWidth":1,"imageHeight":1,"x":0,"y":0,"width":1,"height":1}))).await?;
    }
    // Earlier generated metadata writes enqueue EXIF and sidecar work.
    // Drain those before capturing the immutable ordinary source evidence.
    super::wait_metadata_queues(ctx, session).await?;
    let canonical: Value = session
        .json(ctx, &format!("assets/{first}"), "GET", None)
        .await?;
    assert!(
        canonical["people"]
            .as_array()
            .is_some_and(
                |people| people.iter().any(|person| person["id"] == visible_person
                    && person["name"] == "Generated visible person"
                    && person["isHidden"] == false)
            ),
        "Generated visible person must be attached before capturing the source"
    );
    let first = serde_json::from_value::<suwop_core::immich::Asset>(canonical)
        .map_err(|_| "invalid canonical generated asset")?
        .record(&session.scope, None, None);
    let protected = session
        .asset(ctx, second)
        .await?
        .record(&session.scope, None, None);
    Ok((first, protected))
}
