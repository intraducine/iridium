import Foundation
import GameController
import SwiftUI

#if canImport(MetalKit)

#if os(iOS)
import QuartzCore
import UIKit
#endif

private struct PlayerGlassButton: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            content.buttonStyle(.glass).buttonBorderShape(.circle)
        } else {
            content.buttonStyle(.bordered).buttonBorderShape(.circle)
        }
    }
}

private struct PlayerGlassPanel: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            content.glassEffect(.regular, in: .rect(corners: .concentric(minimum: .fixed(24))))
        } else {
            content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        }
    }
}

struct RuntimePlayerView: View {
    let session: RuntimePlayerSession
    @ObservedObject var viewModel: AppViewModel
    var onCaptureChange: (Bool) -> Void = { _ in }
    // UI tests can supply file-backed presentation without starting a runtime.
    var presentationConfiguration: RuntimePlayerBridgeConfiguration? = nil

    @State private var controllerCount = GCController.controllers().count
    @State private var inputNotice: String?
    @State private var inputNoticeSymbol = "gamecontroller.fill"
    @State private var inputNoticeTask: Task<Void, Never>?
    @State private var touchEventCount = 0
    @State private var frameCount: UInt64 = 0
    @State private var timing = FrameTiming()
    @State private var framesPerSecond: Double = 0
    @State private var fpsSampleCount: UInt64 = 0
    @State private var fpsSampleTime = ProcessInfo.processInfo.systemUptime
    @State private var startupEvents: [String] = []
    @State private var totalLogEntries = 0
    @State private var launchEvents: [String] = []
    @State private var controlsVisible = true
    @State private var isShowingDiagnostics = false
    @State private var isShowingControls = false
    @State private var showPerformance = true
    @State private var isConfirmingClose = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { safeGeometry in
        ControllerMenuHost(nativeNavigation: controlsVisible || isShowingControls || isShowingDiagnostics || isConfirmingClose, backAction: {
            if isConfirmingClose { isConfirmingClose = false }
            else if isShowingControls { isShowingControls = false }
            else if isShowingDiagnostics { isShowingDiagnostics = false }
            else { controlsVisible.toggle() }
        }, fullScreen: true) {
        Group {
            if let bridgeConfiguration = presentationConfiguration ?? viewModel.runtimePlayerBridgeConfiguration(
                for: session.sessionIdentifier
            ) {
                    RuntimeRenderHostView(
                        configuration: bridgeConfiguration,
                        isRunning: session.state == .running
                    ) { count in
                        touchEventCount += count
                    } onFrameCount: { count in
                        frameCount = count
                        let now = ProcessInfo.processInfo.systemUptime
                        let elapsed = now - fpsSampleTime
                        if count < fpsSampleCount {
                            fpsSampleCount = count
                            fpsSampleTime = now
                            framesPerSecond = 0
                        } else if elapsed >= 1 {
                            framesPerSecond = Double(count - fpsSampleCount) / elapsed
                            fpsSampleCount = count
                            fpsSampleTime = now
                        }
                    } onFrameTiming: { value in
                        timing = value
                    } onFirstFramePresented: {
                        viewModel.recordRuntimePlayerFirstFramePresented(
                            sessionIdentifier: session.sessionIdentifier
                        )
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .ignoresSafeArea()
                    .overlay {
                        if controlsVisible {
                            Color.clear
                                .ignoresSafeArea()
                                .contentShape(Rectangle())
                                .onTapGesture { withOptionalAnimation { controlsVisible = false } }
                                .accessibilityLabel("Dismiss debug panel")
                                .accessibilityAddTraits(.isButton)
                        }
                    }
                    .overlay(alignment: .topTrailing) {
                        VStack(alignment: .trailing, spacing: 12) {
                            Button {
                                withOptionalAnimation { controlsVisible.toggle() }
                            } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }
                            .modifier(PlayerGlassButton()).accessibilityLabel("Player Menu")
                            if controlsVisible {
                                VStack(alignment: .leading, spacing: 6) {
                                    Button("Resume", systemImage: "play") { controlsVisible = false }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                    Button("Controls", systemImage: "gamecontroller") { isShowingControls = true; controlsVisible = false }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                    Toggle("Performance", isOn: $showPerformance).frame(minHeight: 44)
                                    Button("View Log", systemImage: "doc.text") { isShowingDiagnostics = true; controlsVisible = false }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                    Button("Close Game", systemImage: "xmark", role: .destructive) { isConfirmingClose = true }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                }
                                .buttonStyle(.plain)
                                .controlSize(.large)
                                .frame(width: 250, alignment: .leading)
                                .padding(16)
                                .modifier(PlayerGlassPanel())
                                .accessibilityIdentifier("playerMenuPanel")
                                .contentShape(Rectangle()).onTapGesture {}
                            }
                        }
                        .padding(.top, safeGeometry.safeAreaInsets.top + 12)
                        .padding(.trailing, max(16, safeGeometry.safeAreaInsets.trailing + 12))
                        .foregroundStyle(.white)
                    }
                    .overlay(alignment: .topLeading) {
                        if !hasPresentedFirstFrame && !controlsVisible {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Starting game…").font(.headline)
                                Text(launchEvents.last ?? "Preparing the runtime. The game has not shown a frame yet.")
                                    .font(.footnote).lineLimit(3)
                            }.padding(16).frame(maxWidth: 280, alignment: .leading)
                                .modifier(PlayerGlassPanel())
                                .accessibilityElement(children: .combine)
                                .accessibilityIdentifier("playerLaunchPanel")
                                .padding(.top, safeGeometry.safeAreaInsets.top + 12)
                                .padding(.leading, max(16, safeGeometry.safeAreaInsets.leading + 12))
                                .allowsHitTesting(false)
                        }
                    }
                .overlay(alignment: .bottomLeading) {
                    if showPerformance {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(framesPerSecond, specifier: "%.1f") FPS · \(timing.milliseconds, specifier: "%.1f") ms")
                        Text("1% low \(timing.low.map { String(format: "%.1f", $0) } ?? "—") · high \(timing.high.map { String(format: "%.1f", $0) } ?? "—")")
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    .modifier(PlayerGlassPanel())
                    .accessibilityIdentifier("playerPerformancePanel")
                    .padding(.leading, max(16, safeGeometry.safeAreaInsets.leading + 12))
                    .padding(.bottom, max(12, safeGeometry.safeAreaInsets.bottom + 8))
                    .allowsHitTesting(false)
                    .accessibilityLabel("Performance. FPS and frame time. One percent low and high over the latest 600 frames.")
                }
                }
                .overlay(alignment: .bottomTrailing) {
                    if let inputNotice {
                        Label(inputNotice, systemImage: inputNoticeSymbol)
                            .font(.callout.weight(.medium))
                            .foregroundStyle(.white)
                            .padding(12)
                            .modifier(PlayerGlassPanel())
                            .padding(.trailing, max(16, safeGeometry.safeAreaInsets.trailing + 12))
                            .padding(.bottom, max(12, safeGeometry.safeAreaInsets.bottom + 8))
                            .allowsHitTesting(false)
                            .accessibilityLabel(inputNotice)
                            .transition(reduceMotion ? .opacity : .asymmetric(
                                insertion: .offset(y: 12).combined(with: .opacity),
                                removal: .opacity
                            ))
                    }
                }
                .preferredColorScheme(.dark)
                .background(Color.black.ignoresSafeArea())
                .statusBarHidden()
                .task(id: session.sessionIdentifier) {
                    frameCount = 0
                    framesPerSecond = 0
                    timing = FrameTiming()
                    fpsSampleCount = 0
                    fpsSampleTime = ProcessInfo.processInfo.systemUptime
                    startupEvents = []
                    launchEvents = []
                    totalLogEntries = 0
                    var logOffsets: [String: UInt64] = [:]
                    while !Task.isCancelled {
                        let previousOffsets = logOffsets
                        let batch = await Task.detached(priority: .utility) {
                            RuntimeLogCapture.startupSummaries(offsets: previousOffsets)
                        }.value
                        logOffsets = batch.offsets
                        let stamp = Date.now.formatted(date: .omitted, time: .standard)
                        totalLogEntries += batch.events.count
                        for event in batch.events {
                            if let summary = RuntimeLogCapture.launchSummary(event), launchEvents.last?.hasSuffix(summary) != true {
                                launchEvents.append("[\(stamp)] \(summary)")
                            }
                        }
                        if launchEvents.count > 500 { launchEvents.removeFirst(launchEvents.count - 500) }
                        startupEvents.append(contentsOf: batch.events.map { "[\(stamp)] \($0)" })
                        // ponytail: retain 500 UI entries; full history stays in the runtime files.
                        if startupEvents.count > 500 { startupEvents.removeFirst(startupEvents.count - 500) }
                        do { try await Task.sleep(for: .seconds(1)) } catch { return }
                    }
                }
                .task(id: bridgeConfiguration.inputEventsPath) {
                    await MainActor.run {
                        controllerCount = GCController.controllers().count
                    }
                    RuntimePlayerControllerBridge.shared.start(
                        eventsPath: bridgeConfiguration.inputEventsPath
                    ) { count in
                        if count != controllerCount {
                            let connected = count > controllerCount
                            controllerCount = count
                            showInputNotice(device: "Controller", symbol: "gamecontroller.fill", connected: connected)
                        }
                    }
                }
                .task(id: session.state) {
                    guard session.state != .running else {
                        return
                    }
                    RuntimePlayerControllerBridge.shared.stop()
                }
                .onAppear {
                    controllerCount = GCController.controllers().count
                }
                .onReceive(NotificationCenter.default.publisher(for: .GCKeyboardDidConnect)) { _ in
                    showInputNotice(device: "Keyboard", symbol: "keyboard", connected: true)
                }
                .onReceive(NotificationCenter.default.publisher(for: .GCKeyboardDidDisconnect)) { _ in
                    showInputNotice(device: "Keyboard", symbol: "keyboard", connected: false)
                }
                .onReceive(NotificationCenter.default.publisher(for: .GCMouseDidConnect)) { _ in
                    showInputNotice(device: "Mouse", symbol: "computermouse.fill", connected: true)
                }
                .onReceive(NotificationCenter.default.publisher(for: .GCMouseDidDisconnect)) { _ in
                    showInputNotice(device: "Mouse", symbol: "computermouse.fill", connected: false)
                }
                .onChange(of: controlsVisible) { _, _ in updatePointerCapture() }
                .onKeyPress(.escape) {
                    controlsVisible.toggle(); return .handled
                }
                .sheet(isPresented: $isShowingControls) {
                    NavigationStack {
                        if let game = viewModel.games.first(where: { $0.id == session.gameID }) {
                            GameControlsView(game: game).toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { isShowingControls = false }.keyboardShortcut(.cancelAction) } }
                        }
                    }
                }
                .onChange(of: isShowingControls) { _, _ in updatePointerCapture() }
                .onChange(of: isShowingDiagnostics) { _, _ in updatePointerCapture() }
                .onChange(of: isConfirmingClose) { _, _ in updatePointerCapture() }
                .onAppear { updatePointerCapture() }
                .onDisappear {
                    onCaptureChange(false)
                    inputNoticeTask?.cancel()
                    RuntimePlayerControllerBridge.shared.stop()
                }
                .alert("Close game?", isPresented: $isConfirmingClose) {
                    Button("Keep playing", role: .cancel) {}
                    Button("Close game", role: .destructive) {
                        viewModel.dismissActiveRuntimePlayer()
                    }
                } message: {
                    Text("Unsaved progress may be lost.")
                }
                .sheet(isPresented: $isShowingDiagnostics) {
                    RuntimePlayerDiagnosticsView(
                        session: session,
                        configuration: bridgeConfiguration,
                        controllerCount: controllerCount,
                        touchEventCount: touchEventCount,
                        events: startupEvents, totalEntries: totalLogEntries
                    )
                    .presentationDetents([.medium, .large])
                }
            } else {
                ZStack {
                    Color.black.ignoresSafeArea()
                    VStack(spacing: 12) {
                        Text("Runtime Player")
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(.white)
                        Text("Closing the fullscreen runtime player.")
                            .font(.footnote)
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    .padding(.top, 16)
                }
                .ignoresSafeArea()
                .statusBarHidden()
                .task {
                    viewModel.dismissActiveRuntimePlayer()
                }
            }
        }
        }.ignoresSafeArea()
        }.statusBarHidden()
    }

    private var hasPresentedFirstFrame: Bool {
        frameCount > 0
    }

    private func updatePointerCapture() {
        onCaptureChange(!controlsVisible && !isShowingDiagnostics && !isShowingControls && !isConfirmingClose)
    }

    private func showInputNotice(device: String, symbol: String, connected: Bool) {
        let message = "\(device) \(connected ? "connected" : "disconnected")"
        withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .smooth(duration: 0.3, extraBounce: 0)) {
            inputNoticeSymbol = symbol
            inputNotice = message
        }
        launchEvents.append("[\(Date.now.formatted(date: .omitted, time: .standard))] \(message)")
        UIAccessibility.post(notification: .announcement, argument: message)
        inputNoticeTask?.cancel()
        inputNoticeTask = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(4)) } catch { return }
            withAnimation(.easeOut(duration: reduceMotion ? 0.15 : 0.2)) {
                inputNotice = nil
            }
        }
    }

    private func withOptionalAnimation(_ changes: () -> Void) {
        if reduceMotion {
            changes()
        } else {
            withAnimation(.easeInOut(duration: 0.22), changes)
        }
    }
}

