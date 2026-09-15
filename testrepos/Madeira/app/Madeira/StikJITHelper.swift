import UIKit
import Darwin

/// Helper to enable JIT via StikDebug/StikJIT URL scheme.
/// Opens StikDebug with the bundled script, polls for CS_DEBUGGED,
/// then allocates JIT memory and detaches the debugger.
enum StikJITHelper {

    private static let persistentScriptRequestKey = "IridiumPersistentJITScriptRequested"

    static var persistentScriptRequested: Bool {
        UserDefaults.standard.bool(forKey: persistentScriptRequestKey) &&
            UserDefaults.standard.double(forKey: "IridiumJITDeadline") > Date().timeIntervalSince1970
    }

    static func consumePersistentScriptRequest() {
        UserDefaults.standard.removeObject(forKey: persistentScriptRequestKey)
    }

    /// The production iOS project packages madeira-jit.js as a resource. Keep one
    /// authoritative copy instead of an embedded base64 fallback that can go stale.
    private static var resolvedScriptBase64: String? {
        guard let url = Bundle.main.url(forResource: "madeira-jit", withExtension: "js"),
              let data = try? Data(contentsOf: url)
        else { return nil }
        return data.base64EncodedString()
    }

    enum Route: String, CaseIterable {
        case automatic, livecontainer2, livecontainer, stikdebug
        var title: String {
            switch self {
            case .automatic: return "Automatic"
            case .livecontainer2: return "LiveContainer2"
            case .livecontainer: return "LiveContainer"
            case .stikdebug: return "StikDebug"
            }
        }
    }
    static let routeKey = "IridiumExternalJITRoute"
    static var route: Route { Route(rawValue: UserDefaults.standard.string(forKey: routeKey) ?? "") ?? .automatic }
    private static var timer: Timer?
    private static var activation: Task<Void, Never>?
    private static var completion: ((Bool) -> Void)?
    private static var checking = false
    private static var request = UUID()
    private(set) static var lastFailure = "JIT was not enabled."

    static var isAvailable: Bool {
        ["livecontainer2", "livecontainer", "stikjit"].contains {
            UIApplication.shared.canOpenURL(URL(string: "\($0)://")!)
        }
    }

    static func cancel() {
        guard completion != nil else { return }
        finish(false, message: "JIT request cancelled.")
    }

    private static func finish(_ success: Bool, message: String? = nil) {
        timer?.invalidate(); timer = nil
        activation?.cancel(); activation = nil
        checking = false
        request = UUID()
        if let message { lastFailure = message; LogStore.shared.log(message, level: .error) }
        if !success { consumePersistentScriptRequest() }
        let callback = completion
        completion = nil
        callback?(success)
    }

    static func enableJIT(completion: @escaping (Bool) -> Void) {
        cancel()
        self.completion = completion
        let token = request
        let wasDebugged = jit_check_debugged()
        let deadline = Date().addingTimeInterval(180)
        UserDefaults.standard.set(deadline.timeIntervalSince1970, forKey: "IridiumJITDeadline")
        UserDefaults.standard.set(true, forKey: persistentScriptRequestKey)
        guard let scriptBase64 = resolvedScriptBase64 else {
            finish(false, message: "Cannot load the bundled JIT script.")
            return
        }
        var components = URLComponents()
        components.scheme = "stikjit"
        components.host = "enable-jit"
        components.queryItems = [
            // StikDebug chooses its PID attach path whenever pid is present. This
            // avoids process_control_launch_app(), which is the source of the
            // "expected integer PID in launch app response" failure for hosted apps.
            URLQueryItem(name: "pid", value: String(getpid())),
            // Keep the bundle ID too so StikDebug can return to the hosted app
            // after the script finishes without using it as the debug target.
            URLQueryItem(name: "bundle-id", value: Bundle.main.bundleIdentifier ?? "com.madeira.emulator"),
            URLQueryItem(name: "script-data", value: scriptBase64)
        ]
        guard let url = components.url else { finish(false, message: "Cannot create the JIT request."); return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            guard request == token else { return }
            if Date() >= deadline { finish(false, message: "JIT timed out. Open your JIT app and try again.") }
            else if checking && jit_check_debugged() { finish(true) }
        }
        let routes: [Route] = route == .automatic ? [.livecontainer2, .stikdebug, .livecontainer] : [route]
        func open(_ index: Int) {
            guard request == token else { return }
            guard index < routes.count else { finish(false, message: "Cannot open the selected JIT app. Choose a route in Launch Support."); return }
            let chosen = routes[index]
            let destination = chosen == .stikdebug ? url : liveContainerURL(for: url, scheme: chosen.rawValue)
            guard let destination else { open(index + 1); return }
            UIApplication.shared.open(destination, options: [:]) { success in
                guard request == token else { return }
                guard success else { open(index + 1); return }
                LogStore.shared.log("Opened \(chosen.title) for JIT.")
                if !wasDebugged { checking = true; return }
                activation = Task { @MainActor in
                    for await _ in NotificationCenter.default.notifications(named: UIApplication.didBecomeActiveNotification) {
                        guard !Task.isCancelled, request == token else { return }
                        checking = true
                        return
                    }
                }
            }
        }
        open(0)
    }

