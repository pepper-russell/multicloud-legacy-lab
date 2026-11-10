import Foundation

// MeshController — the 4th app: keeper of the multicloud VPN mesh.
// Given the mesh definition, it validates the design rules that bite in
// production (overlapping CIDRs, ASN collisions, missing legs) and prints
// the tunnel/BGP checklist the Terraform in ../../terraform/network builds.
//
// Usage: MeshController [path-to-mesh.json]
// Default mesh.json mirrors terraform/network/main.tf.

struct Mesh: Codable {
    struct Cloud: Codable { let name: String; let cidr: String; let asn: Int }
    struct Leg: Codable { let between: [String]; let pskVariable: String }
    let clouds: [Cloud]
    let legs: [Leg]
}

func cidrRange(_ cidr: String) -> (UInt32, UInt32)? {
    let parts = cidr.split(separator: "/")
    guard parts.count == 2, let bits = Int(parts[1]) else { return nil }
    let octets = parts[0].split(separator: ".").compactMap { UInt32($0) }
    guard octets.count == 4 else { return nil }
    let base = (octets[0] << 24) | (octets[1] << 16) | (octets[2] << 8) | octets[3]
    let mask: UInt32 = bits == 0 ? 0 : UInt32.max << (32 - bits)
    return (base & mask, base | ~mask)
}

let defaultMesh = """
{"clouds":[
  {"name":"aws","cidr":"10.10.0.0/16","asn":64512},
  {"name":"azure","cidr":"10.20.0.0/16","asn":65515},
  {"name":"gcp","cidr":"10.30.0.0/16","asn":64514}],
 "legs":[
  {"between":["aws","azure"],"pskVariable":"aws_azure_psk"},
  {"between":["aws","gcp"],"pskVariable":"aws_gcp_psk"},
  {"between":["azure","gcp"],"pskVariable":"azure_gcp_psk"}]}
"""

let path = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : nil
let data: Data
if let path, let d = FileManager.default.contents(atPath: path) { data = d }
else { data = Data(defaultMesh.utf8) }

let mesh = try JSONDecoder().decode(Mesh.self, from: data)
var problems: [String] = []

// Rule 1: no overlapping CIDRs — the mesh dies on this, every time.
for i in mesh.clouds.indices {
    for j in mesh.clouds.indices where j > i {
        guard let a = cidrRange(mesh.clouds[i].cidr), let b = cidrRange(mesh.clouds[j].cidr) else {
            problems.append("Unparseable CIDR on \(mesh.clouds[i].name) or \(mesh.clouds[j].name)"); continue
        }
        if a.0 <= b.1 && b.0 <= a.1 {
            problems.append("CIDR OVERLAP: \(mesh.clouds[i].name) \(mesh.clouds[i].cidr) x \(mesh.clouds[j].name) \(mesh.clouds[j].cidr)")
        }
    }
}
// Rule 2: ASNs unique per cloud.
if Set(mesh.clouds.map(\.asn)).count != mesh.clouds.count { problems.append("ASN collision between clouds") }
// Rule 3: full mesh = n(n-1)/2 legs.
let want = mesh.clouds.count * (mesh.clouds.count - 1) / 2
if mesh.legs.count != want { problems.append("Mesh has \(mesh.legs.count) legs, full mesh needs \(want)") }

print("== Multicloud mesh check ==")
for c in mesh.clouds { print("  \(c.name.padding(toLength: 6, withPad: " ", startingAt: 0)) \(c.cidr)  ASN \(c.asn)") }
for leg in mesh.legs { print("  tunnel \(leg.between[0]) <-> \(leg.between[1])  (PSK via var.\(leg.pskVariable))") }
if problems.isEmpty { print("OK: no overlaps, ASNs unique, full mesh. Safe to terraform apply the network module.") }
else { problems.forEach { print("PROBLEM: \($0)") }; exit(1) }