private struct RuntimePlayerDiagnosticsView: View {
    let session: RuntimePlayerSession
    let configuration: RuntimePlayerBridgeConfiguration
    let controllerCount: Int
    let touchEventCount: Int
    let events: [String]
    let totalEntries: Int
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Log") {
                    Text("Latest \(events.count) of \(totalEntries) received entries").font(.caption)
                    ForEach(Array(events.enumerated().reversed()), id: \.offset) { _, event in
                        Text(event).font(.caption.monospaced()).textSelection(.enabled)
                    }
                    if let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
                        ShareLink("Export Full Log", item: RuntimeLogCapture.destinations(in: directory).logFileURL)
                    }
                }
                Section("Session") {
                    LabeledContent("Game", value: session.gameTitle)
                    LabeledContent("State", value: session.state.rawValue)
                    LabeledContent("Session", value: String(session.sessionIdentifier.prefix(8)))
                    Text(session.statusSummary)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Input") {
                    LabeledContent("Controllers", value: String(controllerCount))
                    LabeledContent("Touch Events", value: String(touchEventCount))
                }

                Section("Presentation") {
                    LabeledContent("Graphics", value: session.graphicsStack.rawValue)
                    LabeledContent(
                        "Surface",
                        value: "\(configuration.surfaceWidth) × \(configuration.surfaceHeight)"
                    )
                    LabeledContent("Audio driver", value: "winecoreaudio")
                }
            }
            .navigationTitle("View Log")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
                }
            }
        }
    }
}

