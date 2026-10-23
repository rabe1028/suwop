use base64::{Engine, engine::general_purpose::STANDARD};
use suwop_core::{
    domain::{AssetKey, PhotoResource, Provider, ResourceRole, StoredAsset},
    editing::{
        AdjustmentBase, AppleEditInput, EditCommand, EditCommandKind, GeometryAdjustment,
        ImageEncodingFacts, ImageTransform, PixelCrop, PixelSize, RenderFormat,
        decode_original_adjustment, prepare_apple_edit,
    },
};

const SIZE: PixelSize = PixelSize {
    width: 6,
    height: 4,
};
const TOKEN: &str = "11111111-1111-4111-8111-111111111111";
const DIRECTORY: &str = "/tmp/suwop-test";
fn source() -> StoredAsset {
    StoredAsset {
        immich_visibility: None,
        immich_stack: suwop_core::domain::ImmichStackState::Unknown,
        immich_stack_membership: None,
        apple_visibility: suwop_core::domain::AppleVisibility::Visible,
        key: AssetKey {
            provider: Provider::Apple,
            scope: "apple".into(),
            asset_id: "photo".into(),
        },
        name: "photo.jpg".into(),
        captured_at: Some(10.0),
        modified_at: Some(10.0),
        revision: "before".into(),
        is_favorite: false,
        latitude: None,
        longitude: None,
        inventory_complete: true,
        is_offline: false,
        deletion_blockers: vec![],
        resources: vec![PhotoResource {
            id: "0:1".into(),
            name: "photo.jpg".into(),
            role: ResourceRole::Image,
            sha1: Some("1".repeat(40)),
            bytes: Some(12),
        }],
    }
}
fn input() -> AppleEditInput {
    let mut fresh = source();
    fresh.resources[0].sha1 = None;
    fresh.resources[0].bytes = None;
    AppleEditInput {
        asset: fresh,
        token: TOKEN.into(),
        path: format!("{DIRECTORY}/input.jpg"),
        image: ImageEncodingFacts {
            raw_dimensions: PixelSize {
                width: 4,
                height: 6,
            },
            orientation: 6,
            has_color_space: true,
            has_alpha: false,
            hdr: false,
        },
        can_edit: true,
        has_adjustments: false,
        adjustment: None,
        supported_formats: vec!["public.jpeg".into(), "public.heic".into()],
        default_format: Some("public.heic".into()),
    }
}
fn rotate() -> EditCommand {
    EditCommand {
        kind: EditCommandKind::RotateClockwise,
        crop: None,
        color: None,
    }
}

#[test]
fn only_known_original_adjustments_can_be_rendered_from_originals() -> Result<(), String> {
    let adjustment = GeometryAdjustment {
        dimensions: SIZE,
        base: AdjustmentBase::Original,
        transform: ImageTransform::original(SIZE)?.rotate_clockwise(SIZE)?,
    };
    let payload = adjustment.encode()?;
    assert_eq!(
        decode_original_adjustment(&payload),
        Some(adjustment.clone())
    );
    let rendered = GeometryAdjustment {
        base: AdjustmentBase::Rendered,
        ..adjustment.clone()
    };
    assert!(decode_original_adjustment(&rendered.encode()?).is_none());
    for (identifier, version, data) in [
        ("another.app", "1", payload.data.clone()),
        (
            payload.format_identifier.as_str(),
            "3",
            payload.data.clone(),
        ),
        (
            payload.format_identifier.as_str(),
            "1",
            "invalid-base64".into(),
        ),
        (
            payload.format_identifier.as_str(),
            "1",
            STANDARD.encode(b"{invalid"),
        ),
        (payload.format_identifier.as_str(), "1", "a".repeat(32_769)),
    ] {
        let mut invalid = payload.clone();
        invalid.format_identifier = identifier.into();
        invalid.format_version = version.into();
        invalid.data = data;
        assert!(decode_original_adjustment(&invalid).is_none());
    }
    let invalid = GeometryAdjustment {
        transform: ImageTransform {
            crop: PixelCrop {
                x: 6,
                y: 0,
                width: 1,
                height: 1,
            },
            ..adjustment.transform
        },
        ..adjustment
    };
    assert!(invalid.encode().is_err());
    Ok(())
}

