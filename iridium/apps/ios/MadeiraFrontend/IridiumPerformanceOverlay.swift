// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI
import UIKit
import Darwin
import Combine

/// The performance overlay's look (OverlayStyle), under its figures in the in-game menu.
struct OverlayStyleSettings: View {
    var showsFrameGraph = true
    @AppStorage(OverlayStyle.layoutKey) private var layout = "grid"
    @AppStorage(OverlayStyle.scaleKey) private var scale = 1.0
    @AppStorage(OverlayStyle.backgroundKey) private var background = "glass"
    @AppStorage(OverlayStyle.opacityKey) private var opacity = 1.0
    @AppStorage(OverlayStyle.labelsKey) private var labels = true
    @AppStorage(OverlayStyle.coloursKey) private var colours = false
    @AppStorage(OverlayStyle.refreshKey) private var refresh = 1.0
    @AppStorage(OverlayStyle.graphSecondsKey) private var graphSeconds = 4.0
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Overlay style").font(.subheadline.weight(.semibold)).padding(.top, 4)
            Picker("Layout", selection: $layout) {
                ForEach(OverlayStyle.layouts, id: \.id) { Text($0.name).tag($0.id) }
            }.pickerStyle(.segmented)
            LabeledContent("Size") { Slider(value: $scale, in: 0.6...1.8, step: 0.05) }
            LabeledContent("Opacity") { Slider(value: $opacity, in: 0.3...1) }
            LabeledContent("Background") {
                Picker("Background", selection: $background) {
                    ForEach(OverlayStyle.backgrounds, id: \.id) { Text($0.name).tag($0.id) }
                }.pickerStyle(.segmented).frame(maxWidth: 220)
            }
            Toggle("Labels", isOn: $labels)
            Toggle("Colour by frame rate", isOn: $colours)
            LabeledContent("Updates") {
                Picker("Updates", selection: $refresh) {
                    Text("0.5 s").tag(0.5); Text("1 s").tag(1.0); Text("2 s").tag(2.0)
                }.pickerStyle(.segmented).frame(maxWidth: 220)
            }
            if showsFrameGraph {
                LabeledContent("Graph span") {
                    Picker("Graph span", selection: $graphSeconds) {
                        Text("2 s").tag(2.0); Text("4 s").tag(4.0); Text("8 s").tag(8.0)
                    }.pickerStyle(.segmented).frame(maxWidth: 220)
                }
            }
            Button("Reset overlay style") {
                layout = "grid"; scale = 1; background = "glass"; opacity = 1; labels = true; colours = false; refresh = 1; graphSeconds = 4
            }.font(.subheadline)
        }.font(.subheadline)
    }
}

// Keep drag state in this small view. Global translation remains stable while
// the view moves; local coordinates feed its own movement back in.
struct IridiumFloatingPerformanceOverlay: View {
    let viewport: CGSize
    let insets: EdgeInsets
    let fields: [String]
    var consoleFrames: (@MainActor () -> UInt64)? = nil
    var onPositionChange: (CGRect) -> Void = { _ in }
    @AppStorage("madeiraLibraryMetricsX") private var nx = 0.25
    @AppStorage("madeiraLibraryMetricsY") private var ny = 0.08
    @GestureState private var drag = CGSize.zero
    @State private var measured = CGSize(width: 48, height: 48)

    private func position(_ translation: CGSize) -> CGPoint {
        let left = insets.leading + measured.width / 2 + 8
        let top = insets.top + measured.height / 2 + 8
        return CGPoint(x: min(max(left, viewport.width * nx + translation.width), max(left, viewport.width - insets.trailing - measured.width / 2 - 8)),
                       y: min(max(top, viewport.height * ny + translation.height), max(top, viewport.height - insets.bottom - measured.height / 2 - 8)))
    }
    var body: some View {
        let center = position(drag)
        let rect = CGRect(x: center.x - measured.width / 2, y: center.y - measured.height / 2, width: measured.width, height: measured.height)
        IridiumPerformanceOverlay(fields: fields, consoleFrames: consoleFrames).accessibilityHint("Drag to move")
        .frame(maxWidth: max(48, min(390, viewport.width - insets.leading - insets.trailing - 16)))
        .fixedSize(horizontal: false, vertical: true)
        .background(GeometryReader { proxy in
            Color.clear.onAppear { measured = proxy.size }.onChange(of: proxy.size) { _, size in measured = size }
        })
        .contentShape(Rectangle())
        .highPriorityGesture(DragGesture(minimumDistance: 6, coordinateSpace: .global).updating($drag) { value, state, transaction in
            transaction.animation = nil; state = value.translation
        }.onEnded { value in
            let end = position(value.translation)
            withTransaction(Transaction(animation: nil)) {
                nx = end.x / max(1, viewport.width); ny = end.y / max(1, viewport.height)
            }
        })
        .offset(x: center.x - measured.width / 2, y: center.y - measured.height / 2)
        .onAppear { onPositionChange(rect) }.onChange(of: rect) { _, value in onPositionChange(value) }
        .onDisappear { onPositionChange(.zero) }
    }
}