#if os(iOS)
private struct RuntimeRenderHostView: UIViewRepresentable {
    let configuration: RuntimePlayerBridgeConfiguration
    let isRunning: Bool
    let onTouchEvents: (Int) -> Void
    let onFrameCount: (UInt64) -> Void
    let onFrameTiming: (FrameTiming) -> Void
    let onFirstFramePresented: () -> Void

    func makeUIView(context: Context) -> RuntimePlayerHostView {
        RuntimePlayerHostView(
            configuration: configuration,
            isRunning: isRunning,
            onTouchEvents: onTouchEvents,
            onFrameCount: onFrameCount,
            onFrameTiming: onFrameTiming,
            onFirstFramePresented: onFirstFramePresented
        )
    }

    func updateUIView(_ uiView: RuntimePlayerHostView, context: Context) {
        _ = context
        uiView.updateConfiguration(configuration, isRunning: isRunning)
    }

    static func dismantleUIView(_ uiView: RuntimePlayerHostView, coordinator: ()) {
        uiView.stop()
    }
}

#if MADEIRA_RUNTIME
private final class PlayerMetalLayer: CAMetalLayer {
    var didPresent: ((Double) -> Void)?

    override func nextDrawable() -> CAMetalDrawable? {
        guard let drawable = super.nextDrawable() else { return nil }
        drawable.addPresentedHandler { [weak self] presented in
            let time = presented.presentedTime
            DispatchQueue.main.async { self?.didPresent?(time) }
        }
        return drawable
    }
}
#endif

