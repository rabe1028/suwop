use serde_json::json;
use suwop_core::editing::{
    EditCommand, EditCommandKind, ImageEditDraft, ImageTransform, PixelCrop, PixelSize,
    read_immich_transform,
};

const SIZE: PixelSize = PixelSize {
    width: 6,
    height: 4,
};
const ID: &str = "11111111-1111-4111-8111-111111111111";
const EDIT1: &str = "22222222-2222-4222-8222-222222222222";
const EDIT2: &str = "33333333-3333-4333-8333-333333333333";
fn command(kind: EditCommandKind) -> EditCommand {
    EditCommand { kind, crop: None }
}
fn crop(x: u32, y: u32, width: u32, height: u32) -> PixelCrop {
    PixelCrop {
        x,
        y,
        width,
        height,
    }
}

#[test]
fn crop_windows_map_back_to_the_original_in_all_eight_orientations() -> Result<(), String> {
    // Hand-calculated original rectangles for the same 2x1 output window.
    let expected = [
        crop(0, 1, 2, 1),
        crop(1, 2, 1, 2),
        crop(4, 2, 2, 1),
        crop(4, 0, 1, 2),
        crop(4, 1, 2, 1),
        crop(1, 0, 1, 2),
        crop(0, 2, 2, 1),
        crop(4, 2, 1, 2),
    ];
    for (index, expected) in expected.into_iter().enumerate() {
        let transform = ImageTransform {
            crop: PixelCrop::full(SIZE),
            clockwise_quarter_turns: u8::try_from(index % 4).map_err(|e| e.to_string())?,
            flip_horizontal: index >= 4,
        };
        let changed = transform.crop_output(SIZE, crop(0, 1, 2, 1))?;
        assert_eq!(changed.crop, expected);
        assert_eq!(
            changed.output_size(SIZE)?,
            PixelSize {
                width: 2,
                height: 1
            }
        );
        assert_eq!(
            changed.clockwise_quarter_turns,
            transform.clockwise_quarter_turns
        );
        assert_eq!(changed.flip_horizontal, transform.flip_horizontal);
    }
    Ok(())
}

#[test]
fn repeated_crops_remain_in_original_coordinates_without_pixel_drift() -> Result<(), String> {
    let original = ImageTransform::original(SIZE)?;
    let first = original.crop_output(SIZE, crop(1, 1, 4, 2))?;
    let rotated = first.rotate_clockwise(SIZE)?;
    assert_eq!(
        rotated.output_size(SIZE)?,
        PixelSize {
            width: 2,
            height: 4
        }
    );
    let second = rotated.crop_output(SIZE, crop(0, 1, 1, 2))?;
    assert_eq!(second.crop, crop(2, 2, 2, 1));
    assert_eq!(
        second.output_size(SIZE)?,
        PixelSize {
            width: 1,
            height: 2
        }
    );
    let third = second.crop_output(SIZE, PixelCrop::full(second.output_size(SIZE)?))?;
    assert_eq!(third, second);
    Ok(())
}

#[test]
fn ordered_rotation_and_mirrors_have_distinct_but_canonical_results() -> Result<(), String> {
    let original = ImageTransform::original(SIZE)?;
    let after_mirror = original.mirror_horizontal(SIZE)?.rotate_clockwise(SIZE)?;
    let after_rotation = original.rotate_clockwise(SIZE)?.mirror_horizontal(SIZE)?;
    assert_eq!(after_mirror.clockwise_quarter_turns, 3);
    assert_eq!(after_rotation.clockwise_quarter_turns, 1);
    assert!(after_mirror.flip_horizontal && after_rotation.flip_horizontal);
    let mut complete_turn = original;
    for _ in 0..4 {
        complete_turn = complete_turn.rotate_clockwise(SIZE)?;
    }
    assert_eq!(complete_turn, original);
    assert_eq!(
        original.mirror_horizontal(SIZE)?.mirror_horizontal(SIZE)?,
        original
    );
    assert_eq!(
        original.mirror_vertical(SIZE)?.mirror_vertical(SIZE)?,
        original
    );
    let both = original.mirror_horizontal(SIZE)?.mirror_vertical(SIZE)?;
    assert_eq!(both.clockwise_quarter_turns, 2);
    assert!(!both.flip_horizontal);
    Ok(())
}

