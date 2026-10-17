import Foundation
import Darwin

// MARK: - Timing

private let timebase: mach_timebase_info_data_t = {
    var tb = mach_timebase_info_data_t()
    mach_timebase_info(&tb)
    return tb
}()

/// Milliseconds from mach_absolute_time (monotonic).
@inline(__always) func nowMs() -> Double {
    let t = mach_absolute_time()
    return Double(t) * Double(timebase.numer) / Double(timebase.denom) / 1_000_000.0
}

@discardableResult
func timed<T>(_ body: () -> T) -> (T, Double) {
    let t0 = nowMs()
    let r = body()
    return (r, nowMs() - t0)
}

func ms(_ body: () -> Void) -> Double {
    let t0 = nowMs()
    body()
    return nowMs() - t0
}

struct Stats {
    var samples: [Double]
    init(_ s: [Double]) { samples = s }
    var sorted: [Double] { samples.sorted() }
    var median: Double {
        let s = sorted
        guard !s.isEmpty else { return .nan }
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }
    var min: Double { samples.min() ?? .nan }
    var max: Double { samples.max() ?? .nan }
    var first: Double { samples.first ?? .nan }
    var description: String {
        String(format: "med %.2f  [min %.2f .. max %.2f]", median, min, max)
    }
    func fmt() -> String { description }
}

func f1(_ x: Double) -> String { String(format: "%.1f", x) }
func f2(_ x: Double) -> String { String(format: "%.2f", x) }

func log(_ s: String) {
    FileHandle.standardOutput.write((s + "\n").data(using: .utf8)!)
}

/// Process resident memory in MB.
func rssMB() -> Double {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    return kr == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576.0 : .nan
}
