// Decodes DNG files with CIRAWFilter using the same settings for each and compares the rendered
// pixel buffers against the first file (the control). Run by run.sh; not part of the app.
//
//   swift compare.swift <scaleFactor> <control.dng> <variant.dng>...
//
// Each file is decoded twice: with the decoder's defaults (as-shot white balance, as the app
// opens a photo), and with temperature and tint pinned to the control's as-shot values, so a
// tag that only moves the white-balance estimate can be told apart from one that changes the
// color conversion itself. Pixels are read as 32-bit float RGBA in extended linear sRGB, the
// app's working space, never from embedded previews or JPEGs.

import CoreImage
import Foundation

let args = CommandLine.arguments.dropFirst()
guard args.count >= 2, let scale = Float(args.first!) else {
    print("usage: compare.swift <scaleFactor> <control.dng> <variant.dng>...")
    exit(2)
}
let urls = args.dropFirst().map { URL(fileURLWithPath: $0) }
// DECODER_VERSION picks one of the filter's supportedDecoderVersions, such as "9" or "9.dng";
// without it the decoder's default is used, as in the app.
let decoderVersion = ProcessInfo.processInfo.environment["DECODER_VERSION"].map { CIRAWDecoderVersion(rawValue: $0) }
let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
let context = CIContext(options: [.workingColorSpace: linear, .workingFormat: CIFormat.RGBAh,
                                  .cacheIntermediates: false])

struct Decoded {
    var pixels: [Float]
    var width: Int, height: Int
    var nativeSize: CGSize
    var temperature: Float, tint: Float
}

func decode(_ url: URL, pinned: (Float, Float)?) -> Decoded? {
    guard let filter = CIRAWFilter(imageURL: url), filter.nativeSize != .zero else { return nil }
    if let version = decoderVersion { filter.decoderVersion = version }
    let size = filter.nativeSize
    let temperature = filter.neutralTemperature, tint = filter.neutralTint
    filter.scaleFactor = scale
    if let pinned {
        filter.neutralTemperature = pinned.0
        filter.neutralTint = pinned.1
    }
    guard let image = filter.outputImage else { return nil }
    let extent = image.extent.integral
    let width = Int(extent.width), height = Int(extent.height)
    var pixels = [Float](repeating: 0, count: width * height * 4)
    pixels.withUnsafeMutableBytes { buffer in
        context.render(image, toBitmap: buffer.baseAddress!, rowBytes: width * 16, bounds: extent,
                       format: .RGBAf, colorSpace: linear)
    }
    return Decoded(pixels: pixels, width: width, height: height, nativeSize: size,
                   temperature: temperature, tint: tint)
}

func f(_ value: Double, _ digits: Int = 4) -> String { String(format: "%.\(digits)f", value) }

/// Mean linear RGB, and how far `b` is from `a`: the mean and maximum absolute difference over
/// RGB channels, and the share of pixels where any channel differs by more than 1/1000.
func compare(_ a: Decoded, _ b: Decoded) -> (mean: Double, max: Double, changed: Double)? {
    guard a.width == b.width, a.height == b.height else { return nil }
    var sum = 0.0, maxDiff = 0.0, changed = 0
    for p in stride(from: 0, to: a.pixels.count, by: 4) {
        var pixelMax = 0.0
        for c in 0..<3 {
            let d = Double(abs(a.pixels[p + c] - b.pixels[p + c]))
            sum += d
            pixelMax = max(pixelMax, d)
        }
        maxDiff = max(maxDiff, pixelMax)
        if pixelMax > 0.001 { changed += 1 }
    }
    let count = Double(a.pixels.count / 4)
    return (sum / (count * 3), maxDiff, Double(changed) / count)
}

func meanRGB(_ d: Decoded) -> String {
    var s = [0.0, 0.0, 0.0]
    for p in stride(from: 0, to: d.pixels.count, by: 4) { for c in 0..<3 { s[c] += Double(d.pixels[p + c]) } }
    let n = Double(d.pixels.count / 4)
    return s.map { f($0 / n) }.joined(separator: " ")
}

let probe = CIRAWFilter(imageURL: urls[0])
print("Camera models Core Image lists containing M11: \(CIRAWFilter.supportedCameraModels.filter { $0.contains("M11") })")
print("default decoderVersion \(probe?.decoderVersion.rawValue ?? "?"), this run \(decoderVersion?.rawValue ?? "default"), supported \(probe?.supportedDecoderVersions.map(\.rawValue) ?? [])")
print("macOS \(ProcessInfo.processInfo.operatingSystemVersionString), scaleFactor \(scale)\n")

for mode in ["as-shot WB (decoder default)", "WB pinned to control's as-shot Kelvin/tint"] {
    print("== \(mode) ==")
    guard let control = decode(urls[0], pinned: nil) else { print("control did not decode"); exit(1) }
    let pin: (Float, Float)? = mode.hasPrefix("WB pinned") ? (control.temperature, control.tint) : nil
    let reference = pin == nil ? control : decode(urls[0], pinned: pin)!
    // A second decode of the control shows the noise floor of decoding itself.
    let repeatDecode = decode(urls[0], pinned: pin)!
    let floor = compare(reference, repeatDecode)!
    print("control repeat decode: mean |d| \(f(floor.mean, 6)), max |d| \(f(floor.max, 6))")
    print("name | native size | as-shot K / tint | mean linear RGB | mean |d| | max |d| | pixels changed")
    for url in urls {
        guard let d = decode(url, pinned: pin) else { print("\(url.lastPathComponent) | DID NOT DECODE AS RAW"); continue }
        // Read the variant's own as-shot estimate, before any pinning.
        let own = decode(url, pinned: nil)!
        let c = compare(reference, d)
        let diff = c.map { "\(f($0.mean, 6)) | \(f($0.max, 4)) | \(f($0.changed * 100, 2))%" } ?? "size differs"
        print("\(url.deletingPathExtension().lastPathComponent) | \(Int(d.nativeSize.width))x\(Int(d.nativeSize.height)) | "
              + "\(f(Double(own.temperature), 0)) / \(f(Double(own.tint), 1)) | \(meanRGB(d)) | \(diff)")
    }
    print("")
}
