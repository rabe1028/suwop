import CoreML
import Foundation

// Usage: bench <compiled-dir> <int8|pal6> <inputs-dir> <ane|gpu>
// Inputs are raw little-endian dumps of preprocessed fixtures (see README).
let args = CommandLine.arguments
let dir = URL(fileURLWithPath: args[1]), suffix = args[2], inputs = URL(fileURLWithPath: args[3])
let units: MLComputeUnits = args[4] == "gpu" ? .cpuAndGPU : .cpuAndNeuralEngine
let length = 128, imageToken: Int32 = 258_880

func footprint() -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    _ = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) } }
    return info.phys_footprint
}
func load(_ name: String, _ units: MLComputeUnits) throws -> MLModel {
    let config = MLModelConfiguration(); config.computeUnits = units
    return try MLModel(contentsOf: dir.appendingPathComponent("\(name).mlmodelc"), configuration: config)
}
func array<T>(_ file: String, _ shape: [Int], _ type: MLMultiArrayDataType, _: T.Type) throws -> MLMultiArray {
    let data = try Data(contentsOf: inputs.appendingPathComponent(file))
    let a = try MLMultiArray(shape: shape.map { NSNumber(value: $0) }, dataType: type)
    data.withUnsafeBytes { raw in memcpy(a.dataPointer, raw.baseAddress!, data.count) }
    return a
}
func ids(_ file: String) throws -> [Int32] {
    let data = try Data(contentsOf: inputs.appendingPathComponent(file))
    return data.withUnsafeBytes { Array($0.bindMemory(to: Int32.self)) }
}
func predict(_ m: MLModel, _ values: [String: MLMultiArray]) throws -> MLFeatureProvider {
    try m.prediction(from: MLDictionaryFeatureProvider(dictionary: values.mapValues { MLFeatureValue(multiArray: $0) }))
}
func embed(_ tokens: MLModel, _ encoder: MLModel, _ list: [Int32], soft: MLMultiArray?) throws -> [Float] {
    let input = try MLMultiArray(shape: [1, NSNumber(value: length)], dataType: .int32)
    let mask = try MLMultiArray(shape: [1, NSNumber(value: length)], dataType: .float32)
    for i in 0 ..< length {
        input[i] = NSNumber(value: i < list.count ? (list[i] == imageToken ? 0 : list[i]) : 0)
        mask[i] = NSNumber(value: i < list.count ? 1 : 0)
    }
    let embeds = try predict(tokens, ["input_ids": input]).featureValue(for: "inputs_embeds")!.multiArrayValue!
    if let soft {
        var next = 0
        for (i, id) in list.enumerated() where id == imageToken {
            for d in 0 ..< 512 { embeds[[0, i, d] as [NSNumber]] = soft[[0, next, d] as [NSNumber]] }
            next += 1
        }
    }
    let out = try predict(encoder, ["inputs_embeds": embeds, "mask": mask]).featureValue(for: "embedding")!.multiArrayValue!
    return (0 ..< 768).map { out[$0].floatValue }
}
let before = footprint()
var t = Date()
let visionEncoder = try load("vision-encoder-\(suffix)", units)
let head = try load("vision-head-fp32", .cpuOnly)
let tokens = try load("tokens-\(suffix)", .cpuOnly)
let encoder = try load("encoder-\(suffix)", units)
let loadSeconds = Date().timeIntervalSince(t)
let afterLoad = footprint()
var imageMs: [Double] = [], textMs: [Double] = [], peak = afterLoad
for i in 0 ..< 20 {
    let pixels = try array("pixels\(i).bin", [1, 630, 768], .float32, Float.self)
    let positions = try array("positions\(i).bin", [1, 630, 2], .int32, Int32.self)
    t = Date()
    let hidden = try predict(visionEncoder, ["pixel_values": pixels, "position_ids": positions]).featureValue(for: "hidden")!.multiArrayValue!
    let soft = try predict(head, ["hidden": hidden, "position_ids": positions]).featureValue(for: "soft_tokens")!.multiArrayValue!
    let image = try embed(tokens, encoder, ids("image_ids\(i).bin"), soft: soft)
    imageMs.append(Date().timeIntervalSince(t) * 1000)
    t = Date()
    let text = try embed(tokens, encoder, ids("text_ids\(i).bin"), soft: nil)
    textMs.append(Date().timeIntervalSince(t) * 1000)
    precondition(image.allSatisfy(\.isFinite) && text.allSatisfy(\.isFinite))
    peak = max(peak, footprint())
}
func median(_ v: [Double]) -> Double { v.sorted()[v.count / 2] }
print(String(format: "%@ \(args[4]) load %.1fs footprint before %.0f MiB after-load %.0f MiB peak %.0f MiB; image median %.0f ms (first %.0f); text median %.0f ms",
             suffix, loadSeconds, Double(before) / 1_048_576, Double(afterLoad) / 1_048_576, Double(peak) / 1_048_576, median(imageMs), imageMs[0], median(textMs)))
