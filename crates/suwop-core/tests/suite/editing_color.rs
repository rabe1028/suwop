use base64::{Engine, engine::general_purpose::STANDARD};
use serde_json::json;
use suwop_core::editing::{
    AdjustmentBase, AppleAdjustment, ColorAdjustments, EditCommand, EditCommandKind,
    GeometryAdjustment, ImageColorFilter, ImageEditDraft, ImageTransform, PixelSize,
    decode_original_adjustment,
};

const SIZE: PixelSize = PixelSize {
    width: 6,
    height: 4,
};

fn set_color(color: ColorAdjustments) -> EditCommand {
    EditCommand {
        kind: EditCommandKind::SetColor,
        crop: None,
        color: Some(color),
    }
}

#[test]
fn color_limits_and_native_mapping_are_owned_by_rust() -> Result<(), String> {
    let neutral = ColorAdjustments::default().native_plan()?;
    assert_eq!(
        (
            neutral.exposure_ev,
            neutral.brightness,
            neutral.contrast,
            neutral.saturation
        ),
        (0.0, 0.0, 1.0, 1.0)
    );
    for edge in [-1_i16, 1] {
        let color = ColorAdjustments {
            exposure: edge * 200,
            brightness: edge * 100,
            contrast: edge * 100,
            saturation: edge * 100,
            filter: ImageColorFilter::Sepia,
        };
        let plan = color.native_plan()?;
        assert!((plan.exposure_ev - f64::from(edge) * 2.0).abs() <= f64::EPSILON);
        assert!((plan.brightness - f64::from(edge)).abs() <= f64::EPSILON);
        assert!((plan.contrast - (1.0 + f64::from(edge))).abs() <= f64::EPSILON);
        assert!((plan.saturation - (1.0 + f64::from(edge))).abs() <= f64::EPSILON);
        for invalid in [
            ColorAdjustments {
                exposure: edge * 201,
                ..color
            },
            ColorAdjustments {
                brightness: edge * 101,
                ..color
            },
            ColorAdjustments {
                contrast: edge * 101,
                ..color
            },
            ColorAdjustments {
                saturation: edge * 101,
                ..color
            },
        ] {
            assert!(invalid.native_plan().is_err());
        }
    }
    Ok(())
}

#[test]
fn color_and_geometry_share_undo_redo_and_reset_without_repeated_noop_steps() -> Result<(), String>
{
    let initial = ImageTransform::original(SIZE)?;
    let color = ColorAdjustments {
        exposure: 75,
        brightness: 10,
        saturation: -40,
        filter: ImageColorFilter::Noir,
        ..ColorAdjustments::default()
    };
    let draft = ImageEditDraft::new(SIZE, initial)?.apply(set_color(color))?;
    assert!(draft.can_save()?);
    assert_eq!(draft.current()?.color, color);
    assert_eq!(draft.apply(set_color(color))?.history.len(), 2);
    let rotated = draft.apply(EditCommand {
        kind: EditCommandKind::RotateClockwise,
        crop: None,
        color: None,
    })?;
    assert_eq!(rotated.current()?.color, color);
    let undone = rotated.apply(EditCommand {
        kind: EditCommandKind::Undo,
        crop: None,
        color: None,
    })?;
    assert_eq!(undone.current()?, draft.current()?);
    let original = undone.apply(EditCommand {
        kind: EditCommandKind::Undo,
        crop: None,
        color: None,
    })?;
    assert_eq!(original.current()?, initial);
    assert!(!original.can_save()?);
    let redo = original.apply(EditCommand {
        kind: EditCommandKind::Redo,
        crop: None,
        color: None,
    })?;
    assert_eq!(redo.current()?.color, color);
    let changed = redo.apply(set_color(ColorAdjustments {
        brightness: 20,
        ..color
    }))?;
    assert!(!changed.view()?.can_redo);
    let reset = changed.apply(EditCommand {
        kind: EditCommandKind::ResetDraft,
        crop: None,
        color: None,
    })?;
    assert_eq!(reset.current()?, initial);
    assert!(!reset.can_save()?);
    assert!(
        draft
            .apply(EditCommand {
                kind: EditCommandKind::Undo,
                crop: None,
                color: Some(color)
            })
            .is_err()
    );
    assert!(
        draft
            .apply(EditCommand {
                kind: EditCommandKind::SetColor,
                crop: None,
                color: None
            })
            .is_err()
    );
    assert!(
        draft
            .apply(set_color(ColorAdjustments {
                exposure: 201,
                ..color
            }))
            .is_err()
    );
    Ok(())
}

#[test]
fn version_two_round_trips_color_and_version_one_remains_neutral() -> Result<(), String> {
    let mut transform = ImageTransform::original(SIZE)?;
    transform.color = ColorAdjustments {
        exposure: -40,
        contrast: 25,
        filter: ImageColorFilter::Mono,
        ..ColorAdjustments::default()
    };
    let adjustment = GeometryAdjustment {
        dimensions: SIZE,
        base: AdjustmentBase::Original,
        transform,
    };
    let encoded = adjustment.encode()?;
    assert_eq!(encoded.format_version, "2");
    assert_eq!(
        decode_original_adjustment(&encoded),
        Some(adjustment.clone())
    );
    let mut legacy = encoded.clone();
    legacy.format_version = "1".into();
    assert!(decode_original_adjustment(&legacy).is_none());
    let old = json!({"dimensions":{"width":6,"height":4},"base":"original","transform":{"crop":{"x":0,"y":0,"width":6,"height":4},"clockwiseQuarterTurns":1,"flipHorizontal":true}});
    legacy.data = STANDARD.encode(serde_json::to_vec(&old).map_err(|error| error.to_string())?);
    let decoded = decode_original_adjustment(&legacy).ok_or("legacy adjustment missing")?;
    assert_eq!(decoded.transform.color, ColorAdjustments::default());
    assert_eq!(decoded.transform.clockwise_quarter_turns, 1);
    assert!(decoded.transform.flip_horizontal);
    for invalid in [
        json!({"exposure":0.5,"brightness":0,"contrast":0,"saturation":0,"filter":"original"}),
        json!({"exposure":0,"brightness":0,"contrast":0,"saturation":0,"filter":"unknown"}),
    ] {
        let mut value = serde_json::to_value(&adjustment).map_err(|error| error.to_string())?;
        value["transform"]["color"] = invalid;
        let payload = AppleAdjustment {
            data: STANDARD.encode(serde_json::to_vec(&value).map_err(|error| error.to_string())?),
            ..encoded.clone()
        };
        assert!(decode_original_adjustment(&payload).is_none());
    }
    assert!(transform.immich_actions(SIZE).is_err());
    Ok(())
}