/// Common overlay style. Windows keeps its existing per-game metric choices.
enum OverlayStyle {
    static let layoutKey = "madeiraOverlayLayout", scaleKey = "madeiraOverlayScale"
    static let backgroundKey = "madeiraOverlayBackground", opacityKey = "madeiraOverlayOpacity"
    static let labelsKey = "madeiraOverlayLabels", coloursKey = "madeiraOverlayColours"
    static let refreshKey = "madeiraOverlayRefresh", graphSecondsKey = "madeiraOverlayGraphSeconds"
    /// "grid": up to five cells a row (as first made); "row": one long row; "column": one figure a line.
    static let layouts: [(id: String, name: String)] = [("grid", "Grid"), ("row", "One row"), ("column", "Column")]
    static let backgrounds: [(id: String, name: String)] = [("glass", "Glass"), ("dark", "Dark"), ("clear", "None")]
    /// The figures the overlay can show, in the order of the menu's switches.
    static let fields = ["FPS", "Frame time", "1% lows", "0.1% lows", "Frame graph", "CPU", "GPU", "RAM", "JIT memory", "Swap & donor", "Battery", "Thermal"]
    static let consoleFields = ["FPS", "Frame time", "RAM", "Battery", "Thermal"]
}

/// Frame times from the present path (madeira_frame_times_us, Winios.m) and the
/// figures made from them: the 1% low is the frame rate of the slowest 1% of
/// frames (their mean frame time), the 1% high that of the fastest 1%.
enum FrameTimes {
    static func read(windowMs: UInt32, max: Int = 2048) -> (intervals: [Double], sinceLast: Double) {
        var buffer = [UInt32](repeating: 0, count: max)
        var since: UInt32 = 0
        let n = Int(madeira_frame_times_us(&buffer, Int32(max), windowMs, &since))
        return (buffer.prefix(n).map { Double($0) / 1000 }, Double(since) / 1000)
    }
    /// (1% low, 1% high) in frames a second, nil without enough frames.
    static func onePercent(_ ms: [Double]) -> (low: Double, high: Double)? {
        guard ms.count >= 10 else { return nil }
        let sorted = ms.sorted(), k = max(1, sorted.count / 100)
        let slow = sorted.suffix(k).reduce(0, +) / Double(k), fast = sorted.prefix(k).reduce(0, +) / Double(k)
        guard slow > 0, fast > 0 else { return nil }
        return (1000 / slow, 1000 / fast)
    }
    /// The 0.1% low in frames a second: the slowest 0.1% of frames (at least the
    /// slowest one), nil without enough frames.
    static func pointOnePercentLow(_ ms: [Double]) -> Double? {
        guard ms.count >= 10 else { return nil }
        let k = max(1, ms.count / 1000), slow = ms.sorted().suffix(k).reduce(0, +) / Double(k)
        return slow > 0 ? 1000 / slow : nil
    }
    /// The frame time to show: the mean of the frames presented in the last
    /// `windowMs`, or the time since the last present when that is longer (a stall
    /// still going on). nil when nothing has presented.
    static func current(windowMs: UInt32) -> Double? {
        let (ms, since) = read(windowMs: windowMs, max: 512)
        let mean = ms.isEmpty ? 0 : ms.reduce(0, +) / Double(ms.count)
        let value = max(mean, since > mean ? since : 0)
        return value > 0 ? value : nil
    }
}

