import Foundation

// FrontPagePublisher — the bridge between FrontPage 98 and the modern web.
// FP98 publishes to the private staging VM (workload 2). This tool promotes
// the site from the staging folder to the public static-hosting folder:
//  - skips FrontPage's private metadata (_vti_cnf, _vti_pvt, _private)
//  - leaves the HTML exactly as FP98 wrote it (themes and all)
//  - checks every local href/src target exists, and lists the dead ones
//    (FrontPage components like hit counters and form handlers can't be
//    fixed — they're reported, not silently dropped)
// Usage: FrontPagePublisher <stagingDir> <publishDir>

let args = CommandLine.arguments
guard args.count >= 3 else { print("usage: FrontPagePublisher <stagingDir> <publishDir>"); exit(2) }
let src = URL(fileURLWithPath: args[1]), dst = URL(fileURLWithPath: args[2])
let fm = FileManager.default
let skipDirs: Set<String> = ["_vti_cnf", "_vti_pvt", "_vti_log", "_private", "_derived"]

var published: [String] = []
var deadLinks: [String] = []
var componentWarnings: [String] = []

guard let walker = fm.enumerator(at: src, includingPropertiesForKeys: nil) else {
    print("cannot read staging dir"); exit(1)
}
var allFiles: Set<String> = []
for case let url as URL in walker {
    let rel = url.path.replacingOccurrences(of: src.path + "/", with: "")
    if skipDirs.contains(where: { rel.hasPrefix($0 + "/") }) { continue }
    var isDir: ObjCBool = false
    fm.fileExists(atPath: url.path, isDirectory: &isDir)
    if !isDir.boolValue { allFiles.insert(rel) }
}

for rel in allFiles.sorted() {
    let from = src.appendingPathComponent(rel)
    let to = dst.appendingPathComponent(rel)
    try? fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? fm.removeItem(at: to)
    try fm.copyItem(at: from, to: to)
    published.append(rel)

    if rel.lowercased().hasSuffix(".htm") || rel.lowercased().hasSuffix(".html") {
        guard let html = try? String(contentsOf: from, encoding: .isoLatin1) else { continue }
        if html.contains("bot=\"") || html.contains("_vti") && html.contains("HitCounter") {
            componentWarnings.append("\(rel): contains a FrontPage server component (counter/form) — it will not run on static hosting")
        }
        // Local link check: href="x" / src="x" pointing at files in the web.
        for attr in ["href=\"", "src=\""] {
            var rest = html
            while let r = rest.range(of: attr) {
                let tail = rest[r.upperBound...]
                guard let end = tail.firstIndex(of: "\"") else { break }
                let target = String(tail[..<end])
                rest = String(tail[end...])
                if target.hasPrefix("http") || target.hasPrefix("mailto:") || target.hasPrefix("#") || target.isEmpty { continue }
                let clean = target.split(separator: "#").first.map(String.init) ?? target
                let resolved = URL(fileURLWithPath: clean, relativeTo: from.deletingLastPathComponent()).standardized.path
                    .replacingOccurrences(of: src.path + "/", with: "")
                if !allFiles.contains(resolved) && !allFiles.contains(clean) {
                    deadLinks.append("\(rel) -> \(clean)")
                }
            }
        }
    }
}

print("== FrontPage 98 publish ==")
print("Published \(published.count) file(s) to \(dst.path)")
componentWarnings.forEach { print("COMPONENT: \($0)") }
if deadLinks.isEmpty { print("Link check clean.") }
else { deadLinks.sorted().forEach { print("DEAD LINK: \($0)") } }
print("Next: sync the publish folder to the workload-2 storage account ($web container), then purge the CDN endpoint.")