    // LiveContainer decodes the first query value as a base64-encoded guest URL.
    static func liveContainerURL(for url: URL, scheme: String = "livecontainer2") -> URL? {
        guard scheme == "livecontainer" || scheme == "livecontainer2" else { return nil }
        var components = URLComponents()
        components.scheme = scheme
        components.host = "open-url"
        components.queryItems = [URLQueryItem(name: "url", value: Data(url.absoluteString.utf8).base64EncodedString())]
        return components.url
    }

    static func allocateAdaptivePool() -> (rx: UnsafeMutableRawPointer, rw: UnsafeMutableRawPointer, size: Int)? {
        let requested = UserDefaults.standard.integer(forKey: "IridiumJITPoolMB")
        let availableMB = Int(os_proc_available_memory() / (1024 * 1024))
        let cap = [128, 256, 512].contains(requested) ? requested : 512
        for mb in [512, 256, 128] where mb <= cap && mb <= availableMB / 2 {
            if let pool = allocatePool(poolSize: mb * 1024 * 1024) { return pool }
        }
        return nil
    }
    private static var pinned = false

    /// Allocate a JIT memory pool via BRK #0xf00d, then detach the debugger.
    /// Call this after CS_DEBUGGED is confirmed.
    /// Returns the allocated RX base address and RW mapping, or nil on failure.
    static func allocateAndDetach(poolSize: Int = 128 * 1024 * 1024) -> (rx: UnsafeMutableRawPointer, rw: UnsafeMutableRawPointer, size: Int)? {
        guard let result = allocatePool(poolSize: poolSize) else { return nil }
        // Don't detach yet — Wine needs the debugger to prepare PE DLL code pages.
        // Detach will happen later via detachDebugger().
        return result
    }

