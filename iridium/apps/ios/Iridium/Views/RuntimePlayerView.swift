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
    @State private var controlsVisible = false
    @State private var isDeviceKeyboardPresented = false
    @State private var isShowingDiagnostics = false
    @State private var isShowingControls = false
    @State private var showPerformance = true
    @AppStorage("IridiumMouseSensitivity") private var mouseSensitivity = 1.0
    @AppStorage("IridiumScrollSensitivity") private var scrollSensitivity = 1.0
    @State private var isConfirmingClose = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { safeGeometry in
        ControllerMenuHost(nativeNavigation: controlsVisible || isShowingControls || isShowingDiagnostics || isConfirmingClose, backAction: (controlsVisible || isShowingControls || isShowingDiagnostics || isConfirmingClose) ? {
            if isConfirmingClose { isConfirmingClose = false }
            else if isShowingControls { isShowingControls = false }
            else if isShowingDiagnostics { isShowingDiagnostics = false }
            else { controlsVisible = false }
        } : nil, fullScreen: true) {
        Group {
            if let bridgeConfiguration = presentationConfiguration ?? viewModel.runtimePlayerBridgeConfiguration(
                for: session.sessionIdentifier
            ) {
                    RuntimeRenderHostView(
                        configuration: bridgeConfiguration,
                        isRunning: session.state == .running,
                        deviceKeyboardPresented: isDeviceKeyboardPresented
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
                    } onDeviceKeyboardDismissed: {
                        isDeviceKeyboardPresented = false
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
                            .modifier(PlayerGlassButton()).focusable(false).accessibilityLabel("Player Menu")
                            if controlsVisible {
                                ScrollView {
                                VStack(alignment: .leading, spacing: 6) {
                                    Button("Resume", systemImage: "play") { controlsVisible = false }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                    Button("Controls", systemImage: "gamecontroller") { isShowingControls = true; controlsVisible = false }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                    Button(isDeviceKeyboardPresented ? "Hide Device Keyboard" : "Device Keyboard", systemImage: "keyboard") {
                                        isDeviceKeyboardPresented.toggle()
                                        controlsVisible = false
                                    }
                                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                    .accessibilityIdentifier("deviceKeyboardButton")
                                    #if MADEIRA_RUNTIME
                                    Stepper(value: $mouseSensitivity, in: 0.25...4, step: 0.25) {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text("Mouse sensitivity")
                                            Text(mouseSensitivity.formatted(.number.precision(.fractionLength(2))) + "×")
                                                .font(.caption).monospacedDigit()
                                        }
                                    }
                                    .accessibilityIdentifier("mouseSensitivity")
                                    Stepper(value: $scrollSensitivity, in: 0.25...4, step: 0.25) {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text("Scroll sensitivity")
                                            Text(scrollSensitivity.formatted(.number.precision(.fractionLength(2))) + "×")
                                                .font(.caption).monospacedDigit()
                                        }
                                    }
                                    .accessibilityIdentifier("scrollSensitivity")
                                    #endif
                                    Toggle("Performance", isOn: $showPerformance).frame(minHeight: 44)
                                    Button("View Log", systemImage: "doc.text") { isShowingDiagnostics = true; controlsVisible = false }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                    Button("Close Game", systemImage: "xmark", role: .destructive) { isConfirmingClose = true }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                }
                                .buttonStyle(.plain)
                                .controlSize(.large)
                                .frame(width: 250, alignment: .leading)
                                .padding(16)
                                }
                                .scrollBounceBehavior(.basedOnSize)
                                .frame(width: 282, height: min(410, max(100, safeGeometry.size.height - safeGeometry.safeAreaInsets.top - safeGeometry.safeAreaInsets.bottom - 80)))
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
                                Text(launchEvents.last ?? "Preparing the game…")
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
                .onChange(of: isDeviceKeyboardPresented) { _, _ in updatePointerCapture() }
                .onKeyPress(.escape) {
                    guard controlsVisible else { return .ignored }
                    controlsVisible = false
                    return .handled
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
                    isDeviceKeyboardPresented = false
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
                        Text("Closing game…")
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
        onCaptureChange(
            !controlsVisible
                && !isDeviceKeyboardPresented
                && !isShowingDiagnostics
                && !isShowingControls
                && !isConfirmingClose
        )
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
    let deviceKeyboardPresented: Bool
    let onTouchEvents: (Int) -> Void
    let onFrameCount: (UInt64) -> Void
    let onFrameTiming: (FrameTiming) -> Void
    let onFirstFramePresented: () -> Void
    let onDeviceKeyboardDismissed: () -> Void

    func makeUIView(context: Context) -> RuntimePlayerHostView {
        RuntimePlayerHostView(
            configuration: configuration,
            isRunning: isRunning,
            deviceKeyboardPresented: deviceKeyboardPresented,
            onTouchEvents: onTouchEvents,
            onFrameCount: onFrameCount,
            onFrameTiming: onFrameTiming,
            onFirstFramePresented: onFirstFramePresented,
            onDeviceKeyboardDismissed: onDeviceKeyboardDismissed
        )
    }

    func updateUIView(_ uiView: RuntimePlayerHostView, context: Context) {
        _ = context
        uiView.updateConfiguration(configuration, isRunning: isRunning)
        uiView.setDeviceKeyboardPresented(deviceKeyboardPresented)
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

private final class RuntimePlayerHostView: UIView, UITextFieldDelegate {
    #if MADEIRA_RUNTIME
    private let madeiraLayer = PlayerMetalLayer()
    private var pointerContact = MadeiraPointerContact()
    #endif
    private let imageView = UIImageView(frame: .zero)
    private let deviceKeyboardField = UITextField(frame: .zero)
    private let onTouchEvents: (Int) -> Void
    private var timing = FrameTiming()
    private let onFrameTiming: (FrameTiming) -> Void
    private let onFrameCount: (UInt64) -> Void
    private let onFirstFramePresented: () -> Void
    private let onDeviceKeyboardDismissed: () -> Void

    private var configuration: RuntimePlayerBridgeConfiguration
    private var inputBridge: RuntimePlayerInputBridge
    private var isRunning: Bool
    private var deviceKeyboardPresented: Bool
    private var keyboardOverlap: CGFloat = 0
    private var keyboardObservers: [NSObjectProtocol] = []
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
        deviceKeyboardPresented: Bool,
        onTouchEvents: @escaping (Int) -> Void,
        onFrameCount: @escaping (UInt64) -> Void,
        onFrameTiming: @escaping (FrameTiming) -> Void,
        onFirstFramePresented: @escaping () -> Void,
        onDeviceKeyboardDismissed: @escaping () -> Void
    ) {
        self.configuration = configuration
        self.inputBridge = RuntimePlayerInputBridge(eventsPath: configuration.inputEventsPath)
        self.isRunning = isRunning
        self.deviceKeyboardPresented = deviceKeyboardPresented
        self.onFrameTiming = onFrameTiming
        self.onFrameCount = onFrameCount
        self.onTouchEvents = onTouchEvents
        self.onFirstFramePresented = onFirstFramePresented
        self.onDeviceKeyboardDismissed = onDeviceKeyboardDismissed
        super.init(frame: .zero)

        backgroundColor = UIColor(red: 0.04, green: 0.05, blue: 0.08, alpha: 1.0)
        imageView.contentMode = .scaleAspectFit
        imageView.backgroundColor = .clear
        addSubview(imageView)

        deviceKeyboardField.delegate = self
        deviceKeyboardField.autocorrectionType = .no
        deviceKeyboardField.autocapitalizationType = .none
        deviceKeyboardField.spellCheckingType = .no
        deviceKeyboardField.smartQuotesType = .no
        deviceKeyboardField.smartDashesType = .no
        deviceKeyboardField.keyboardType = .asciiCapable
        deviceKeyboardField.textContentType = .none
        deviceKeyboardField.textColor = .clear
        deviceKeyboardField.tintColor = .clear
        deviceKeyboardField.backgroundColor = .clear
        deviceKeyboardField.alpha = 0.01
        deviceKeyboardField.isAccessibilityElement = false
        addSubview(deviceKeyboardField)

        let center = NotificationCenter.default
        keyboardObservers = [
            center.addObserver(
                forName: UIResponder.keyboardWillChangeFrameNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                self?.handleKeyboardFrameChange(notification)
            },
            center.addObserver(
                forName: UIResponder.keyboardWillHideNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                self?.handleKeyboardWillHide(notification)
            },
        ]

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
            // Keep the guest drawable fixed. Device-keyboard presentation only changes layer.frame.
            madeiraLayer.drawableSize = MadeiraResolution.selected.size
            layer.addSublayer(madeiraLayer)
            madeira_display_set_layer(madeiraLayer)
            addInteraction(UIPointerInteraction(delegate: self))
        }
        #endif
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        for observer in keyboardObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        stop()
    }

    override var canBecomeFirstResponder: Bool {
        true
    }

    private var renderViewportFrame: CGRect {
        guard keyboardOverlap > 0 else {
            return bounds
        }

        let available = CGRect(
            x: bounds.minX,
            y: bounds.minY,
            width: bounds.width,
            height: max(bounds.height - keyboardOverlap, 1)
        )
        let guestWidth = CGFloat(max(configuration.surfaceWidth, 1))
        let guestHeight = CGFloat(max(configuration.surfaceHeight, 1))
        let scale = min(available.width / guestWidth, available.height / guestHeight)
        let width = max(guestWidth * scale, 1)
        let height = max(guestHeight * scale, 1)
        return CGRect(
            x: available.midX - width / 2,
            y: available.midY - height / 2,
            width: width,
            height: height
        )
    }

    private func normalizedRenderPoint(_ point: CGPoint) -> CGPoint {
        let viewport = renderViewportFrame
        return CGPoint(
            x: viewport.width > 0
                ? min(max((point.x - viewport.minX) / viewport.width, 0), 1)
                : 0,
            y: viewport.height > 0
                ? min(max((point.y - viewport.minY) / viewport.height, 0), 1)
                : 0
        )
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let viewport = renderViewportFrame
        imageView.frame = viewport
        deviceKeyboardField.frame = CGRect(x: viewport.minX, y: viewport.minY, width: 1, height: 1)
        #if MADEIRA_RUNTIME
        if MadeiraRuntimeAdapter.enabled {
            madeiraLayer.frame = viewport
            winios_cursor_attach(madeiraLayer)
        }
        #endif
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            if deviceKeyboardField.isFirstResponder {
                _ = deviceKeyboardField.resignFirstResponder()
            }
            keyboardOverlap = 0
            #if MADEIRA_RUNTIME
            if MadeiraRuntimeAdapter.enabled { MadeiraHardwareInput.stop(); winios_cursor_attach(nil) }
            #endif
            stopDisplayLink()
        } else {
            #if MADEIRA_RUNTIME
            if MadeiraRuntimeAdapter.enabled { MadeiraHardwareInput.start() }
            #endif
            updateDeviceKeyboardPresentation()
            updateDisplayLinkForRunningState()
        }
    }

    override var keyCommands: [UIKeyCommand]? {
        #if MADEIRA_RUNTIME
        if MadeiraRuntimeAdapter.enabled {
            guard MadeiraHardwareInput.acceptingInput else { return [] }
            let escape = UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(consumeGameEscape))
            escape.wantsPriorityOverSystemBehavior = true
            return [escape]
        }
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

    #if MADEIRA_RUNTIME
    // GCKeyboard and pressesBegan/Ended deliver the key. Consume its system action only.
    @objc private func consumeGameEscape() {}
    #endif

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
        setNeedsLayout()
        updateDisplayLinkForRunningState()
    }

    func setDeviceKeyboardPresented(_ presented: Bool) {
        guard deviceKeyboardPresented != presented else {
            if presented {
                updateDeviceKeyboardPresentation()
            }
            return
        }

        deviceKeyboardPresented = presented
        updateDeviceKeyboardPresentation()
    }

    private func updateDeviceKeyboardPresentation() {
        guard window != nil else {
            return
        }

        if deviceKeyboardPresented {
            deviceKeyboardField.text = ""
            if !deviceKeyboardField.isFirstResponder {
                _ = deviceKeyboardField.becomeFirstResponder()
            }
        } else {
            if deviceKeyboardField.isFirstResponder {
                _ = deviceKeyboardField.resignFirstResponder()
            }
            updateKeyboardOverlap(0, notification: nil)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window != nil, !self.deviceKeyboardPresented else { return }
                _ = self.becomeFirstResponder()
            }
        }
    }

    private func handleKeyboardFrameChange(_ notification: Notification) {
        guard deviceKeyboardPresented, deviceKeyboardField.isFirstResponder,
              let endFrame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
        else {
            return
        }

        let localFrame = convert(endFrame, from: nil)
        let overlap = bounds.intersects(localFrame)
            ? max(0, bounds.maxY - max(bounds.minY, localFrame.minY))
            : 0
        updateKeyboardOverlap(overlap, notification: notification)
    }

    private func handleKeyboardWillHide(_ notification: Notification) {
        guard deviceKeyboardField.isFirstResponder || deviceKeyboardPresented else {
            return
        }
        updateKeyboardOverlap(0, notification: notification)
    }

    private func updateKeyboardOverlap(_ overlap: CGFloat, notification: Notification?) {
        let clamped = min(max(overlap, 0), bounds.height)
        guard abs(clamped - keyboardOverlap) > 0.5 else {
            return
        }

        keyboardOverlap = clamped
        setNeedsLayout()

        let duration = (notification?.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? NSNumber)?.doubleValue ?? 0.25
        let curveValue = (notification?.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? NSNumber)?.uintValue ?? 7
        let options = UIView.AnimationOptions(rawValue: UInt(curveValue) << 16).union(.beginFromCurrentState)
        UIView.animate(withDuration: duration, delay: 0, options: options) {
            self.layoutIfNeeded()
        }
    }

    func textFieldDidEndEditing(_ textField: UITextField) {
        guard textField === deviceKeyboardField else { return }
        let shouldNotify = deviceKeyboardPresented
        deviceKeyboardPresented = false
        updateKeyboardOverlap(0, notification: nil)
        if shouldNotify {
            onDeviceKeyboardDismissed()
        }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window != nil, !self.deviceKeyboardPresented else { return }
            _ = self.becomeFirstResponder()
        }
    }

    func textField(
        _ textField: UITextField,
        shouldChangeCharactersIn range: NSRange,
        replacementString string: String
    ) -> Bool {
        guard textField === deviceKeyboardField else { return false }
        if string.isEmpty, range.length > 0 {
            postDeviceKeyboardBackspace()
        } else if !string.isEmpty {
            postDeviceKeyboardText(string)
        }
        return false
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        guard textField === deviceKeyboardField else { return false }
        postDeviceKeyboardText("\n")
        return false
    }

    private func postDeviceKeyboardText(_ text: String) {
        guard isRunning else { return }

        #if MADEIRA_RUNTIME
        if MadeiraRuntimeAdapter.enabled {
            for character in text {
                guard let (virtualKey, needsShift) = Self.virtualKey(forDeviceKeyboardCharacter: character) else {
                    continue
                }
                if needsShift { winios_post_key(0x10, 1) }
                winios_post_key(virtualKey, 1)
                winios_post_key(virtualKey, 0)
                if needsShift { winios_post_key(0x10, 0) }
            }
            return
        }
        #endif

        for character in text {
            let name: String
            switch character {
            case "\n", "\r": name = "Return"
            case "\t": name = "Tab"
            case " ": name = "Space"
            default: name = String(character)
            }
            inputBridge.appendKeyboard(name: name, phase: "down")
            inputBridge.appendKeyboard(name: name, phase: "up")
        }
    }

    private func postDeviceKeyboardBackspace() {
        guard isRunning else { return }

        #if MADEIRA_RUNTIME
        if MadeiraRuntimeAdapter.enabled {
            winios_post_key(0x08, 1)
            winios_post_key(0x08, 0)
            return
        }
        #endif

        inputBridge.appendKeyboard(name: "Backspace", phase: "down")
        inputBridge.appendKeyboard(name: "Backspace", phase: "up")
    }

    #if MADEIRA_RUNTIME
    private static func virtualKey(forDeviceKeyboardCharacter character: Character) -> (Int32, Bool)? {
        if character == "\n" || character == "\r" { return (0x0D, false) }
        if character == "\t" { return (0x09, false) }
        if character == " " { return (0x20, false) }
        if character.isLetter,
           let uppercase = character.uppercased().first?.asciiValue,
           uppercase >= 0x41, uppercase <= 0x5A
        {
            return (Int32(uppercase), character.isUppercase)
        }
        if let ascii = character.asciiValue, ascii >= 0x30, ascii <= 0x39 {
            return (Int32(ascii), false)
        }
        let table: [Character: (Int32, Bool)] = [
            "!": (0x31, true), "@": (0x32, true), "#": (0x33, true), "$": (0x34, true),
            "%": (0x35, true), "^": (0x36, true), "&": (0x37, true), "*": (0x38, true),
            "(": (0x39, true), ")": (0x30, true),
            "-": (0xBD, false), "_": (0xBD, true),
            "=": (0xBB, false), "+": (0xBB, true),
            "[": (0xDB, false), "{": (0xDB, true),
            "]": (0xDD, false), "}": (0xDD, true),
            "\\": (0xDC, false), "|": (0xDC, true),
            ";": (0xBA, false), ":": (0xBA, true),
            "'": (0xDE, false), "\"": (0xDE, true),
            ",": (0xBC, false), "<": (0xBC, true),
            ".": (0xBE, false), ">": (0xBE, true),
            "/": (0xBF, false), "?": (0xBF, true),
            "`": (0xC0, false), "~": (0xC0, true),
        ]
        return table[character]
    }
    #endif

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        appendTouches(touches, phase: "began", event: event)
        super.touchesBegan(touches, with: event)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        appendTouches(touches, phase: "moved", event: event)
        super.touchesMoved(touches, with: event)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        appendTouches(touches, phase: "ended", event: event)
        super.touchesEnded(touches, with: event)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        appendTouches(touches, phase: "cancelled", event: event)
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

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        appendPresses(presses, phase: "up")
        super.pressesCancelled(presses, with: event)
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
        setDeviceKeyboardPresented(false)
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
        guard recognizer.state == .began || recognizer.state == .changed else { return }
        moveSystemPointer(to: recognizer.location(in: self))
    }

    private var loggedSystemPointer = false
    fileprivate func moveSystemPointer(to point: CGPoint) {
        guard MadeiraRuntimeAdapter.enabled, isRunning, MadeiraHardwareInput.acceptingInput,
              !MadeiraHardwareInput.usesRawMouse else { return }
        let size = madeiraLayer.drawableSize
        let normalized = normalizedRenderPoint(point)
        if let (x, y) = MadeiraPointerContact.position(
            x: Double(normalized.x), y: Double(normalized.y),
            width: Double(size.width), height: Double(size.height)
        ) {
            winios_pointer(x, y, 0x8001, 0)
            if !loggedSystemPointer {
                loggedSystemPointer = true
                RuntimeLogCapture.writeLine("[Launch] UIKit pointer position received; absolute mouse routing active.")
            }
        }
    }
    #endif

    private var pointerButtons: [UInt64: UInt32] = [:]

    private func appendTouches(_ touches: Set<UITouch>, phase: String, event: UIEvent?) {
        guard isRunning else {
            return
        }

        #if MADEIRA_RUNTIME
        if MadeiraRuntimeAdapter.enabled {
            for touch in touches {
                if touch.type == .indirectPointer {
                    let id = UInt64(UInt(bitPattern: Unmanaged.passUnretained(touch).toOpaque()))
                    // UIKit can deliver trackpad buttons even when GCMouse does not.
                    // Keep absolute coordinates out of the relative mouse path.
                    moveSystemPointer(to: touch.location(in: self))
                    if phase == "began" {
                        let flag: UInt32 = event?.buttonMask.contains(.secondary) == true ? 0x0008 : 0x0002
                        pointerButtons[id] = flag
                        MadeiraHardwareInput.mouseButton(flag: flag, pressed: true)
                    } else if phase == "ended" || phase == "cancelled" {
                        if let flag = pointerButtons.removeValue(forKey: id) {
                            MadeiraHardwareInput.mouseButton(flag: flag, pressed: false)
                        }
                    }
                    continue
                }
                let point = touch.location(in: self)
                let normalized = normalizedRenderPoint(point)
                let size = madeiraLayer.drawableSize
                guard let (x, y) = MadeiraPointerContact.position(
                    x: Double(normalized.x), y: Double(normalized.y),
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
            let normalized = normalizedRenderPoint(touch.location(in: self))
            let identifier = UInt64(UInt(bitPattern: Unmanaged.passUnretained(touch).toOpaque()))
            inputBridge.appendTouch(
                identifier: identifier,
                phase: phase,
                normalizedX: normalized.x,
                normalizedY: normalized.y
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
        if MadeiraRuntimeAdapter.enabled {
            for press in presses {
                if let key = press.key {
                    MadeiraHardwareInput.key(hid: Int(key.keyCode.rawValue), pressed: phase == "down")
                }
            }
            return
        }
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

#if MADEIRA_RUNTIME
extension RuntimePlayerHostView: UIPointerInteractionDelegate {
    func pointerInteraction(_ interaction: UIPointerInteraction, regionFor request: UIPointerRegionRequest,
                            defaultRegion: UIPointerRegion) -> UIPointerRegion? {
        moveSystemPointer(to: request.location)
        return defaultRegion
    }

    func pointerInteraction(_ interaction: UIPointerInteraction, styleFor region: UIPointerRegion) -> UIPointerStyle? {
        // Wine owns cursor appearance and visibility inside the game image.
        return UIPointerStyle.hidden()
    }
}
#endif
