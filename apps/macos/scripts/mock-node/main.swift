import Foundation

// A stand-in tang node for pairing work: `scripts/mock-node.sh [name] [port]`.
// Advertises `_frog-node._tcp` with v=2 TXT, opens a pairing window and prints the code.
setvbuf(stdout, nil, _IOLBF, 0)
let args = CommandLine.arguments
let node = MockNode(name: args.count > 1 ? args[1] : "mew")
node.advertise = true
let port = try node.start(port: args.count > 2 ? UInt16(args[2]) ?? 8911 : 8911)
let code = node.openWindow(code: ProcessInfo.processInfo.environment["MOCK_CODE"])
print("mock node \(node.name) on :\(port) · code \(code) · fingerprint \(PairCrypto.grouped(node.fingerprint))")
print("POST /pair/open from this machine for a new code.")
dispatchMain()