private final class RuntimePlayerHostView: UIView {
    #if MADEIRA_RUNTIME
    private let madeiraLayer = PlayerMetalLayer()
    private var pointerContact = MadeiraPointerContact()
    #endif
    private let imageView = UIImageView(frame: .zero)
    private let onTouchEvents: (Int) -> Void
    private var timing = FrameTiming()
    private let onFrameTiming: (FrameTiming) -> Void
    private let onFrameCount: (UInt64) -> Void
    private let onFirstFramePresented: () -> Void

    private var configuration: RuntimePlayerBridgeConfiguration
    private var inputBridge: RuntimePlayerInputBridge
    private var isRunning: Bool
    private var displayLink: CADisplayLink?
    private var lastFramebufferSignature = ""
    private var didSeedInitialFramebufferSignature = false
    private var presentedFrameCount = 0
    private var lastPresentedFrameAt: CFTimeInterval?
    private var pollTickCount = 0
    private var noChangeTickCount = 0
    private var lastPollDiagnosticAt: CFTimeInterval?
    private var didNotifyFirstPresentedFrame = false
    private var pendingTouchEventCount = 0
    private var lastTouchEventFlushAt: CFTimeInterval?
    private var touchEventFlushWorkItem: DispatchWorkItem?

    init(
        configuration: RuntimePlayerBridgeConfiguration,
        isRunning: Bool,
        onTouchEvents: @escaping (Int) -> Void,
        onFrameCount: @escaping (UInt64) -> Void,
        onFrameTiming: @escaping (FrameTiming) -> Void,
        onFirstFramePresented: @escaping () -> Void
    ) {
        self.configuration = configuration
        self.inputBridge = RuntimePlayerInputBridge(eventsPath: configuration.inputEventsPath)
        self.isRunning = isRunning
        self.onFrameTiming = onFrameTiming
        self.onFrameCount = onFrameCount
        self.onTouchEvents = onTouchEvents
        self.onFirstFramePresented = onFirstFramePresented
        super.init(frame: .zero)

        backgroundColor = UIColor(red: 0.04, green: 0.05, blue: 0.08, alpha: 1.0)
        imageView.contentMode = .scaleAspectFit
        imageView.backgroundColor = .clear
        addSubview(imageView)
        #if MADEIRA_RUNTIME
        if MadeiraRuntimeAdapter.enabled {
            if UIDevice.current.userInterfaceIdiom == .phone {
                // Scope the pointer interaction's tablet traits to the render view only.
                traitOverrides.userInterfaceIdiom = .pad
            }
            let hover = UIHoverGestureRecognizer(target: self, action: #selector(pointerHovered(_:)))
            hover.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
            addGestureRecognizer(hover)
            madeiraLayer.didPresent = { [weak self] time in
                self?.recordFrameTiming(time)
            }
            madeiraLayer.device = MTLCreateSystemDefaultDevice()
            madeiraLayer.pixelFormat = .bgra8Unorm
            madeiraLayer.framebufferOnly = true
            madeiraLayer.drawableSize = CGSize(width: 960, height: 540)
            layer.addSublayer(madeiraLayer)
            madeira_display_set_layer(madeiraLayer)
        }
        #endif
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        stop()
    }

    override var canBecomeFirstResponder: Bool {
        true
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        imageView.frame = bounds
        #if MADEIRA_RUNTIME
        if MadeiraRuntimeAdapter.enabled {
            madeiraLayer.frame = bounds
        }
        #endif
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            #if MADEIRA_RUNTIME
            if MadeiraRuntimeAdapter.enabled { MadeiraHardwareInput.stop() }
            #endif
            stopDisplayLink()
        } else {
            #if MADEIRA_RUNTIME
            if MadeiraRuntimeAdapter.enabled { MadeiraHardwareInput.start() }
            #endif
            _ = becomeFirstResponder()
            updateDisplayLinkForRunningState()
        }
    }