#[test]
fn native_edit_preserves_orientation_and_existing_geometry_and_uses_supported_default_format()
-> Result<(), String> {
    let mut input = input();
    let transform = ImageTransform {
        crop: PixelCrop {
            x: 1,
            y: 1,
            width: 4,
            height: 2,
        },
        clockwise_quarter_turns: 1,
        flip_horizontal: true,
        color: suwop_core::editing::ColorAdjustments::default(),
    };
    let adjustment = GeometryAdjustment {
        dimensions: SIZE,
        base: AdjustmentBase::Original,
        transform,
    };
    input.has_adjustments = true;
    input.adjustment = Some(adjustment.encode()?);
    let prepared = prepare_apple_edit(&source(), &input, DIRECTORY)?;
    assert_eq!(prepared.draft.dimensions, SIZE);
    assert_eq!(prepared.draft.initial, transform);
    assert_eq!(prepared.base, AdjustmentBase::Original);
    assert_eq!(prepared.output_format, RenderFormat::Heic);
    assert!(prepared.save_plan(&prepared.draft).is_err());
    let changed = prepared.draft.apply(rotate())?;
    let plan = prepared.save_plan(&changed)?;
    assert_eq!(plan.orientation, 6);
    assert_eq!(plan.transform.crop, transform.crop);
    assert_eq!(plan.transform.clockwise_quarter_turns, 0);
    assert!(plan.transform.flip_horizontal);
    let decoded =
        decode_original_adjustment(&plan.adjustment).ok_or("saved geometry unreadable")?;
    assert_eq!(decoded.transform, plan.transform);
    assert_eq!(decoded.dimensions, SIZE);
    let mut tampered = changed.clone();
    tampered.dimensions = PixelSize {
        width: 4,
        height: 6,
    };
    assert!(prepared.save_plan(&tampered).is_err());
    tampered = changed;
    tampered.initial.flip_horizontal = !tampered.initial.flip_horizontal;
    assert!(prepared.save_plan(&tampered).is_err());
    Ok(())
}

#[test]
fn a_foreign_rendered_base_is_never_claimed_to_be_reconstructible_from_originals()
-> Result<(), String> {
    let mut input = input();
    input.has_adjustments = true;
    // PhotoKit has rendered the unknown previous adjustments into this input.
    input.adjustment = None;
    let prepared = prepare_apple_edit(&source(), &input, DIRECTORY)?;
    assert_eq!(prepared.base, AdjustmentBase::Rendered);
    assert_eq!(prepared.draft.initial, ImageTransform::original(SIZE)?);
    let plan = prepared.save_plan(&prepared.draft.apply(rotate())?)?;
    assert!(decode_original_adjustment(&plan.adjustment).is_none());
    Ok(())
}

#[test]
fn changed_source_unsupported_encoding_and_escaping_paths_never_prepare_a_native_save()
-> Result<(), String> {
    let valid = input();
    let mut invalid = Vec::new();
    let mut value = valid.clone();
    value.asset.revision = "changed".into();
    invalid.push(value);
    let mut value = valid.clone();
    value.asset.key.scope = "other".into();
    invalid.push(value);
    let mut value = valid.clone();
    value.asset.resources[0].name = "other.jpg".into();
    invalid.push(value);
    let mut value = valid.clone();
    value.asset.captured_at = Some(20.0);
    invalid.push(value);
    let mut value = valid.clone();
    value.asset.modified_at = Some(20.0);
    invalid.push(value);
    let mut value = valid.clone();
    value.asset.is_favorite = true;
    invalid.push(value);
    let mut value = valid.clone();
    value.asset.latitude = Some(1.0);
    invalid.push(value);
    let mut value = valid.clone();
    value.asset.is_offline = true;
    invalid.push(value);
    let mut value = valid.clone();
    value.asset.inventory_complete = false;
    invalid.push(value);
    let mut value = valid.clone();
    value.can_edit = false;
    invalid.push(value);
    let mut value = valid.clone();
    value.token = "invalid".into();
    invalid.push(value);
    let mut value = valid.clone();
    value.path = "/tmp/outside.jpg".into();
    invalid.push(value);
    let mut value = valid.clone();
    value.path = format!("{DIRECTORY}/../outside.jpg");
    invalid.push(value);
    let mut value = valid.clone();
    value.image.hdr = true;
    invalid.push(value);
    let mut value = valid.clone();
    value.image.has_alpha = true;
    invalid.push(value);
    let mut value = valid.clone();
    value.image.has_color_space = false;
    invalid.push(value);
    let mut value = valid.clone();
    value.supported_formats = vec!["unknown".into()];
    invalid.push(value);
    let mut value = valid.clone();
    value.image.orientation = 0;
    invalid.push(value);
    let mut value = valid.clone();
    value.image.raw_dimensions.width = 0;
    invalid.push(value);
    let mut value = valid.clone();
    value.adjustment = Some(
        GeometryAdjustment {
            dimensions: SIZE,
            base: AdjustmentBase::Original,
            transform: ImageTransform::original(SIZE)?,
        }
        .encode()?,
    );
    invalid.push(value); // An adjustment without the native adjustment-presence fact.
    for value in invalid {
        assert!(prepare_apple_edit(&source(), &value, DIRECTORY).is_err());
    }
    let mut video = source();
    video.resources[0].role = ResourceRole::LiveVideo;
    let mut value = valid.clone();
    value.asset = video.clone();
    assert!(prepare_apple_edit(&video, &value, DIRECTORY).is_err());
    let mut remote = source();
    remote.key.provider = Provider::Immich;
    let mut value = valid;
    value.asset = remote.clone();
    assert!(prepare_apple_edit(&remote, &value, DIRECTORY).is_err());
    Ok(())
}