/// The frame-time graph: each frame a step as wide as it lasted and as high as its
/// time, newest on the right, so a stall is a plateau as long as the stall; the
/// frame still being made grows at the right edge. Drawn ten times a second.
struct FrameTimeGraph: View {
    let width: CGFloat
    let height: CGFloat
    let scale: CGFloat
    let seconds: Double
    let colours: Bool
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { _ in
            let (ms, since) = FrameTimes.read(windowMs: UInt32(seconds * 1000), max: 1024)
            let sorted = ms.sorted()
            let median = sorted.isEmpty ? 16.7 : sorted[sorted.count / 2]
            let p99 = sorted.isEmpty ? 16.7 : sorted[min(sorted.count - 1, sorted.count * 99 / 100)]
            // The frame still being made, once it is clearly late.
            let pending = since > max(50, median * 2) ? since : 0
            let top = [33.3, 50, 66.7, 100, 200, 500, 1000, 2000, 5000].first(where: { $0 >= max(p99, pending) * 1.15 }) ?? 5000
            ZStack(alignment: .topTrailing) {
                Canvas { context, size in
                    let w = size.width, h = size.height
                    func y(_ v: Double) -> CGFloat { h - CGFloat(min(v, top) / top) * (h - 1) }
                    for guide in [16.7, 33.3] where guide < top {
                        var line = Path(); line.move(to: CGPoint(x: 0, y: y(guide))); line.addLine(to: CGPoint(x: w, y: y(guide)))
                        context.stroke(line, with: .color(.primary.opacity(0.18)), style: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                    }
                    // Right edge = now; walk back from the newest frame.
                    var steps: [(x0: CGFloat, x1: CGFloat, v: Double)] = []
                    var end = since
                    if pending > 0 { steps.append((w - CGFloat(pending / 1000 / seconds) * w, w, pending)) }
                    for v in ms.reversed() {
                        let x1 = w - CGFloat(end / 1000 / seconds) * w, x0 = w - CGFloat((end + v) / 1000 / seconds) * w
                        if x1 < 0 { break }
                        steps.append((max(0, x0), x1, v)); end += v
                    }
                    guard !steps.isEmpty else { return }
                    var outline = Path(), fill = Path()
                    let ordered = steps.reversed()
                    fill.move(to: CGPoint(x: ordered.first!.x0, y: h))
                    for (i, s) in ordered.enumerated() {
                        if i == 0 { outline.move(to: CGPoint(x: s.x0, y: y(s.v))) } else { outline.addLine(to: CGPoint(x: s.x0, y: y(s.v))) }
                        outline.addLine(to: CGPoint(x: s.x1, y: y(s.v)))
                        fill.addLine(to: CGPoint(x: s.x0, y: y(s.v))); fill.addLine(to: CGPoint(x: s.x1, y: y(s.v)))
                    }
                    fill.addLine(to: CGPoint(x: ordered.last!.x1, y: h)); fill.closeSubpath()
                    context.fill(fill, with: .color(.primary.opacity(0.12)))
                    context.stroke(outline, with: .color(.primary.opacity(0.85)), lineWidth: max(1, scale))
                    // Spikes: frames over twice the median, marked in orange (red over 100 ms) with colours on.
                    if colours {
                        for s in steps where s.v > max(median * 2, 25) {
                            var spike = Path(); spike.move(to: CGPoint(x: s.x0, y: y(s.v))); spike.addLine(to: CGPoint(x: s.x1, y: y(s.v)))
                            spike.move(to: CGPoint(x: s.x0, y: y(s.v))); spike.addLine(to: CGPoint(x: s.x0, y: h))
                            context.stroke(spike, with: .color(s.v > 100 ? .red : .orange), lineWidth: max(1.5, scale * 1.5))
                        }
                    }
                }
                Text(top >= 1000 ? String(format: "%.0f s", top / 1000) : String(format: "%.0f ms", top))
                    .font(.system(size: 8 * scale, weight: .medium, design: .rounded).monospacedDigit())
                    .foregroundStyle(.secondary).padding(.trailing, 2)
            }
            .frame(width: width, height: height)
        }
        .accessibilityHidden(true)
    }
}

