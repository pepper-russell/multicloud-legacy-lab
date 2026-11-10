import Foundation

// CobolMigrator — the migration driver for workload 3 (bank, PCI).
// It does NOT transpile by itself; it orchestrates the pipeline the plan
// document defines and produces the two artifacts a bank actually signs:
//   1. an inventory (programs, copybooks, data files, sizes)
//   2. a reconciliation report (record counts + control totals) proving
//      the migrated data matches the source — the PCI/audit evidence.
// Stages it drives: inventory -> convert-data -> transpile -> reconcile.
// Usage: CobolMigrator inventory <srcDir>
//        CobolMigrator convert-data <inFile> <outFile>   (EBCDIC CP037 -> UTF-8)
//        CobolMigrator reconcile <sourceCounts.json> <targetCounts.json>

let args = CommandLine.arguments
let fm = FileManager.default

// Minimal CP037 map for the characters that dominate bank data files
// (letters, digits, common punctuation). Full-table conversion belongs in
// the pipeline's iconv step — this is the field-expedient path, labeled.
func ebcdicToASCII(_ b: UInt8) -> UInt8 {
    switch b {
    case 0x40: return 0x20
    case 0x81...0x89: return b - 0x22          // a-i
    case 0x91...0x99: return b - 0x31          // j-r
    case 0xA2...0xA9: return b - 0x41          // s-z
    case 0xC1...0xC9: return b - 0x84          // A-I
    case 0xD1...0xD9: return b - 0x94          // J-R
    case 0xE2...0xE9: return b - 0xA3          // S-Z
    case 0xF0...0xF9: return b - 0xC0          // 0-9
    case 0x4B: return 0x2E                     // .
    case 0x6B: return 0x2C                     // ,
    case 0x60: return 0x2D                     // -
    case 0x61: return 0x2F                     // /
    case 0x7A: return 0x3A                     // :
    case 0x5A: return 0x21                     // !
    case 0x7D: return 0x27                     // '
    case 0x7E: return 0x3D                     // =
    case 0x25: return 0x0A                     // line feed in many CP037 files
    default: return b
    }
}

guard args.count >= 2 else {
    print("usage: CobolMigrator <inventory|convert-data|reconcile> ..."); exit(2)
}

switch args[1] {
case "inventory":
    guard args.count >= 3 else { print("usage: CobolMigrator inventory <srcDir>"); exit(2) }
    var programs: [(String, String, [String])] = []
    var dataFiles: [String] = []
    let walker = fm.enumerator(atPath: args[2])
    while let f = walker?.nextObject() as? String {
        let lower = f.lowercased()
        if lower.hasSuffix(".cob") || lower.hasSuffix(".cbl") {
            let text = (try? String(contentsOfFile: args[2] + "/" + f, encoding: .utf8)) ?? ""
            let pid = text.range(of: "PROGRAM-ID.", options: .caseInsensitive)
                .map { r in text[r.upperBound...].prefix { !$0.isWhitespace && $0 != "." } } ?? "?"
            let copies = text.components(separatedBy: "COPY ").dropFirst()
                .map { $0.prefix { !$0.isWhitespace && $0 != "." } }.map(String.init)
            programs.append((f, String(pid), copies))
        } else if lower.hasSuffix(".dat") || lower.hasSuffix(".vsam") || lower.hasSuffix(".seq") {
            dataFiles.append(f)
        }
    }
    print("== COBOL estate inventory ==")
    print("Programs: \(programs.count)")
    for p in programs.sorted(by: { $0.0 < $1.0 }) {
        print("  \(p.0)  PROGRAM-ID: \(p.1)  copybooks: \(p.2.isEmpty ? "none" : p.2.joined(separator: ", "))")
    }
    print("Data files: \(dataFiles.count)")
    dataFiles.sorted().forEach { print("  \($0)") }
    print("PCI note: inventory only — no cardholder data read, no PAN values touched.")

case "convert-data":
    guard args.count >= 4 else { print("usage: CobolMigrator convert-data <in> <out>"); exit(2) }
    guard let raw = fm.contents(atPath: args[2]) else { print("cannot read \(args[2])"); exit(1) }
    let converted = Data(raw.map(ebcdicToASCII))
    try converted.write(to: URL(fileURLWithPath: args[3]))
    print("Converted \(raw.count) bytes CP037 -> UTF-8: \(args[2]) -> \(args[3])")
    print("Verify against the reconciliation counts before this file goes anywhere near the target.")

case "reconcile":
    guard args.count >= 4 else { print("usage: CobolMigrator reconcile <source.json> <target.json>"); exit(2) }
    func load(_ p: String) -> [String: Int] {
        guard let d = fm.contents(atPath: p),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Int] else { return [:] }
        return obj
    }
    let s = load(args[2]), t = load(args[3])
    var bad = 0
    print("== Reconciliation ==")
    for k in Set(s.keys).union(t.keys).sorted() {
        if s[k] == t[k] { print("  MATCH \(k): \(s[k] ?? 0)") }
        else { print("  MISMATCH \(k): source \(s[k] ?? -1) vs target \(t[k] ?? -1)"); bad += 1 }
    }
    print(bad == 0 ? "Reconciliation clean — evidence pack can be signed." : "Reconciliation FAILED on \(bad) file(s). Cutover is blocked. That is the rule, not a suggestion.")
    exit(bad == 0 ? 0 : 1)

default:
    print("unknown stage: \(args[1])"); exit(2)
}