    /// Allocate a JIT memory pool via BRK #0xf00d WITHOUT detaching the debugger.
    /// The debugger stays attached so Wine can use BRK to prepare PE code pages.
    static func allocatePool(poolSize: Int = 128 * 1024 * 1024) -> (rx: UnsafeMutableRawPointer, rw: UnsafeMutableRawPointer, size: Int)? {
        LogStore.shared.log("Allocating \(poolSize / 1024 / 1024)MB JIT pool via debugger...")

        // iOS-Madeira: FEX's dispatcher emit has a position-dependent encoding
        // bug — only works when the JIT pool lands at a high enough address
        // (empirically ≥ 0x119000000, so dispatcher at +0x7ffc130 has top byte
        // 0x12). When iOS allocates 0x114-0x117xxx the dispatcher's literal-
        // pool fixups silently break and execution branches to zero memory
        // before the first compiled block runs. Pre-claim ~96MB of low address
        // space to push the next ANYWHERE allocation up.
        //
        // We keep these allocations alive for the lifetime of the process —
        // freeing them could let iOS reuse them and cause aliasing issues.
        var pinChunks: [vm_address_t] = []
        let chunkSize = 16 * 1024 * 1024  // 16 MB per chunk
        // Pin until the allocation frontier crosses the mode-A threshold
        // (0x119000000) instead of a fixed 96MB. A fixed count loses the
        // ASLR lottery whenever the base slide is low (observed 2026-07-03:
        // 6 chunks ended at 0x118790000, pool landed 8.4MB short of the
        // threshold and the run fast-failed). vm_allocate is zero-fill
        // reserve-only, so extra chunks don't add resident footprint.
        // The BAD POOL check below stays as the safety net for non-
        // sequential placements.
        let pinTarget: vm_address_t = 0x119000000
        let maxChunks = 32                 // safety cap (512 MB of reservation)
        for i in 0..<(pinned ? 0 : maxChunks) {
            var addr: vm_address_t = 0
            let kr = vm_allocate(mach_task_self_, &addr, vm_size_t(chunkSize), VM_FLAGS_ANYWHERE)
            if kr == KERN_SUCCESS {
                pinChunks.append(addr)
                LogStore.shared.log(String(format: "JIT-pool pin chunk %d at 0x%lx (16MB)", i, Int(addr)))
                if addr + vm_address_t(chunkSize) >= pinTarget { break }
            } else {
                LogStore.shared.log("JIT-pool pin chunk \(i) FAILED kr=\(kr)", level: .error)
                break
            }
        }

        pinned = true

        // Ask debugger to allocate RX pages (x0=0 triggers _M allocation).
        // With pin chunks claimed, this should land at a higher address.
        //
        // Two placement constraints (violating either bricks the session):
        // - LOW BOUND: FEX has a position-dependent emit bug below
        //   0x119000000 (mode A: dispatcher branches to zero memory before
        //   block 0 runs; higher-address mode B is runtime-patched in
        //   signal_arm64_ios.c init_syscall_frame).
        // - GUEST WINDOW (ml78, 2026-07-13): with the 896MB pool the kernel
        //   often places the region at 0x7000000000 — inside the guest
        //   x86-64 64GB window [0x70,0x80)G where Wine packs PE images and
        //   the fault handlers classify PCs as guest addresses. Executing
        //   pool code there hangs the first pool call silently (black
        //   screen / wallpaper-only desktop).
        // Reject bad placements and re-roll: a bad region is freed when the
        // kernel allows, otherwise kept alive as a pin.
        // ⚠️ ml596: the old claim that the next pick "must land elsewhere" is FALSE.
        // ml595 freed and re-requested three times and the kernel handed back the
        // SAME 0x7000000000 hole each time, so the retry loop is not a strategy —
        // it is three identical attempts. Failure is therefore deterministic within
        // a launch and the caller must abort rather than run without a pool. A real
        // fix needs explicit placement (hinted allocation / reserve-and-carve),
        // not a re-roll; simply pinning the bad region to force a different address
        // costs another 896MB against the 4096MB jetsam ceiling.
        let goodLow = 0x119000000
        let guestLo = 0x7000000000
        let guestHi = 0x8000000000
        var rxPtrOpt: UnsafeMutableRawPointer? = nil
        for attempt in 0..<3 {
            guard let p = jit26_prepare_region(nil, poolSize), p != UnsafeMutableRawPointer(bitPattern: 0) else {
                LogStore.shared.log("Debugger failed to allocate RX memory (attempt \(attempt))", level: .error)
                break
            }
            let a = Int(bitPattern: p)
            let inGuestWindow = a + poolSize > guestLo && a < guestHi
            if a >= goodLow && !inGuestWindow {
                rxPtrOpt = p
                break
            }
            LogStore.shared.log(String(format: "BAD POOL placement 0x%lx (%@) — re-rolling (attempt %d)",
                                       a, a < goodLow ? "mode A low" : "guest 64G window",
                                       attempt), level: .error)
            let dkr = vm_deallocate(mach_task_self_, vm_address_t(a), vm_size_t(poolSize))
            LogStore.shared.log(dkr == KERN_SUCCESS
                ? "  bad region freed"
                : "  bad region kept as pin (vm_deallocate kr=\(dkr))")
        }
        guard let rxPtr = rxPtrOpt else {
            LogStore.shared.log("JIT pool placement failed.", level: .error)
            return nil
        }
        let rxAddr = Int(bitPattern: rxPtr)
        LogStore.shared.log("RX pool at \(String(format: "%p", rxAddr))")

        // Create RW mapping via vm_remap
        var rwAddr: vm_address_t = 0
        var curProt: vm_prot_t = 0
        var maxProt: vm_prot_t = 0

        // task #35: place the RW alias BELOW the 64GB carveout floor.
        // With VM_FLAGS_ANYWHERE the kernel picks the first free address above
        // the GPU carveout [64G,448G) — which is 0x7000000000 exactly. That is
        // the base of a 16GB jumbo slot, so this 896MB data-only mapping was
        // sterilizing a whole slot that CEF's PartitionAlloc needs. The top
        // window [448G,512G) holds only four such slots and CEF wants at least
        // four pools, so we cannot afford to spend one on ourselves.
        // Data-only (never executed — exec always goes through the RX alias),
        // so placement is unconstrained; fall back to ANYWHERE if all candidates
        // are taken, which restores the previous behaviour exactly.
        // ml91: six hand-picked candidates (8/12/16/24/32/48G) ALL failed —
        // sub-64G is far more crowded than assumed. Sweep the whole region on a
        // 1GB stride instead of guessing. Each failed vm_remap(FIXED) is cheap,
        // so ~58 probes at startup costs nothing and finds any real hole.
        // ml92 measured the real map: there is NO sub-64G space at all. The only
        // "free" region down there (0..0x102454000) is __PAGEZERO, and 4G-64G is
        // fully reserved (malloc xzone) — 58 probes on a 1GB stride found nothing.
        // Usable VA is exactly one ~63GB window, 0x7038000000..0x7fffdf0000.
        //
        // That window holds four 16GB-aligned slots (448/464/480/496G) and CEF's
        // PartitionAlloc wants one pool per slot. Landing here at 0x7000000000
        // spends the 448G slot on an 896MB mapping. Slot 496G is ALREADY ruined
        // by Wine furniture (PE images at ~0x7e874c0000 = 505.8G), so parking at
        // the very top costs nothing that isn't already lost and hands 448G back
        // to PartitionAlloc intact.
        // ml91/ml92/ml93: relocating this alias was tried and REVERTED. The map
        // says usable VA is a single ~63GB window (0x7038000000..0x7fffdf0000);
        // sub-64G is __PAGEZERO plus a fully-reserved 4G-64G band, so 58 probes
        // on a 1GB stride found nothing (ml92). Parking at the top of space
        // instead (0x7fc8000000) DID place, but Wine allocates its furniture
        // top-down — the TEB landed 1.25MB below us at 0x7fc7ec0000, pool copies
        // came out zero-filled, and libarm64ecfex died on 8 exec faults before
        // CEF was even reached (ml93). There is nowhere to put an 896MB mapping
        // that does not cost either a 16GB PartitionAlloc slot or Wine's own
        // furniture. The kernel pick (0x7000000000, base of the window) is the
        // least harmful: it spends the 448G slot but leaves the top — where Wine
        // clusters — alone.
        // ml96 census: CEF needs THREE 16GB pools (48GB), not the 144GB a naive
        // sum suggested — #3/#4/#5 are one pool re-rolling its hint, and the two
        // 32GB requests are that same pool over-reserving for 16GB ALIGNMENT.
        // 48GB fits in the 63GB window, so the third pool fails only because no
        // 16GB-ALIGNED slot is left: 464G and 480G are taken, 496G is broken by
        // Wine furniture, and 448G is spent on this 896MB alias.
        //
        // Freeing 448G should let pool 3 land. ml93 tried that and failed by
        // parking at 0x7fc8000000 — the extreme top, exactly where Wine
        // allocates its furniture top-down (the TEB landed 1.25MB below us and
        // pool copies came back zeroed). The map says 0x7c00000000..0x7e874c0000
        // is free, so take the BOTTOM of the already-broken 496G slot instead
        // and leave the top for Wine.
        // DO NOT relocate this alias without new evidence. Three placements were
        // measured against the default kernel pick (0x7000000000, which the
        // kernel picks because it is the first free address above the GPU
        // carveout):
        //   0x7000000000 (default)  ml94=8, ml96=1  exec faults, reaches libcef
        //   0x7fc8000000 (top)      ml93=8          exec faults, dies before CEF
        //   0x7c00000000 (496G)     ml97=16, ml98=16 exec faults, dies before CEF
        // Same fault class in every case (pool page loses content/exec, on a
        // recycled range) — relocation makes an EXISTING intermittent bug worse
        // rather than introducing a new one. Two mechanisms were proposed and
        // BOTH disproven: Wine furniture collision (ml93) and the reclaim-recover
        // band claiming the alias (ml97; the band exclusion landed in
        // signal_arm64_ios.c and did NOT change the count). Whatever couples the
        // alias base to pool stability is still unidentified.
        //
        // Cost of staying here: the alias occupies the base of the 448G slot, so
        // PartitionAlloc gets only two of the three 16GB-aligned pools it needs
        // (see the ml96 [jumbo#N] census). Freeing that slot is worth doing —
        // but by moving WINE's furniture out of 496G, not by moving this.
        rwAddr = 0
        let kr1 = vm_remap(
            mach_task_self_,
            &rwAddr,
            vm_size_t(poolSize),
            0,
            VM_FLAGS_ANYWHERE,
            mach_task_self_,
            vm_address_t(bitPattern: rxPtr),
            0, // copy = false
            &curProt,
            &maxProt,
            VM_INHERIT_NONE
        )

        guard kr1 == KERN_SUCCESS else {
            LogStore.shared.log("vm_remap failed: \(kr1)", level: .error)
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: rxPtr), vm_size_t(poolSize))
            return nil
        }

        // Set RW protection
        let kr2 = vm_protect(mach_task_self_, rwAddr, vm_size_t(poolSize), 0, VM_PROT_READ | VM_PROT_WRITE)
        guard kr2 == KERN_SUCCESS else {
            LogStore.shared.log("vm_protect(RW) failed: \(kr2)", level: .error)
            vm_deallocate(mach_task_self_, rwAddr, vm_size_t(poolSize))
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: rxPtr), vm_size_t(poolSize))
            return nil
        }

        let rwPtr = UnsafeMutableRawPointer(bitPattern: rwAddr)!
        LogStore.shared.log("RW mapping at \(String(format: "%p", Int(bitPattern: rwPtr)))")

        // ml358: the pool has NEVER been jetsam-exempt. jit_region_create()
        // applies NO_FOOTPRINT, but this path takes its RX pages from the
        // debugger and vm_remaps the RW alias, so every written pool page has
        // counted against phys_footprint in full — which is what killed ml357
        // ("Terminated due to memory issue" with 848MB of pool written). Apply
        // the ledger exemption to the shared object now that both aliases
        // exist; the helper logs footprint either side, so the next log says
        // whether the kernel honoured it. Non-fatal if refused.
        // ml360: the entry must be made over the RW ALIAS, not the RX view —
        // ml360's run showed mach_make_memory_entry_64(READ|WRITE) over the
        // debugger's RX pages fails with KERN_PROTECTION_FAILURE. Same vm
        // object either way; the RW alias actually permits the access.
        let exempt = jit_make_region_no_footprint(rwPtr, poolSize, "pool-RW-alias")
        // ml359: log the verdict through LogStore.log (which appends to the
        // file) — the ml358 run lost it because the jit_log callback only fed
        // the UI view. Detail (kr / footprint delta) is in the jit_log lines.
        LogStore.shared.log("[no-footprint] pool applied=\(exempt)", level: exempt ? .success : .error)

        LogStore.shared.log("JIT pool ready (debugger still attached).", level: .success)

        return (rx: rxPtr, rw: rwPtr, size: poolSize)
    }

    /// Detach the debugger. Call this after Wine is done loading PE DLLs.
    static func detachDebugger() {
        guard getenv("MADEIRA_DETACHED") == nil else { return }
        LogStore.shared.log("Detaching debugger...")
        jit26_detach()
        // task #34: signal in-process waiters (share-probe poller). CS_DEBUGGED
        // is sticky post-detach, so an env flag is the reliable signal.
        setenv("MADEIRA_DETACHED", "1", 1)
        LogStore.shared.log("Debugger detached.", level: .success)
    }
}
