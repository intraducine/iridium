// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

extension IridiumMadeiraRuntime {
    static var jitMemoryReady: Bool { StikJITHelper.poolExecutionVerified && ir_jit_memory_verified() }
    static var jitMemoryPrepared: Bool { StikJITHelper.poolReady }
    static func verifyJITMemory() -> Bool { StikJITHelper.verifyPreparedPool() }

    /// The adapter owns Madeira's placement rules and host-lifetime arena size.
    static func prepareJITMemory() -> Bool {
        let configured = MadeiraConfig.get("pool").flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        let megabytes = configured.flatMap { (256...1152).contains($0) ? $0 : nil } ?? 896
        guard let pool = StikJITHelper.allocatePool(poolSize: megabytes * 1024 * 1024) else { return false }
        let spans = [0..<pool.firstRegionBytes] + pool.additionalRegions
        var regions = spans.map { range in
            IRJITWindowsRegion(rx: pool.rx + range.lowerBound, rw: pool.rw + range.lowerBound, bytes: range.count, bootstrap: range.lowerBound == 0)
        }
        if let low = pool.low {
            let offset = low.rx - Int(bitPattern: pool.rx)
            regions.insert(IRJITWindowsRegion(rx: pool.rx + offset, rw: pool.rw + offset, bytes: low.size, bootstrap: true), at: 0)
        }
        return regions.withUnsafeBufferPointer { ir_jit_memory_register_windows($0.baseAddress, $0.count) }
    }
}
