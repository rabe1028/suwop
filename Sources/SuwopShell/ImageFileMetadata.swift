#if canImport(ImageIO)
    import Foundation
    import ImageIO

    enum ImageFileMetadata {
        static func properties(_ metadata: CurrentImageMetadata) -> [CFString: Any] {
            var result: [CFString: Any] = [kCGImagePropertyOrientation: 1]
            if let date = metadata.dateTimeOriginal {
                var exif: [CFString: Any] = [
                    kCGImagePropertyExifDateTimeOriginal: date,
                    kCGImagePropertyExifOffsetTimeOriginal: "+00:00",
                ]
                if let fraction = metadata.subsecTimeOriginal {
                    exif[kCGImagePropertyExifSubsecTimeOriginal] = fraction
                }
                result[kCGImagePropertyExifDictionary] = exif
            }
            if let latitude = metadata.latitude, let longitude = metadata.longitude {
                result[kCGImagePropertyGPSDictionary] = [
                    kCGImagePropertyGPSLatitude: abs(latitude),
                    kCGImagePropertyGPSLatitudeRef: latitude < 0 ? "S" : "N",
                    kCGImagePropertyGPSLongitude: abs(longitude),
                    kCGImagePropertyGPSLongitudeRef: longitude < 0 ? "W" : "E",
                ] as [CFString: Any]
            }
            return result
        }

        static func read(_ path: String) throws -> CurrentImageMetadata {
            guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
                  let fields = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            else { throw SuwopError("書き出した画像のメタデータを読み込めません。") }
            let exif = fields[kCGImagePropertyExifDictionary] as? [CFString: Any]
            let date = exif?[kCGImagePropertyExifDateTimeOriginal] as? String
            if date != nil, exif?[kCGImagePropertyExifOffsetTimeOriginal] as? String != "+00:00" {
                throw SuwopError("書き出した撮影日時のタイムゾーンを確認できません。")
            }
            let gps = fields[kCGImagePropertyGPSDictionary] as? [CFString: Any]
            return CurrentImageMetadata(
                dateTimeOriginal: date,
                latitude: coordinate(
                    gps,
                    value: kCGImagePropertyGPSLatitude,
                    ref: kCGImagePropertyGPSLatitudeRef,
                    positive: "N",
                    negative: "S"
                ),
                longitude: coordinate(
                    gps,
                    value: kCGImagePropertyGPSLongitude,
                    ref: kCGImagePropertyGPSLongitudeRef,
                    positive: "E",
                    negative: "W"
                ),
                subsecTimeOriginal: exif?[kCGImagePropertyExifSubsecTimeOriginal] as? String
            )
        }

        private static func coordinate(
            _ gps: [CFString: Any]?, value: CFString, ref: CFString, positive: String, negative: String
        ) -> Double? {
            guard let number = (gps?[value] as? NSNumber)?.doubleValue,
                  let direction = gps?[ref] as? String
            else { return nil }
            if direction == positive {
                return number
            }
            if direction == negative {
                return -number
            }
            return nil
        }
    }
#endif
