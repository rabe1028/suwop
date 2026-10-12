#if canImport(CoreImage)
    import CoreImage
    import CoreImage.CIFilterBuiltins

    enum NativeColorRenderer {
        static func apply(_ image: CIImage, color: ColorAdjustments) throws -> CIImage {
            let plan = try CoreBridge.utility(12, input: .from(color)).decode(NativeColorPlan.self)
            var output = image
            if plan.exposureEv != 0 {
                let filter = CIFilter.exposureAdjust()
                filter.inputImage = output
                filter.ev = Float(plan.exposureEv)
                output = try result(filter)
            }
            if plan.brightness != 0 || plan.contrast != 1 || plan.saturation != 1 {
                let filter = CIFilter.colorControls()
                filter.inputImage = output
                filter.brightness = Float(plan.brightness)
                filter.contrast = Float(plan.contrast)
                filter.saturation = Float(plan.saturation)
                output = try result(filter)
            }
            switch plan.filter {
            case .original: break
            case .mono:
                let filter = CIFilter.photoEffectMono()
                filter.inputImage = output
                output = try result(filter)
            case .noir:
                let filter = CIFilter.photoEffectNoir()
                filter.inputImage = output
                output = try result(filter)
            case .sepia:
                let filter = CIFilter.sepiaTone()
                filter.inputImage = output
                filter.intensity = 1
                output = try result(filter)
            }
            return output.cropped(to: image.extent)
        }

        private static func result(_ filter: CIFilter) throws -> CIImage {
            guard let image = filter.outputImage else { throw SuwopError("明るさ・色の描画に失敗しました。") }
            return image
        }
    }
#endif
