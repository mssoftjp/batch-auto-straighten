import CoreGraphics
import Darwin
import Foundation
import ImageIO

private let processLimitSeconds: UInt32 = 15

private let schema = "batch-auto-straighten.horizon.v2"

private func parseArgs(_ args: [String]) -> (id: String, image: String, output: String, previewDegrees: Double?, original: String?)? {
  var id: String?
  var image: String?
  var output: String?
  var previewDegrees: Double?
  var original: String?
  var index = 0
  while index < args.count {
    let key = args[index]
    let next = index + 1 < args.count ? args[index + 1] : nil
    switch key {
    case "--id":
      id = next
      index += 1
    case "--image":
      image = next
      index += 1
    case "--preview-degrees":
      guard let next, let value = Double(next), value.isFinite, abs(value) <= 90 else { return nil }
      previewDegrees = value
      index += 1
    case "--output":
      output = next
      index += 1
    case "--original":
      original = next
      index += 1
    default:
      break
    }
    index += 1
  }
  guard let id, let image, let output,
        !id.isEmpty, !image.isEmpty, !output.isEmpty
  else {
    return nil
  }
  return (id, image, output, previewDegrees, original)
}

private func writeJSON(_ object: [String: Any], to path: String) throws {
  let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
  try data.write(to: URL(fileURLWithPath: path), options: .atomic)
}

private func loadCGImage(path: String) -> CGImage? {
  let url = URL(fileURLWithPath: path) as CFURL
  guard let source = CGImageSourceCreateWithURL(url, nil) else {
    return nil
  }
  return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: true] as CFDictionary)
}

private func detect(id: String, originalPath: String?) -> [String: Any] {
  var payload: [String: Any] = [
    "schema": schema,
    "id": id,
  ]
  if let originalPath, let camera = CameraRoll.read(path: originalPath) {
    payload["kind"] = "horizon"
    payload["source"] = "camera_roll"
    payload["roll_degrees"] = camera.roll
    payload["make"] = camera.make
    return payload
  }
  payload["source"] = "camera_roll"
  payload["kind"] = "none"
  payload["detail"] = "camera_metadata_unavailable"
  return payload
}

guard let parsed = parseArgs(Array(CommandLine.arguments.dropFirst())) else {
  fputs("usage: horizon-helper --id ID --image PATH --output PATH [--original PATH]\n", stderr)
  exit(2)
}

signal(SIGALRM, SIG_DFL)
alarm(processLimitSeconds)

// Validate before either JSON output or image rendering can touch the source.
private func sameFile(_ a: String, _ b: String) -> Bool {
  let first = URL(fileURLWithPath: a).standardizedFileURL.resolvingSymlinksInPath()
  let second = URL(fileURLWithPath: b).standardizedFileURL.resolvingSymlinksInPath()
  if first == second { return true }
  if let left = try? FileManager.default.attributesOfItem(atPath: first.path),
     let right = try? FileManager.default.attributesOfItem(atPath: second.path),
     let leftID = left[.systemFileNumber] as? NSNumber,
     let rightID = right[.systemFileNumber] as? NSNumber,
     let leftDevice = left[.systemNumber] as? NSNumber,
     let rightDevice = right[.systemNumber] as? NSNumber {
    return leftID == rightID && leftDevice == rightDevice
  }
  return false
}
if sameFile(parsed.output, parsed.image) ||
    (parsed.original.map { sameFile(parsed.output, $0) } ?? false) {
  fputs("output must not overwrite an input\n", stderr)
  exit(2)
}

do {
  if let degrees = parsed.previewDegrees {
    guard let image = loadCGImage(path: parsed.image) else { exit(3) }
    try CropPreview.render(image: image, degrees: degrees, output: parsed.output)
  } else {
    try writeJSON(detect(id: parsed.id, originalPath: parsed.original), to: parsed.output)
  }
  exit(0)
} catch {
  fputs("write failed\n", stderr)
  exit(1)
}