struct IridiumPerformanceOverlay: View {
    let fields: [String]
    var consoleFrames: (@MainActor () -> UInt64)? = nil
    private var windows: Bool { consoleFrames == nil }
    private func frameCount() -> UInt64 { consoleFrames?() ?? madeira_shown_frame_count() }
    @AppStorage(OverlayStyle.layoutKey) private var layout = "grid"
    @AppStorage(OverlayStyle.scaleKey) private var scale = 1.0
    @AppStorage(OverlayStyle.backgroundKey) private var background = "glass"
    @AppStorage(OverlayStyle.opacityKey) private var opacity = 1.0
    @AppStorage(OverlayStyle.labelsKey) private var labels = true
    @AppStorage(OverlayStyle.coloursKey) private var colours = false
    @AppStorage(OverlayStyle.refreshKey) private var refresh = 1.0
    @AppStorage(OverlayStyle.graphSecondsKey) private var graphSeconds = 4.0
    @State private var lastCount: UInt64 = 0
    @State private var lastTime = CACurrentMediaTime()
    @State private var tick = 0
    @State private var fps = 0.0
    @State private var onePercent: (low: Double, high: Double)?
    @State private var pointOneLow: Double?
    /// Measured from the present path, like the graph (1000 / FPS hid the slow frames).
    @State private var frameMs: Double?
    @State private var memory = 0
    @State private var battery = -1
    /// iOS lowers clocks from .serious on, so a frame rate that sags after a few
    /// minutes can be told apart from one the game or the runtime caused.
    @State private var thermal = ProcessInfo.processInfo.thermalState
    @State private var cpuMeter = CPUMeter()
    @State private var cpu: (total: Double, top: Double)?
    @State private var lastGPUBusy = 0.0
    @State private var lastGPUBuffers: UInt64 = 0
    @State private var gpu = -1.0
    @State private var gpuFrameMs = 0.0
    /// ml2021: the swap tier's figures (madeira_swap_overlay_stats): MB backed by the
    /// swap file, MB served from the donor pool, the pool's registered size, and the
    /// takes its free-RAM guard refused.
    @State private var swapFileMB = 0
    @State private var donatedMB = 0
    @State private var donorPoolMB = 0
    @State private var donorGuarded = 0
    /// Half-second ticks; the figures change every `refresh` seconds (0.5, 1 or 2).
    private let ticks = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()
    /// ml2021: one cell per figure. A fixed width per cell (the widest value it can show)
    /// keeps the pill from shifting as digits change; monospaced digits keep the value
    /// still within the cell. Label above, value below, hairlines between cells, the
    /// system material behind: no gradients, no custom colours beyond the thermal dot
    /// (and, with Colours on, the frame-rate figures).
    struct Cell: Identifiable {
        let id: String
        let label: String
        let value: String
        let width: CGFloat
        var dot: Color? = nil
        var tint: Color? = nil
    }
    private var s: CGFloat { CGFloat(min(max(scale, 0.5), 2)) }
    private func speed(_ rate: Double) -> Color? {
        guard colours, rate > 0 else { return nil }
        return rate >= 45 ? .green : rate >= 25 ? .yellow : .red
    }
    private var cells: [Cell] {
        var result: [Cell] = []
        if fields.contains("FPS") {
            result.append(Cell(id: "fps", label: "FPS", value: String(format: "%.0f", fps), width: 44, tint: speed(fps)))
        }
        if fields.contains("Frame time") {
            result.append(Cell(id: "ms", label: "MS", value: frameMs.map { String(format: $0 >= 100 ? "%.0f" : "%.1f", $0) } ?? "–", width: 52))
        }
        if windows && fields.contains("1% lows") {
            result.append(Cell(id: "low", label: "1% LOW", value: onePercent.map { String(format: "%.0f", $0.low) } ?? "–", width: 52,
                               tint: onePercent.flatMap { speed($0.low) }))
            result.append(Cell(id: "high", label: "1% HIGH", value: onePercent.map { String(format: "%.0f", $0.high) } ?? "–", width: 54))
        }
        if windows && fields.contains("0.1% lows") {
            result.append(Cell(id: "low01", label: "0.1% LOW", value: pointOneLow.map { String(format: "%.0f", $0) } ?? "–", width: 60,
                               tint: pointOneLow.flatMap { speed($0) }))
        }
        if fields.contains("CPU") {
            result.append(Cell(id: "cpu", label: "CPU", value: cpu.map { String(format: "%.0f%%", $0.total) } ?? "–", width: 50))
            result.append(Cell(id: "top", label: "TOP", value: cpu.map { String(format: "%.0f%%", $0.top) } ?? "–", width: 50))
        }
        if windows && fields.contains("GPU") {
            result.append(Cell(id: "gpu", label: "GPU", value: gpu < 0 ? "–" : String(format: "%.0f%%", gpu), width: 50))
            result.append(Cell(id: "gpums", label: "GPU MS", value: gpu < 0 || gpuFrameMs <= 0 ? "–" : String(format: "%.1f", gpuFrameMs), width: 56))
        }
        if fields.contains("RAM") { result.append(Cell(id: "ram", label: "MB", value: "\(memory)", width: 54)) }
        if windows && fields.contains("Swap & donor") {
            if donorPoolMB > 0 { result.append(Cell(id: "donor", label: "DONOR", value: "\(donatedMB)", width: 54)) }
            result.append(Cell(id: "swap", label: "SWAP", value: "\(swapFileMB)", width: 54))
        }
        if fields.contains("Battery"), battery >= 0 { result.append(Cell(id: "bat", label: "BAT", value: "\(battery)%", width: 50)) }
        if fields.contains("Thermal") {
            let (word, dot): (String, Color) = {
                switch thermal {
                case .nominal: return ("Cool", .green)
                case .fair: return ("Warm", .yellow)
                case .serious: return ("Hot", .orange)
                case .critical: return ("Critical", .red)
                @unknown default: return ("–", .gray)
                }
            }()
            result.append(Cell(id: "temp", label: "TEMP", value: word, width: 62, dot: dot))
        }
        return result
    }
    private func value(_ c: Cell) -> some View {
        HStack(spacing: 4 * s) {
            if let dot = c.dot { Circle().fill(dot).frame(width: 6 * s, height: 6 * s) }
            Text(c.value).font(.system(size: 13 * s, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(c.tint ?? .primary)
        }
    }
    private func label(_ c: Cell) -> some View {
        Text(c.label).font(.system(size: 9 * s, weight: .medium, design: .rounded)).tracking(0.6 * s).foregroundStyle(.secondary)
    }
    private func cell(_ c: Cell) -> some View {
        VStack(spacing: 1 * s) {
            if labels { label(c) }
            value(c)
        }
        .frame(width: c.width * s)
    }
    private func row(_ cells: [Cell]) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(cells.enumerated()), id: \.element.id) { index, c in
                if index > 0 { Rectangle().fill(.primary.opacity(0.12)).frame(width: 1, height: (labels ? 20 : 14) * s) }
                cell(c)
            }
        }
    }
    /// The width a row of these cells takes (cells and hairlines).
    private func width(_ cells: [Cell]) -> CGFloat {
        cells.reduce(0) { $0 + $1.width * s } + CGFloat(max(0, cells.count - 1))
    }
    private func graph(width: CGFloat, height: CGFloat) -> some View {
        FrameTimeGraph(width: width, height: height, scale: s, seconds: min(max(graphSeconds, 1), 10), colours: colours)
    }
    @ViewBuilder private var content: some View {
        let all = cells
        let showGraph = windows && fields.contains("Frame graph")
        switch layout {
        case "row":
            HStack(spacing: 0) {
                row(all)
                if showGraph {
                    if !all.isEmpty { Rectangle().fill(.primary.opacity(0.12)).frame(width: 1, height: (labels ? 20 : 14) * s).padding(.trailing, 4 * s) }
                    graph(width: 120 * s, height: (labels ? 26 : 18) * s)
                }
            }
        case "column":
            VStack(alignment: .leading, spacing: 3 * s) {
                ForEach(all) { c in
                    HStack(spacing: 8 * s) {
                        if labels { label(c) }
                        Spacer(minLength: 0)
                        value(c)
                    }
                    .frame(width: 112 * s)
                }
                if showGraph { graph(width: 112 * s, height: 34 * s) }
            }
            .padding(.horizontal, 2 * s)
        default:
            // Up to five cells on a row; more wrap onto a second row so the pill stays under the
            // viewport's width instead of truncating.
            let split = all.count > 5 ? (all.count + 1) / 2 : all.count
            let first = Array(all.prefix(split)), second = Array(all.suffix(from: split))
            VStack(spacing: 6 * s) {
                if !first.isEmpty { row(first) }
                if !second.isEmpty { row(second) }
                if showGraph { graph(width: max(width(first), width(second), 150 * s), height: 34 * s) }
            }
        }
    }
    @ViewBuilder private func backdrop<V: View>(_ v: V) -> some View {
        let shape = RoundedRectangle(cornerRadius: 12 * s, style: .continuous)
        switch background {
        case "dark":
            v.background(Color.black.opacity(0.55), in: shape)
                .overlay(shape.strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
                .environment(\.colorScheme, .dark)
        case "clear":
            v.shadow(color: .black.opacity(0.9), radius: 1.5).environment(\.colorScheme, .dark)
        default:
            v.background(.ultraThinMaterial, in: shape)
                .overlay(shape.strokeBorder(.primary.opacity(0.1), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
        }
    }
    var body: some View {
        backdrop(content.padding(.horizontal, 6 * s).padding(.vertical, 6 * s))
        .opacity(min(max(opacity, 0.2), 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(parts.joined(separator: ", "))
            .onAppear {
                lastCount = frameCount(); lastTime = CACurrentMediaTime(); UIDevice.current.isBatteryMonitoringEnabled = true
                applyGPUMeter()
            }
            .onDisappear { UIDevice.current.isBatteryMonitoringEnabled = false; if windows { madeira_gpu_meter_enable(0) } }
            .onChange(of: fields) { _, _ in applyGPUMeter() }
            .onReceive(ticks) { _ in
                tick += 1
                guard tick % max(1, Int((refresh / 0.5).rounded())) == 0 else { return }
                let now = CACurrentMediaTime()
                let count = frameCount(); let dt = now - lastTime
                let frames = count >= lastCount ? count - lastCount : 0
                fps = Double(frames) / max(0.001, dt); lastCount = count; lastTime = now
                // Over the last ten seconds, so a stall stays in the figure for a while.
                if windows && fields.contains("1% lows") { onePercent = FrameTimes.onePercent(FrameTimes.read(windowMs: 10_000).intervals) }
                // 0.1% needs more frames: thirty seconds (the ring holds 2048).
                if windows && fields.contains("0.1% lows") { pointOneLow = FrameTimes.pointOnePercentLow(FrameTimes.read(windowMs: 30_000).intervals) }
                if fields.contains("Frame time") {
                    frameMs = windows ? FrameTimes.current(windowMs: UInt32(max(0.5, refresh) * 1000))
                        : (fps > 0 ? 1000 / fps : nil)
                }
                if let reading = RuntimeMemorySnapshot.sample() { memory = Int(clamping: reading.usedBytes >> 20) }
                battery = UIDevice.current.batteryLevel < 0 ? -1 : Int(UIDevice.current.batteryLevel * 100)
                let state = ProcessInfo.processInfo.thermalState
                if state != thermal {
                    LogStore.shared.log("[thermal] \(DeviceLoadDiagnostics.thermalName(thermal)) -> \(DeviceLoadDiagnostics.thermalName(state)) at \(String(format: "%.0f", fps)) FPS")
                    thermal = state
                }
                if fields.contains("CPU") { cpu = cpuMeter.sample() }
                if windows && fields.contains("Swap & donor") {
                    var file: UInt64 = 0, donated: UInt64 = 0, pool: UInt64 = 0, guarded: UInt64 = 0
                    madeira_swap_overlay_stats(&file, &donated, &pool, &guarded)
                    swapFileMB = Int(file); donatedMB = Int(donated); donorPoolMB = Int(pool); donorGuarded = Int(guarded)
                }
                if windows && fields.contains("GPU") {
                    let busy = madeira_gpu_meter_busy_seconds(), buffers = madeira_gpu_meter_cmdbufs()
                    let used = max(0, busy - lastGPUBusy)
                    gpu = buffers > lastGPUBuffers ? min(100, used / max(0.001, dt) * 100) : -1
                    gpuFrameMs = frames > 0 ? used * 1000 / Double(frames) : 0
                    lastGPUBusy = busy; lastGPUBuffers = buffers
                }
            }
    }
    /// ml1174: command buffers get a GPU-time handler only while GPU is shown.
    private func applyGPUMeter() {
        guard windows else { return }
        madeira_gpu_meter_enable(fields.contains("GPU") ? 1 : 0)
        lastGPUBusy = madeira_gpu_meter_busy_seconds(); lastGPUBuffers = madeira_gpu_meter_cmdbufs(); gpu = -1
    }
    private var parts: [String] {
        var result: [String] = []
        if fields.contains("FPS") { result.append(String(format: "%.0f FPS", fps)) }
        if fields.contains("Frame time") { result.append(frameMs.map { String(format: windows ? "%.1f ms" : "%.1f ms average", $0) } ?? "— ms") }
        if windows && fields.contains("1% lows") {
            result.append(onePercent.map { String(format: "1%% low %.0f, 1%% high %.0f FPS", $0.low, $0.high) } ?? "1% lows —")
        }
        if windows && fields.contains("0.1% lows") { result.append(pointOneLow.map { String(format: "0.1%% low %.0f FPS", $0) } ?? "0.1% low —") }
        if fields.contains("CPU") {
            result.append(cpu.map { String(format: "CPU %.0f%% (top %.0f%%)", $0.total, $0.top) } ?? "CPU —")
        }
        if windows && fields.contains("GPU") {
            if gpu < 0 { result.append("GPU —") }
            else if gpuFrameMs > 0 { result.append(String(format: "GPU %.0f%% (%.1f ms)", gpu, gpuFrameMs)) }
            else { result.append(String(format: "GPU %.0f%%", gpu)) }
        }
        if fields.contains("RAM") { result.append("\(memory) MB") }
        // The memory games' code runs from; "FULL" once a DLL did not fit (JITPoolMeter).
        if windows && fields.contains("JIT memory") { result.append(JITPoolMeter.text(JITPoolMeter.current) ?? "JIT —") }
        if windows && fields.contains("Swap & donor") {
            // RAM above is the app's own footprint; donated memory is billed to the
            // extension's ledger, so it is shown beside it rather than added to it.
            if donorPoolMB > 0 {
                result.append(donorGuarded > 0 ? "Donated \(donatedMB)/\(donorPoolMB) MB (\(donorGuarded) guarded)"
                                               : "Donated \(donatedMB)/\(donorPoolMB) MB")
            }
            result.append("Swap \(swapFileMB) MB")
        }
        if fields.contains("Battery"), battery >= 0 { result.append("\(battery)%") }
        if fields.contains("Thermal") {
            switch thermal {
            case .nominal: result.append("Cool")
            case .fair: result.append("Warm")
            case .serious: result.append("Hot")
            case .critical: result.append("Critical")
            @unknown default: break
            }
        }
        return result
    }
}

/// ml1174: CPU load for the performance overlay, from the process's thread
/// times. `total` is the CPU time since the previous sample as a share of all
/// cores; `top` is the busiest thread's share of one core, which shows a game
/// held back by one thread while the total stays low.
final class CPUMeter {
    private var last: [UInt64: Double] = [:]
    private var lastWall = 0.0
    private let cores = Double(max(1, ProcessInfo.processInfo.activeProcessorCount))

    /// nil on the first call, and when the threads cannot be read.
    func sample() -> (total: Double, top: Double)? {
        var list: thread_act_array_t?
        var count: mach_msg_type_number_t = 0
        guard task_threads(mach_task_self_, &list, &count) == KERN_SUCCESS, let list else { return nil }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: list)),
                          vm_size_t(Int(count) * MemoryLayout<thread_t>.stride))
        }
        let wall = CACurrentMediaTime()
        var now: [UInt64: Double] = [:]
        var sum = 0.0, top = 0.0
        for i in 0..<Int(count) {
            let thread = list[i]
            defer { mach_port_deallocate(mach_task_self_, thread) }
            var ident = thread_identifier_info_data_t()
            var identCount = mach_msg_type_number_t(MemoryLayout<thread_identifier_info_data_t>.size / MemoryLayout<natural_t>.size)
            var basic = thread_basic_info_data_t()
            var basicCount = mach_msg_type_number_t(MemoryLayout<thread_basic_info_data_t>.size / MemoryLayout<natural_t>.size)
            let identResult = withUnsafeMutablePointer(to: &ident) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(identCount)) {
                    thread_info(thread, thread_flavor_t(THREAD_IDENTIFIER_INFO), $0, &identCount)
                }
            }
            let basicResult = withUnsafeMutablePointer(to: &basic) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(basicCount)) {
                    thread_info(thread, thread_flavor_t(THREAD_BASIC_INFO), $0, &basicCount)
                }
            }
            guard identResult == KERN_SUCCESS, basicResult == KERN_SUCCESS else { continue }
            let seconds = Double(basic.user_time.seconds + basic.system_time.seconds)
                + Double(basic.user_time.microseconds + basic.system_time.microseconds) / 1e6
            now[ident.thread_id] = seconds
            if let before = last[ident.thread_id] {
                let used = max(0, seconds - before)
                sum += used; top = max(top, used)
            }
        }
        let interval = wall - lastWall
        let first = last.isEmpty
        last = now; lastWall = wall
        guard !first, interval > 0 else { return nil }
        return (min(100, sum / interval / cores * 100), min(100, top / interval * 100))
    }
}