#[test]
fn native_bitmap_budget_is_enforced_on_input_before_any_crop() -> Result<(), String> {
    let supported = PixelSize {
        width: 4_000,
        height: 4_000,
    };
    supported.validate()?;
    for size in [
        PixelSize {
            width: 4_001,
            height: 4_000,
        },
        PixelSize {
            width: 6_000,
            height: 4_000,
        },
        PixelSize {
            width: 8_000,
            height: 6_000,
        },
        PixelSize {
            width: 20_000,
            height: 10_000,
        },
    ] {
        assert!(size.validate().is_err());
        assert!(crop(0, 0, 1, 1).validate(size).is_err());
    }
    Ok(())
}

#[test]
fn invalid_or_overflowing_geometry_is_rejected_before_rendering() -> Result<(), String> {
    for size in [
        PixelSize {
            width: 0,
            height: 1,
        },
        PixelSize {
            width: 1,
            height: 0,
        },
        PixelSize {
            width: u32::MAX,
            height: u32::MAX,
        },
        PixelSize {
            width: 20_000,
            height: 20_000,
        },
    ] {
        assert!(ImageTransform::original(size).is_err());
    }
    let original = ImageTransform::original(SIZE)?;
    for window in [
        crop(0, 0, 0, 1),
        crop(0, 0, 1, 0),
        crop(5, 0, 2, 1),
        crop(0, 3, 1, 2),
        crop(u32::MAX, 0, 2, 1),
        crop(0, u32::MAX, 1, 2),
    ] {
        assert!(original.crop_output(SIZE, window).is_err());
    }
    let mut malformed = original;
    malformed.clockwise_quarter_turns = 4;
    assert!(malformed.immich_actions(SIZE).is_err());
    assert!(malformed.output_size(SIZE).is_err());
    assert!(
        serde_json::from_value::<PixelCrop>(json!({"x":-1,"y":0,"width":1,"height":1})).is_err()
    );
    assert!(
        serde_json::from_value::<PixelCrop>(json!({"x":0,"y":0,"width":1,"height":1,"other":true}))
            .is_err()
    );
    Ok(())
}

#[test]
fn canonical_remote_actions_crop_first_and_do_not_repeat_rotations_or_mirrors() -> Result<(), String>
{
    let original = ImageTransform::original(SIZE)?;
    assert!(original.immich_actions(SIZE)?.is_empty());
    let changed = original
        .crop_output(SIZE, crop(1, 1, 4, 2))?
        .mirror_vertical(SIZE)?
        .rotate_clockwise(SIZE)?;
    assert_eq!(
        changed.immich_actions(SIZE)?,
        vec![
            json!({"action":"crop","parameters":{"x":1,"y":1,"width":4,"height":2}}),
            json!({"action":"rotate","parameters":{"angle":90}}),
            json!({"action":"mirror","parameters":{"axis":"horizontal"}}),
        ]
    );
    Ok(())
}

#[test]
fn draft_undo_redo_and_reset_preserve_the_existing_edit_and_discard_stale_redo()
-> Result<(), String> {
    let original = ImageTransform::original(SIZE)?;
    let existing = original
        .crop_output(SIZE, crop(1, 1, 4, 2))?
        .rotate_clockwise(SIZE)?;
    let draft = ImageEditDraft::new(SIZE, existing)?;
    assert!(!draft.can_save()?);
    assert!(draft.apply(command(EditCommandKind::Undo)).is_err());
    let rotated = draft.apply(command(EditCommandKind::RotateClockwise))?;
    let mirrored = rotated.apply(command(EditCommandKind::MirrorHorizontal))?;
    let undone = mirrored.apply(command(EditCommandKind::Undo))?;
    assert_eq!(undone.current()?, rotated.current()?);
    assert_eq!(undone.apply(command(EditCommandKind::Redo))?, mirrored);
    let alternative = undone.apply(command(EditCommandKind::MirrorVertical))?;
    assert!(alternative.apply(command(EditCommandKind::Redo)).is_err());
    let reset = alternative.apply(command(EditCommandKind::ResetDraft))?;
    assert_eq!(reset.current()?, existing);
    assert!(!reset.can_save()?);
    assert_eq!(
        reset.apply(command(EditCommandKind::Undo))?.current()?,
        alternative.current()?
    );
    assert_eq!(draft.current()?, existing);
    Ok(())
}

