// Apple Vision text recognition CLI (on-device, free) — proxy for what an
// iOS Flutter app gets via VNRecognizeTextRequest. ML Kit (Android) differs.
//
// Usage: vision_ocr <level:accurate|fast> <langcorr:0|1> <customwords:0|1> <minTextHeight> img1 [img2 ...]
// Output: one JSON object per image on stdout:
//   {"file":..., "w":..., "h":..., "ms":..., "obs":[{"text":..,"conf":..,"box":[x,y,w,h],"cands":[..],
//      "chars":[{"c":"Q","box":[..]}]}]}
// Boxes are normalised, origin TOP-left (converted from Vision's bottom-left).
import Foundation
import Vision
import CoreGraphics
import ImageIO

func loadCG(_ path: String) -> CGImage? {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(src, 0, nil)
}

func flip(_ r: CGRect) -> [Double] {
    return [Double(r.origin.x), Double(1 - r.origin.y - r.size.height), Double(r.size.width), Double(r.size.height)]
}

let args = CommandLine.arguments
if args.count < 6 {
    FileHandle.standardError.write("usage: vision_ocr accurate|fast langcorr customwords minH files...\n".data(using: .utf8)!)
    exit(2)
}
let level = args[1]
let langCorr = args[2] == "1"
let custom = args[3] == "1"
let minH = Float(args[4]) ?? 0
let files = Array(args[5...])

for f in files {
    guard let cg = loadCG(f) else { print("{\"file\":\"\(f)\",\"error\":\"load\"}"); continue }
    let req = VNRecognizeTextRequest()
    req.recognitionLevel = level == "fast" ? .fast : .accurate
    req.usesLanguageCorrection = langCorr
    req.recognitionLanguages = ["en-US"]
    if custom { req.customWords = ["A", "K", "Q", "J", "10", "9", "8", "7", "6", "5", "4", "3", "2"] }
    if minH > 0 { req.minimumTextHeight = minH }
    if let r = ProcessInfo.processInfo.environment["VNREV"], let ri = Int(r) { req.revision = ri }
    let handler = VNImageRequestHandler(cgImage: cg, options: [:])
    let t0 = Date()
    do { try handler.perform([req]) } catch {
        print("{\"file\":\"\(f)\",\"error\":\"\(error)\"}"); continue
    }
    let ms = Date().timeIntervalSince(t0) * 1000
    var obsOut: [[String: Any]] = []
    for o in req.results ?? [] {
        let cands = o.topCandidates(5)
        guard let best = cands.first else { continue }
        var chars: [[String: Any]] = []
        let s = best.string
        var idx = s.startIndex
        while idx < s.endIndex {
            let nxt = s.index(after: idx)
            if let bb = try? best.boundingBox(for: idx..<nxt) {
                chars.append(["c": String(s[idx..<nxt]), "box": flip(bb.boundingBox)])
            }
            idx = nxt
        }
        obsOut.append([
            "text": s, "conf": best.confidence, "box": flip(o.boundingBox),
            "cands": cands.map { ["t": $0.string, "c": $0.confidence] }, "chars": chars,
        ])
    }
    let out: [String: Any] = ["file": f, "w": cg.width, "h": cg.height, "ms": ms, "level": level, "rev": req.revision,
                              "langcorr": langCorr, "custom": custom, "obs": obsOut]
    let data = try! JSONSerialization.data(withJSONObject: out, options: [])
    print(String(data: data, encoding: .utf8)!)
}
