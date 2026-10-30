// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

extension IridiumMadeiraRuntime {
    /// The adapter owns Madeira's placement rules and host-lifetime arena size.
    static func prepareJITMemory() -> Bool {
        let configured = MadeiraConfig.get("pool").flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        let megabytes = configured.flatMap { (256...1152).contains($0) ? $0 : nil } ?? 896
        return StikJITHelper.allocatePool(poolSize: megabytes * 1024 * 1024) != nil
    }
}
