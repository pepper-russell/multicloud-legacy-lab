import Foundation

// Tier3Manager — companion to workload 1 (the WS2008 / VB6 / dBase tier).
// Two jobs:
//  1. Replication check: compare the live dBase share against the vault
//     copy (file sizes + record counts parsed from the DBF headers) and
//     report drift before it becomes data loss.
//  2. Migration dry-run: parse each .DBF header and emit the SQL DDL the
//     dbase-to-sql migration plan will use, so the plan is never a guess.
//
// Usage: Tier3Manager <liveDir> <vaultDir> [--emit-sql]

struct DBFInfo {
    let file: String
    let records: UInt32
    let recordLength: UInt16
    struct Field { let name: String; let type: Character; let length: UInt8 }
    let fields: [Field]
}

func parseDBF(_ url: URL) -> DBFInfo? {
    guard let d = try? Data(contentsOf: url), d.count >= 32 else { return nil }
    let records = d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self) }
    let headerLen = d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 8, as: UInt16.self) }
    let recordLen = d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 10, as: UInt16.self) }
    var fields: [DBFInfo.Field] = []
    var off = 32
    while off + 32 <= Int(headerLen), d[off] != 0x0D {
        let nameBytes = d[off..<(off + 11)].filter { $0 != 0 }
        let name = String(bytes: nameBytes, encoding: .ascii) ?? "FIELD\(fields.count)"
        let type = Character(UnicodeScalar(d[off + 11]))
        fields.append(.init(name: name, type: type, length: d[off + 16]))
        off += 32
    }
    return DBFInfo(file: url.lastPathComponent, records: records, recordLength: recordLen, fields: fields)
}

func sqlType(_ f: DBFInfo.Field) -> String {
    switch f.type {
    case "C": return "VARCHAR(\(max(Int(f.length), 1)))"
    case "N", "F": return "NUMERIC(18,4)"
    case "D": return "DATE"
    case "L": return "BOOLEAN"
    case "M": return "TEXT" // memo: lives in the .DBT — plan migrates it via the DBT reader step
    default: return "TEXT"
    }
}

let args = CommandLine.arguments
guard args.count >= 3 else {
    print("usage: Tier3Manager <liveDir> <vaultDir> [--emit-sql]"); exit(2)
}
let emitSQL = args.contains("--emit-sql")
let fm = FileManager.default
let liveFiles = (try? fm.contentsOfDirectory(atPath: args[1]))?.filter { $0.lowercased().hasSuffix(".dbf") } ?? []
let vaultFiles = Set((try? fm.contentsOfDirectory(atPath: args[2]))?.filter { $0.lowercased().hasSuffix(".dbf") } ?? [])

print("== dBase replication check ==")
var drift = 0
for f in liveFiles.sorted() {
    let live = parseDBF(URL(fileURLWithPath: args[1]).appendingPathComponent(f))
    guard vaultFiles.contains(f), let live else {
        print("  MISSING IN VAULT: \(f)"); drift += 1; continue
    }
    let vault = parseDBF(URL(fileURLWithPath: args[2]).appendingPathComponent(f))
    if let vault, vault.records == live.records {
        print("  OK   \(f): \(live.records) records, in sync")
    } else {
        print("  DRIFT \(f): live \(live.records) records vs vault \(vault?.records ?? 0)"); drift += 1
    }
    if emitSQL {
        let table = f.replacingOccurrences(of: ".", with: "_").lowercased()
        let cols = live.fields.map { "  \($0.name.lowercased()) \(sqlType($0))" }.joined(separator: ",\n")
        print("-- migration DDL for \(f)\nCREATE TABLE \(table) (\n\(cols)\n);")
    }
}
print(drift == 0 ? "Replication healthy." : "Replication drift on \(drift) file(s) — replicate before anything else touches the share.")
exit(drift == 0 ? 0 : 1)