#[test]
fn malformed_history_or_commands_cannot_modify_a_valid_draft() -> Result<(), String> {
    let draft = ImageEditDraft::new(SIZE, ImageTransform::original(SIZE)?)?;
    let mut malformed = draft.clone();
    malformed.cursor = usize::MAX;
    assert!(
        malformed
            .apply(command(EditCommandKind::RotateClockwise))
            .is_err()
    );
    malformed = draft.clone();
    malformed.history.clear();
    assert!(malformed.current().is_err());
    malformed = draft.clone();
    malformed.history[0].flip_horizontal = true;
    assert!(malformed.can_save().is_err());
    malformed = draft.clone();
    malformed.history.resize(513, draft.initial);
    assert!(malformed.validate().is_err());
    assert!(draft.apply(command(EditCommandKind::Crop)).is_err());
    assert!(
        draft
            .apply(EditCommand {
                kind: EditCommandKind::RotateClockwise,
                crop: Some(crop(0, 0, 1, 1))
            })
            .is_err()
    );
    assert_eq!(draft.history.len(), 1);
    assert_eq!(draft.current()?, draft.initial);
    Ok(())
}

#[test]
fn existing_remote_edit_order_is_preserved_when_normalizing_geometry() -> Result<(), String> {
    let first = json!({"id":EDIT1,"action":"mirror","parameters":{"axis":"horizontal"}});
    let second = json!({"id":EDIT2,"action":"rotate","parameters":{"angle":90}});
    let result = read_immich_transform(SIZE, ID, json!({"assetId":ID,"edits":[first,second]}))?;
    assert_eq!(result.clockwise_quarter_turns, 3);
    assert!(result.flip_horizontal);
    assert_eq!(
        result.immich_actions(SIZE)?,
        vec![
            json!({"action":"rotate","parameters":{"angle":270}}),
            json!({"action":"mirror","parameters":{"axis":"horizontal"}}),
        ]
    );
    assert_eq!(
        read_immich_transform(SIZE, ID, json!({"assetId":ID,"edits":[]}))?,
        ImageTransform::original(SIZE)?
    );
    Ok(())
}

#[test]
fn malformed_remote_edits_are_rejected_instead_of_being_silently_discarded() {
    let valid = json!({"id":EDIT1,"action":"rotate","parameters":{"angle":90}});
    let invalid = [
        json!({"assetId":EDIT1,"edits":[]}),
        json!({"assetId":ID}),
        json!({"assetId":ID,"edits":[valid.clone(),valid]}),
        json!({"assetId":ID,"edits":[
            {"id":EDIT1,"action":"mirror","parameters":{"axis":"horizontal"}},
            {"id":EDIT2,"action":"mirror","parameters":{"axis":"horizontal"}}
        ]}),
        json!({"assetId":ID,"edits":[
            {"id":EDIT1,"action":"rotate","parameters":{"angle":90}},
            {"id":EDIT2,"action":"crop","parameters":{"x":0,"y":0,"width":2,"height":2}}
        ]}),
        json!({"assetId":ID,"edits":[{"id":EDIT1,"action":"rotate","parameters":{"angle":45}}]}),
        json!({"assetId":ID,"edits":[{"id":EDIT1,"action":"crop","parameters":{"x":5,"y":0,"width":2,"height":1}}]}),
        json!({"assetId":ID,"edits":[{"id":EDIT1,"action":"filter","parameters":{}}]}),
        json!({"assetId":ID,"edits":[{"id":EDIT1,"action":"mirror","parameters":{"axis":"diagonal"}}]}),
        json!({"assetId":ID,"edits":[{"id":EDIT1,"action":"rotate","parameters":{"angle":90,"crop":true}}]}),
        json!({"assetId":ID,"edits":[{"id":"invalid","action":"rotate","parameters":{"angle":90}}]}),
    ];
    for response in invalid {
        assert!(read_immich_transform(SIZE, ID, response).is_err());
    }
}
