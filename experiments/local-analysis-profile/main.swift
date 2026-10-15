import CSuwop
import Foundation

struct ProbeError: Error { let message: String }
let arguments = CommandLine.arguments
guard arguments.count >= 3 else { throw ProbeError(message: "prepare|index ROOT [ROWS]") }
let mode = arguments[1]
let root = URL(fileURLWithPath: arguments[2], isDirectory: true)
func call(_ command: [String: Any]) throws -> Any {
    let data = try JSONSerialization.data(withJSONObject: ["root": root.path, "command": command])
    let text = String(decoding: data, as: UTF8.self)
    let pointer = text.withCString { suwop_call(0, 15, $0) }
    guard let pointer else { throw ProbeError(message: "No bridge response") }
    defer { suwop_free(pointer) }
    let response = try JSONSerialization.jsonObject(with: Data(String(cString: pointer).utf8))
    guard let response = response as? [String: Any] else { throw ProbeError(message: "Invalid response") }
    if let message = response["error"] as? String { throw ProbeError(message: message) }
    return response["value"] ?? NSNull()
}
if mode == "prepare" {
    guard !FileManager.default.fileExists(atPath: root.path), arguments.count == 4,
          let count = Int(arguments[3]), (10 ... 20000).contains(count)
    else { throw ProbeError(message: "Use a new directory and 10..20000 synthetic rows") }
    let assets: [[String: Any]] = (0 ..< count).map { index in
        ["key": ["provider": "apple", "scope": "synthetic", "assetID": String(index)],
         "name": "synthetic.jpg", "revision": "1", "appleVisibility": "visible", "resources": [], "isFavorite": false,
         "inventoryComplete": false, "isOffline": false, "deletionBlockers": []]
    }
    let state: [String: Any] = ["schemaVersion": 5, "appleScope": "synthetic", "connection": NSNull(),
        "snapshots": [["provider": "apple", "scope": "synthetic", "access": "full", "scannedAt": 0, "assets": assets]]]
    _ = try call(["type": "persist", "state": state])
    let model: [String: Any] = ["name": "synthetic", "version": "1", "preprocessing": "synthetic-l2-v1",
        "rendition": "original", "dimensions": 512]
    let budget: [String: Any] = ["cacheBytes": 8 << 20, "workingBytes": 128 << 20, "maxBatchRows": 512]
    guard let key = try call(["type": "register", "model": model, "budget": budget]) as? String
    else { throw ProbeError(message: "Missing model key") }
    _ = try call(["type": "pause", "modelKey": key])
    try Data(key.utf8).write(to: root.appendingPathComponent("model-key.txt"))
} else if mode == "index" {
    let key = try String(contentsOf: root.appendingPathComponent("model-key.txt"), encoding: .utf8)
    let started = Date()
    _ = try call(["type": "resume", "modelKey": key])
    var finalStatus: [String: Any] = [:]
    while Date().timeIntervalSince(started) < 300 {
        guard let statuses = try call(["type": "status"]) as? [[String: Any]], let status = statuses.first
        else { throw ProbeError(message: "Missing status") }
        if status["state"] as? String == "ready" { finalStatus = status; break }
        if status["state"] as? String == "paused" { throw ProbeError(message: String(describing: status)) }
        Thread.sleep(forTimeInterval: 0.05)
    }
    guard !finalStatus.isEmpty else { throw ProbeError(message: "Worker timed out") }
    let indexedSeconds = Date().timeIntervalSince(started)
    let queryStarted = Date()
    guard let hits = try call(["type": "search", "modelKey": key,
                              "vector": Array(repeating: 0.5, count: 512), "limit": 10]) as? [Any], hits.count == 10
    else { throw ProbeError(message: "Search did not return ten hits") }
    let querySeconds = Date().timeIntervalSince(queryStarted)
    // Let the idle native worker close SQLite before the caller measures disk use.
    Thread.sleep(forTimeInterval: 2.5)
    let report: [String: Any] = ["status": finalStatus, "indexSeconds": indexedSeconds, "querySeconds": querySeconds]
    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        .write(to: root.appendingPathComponent("report.json"))
} else { throw ProbeError(message: "Unknown mode") }
