import Foundation
import TangLLM
import os

/// tang-llm linked in-process. Calls block, so run them off the main thread.
final class Tang: @unchecked Sendable {
    private let handle: OpaquePointer

    init(dir: URL, context: Int, q4: Bool = false) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard let h = tang_load(dir.path, UInt32(context), q4, &error) else {
            defer { tang_string_free(error) }
            throw TangError(message: error.map { String(cString: $0) } ?? "load failed")
        }
        handle = h
    }

    deinit { tang_free(handle) }

    func info() -> [String: Any] { Self.json(tang_info(handle)) }

    func bench(prompt: Int, gen: Int) -> [String: Any] {
        Self.json(tang_bench(handle, UInt32(prompt), UInt32(gen)))
    }

    /// Streams text into `onText`; return false from it to stop.
    func chat(_ messages: [[String: String]], maxTokens: Int, onText: @escaping (String) -> Bool) -> [String: Any] {
        let data = try! JSONSerialization.data(withJSONObject: messages)
        let box = Unmanaged.passRetained(Box(onText))
        defer { box.release() }
        return Self.json(tang_chat(handle, String(decoding: data, as: UTF8.self), UInt32(maxTokens), { text, ctx in
            let box = Unmanaged<Box>.fromOpaque(ctx!).takeUnretainedValue()
            return box.onText(String(cString: text!))
        }, box.toOpaque()))
    }

    private final class Box {
        let onText: (String) -> Bool
        init(_ f: @escaping (String) -> Bool) { onText = f }
    }

    private static func json(_ s: UnsafeMutablePointer<CChar>?) -> [String: Any] {
        defer { tang_string_free(s) }
        guard let s, let obj = try? JSONSerialization.jsonObject(with: Data(String(cString: s).utf8)) as? [String: Any]
        else { return ["error": "bad reply"] }
        return obj
    }
}

struct TangError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

/// What the process is using and what iOS will still give it, in MB.
enum Memory {
    static var footprintMB: Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }

    static var availableMB: Double { Double(os_proc_available_memory()) / 1_048_576 }
}
