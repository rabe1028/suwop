use suwop_core::editing::{
    AdjustmentBase, ColorAdjustments, EditClipboard, EditCopyOptions, ImageColorFilter,
    ImageEditDraft, ImageEditPresentation, ImageTransform, PixelCrop, PixelSize, RenderFormat,
};

fn presentation(size: PixelSize) -> Result<ImageEditPresentation, String> {
    Ok(ImageEditPresentation {
        name: "source.jpg".into(),
        path: "/tmp/source.jpg".into(),
        orientation: 1,
        draft: ImageEditDraft::new(size, ImageTransform::original(size)?)?,
        base: AdjustmentBase::Original,
        output_format: RenderFormat::Jpeg,
    })
}
fn clipboard() -> Result<EditClipboard, String> {
    let mut source = presentation(PixelSize {
        width: 100,
        height: 80,
    })?;
    let mut transform = source.draft.initial;
    transform.crop = PixelCrop {
        x: 13,
        y: 7,
        width: 62,
        height: 43,
    };
    transform.clockwise_quarter_turns = 1;
    transform.flip_horizontal = true;
    transform.color = ColorAdjustments {
        exposure: 120,
        brightness: -5,
        contrast: 20,
        saturation: -35,
        filter: ImageColorFilter::Sepia,
    };
    source.draft = ImageEditDraft::new(source.draft.dimensions, transform)?;
    EditClipboard::capture(
        &source,
        EditCopyOptions {
            adjustments: true,
            filter: true,
            geometry: true,
        },
    )
}

#[test]
fn selective_paste_keeps_unselected_fields_and_scales_crop_with_outward_rounding()
-> Result<(), String> {
    let mut target = presentation(PixelSize {
        width: 53,
        height: 41,
    })?;
    let mut initial = target.draft.initial;
    initial.color.filter = ImageColorFilter::Noir;
    initial.color.exposure = -50;
    initial.clockwise_quarter_turns = 2;
    target.draft = ImageEditDraft::new(target.draft.dimensions, initial)?;
    for mask in 1..8 {
        let mut copied = clipboard()?;
        copied.options = EditCopyOptions {
            adjustments: mask & 1 != 0,
            filter: mask & 2 != 0,
            geometry: mask & 4 != 0,
        };
        let plan = copied.plan(&target)?.ok_or("missing plan")?;
        assert_eq!(
            plan.transform.color.exposure,
            if copied.options.adjustments { 120 } else { -50 }
        );
        assert_eq!(
            plan.transform.color.filter,
            if copied.options.filter {
                ImageColorFilter::Sepia
            } else {
                ImageColorFilter::Noir
            }
        );
        assert_eq!(
            plan.transform.clockwise_quarter_turns,
            if copied.options.geometry { 1 } else { 2 }
        );
        assert_eq!(
            plan.transform.crop,
            if copied.options.geometry {
                PixelCrop {
                    x: 6,
                    y: 3,
                    width: 34,
                    height: 23,
                }
            } else {
                initial.crop
            }
        );
        assert_eq!(plan.transform.flip_horizontal, copied.options.geometry);
        plan.transform.validate(target.draft.dimensions)?;
    }
    Ok(())
}

#[test]
fn unchanged_paste_has_no_plan_and_rejects_unknown_bases_empty_choices_and_corrupt_recipe()
-> Result<(), String> {
    let copied = clipboard()?;
    let mut target = presentation(copied.dimensions)?;
    target.draft = ImageEditDraft::new(copied.dimensions, copied.transform)?;
    assert!(copied.plan(&target)?.is_none());
    target.base = AdjustmentBase::Rendered;
    assert!(copied.plan(&target).is_err());
    assert!(EditClipboard::capture(&target, copied.options).is_err());
    target.base = AdjustmentBase::Original;
    let mut invalid = copied.clone();
    invalid.options = EditCopyOptions {
        adjustments: false,
        filter: false,
        geometry: false,
    };
    assert!(invalid.plan(&target).is_err());
    invalid = copied.clone();
    invalid.transform.color.exposure = 201;
    assert!(invalid.plan(&target).is_err());
    let neutral = presentation(copied.dimensions)?;
    assert!(EditClipboard::capture(&neutral, copied.options).is_err());
    // Small targets and extreme aspect ratios never create zero-sized crops.
    for size in [
        PixelSize {
            width: 1,
            height: 1,
        },
        PixelSize {
            width: 1,
            height: 131_072,
        },
    ] {
        let target = presentation(size)?;
        copied
            .plan(&target)?
            .ok_or("missing scaled plan")?
            .transform
            .validate(size)?;
    }
    Ok(())
}