    override var keyCommands: [UIKeyCommand]? {
        #if MADEIRA_RUNTIME
        if MadeiraRuntimeAdapter.enabled { return [] }
        #endif
        return [
            UIKeyCommand(input: UIKeyCommand.inputUpArrow, modifierFlags: [], action: #selector(handleKeyCommand(_:))),
            UIKeyCommand(input: UIKeyCommand.inputDownArrow, modifierFlags: [], action: #selector(handleKeyCommand(_:))),
            UIKeyCommand(input: UIKeyCommand.inputLeftArrow, modifierFlags: [], action: #selector(handleKeyCommand(_:))),
            UIKeyCommand(input: UIKeyCommand.inputRightArrow, modifierFlags: [], action: #selector(handleKeyCommand(_:))),
            UIKeyCommand(input: " ", modifierFlags: [], action: #selector(handleKeyCommand(_:))),
            UIKeyCommand(input: "\r", modifierFlags: [], action: #selector(handleKeyCommand(_:))),
            UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(handleKeyCommand(_:))),
            UIKeyCommand(input: "w", modifierFlags: [], action: #selector(handleKeyCommand(_:))),
            UIKeyCommand(input: "a", modifierFlags: [], action: #selector(handleKeyCommand(_:))),
            UIKeyCommand(input: "s", modifierFlags: [], action: #selector(handleKeyCommand(_:))),
            UIKeyCommand(input: "d", modifierFlags: [], action: #selector(handleKeyCommand(_:))),
        ]
    }

    func updateConfiguration(_ configuration: RuntimePlayerBridgeConfiguration, isRunning: Bool) {
        let runningChanged = self.isRunning != isRunning
        self.isRunning = isRunning

        guard self.configuration != configuration else {
            if runningChanged {
                updateDisplayLinkForRunningState()
            }
            return
        }

        self.configuration = configuration
        inputBridge = RuntimePlayerInputBridge(eventsPath: configuration.inputEventsPath)
        lastFramebufferSignature = ""
        didSeedInitialFramebufferSignature = false
        presentedFrameCount = 0
        lastPresentedFrameAt = nil
        pollTickCount = 0
        noChangeTickCount = 0
        lastPollDiagnosticAt = nil
        didNotifyFirstPresentedFrame = false
        flushPendingTouchEvents()
        displayLink?.preferredFramesPerSecond = 5
        updateDisplayLinkForRunningState()
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        appendTouches(touches, phase: "began")
        super.touchesBegan(touches, with: event)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        appendTouches(touches, phase: "moved")
        super.touchesMoved(touches, with: event)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        appendTouches(touches, phase: "ended")
        super.touchesEnded(touches, with: event)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        appendTouches(touches, phase: "cancelled")
        super.touchesCancelled(touches, with: event)
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        appendPresses(presses, phase: "down")
        super.pressesBegan(presses, with: event)
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        appendPresses(presses, phase: "up")
        super.pressesEnded(presses, with: event)
    }

    @objc
    private func handleKeyCommand(_ command: UIKeyCommand) {
        guard isRunning else {
            return
        }

        let keyName = command.input ?? "unknown"
        inputBridge.appendKeyboard(name: keyName, phase: "down")
        inputBridge.appendKeyboard(name: keyName, phase: "up")
    }

    @objc
    private func renderFrameIfNeeded() {
        #if MADEIRA_RUNTIME
        if MadeiraRuntimeAdapter.enabled {
            let count = madeira_get_present_count()
            onFrameCount(count)
            if count > 0 && !didNotifyFirstPresentedFrame {
                didNotifyFirstPresentedFrame = true
                onFirstFramePresented()
            }
            return
        }
        #endif
        guard isRunning else {
            stopDisplayLink()
            return
        }

        onFrameCount(UInt64(presentedFrameCount))
        pollTickCount += 1
        let signature = framebufferSignature()
        if !didNotifyFirstPresentedFrame,
           FileManager.default.fileExists(atPath: configuration.frameReadyPath)
        {
            lastFramebufferSignature = signature
            noChangeTickCount = 0
            guard let image = loadFramebufferImage() else {
                return
            }
            imageView.image = image
            recordPresentedFrame()
            return
        }
        if !didSeedInitialFramebufferSignature {
            didSeedInitialFramebufferSignature = true
            lastFramebufferSignature = signature
            recordAwaitingFirstFramebufferUpdate()
            return
        }

        guard signature != lastFramebufferSignature else {
            recordUnchangedFramebufferPoll()
            return
        }

        lastFramebufferSignature = signature
        noChangeTickCount = 0
        guard let image = loadFramebufferImage() else {
            return
        }
        imageView.image = image
        recordPresentedFrame()
    }

    private func recordAwaitingFirstFramebufferUpdate() {
        lastPollDiagnosticAt = CACurrentMediaTime()
        RuntimeLogCapture.writeLine(
            "[IridiumRuntime] runtimePlayer: awaitingFirstFramebufferUpdate session=\(configuration.sessionIdentifier) pollTicks=\(pollTickCount) presentedFrames=\(presentedFrameCount) readyMarker=\(configuration.frameReadyPath) surface=\(configuration.surfaceWidth)x\(configuration.surfaceHeight)"
        )
    }

    private func recordUnchangedFramebufferPoll() {
        noChangeTickCount += 1
        let now = CACurrentMediaTime()
        let shouldLog =
            lastPollDiagnosticAt == nil
            || now - (lastPollDiagnosticAt ?? now) >= 2.0

        guard shouldLog else {
            return
        }

        lastPollDiagnosticAt = now
        RuntimeLogCapture.writeLine(
            "[IridiumRuntime] runtimePlayer: framePollNoChange session=\(configuration.sessionIdentifier) pollTicks=\(pollTickCount) unchangedTicks=\(noChangeTickCount) presentedFrames=\(presentedFrameCount) surface=\(configuration.surfaceWidth)x\(configuration.surfaceHeight)"
        )
    }

    private func recordFrameTiming(_ time: Double) {
        let previous = timing.updatedAt
        timing.record(time)
        if timing.updatedAt != previous { onFrameTiming(timing) }
    }

    private func recordPresentedFrame() {
        recordFrameTiming(CACurrentMediaTime())
        let now = CACurrentMediaTime()
        let delta = lastPresentedFrameAt.map { now - $0 }
        lastPresentedFrameAt = now
        presentedFrameCount += 1
        onFrameCount(UInt64(presentedFrameCount))
        lastPollDiagnosticAt = now
        if !didNotifyFirstPresentedFrame {
            didNotifyFirstPresentedFrame = true
            displayLink?.preferredFramesPerSecond = 30
            onFirstFramePresented()
        }

        if presentedFrameCount <= 3 || (delta ?? 0) >= 1.0 || presentedFrameCount.isMultiple(of: 30) {
            let deltaSummary = delta.map { String(format: "%.3f", $0) } ?? "initial"
            RuntimeLogCapture.writeLine(
                "[IridiumRuntime] runtimePlayer: framePresented session=\(configuration.sessionIdentifier) count=\(presentedFrameCount) deltaSeconds=\(deltaSummary) surface=\(configuration.surfaceWidth)x\(configuration.surfaceHeight)"
            )
        }
    }

    private func startDisplayLink() {
        guard displayLink == nil else {
            return
        }
        guard isRunning else {
            return
        }

        let link = CADisplayLink(target: self, selector: #selector(renderFrameIfNeeded))
        link.add(to: .main, forMode: .common)
        link.preferredFramesPerSecond = didNotifyFirstPresentedFrame ? 30 : 5
        displayLink = link
    }

    private func updateDisplayLinkForRunningState() {
        if isRunning, window != nil {
            startDisplayLink()
            renderFrameIfNeeded()
        } else {
            stopDisplayLink()
        }
    }

    func stop() {
        #if MADEIRA_RUNTIME
        if pointerContact.release() { winios_pointer(0, 0, 0x0004, 0) }
        #endif
        flushPendingTouchEvents()
        stopDisplayLink()
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    private func framebufferSignature() -> String {
        guard let attributes = try? FileManager.default.attributesOfItem(
            atPath: configuration.framebufferPath
        ) else {
            return "missing"
        }

        let modifiedAt = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        return "\(size)-\(modifiedAt)"
    }

    private func loadFramebufferImage() -> UIImage? {
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
            .union(.byteOrder32Little)

        guard let data = try? Data(
            contentsOf: URL(fileURLWithPath: configuration.framebufferPath),
            options: .mappedIfSafe
        ) else {
            return nil
        }

        let expectedBytes = configuration.surfaceWidth * configuration.surfaceHeight * 4
        guard data.count == expectedBytes else {
            return nil
        }

        guard let provider = CGDataProvider(data: data as CFData),
            let image = CGImage(
                width: configuration.surfaceWidth,
                height: configuration.surfaceHeight,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: configuration.surfaceWidth * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: bitmapInfo,
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
            )
        else {
            return nil
        }

        return UIImage(cgImage: image)
    }

    #if MADEIRA_RUNTIME
    @objc private func pointerHovered(_ recognizer: UIHoverGestureRecognizer) {
        guard MadeiraRuntimeAdapter.enabled, isRunning, !MadeiraHardwareInput.pointerCaptured,
              recognizer.state == .began || recognizer.state == .changed else { return }
        let point = recognizer.location(in: self)
        let size = madeiraLayer.drawableSize
        if let (x, y) = MadeiraPointerContact.position(
            x: Double(point.x / max(bounds.width, 1)), y: Double(point.y / max(bounds.height, 1)),
            width: Double(size.width), height: Double(size.height)
        ) { winios_pointer(x, y, 0x8001, 0) }
    }
    #endif

    private func appendTouches(_ touches: Set<UITouch>, phase: String) {
        guard isRunning else {
            return
        }

        #if MADEIRA_RUNTIME
        if MadeiraRuntimeAdapter.enabled {
            for touch in touches {
                if touch.type == .indirectPointer && MadeiraHardwareInput.pointerCaptured { continue }
                let point = touch.location(in: self)
                let size = madeiraLayer.drawableSize
                guard let (x, y) = MadeiraPointerContact.position(
                    x: Double(point.x / max(bounds.width, 1)), y: Double(point.y / max(bounds.height, 1)),
                    width: Double(size.width), height: Double(size.height)
                ) else { continue }
                let id = UInt64(UInt(bitPattern: Unmanaged.passUnretained(touch).toOpaque()))
                if let flags = pointerContact.flags(id: id, phase: phase) {
                    winios_pointer(x, y, flags, 0)
                    recordTouchEvents(1, phase: phase)
                }
            }
            return
        }
        #endif
        var appendedCount = 0
        for touch in touches {
            let location = touch.location(in: self)
            let normalizedX = bounds.width > 0 ? min(max(location.x / bounds.width, 0), 1) : 0
            let normalizedY = bounds.height > 0 ? min(max(location.y / bounds.height, 0), 1) : 0
            let identifier = UInt64(UInt(bitPattern: Unmanaged.passUnretained(touch).toOpaque()))
            inputBridge.appendTouch(
                identifier: identifier,
                phase: phase,
                normalizedX: normalizedX,
                normalizedY: normalizedY
            )
            appendedCount += 1
        }

        if appendedCount > 0 {
            recordTouchEvents(appendedCount, phase: phase)
        }
    }

    private func recordTouchEvents(_ count: Int, phase: String) {
        pendingTouchEventCount += count

        if phase == "began" || phase == "ended" || phase == "cancelled" {
            flushPendingTouchEvents()
            return
        }

        let now = CACurrentMediaTime()
        if let lastTouchEventFlushAt, now - lastTouchEventFlushAt < 0.25 {
            scheduleTouchEventFlush(after: 0.25 - (now - lastTouchEventFlushAt))
        } else {
            flushPendingTouchEvents(now: now)
        }
    }

    private func scheduleTouchEventFlush(after delay: CFTimeInterval) {
        guard touchEventFlushWorkItem == nil else {
            return
        }

        let workItem = DispatchWorkItem { [weak self] in
            self?.flushPendingTouchEvents()
        }
        touchEventFlushWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func flushPendingTouchEvents(now: CFTimeInterval = CACurrentMediaTime()) {
        touchEventFlushWorkItem?.cancel()
        touchEventFlushWorkItem = nil

        guard pendingTouchEventCount > 0 else {
            return
        }

        let count = pendingTouchEventCount
        pendingTouchEventCount = 0
        lastTouchEventFlushAt = now
        onTouchEvents(count)
    }

    private func appendPresses(_ presses: Set<UIPress>, phase: String) {
        guard isRunning else {
            return
        }

        #if MADEIRA_RUNTIME
        if MadeiraRuntimeAdapter.enabled { return }
        #endif
        for press in presses {
            inputBridge.appendKeyboard(name: keyName(for: press.type), phase: phase)
        }
    }

    private func keyName(for pressType: UIPress.PressType) -> String {
        switch pressType {
        case .upArrow:
            return "ArrowUp"
        case .downArrow:
            return "ArrowDown"
        case .leftArrow:
            return "ArrowLeft"
        case .rightArrow:
            return "ArrowRight"
        case .select:
            return "Return"
        case .menu:
            return "Escape"
        case .playPause:
            return "PlayPause"
        default:
            return "Press\(pressType.rawValue)"
        }
    }
}

private final class RuntimePlayerInputBridge {
    private let eventsPath: String
    private let queue = DispatchQueue(label: "com.iridium.runtime-player-input")
    private var nextSequence: UInt64 = 0
    private var lastDiagnosticAt: CFTimeInterval = 0
    private var writeFailureCount = 0
    private var fileHandle: FileHandle?

    init(eventsPath: String) {
        self.eventsPath = eventsPath
    }

    deinit {
        try? fileHandle?.close()
        fileHandle = nil
    }

    func close() {
        queue.async {
            try? self.fileHandle?.close()
            self.fileHandle = nil
        }
    }

    func appendTouch(identifier: UInt64, phase: String, normalizedX: CGFloat, normalizedY: CGFloat) {
        append(
            type: "touch",
            phase: phase,
            identifier: identifier,
            normalizedX: normalizedX,
            normalizedY: normalizedY,
            value: phase == "ended" || phase == "cancelled" ? 0 : 1,
            name: "finger"
        )
    }

    func appendKeyboard(name: String, phase: String) {
        append(
            type: "keyboard",
            phase: phase,
            identifier: 0,
            normalizedX: nil,
            normalizedY: nil,
            value: phase == "up" ? 0 : 1,
            name: name
        )
    }

    func appendControllerButton(name: String, pressed: Bool, value: Float) {
        append(
            type: "controllerButton",
            phase: pressed ? "down" : "up",
            identifier: 0,
            normalizedX: nil,
            normalizedY: nil,
            value: Double(value),
            name: name
        )
    }

    func appendControllerAxis(name: String, value: Float) {
        append(
            type: "controllerAxis",
            phase: "changed",
            identifier: 0,
            normalizedX: nil,
            normalizedY: nil,
            value: Double(value),
            name: name
        )
    }

    private func append(
        type: String,
        phase: String,
        identifier: UInt64,
        normalizedX: CGFloat?,
        normalizedY: CGFloat?,
        value: Double,
        name: String
    ) {
        #if MADEIRA_RUNTIME
        if MadeiraRuntimeAdapter.enabled {
            MadeiraRuntimeAdapter.input(type: type, phase: phase, x: normalizedX, y: normalizedY, value: value, name: name)
            return
        }
        #endif
        let submittedAt = CACurrentMediaTime()
        queue.async {
            let sequence = self.nextSequence
            self.nextSequence += 1

            let record = [
                String(sequence),
                type,
                phase,
                String(identifier),
                normalizedX.map { String(format: "%.6f", Double($0)) } ?? "",
                normalizedY.map { String(format: "%.6f", Double($0)) } ?? "",
                String(format: "%.6f", value),
                name,
            ].joined(separator: ",") + "\n"

            guard let data = record.data(using: .utf8) else {
                return
            }

            let url = URL(fileURLWithPath: self.eventsPath)
            var writeFailed = false
            do {
                let handle = try self.openFileHandle(forWritingTo: url)
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } catch {
                try? self.fileHandle?.close()
                self.fileHandle = nil
                if !self.writeWithOneShotAppend(data, to: url) {
                    writeFailed = true
                    self.writeFailureCount += 1
                }
            }
            self.recordInputWriteDiagnostic(
                sequence: sequence,
                type: type,
                phase: phase,
                submittedAt: submittedAt,
                writeFailed: writeFailed
            )
        }
    }

    private func openFileHandle(forWritingTo url: URL) throws -> FileHandle {
        if let fileHandle {
            return fileHandle
        }

        let handle = try FileHandle(forWritingTo: url)
        fileHandle = handle
        return handle
    }

    private func writeWithOneShotAppend(_ data: Data, to url: URL) -> Bool {
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }

        do {
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.close()
            return true
        } catch {
            return false
        }
    }

    private func recordInputWriteDiagnostic(
        sequence: UInt64,
        type: String,
        phase: String,
        submittedAt: CFTimeInterval,
        writeFailed: Bool
    ) {
        let now = CACurrentMediaTime()
        let queueLagMS = (now - submittedAt) * 1000
        let shouldLog =
            sequence < 5
            || sequence.isMultiple(of: 60)
            || queueLagMS >= 100
            || writeFailed
            || now - lastDiagnosticAt >= 2.0

        guard shouldLog else {
            return
        }

        lastDiagnosticAt = now
        RuntimeLogCapture.writeLine(
            "[IridiumRuntime] runtimePlayer: inputEventWritten sequence=\(sequence) type=\(type) phase=\(phase) queueLagMS=\(String(format: "%.1f", queueLagMS)) failures=\(writeFailureCount) path=\(eventsPath)"
        )
    }
}

@MainActor
private final class RuntimePlayerControllerBridge {
    static let shared = RuntimePlayerControllerBridge()

    private var controllerCountHandler: ((Int) -> Void)?
    private var notificationTokens: [NSObjectProtocol] = []
    private var inputBridge: RuntimePlayerInputBridge?
    private var trackedControllers: [ObjectIdentifier: GCController] = [:]

    func start(eventsPath: String, controllerCountDidChange: @escaping (Int) -> Void) {
        stop()
        inputBridge = RuntimePlayerInputBridge(eventsPath: eventsPath)
        controllerCountHandler = controllerCountDidChange

        notificationTokens = [
            NotificationCenter.default.addObserver(
                forName: .GCControllerDidConnect,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.refreshControllers()
                }
            },
            NotificationCenter.default.addObserver(
                forName: .GCControllerDidDisconnect,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.refreshControllers()
                }
            },
        ]

        refreshControllers()
    }

    func stop() {
        for token in notificationTokens {
            NotificationCenter.default.removeObserver(token)
        }
        notificationTokens.removeAll()

        for controller in trackedControllers.values {
            detachHandlers(from: controller)
        }
        trackedControllers.removeAll()
        controllerCountHandler = nil
        inputBridge = nil
    }

    private func refreshControllers() {
        let controllers = GCController.controllers()
        var nextControllers: [ObjectIdentifier: GCController] = [:]
        for controller in controllers {
            nextControllers[ObjectIdentifier(controller)] = controller
            if trackedControllers[ObjectIdentifier(controller)] == nil {
                attachHandlers(to: controller)
            }
        }

        for (identifier, controller) in trackedControllers where nextControllers[identifier] == nil {
            detachHandlers(from: controller)
        }

        trackedControllers = nextControllers
        controllerCountHandler?(trackedControllers.count)
    }

    private func attachHandlers(to controller: GCController) {
        if let extendedGamepad = controller.extendedGamepad {
            bind(button: extendedGamepad.buttonMenu, name: "buttonMenu")
            bind(button: extendedGamepad.buttonA, name: "buttonA")
            bind(button: extendedGamepad.buttonB, name: "buttonB")
            bind(button: extendedGamepad.buttonX, name: "buttonX")
            bind(button: extendedGamepad.buttonY, name: "buttonY")
            bind(button: extendedGamepad.leftShoulder, name: "leftShoulder")
            bind(button: extendedGamepad.rightShoulder, name: "rightShoulder")
            bind(button: extendedGamepad.leftTrigger, name: "leftTrigger")
            bind(button: extendedGamepad.rightTrigger, name: "rightTrigger")
            bind(direction: extendedGamepad.dpad.up, name: "dpadUp")
            bind(direction: extendedGamepad.dpad.down, name: "dpadDown")
            bind(direction: extendedGamepad.dpad.left, name: "dpadLeft")
            bind(direction: extendedGamepad.dpad.right, name: "dpadRight")
            bind(axis: extendedGamepad.leftThumbstick.xAxis, name: "leftThumbX")
            bind(axis: extendedGamepad.leftThumbstick.yAxis, name: "leftThumbY")
            bind(axis: extendedGamepad.rightThumbstick.xAxis, name: "rightThumbX")
            bind(axis: extendedGamepad.rightThumbstick.yAxis, name: "rightThumbY")
        } else if let microGamepad = controller.microGamepad {
            bind(button: microGamepad.buttonA, name: "buttonA")
            bind(button: microGamepad.buttonX, name: "buttonX")
            bind(direction: microGamepad.dpad.up, name: "dpadUp")
            bind(direction: microGamepad.dpad.down, name: "dpadDown")
            bind(direction: microGamepad.dpad.left, name: "dpadLeft")
            bind(direction: microGamepad.dpad.right, name: "dpadRight")
        }
    }

    private func detachHandlers(from controller: GCController) {
        #if MADEIRA_RUNTIME
        if MadeiraRuntimeAdapter.enabled { MadeiraRuntimeAdapter.releaseKeys() }
        #endif
        if let extendedGamepad = controller.extendedGamepad {
            clear(button: extendedGamepad.buttonMenu)
            clear(button: extendedGamepad.buttonA)
            clear(button: extendedGamepad.buttonB)
            clear(button: extendedGamepad.buttonX)
            clear(button: extendedGamepad.buttonY)
            clear(button: extendedGamepad.leftShoulder)
            clear(button: extendedGamepad.rightShoulder)
            clear(button: extendedGamepad.leftTrigger)
            clear(button: extendedGamepad.rightTrigger)
            clear(direction: extendedGamepad.dpad.up)
            clear(direction: extendedGamepad.dpad.down)
            clear(direction: extendedGamepad.dpad.left)
            clear(direction: extendedGamepad.dpad.right)
            clear(axis: extendedGamepad.leftThumbstick.xAxis)
            clear(axis: extendedGamepad.leftThumbstick.yAxis)
            clear(axis: extendedGamepad.rightThumbstick.xAxis)
            clear(axis: extendedGamepad.rightThumbstick.yAxis)
        } else if let microGamepad = controller.microGamepad {
            clear(button: microGamepad.buttonA)
            clear(button: microGamepad.buttonX)
            clear(direction: microGamepad.dpad.up)
            clear(direction: microGamepad.dpad.down)
            clear(direction: microGamepad.dpad.left)
            clear(direction: microGamepad.dpad.right)
        }
    }

    private func bind(button: GCControllerButtonInput, name: String) {
        button.valueChangedHandler = { [weak self] _, value, pressed in
            self?.inputBridge?.appendControllerButton(name: name, pressed: pressed, value: value)
        }
    }

    private func bind(direction: GCControllerButtonInput, name: String) {
        bind(button: direction, name: name)
    }

    private func bind(axis: GCControllerAxisInput, name: String) {
        axis.valueChangedHandler = { [weak self] _, value in
            self?.inputBridge?.appendControllerAxis(name: name, value: value)
        }
    }

    private func clear(button: GCControllerButtonInput) {
        button.valueChangedHandler = nil
    }

    private func clear(direction: GCControllerButtonInput) {
        clear(button: direction)
    }

    private func clear(axis: GCControllerAxisInput) {
        axis.valueChangedHandler = nil
    }
}
#endif

#endif
