# Capture date fixtures

Both PNGs contain the same opaque 4×3 RGB pixels and the EXIF capture instant
`2020:01:02 03:04:05.125+09:00` (`1577901845.125` Unix seconds). The control has an
additional Artist tag so Immich does not deduplicate it with the adjusted case.
They are synthetic and contain no personal photo or location information.

Reproduce with ExifTool (not required by the test runtime): decode this PNG into
`adjusted-date.png`, then run the commands below.

```text
iVBORw0KGgoAAAANSUhEUgAAAAQAAAADCAIAAAA7ljmRAAAAFElEQVR4nGP4z8DAAMb//0MZ2DgAGRwO8lIWG74AAAAASUVORK5CYII=
```

```sh
exiftool -overwrite_original -EXIF:DateTimeOriginal='2020:01:02 03:04:05' \
  -EXIF:OffsetTimeOriginal='+09:00' -EXIF:SubSecTimeOriginal='125' adjusted-date.png
cp adjusted-date.png control-date.png
exiftool -overwrite_original -EXIF:Artist='Suwop date control fixture' control-date.png
exiftool -validate -warning -s -SubSecDateTimeOriginal adjusted-date.png control-date.png
```

ExifTool validated both PNGs. The isolated Immich test must independently verify
the embedded instant on the control, the different library adjustment on a new
copy, the original bytes after transfer, and metadata preservation on duplicate
uploads. A PNG without embedded EXIF cannot prove the adjustment takes precedence.
