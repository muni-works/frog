import XCTest
@testable import Frog

/// A machine's model list (Settings › Models › a machine): what each row says and offers, the
/// short default list per machine, and states that end.
@MainActor
final class LocalModelsTests: XCTestCase {
    /// mew's `GET /node` on 2026-11-17 (Frog 0.6.4, tang-llm 0.1.0), trimmed to what the app
    /// reads; its id, key and paths left out. It had said "loading openai/gpt-oss-20b" for
    /// 454,050 s (five days): nothing loaded, one turn waiting, the load never ended.
    static let mewReport = #"""
    {"schema":2,"node_id":"fixture-mew","name":"mew","version":"0.1.0",
     "hardware":{"kind":"cuda","name":"NVIDIA GeForce RTX 3090","unified_memory":false,"total_bytes":25295257600,"free_bytes":13303087104},
     "models":{"loaded":[],"loading":{"id":"openai/gpt-oss-20b","elapsed_ms":454050303},
      "on_disk":[
       {"id":"mlx-community/Qwen3-32B-4bit","weights_hash":"1111111111111111","quant":"mlx-4bit","size_bytes":18429850874,"load_bytes":21651076346},
       {"id":"Qwen/Qwen2.5-7B","weights_hash":"2222222222222222","quant":"bf16","size_bytes":15231271888,"load_bytes":5827299090},
       {"id":"openai/gpt-oss-20b","weights_hash":"3333333333333333","quant":"bf16","size_bytes":13761316904,"load_bytes":5346765387},
       {"id":"unsloth/gemma-3-4b-it","weights_hash":"4444444444444444","quant":"bf16","size_bytes":8600277880,"load_bytes":4633420665},
       {"id":"mlx-community/Qwen3-14B-4bit","weights_hash":"5555555555555555","quant":"mlx-4bit","size_bytes":8307898514,"load_bytes":10723817618},
       {"id":"mlx-community/Qwen3-8B-4bit","weights_hash":"6666666666666666","quant":"mlx-4bit","size_bytes":4607835174,"load_bytes":6889536550},
       {"id":"Qwen/Qwen3-VL-2B-Instruct","weights_hash":"7777777777777777","quant":"bf16","size_bytes":4255140312,"load_bytes":3210024132},
       {"id":"Qwen/Qwen2.5-1.5B","weights_hash":"8888888888888888","quant":"bf16","size_bytes":3087467144,"load_bytes":2176972982}
      ]},
     "queue":{"running":[],"waiting":[{"id":894}]}}
    """#

    static func mew() throws -> Device {
        var d = Device(id: "n1", role: .node, name: "mew")
        d.paired = true
        d.apply(try JSONDecoder().decode(NodeReport.self, from: Data(mewReport.utf8)))
        return d
    }

    /// Regression: a load the node has reported for days isn't "loading"; it's stuck, and the
    /// row goes back to what the model really is (on disk) with the reason.
    func testALoadReportedForDaysIsNotLoading() throws {
        let d = try Self.mew()
        XCTAssertNil(d.loadingID, "a five-day-old load isn't a load in progress")
        XCTAssertNil(d.loading)
    }
}
