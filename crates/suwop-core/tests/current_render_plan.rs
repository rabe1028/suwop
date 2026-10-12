use serde_json::{Value, json};
use suwop_core::{
    domain::{AssetKey, Provider, StoredAsset},
    editing::{ImageEncodingFacts, PixelSize},
    sharing::{CurrentImageFacts, CurrentImageRenderPlan, CurrentImageRenderResult},
};

const ID: &str = "11111111-1111-4111-8111-111111111111";
fn source() -> StoredAsset {
    StoredAsset {
        key: AssetKey {
            provider: Provider::Immich,
            scope: "library".into(),
            asset_id: ID.into(),
        },
        name: "original.png".into(),
        revision: "original".into(),
        captured_at: Some(10.125),
        modified_at: None,
        latitude: Some(-33.5),
        longitude: Some(151.0),
        resources: vec![],
        is_favorite: false,
        is_offline: false,
        inventory_complete: true,
        deletion_blockers: vec![],
    }
}
fn encoding() -> ImageEncodingFacts {
    ImageEncodingFacts {
        raw_dimensions: PixelSize {
            width: 4,
            height: 3,
        },
        orientation: 1,
        has_color_space: true,
        has_alpha: true,
        hdr: false,
    }
}
fn edits() -> Value {
    json!({"assetId":ID,"edits":[
        {"id":"22222222-2222-4222-8222-222222222222","action":"crop","parameters":{"x":0,"y":0,"width":2,"height":1}},
        {"id":"33333333-3333-4333-8333-333333333333","action":"rotate","parameters":{"angle":90}}
    ]})
}

#[test]
fn current_render_plan_uses_latest_geometry_and_utc_metadata_without_mutating_source()
-> Result<(), String> {
    let source = source();
    let before = serde_json::to_value(&source).map_err(|e| e.to_string())?;
    let plan = CurrentImageRenderPlan::remote(&source, &encoding(), edits())?;
    assert_eq!(
        plan.transform.output_size(plan.dimensions)?,
        PixelSize {
            width: 1,
            height: 2
        }
    );
    assert_eq!(
        plan.metadata.date_time_original.as_deref(),
        Some("1970:01:01 00:00:10")
    );
    assert_eq!(plan.metadata.subsec_time_original.as_deref(), Some("125"));
    assert_eq!(plan.metadata.latitude, Some(-33.5));
    assert_eq!(plan.metadata.longitude, Some(151.0));
    assert_eq!(
        serde_json::to_value(&source).map_err(|e| e.to_string())?,
        before
    );
    Ok(())
}

#[test]
fn unsupported_unknown_or_oversized_render_inputs_are_rejected() {
    for fault in 0..6 {
        let mut input = encoding();
        let mut edits = edits();
        match fault {
            0 => input.hdr = true,
            1 => input.has_color_space = false,
            2 => input.orientation = 0,
            3 => {
                input.raw_dimensions = PixelSize {
                    width: 4001,
                    height: 4000,
                }
            }
            4 => edits["edits"] = json!([]),
            _ => edits["assetId"] = json!("44444444-4444-4444-8444-444444444444"),
        }
        assert!(CurrentImageRenderPlan::remote(&source(), &input, edits).is_err());
    }
}

#[test]
fn partial_nonfinite_or_out_of_range_metadata_never_reaches_the_encoder() {
    for fault in 0..6 {
        let mut source = source();
        match fault {
            0 => source.captured_at = Some(f64::NAN),
            1 => source.latitude = None,
            2 => source.latitude = Some(f64::INFINITY),
            3 => source.latitude = Some(91.0),
            4 => source.longitude = Some(181.0),
            _ => source.captured_at = Some(253_402_300_800.0),
        }
        assert!(CurrentImageRenderPlan::remote(&source, &encoding(), edits()).is_err());
    }
}

#[test]
fn rendered_dimensions_orientation_and_metadata_must_match_the_plan() -> Result<(), String> {
    let plan = CurrentImageRenderPlan::remote(&source(), &encoding(), edits())?;
    let result = CurrentImageRenderResult {
        image: CurrentImageFacts {
            content_type: "public.png".into(),
            width: 1,
            height: 2,
            orientation: 1,
            frames: 1,
        },
        metadata: plan.metadata.clone(),
    };
    plan.verify(&result)?;
    for fault in 0..6 {
        let mut wrong = result.clone();
        match fault {
            0 => wrong.image.width = 2,
            1 => wrong.image.orientation = 6,
            2 => wrong.image.content_type = "public.jpeg".into(),
            3 => wrong.metadata.date_time_original = None,
            4 => wrong.metadata.subsec_time_original = None,
            _ => wrong.metadata.latitude = Some(-33.6),
        }
        assert!(plan.verify(&wrong).is_err());
    }
    Ok(())
}
