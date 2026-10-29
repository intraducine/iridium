import SwiftUI
import UniformTypeIdentifiers
import UIKit
import Darwin
import ImageIO
import Combine

// IRIDIUM-OWNED-UNIT
struct LibraryLargeTitle: ToolbarContent {
    var body: some ToolbarContent {
        if #available(iOS 26.0, *) {
            ToolbarItem(placement: .topBarLeading) { LibraryTitleText() }.sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .topBarLeading) { LibraryTitleText() }
        }
    }
}

/// The title, then a bolt for JIT: a thin outline in the title's colour until
/// the debugger is attached, then filled in the accent colour (LibraryJITState;
/// the SF Symbols replace effect animates the change).
/// The bolt is as tall as the title's capitals and centred on them: an SF
/// Symbol at the title's own size is nearly twice the height of its M.
struct LibraryTitleText: View {
    @ObservedObject private var alignment = LibraryHeaderAlignment.shared
    @ObservedObject private var jitState = LibraryJITState.shared
    var body: some View {
        let jit = jitState.enabled
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(LibraryHeaderAlignment.title).accessibilityAddTraits(.isHeader)
            Image(systemName: jit ? "bolt.fill" : "bolt")
                .font(.system(size: LibraryHeaderAlignment.titleFont().pointSize * 0.53, weight: .thin))
                .foregroundStyle(jit ? Color.accentColor : Color.primary)
                .contentTransition(.symbolEffect(.replace))
                .alignmentGuide(.firstTextBaseline) { d in d.height / 2 + LibraryHeaderAlignment.titleFont().capHeight / 2 }
                .accessibilityLabel(jit ? "JIT enabled" : "JIT not enabled")
        }
        .font(.largeTitle.bold())
        .fixedSize()
        .offset(x: alignment.shift)
        .background(LibraryTitleAnchor())   // after the offset: marks where the text is laid out
    }
}

/// Whether JIT is available (the debugger is attached), checked every 2 s like
/// LibraryStatus. Shared by the title's bolt and the Enable JIT buttons, which
/// are disabled once it is.
final class LibraryJITState: ObservableObject {
    static let shared = LibraryJITState()
    @Published private(set) var enabled = ir_jit_memory_ready() || StikJITHelper.ready
    private var timer: Timer?
    private init() {
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(timer, forMode: .common)   // keeps ticking while a list scrolls
        self.timer = timer
    }
    func refresh() {
        let now = ir_jit_memory_ready() || StikJITHelper.ready
        guard now != enabled else { return }
        withAnimation(UIAccessibility.isReduceMotionEnabled ? nil : .default) { enabled = now }
    }
}

/// Lines the large title's first letter up with the search field below it. The
/// navigation bar's leading inset differs between iOS versions (the title sat
/// 4 pt inside the field on iOS 26.2 and level with its edge on iOS 27, before
/// the glyph's own side bearing), so the offset is measured: the field's leading
/// edge and the title's frame, both in window coordinates, less the side
/// bearing of the title's first glyph. Checked in the iOS 26.2 and iOS 27
/// simulators: the M starts on the field's edge to the pixel on both.
final class LibraryHeaderAlignment: ObservableObject {
    static let shared = LibraryHeaderAlignment()
    static let title = "Madeira"
    @Published private(set) var shift: CGFloat = 0
    weak var field: UIView?
    weak var anchor: UIView?
    private var pending = false

    /// Called from layout passes; measures once they have finished, when the
    /// search field and the title are both at their final positions.
    func update() {
        guard !pending else { return }
        pending = true
        DispatchQueue.main.async { self.pending = false; self.measure(retries: 0) }
    }
    private func measure(retries: Int) {
        guard let field, let anchor, let window = field.window, anchor.window === window else { return }
        guard field.bounds.width > 0, anchor.bounds.width > 0 else {   // not laid out yet
            if retries < 20 { DispatchQueue.main.async { self.measure(retries: retries + 1) } }
            return
        }
        let fieldX = field.convert(field.bounds, to: nil).minX
        let titleX = anchor.convert(anchor.bounds, to: nil).minX
        let scale = window.screen.scale
        let target = ((fieldX - titleX - Self.inkInset()) * scale).rounded() / scale
        if abs(target - shift) > 0.01 { shift = target }
    }

    /// The title's font: the large title style, bold, at the current text size.
    static func titleFont() -> UIFont {
        let base = UIFontDescriptor.preferredFontDescriptor(withTextStyle: .largeTitle)
        return UIFont(descriptor: base.withSymbolicTraits(.traitBold) ?? base, size: 0)
    }

    /// How far the first glyph's ink starts right of the text's origin, in the
    /// title's font.
    static func inkInset() -> CGFloat {
        let font = titleFont() as CTFont
        guard var unit = title.utf16.first else { return 0 }
        var glyph: CGGlyph = 0
        guard CTFontGetGlyphsForCharacters(font, &unit, &glyph, 1) else { return 0 }
        var rect = CGRect.zero
        CTFontGetBoundingRectsForGlyphs(font, .horizontal, &glyph, &rect, 1)
        return rect.minX
    }
}

/// Marks where the title's text is laid out (before its alignment offset).
struct LibraryTitleAnchor: UIViewRepresentable {
    func makeUIView(context: Context) -> Anchor { Anchor() }
    func updateUIView(_ view: Anchor, context: Context) {}
    final class Anchor: UIView {
        override init(frame: CGRect) { super.init(frame: frame); isUserInteractionEnabled = false }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func didMoveToWindow() { super.didMoveToWindow(); report() }
        override func layoutSubviews() { super.layoutSubviews(); report() }
        private func report() {
            guard window != nil else { return }
            LibraryHeaderAlignment.shared.anchor = self
            LibraryHeaderAlignment.shared.update()
        }
    }
}

/// A search controller whose bar reports its layout to LibraryHeaderAlignment.
final class ReportingSearchController: UISearchController {
    private lazy var reportingBar = ReportingSearchBar()
    override var searchBar: UISearchBar { reportingBar }
}
final class ReportingSearchBar: UISearchBar {
    override func layoutSubviews() {
        super.layoutSubviews()
        LibraryHeaderAlignment.shared.field = searchTextField
        LibraryHeaderAlignment.shared.update()
    }
}

/// The library's search field: the system search bar (Liquid Glass on iOS 26),
/// stacked under the navigation bar at full width, with the Madeira title and
/// the toolbar buttons on the row above it. A UISearchController on the
/// NavigationStack's own navigation item: `.searchable` shows nothing here (the
/// TabView sits inside the NavigationStack). Removed again when the library
/// goes away, so the developer screen has no search bar. Checked in the iOS
/// simulator: the title and the toolbar buttons share a centre line, and the
/// field spans the screen on both tabs.
struct LibraryNavSearch: UIViewControllerRepresentable {
    @Binding var text: String
    let placeholder: String

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIViewController(context: Context) -> Host {
        let host = Host()
        host.coordinator = context.coordinator
        return host
    }
    func updateUIViewController(_ host: Host, context: Context) {
        context.coordinator.parent = self
        host.apply()
        // SwiftUI rebuilds the navigation item when the toolbar changes (the
        // library's buttons leave with the Settings tab) and can drop the search
        // controller on the way; put it back once that update has landed.
        DispatchQueue.main.async { host.apply() }
    }
    static func dismantleUIViewController(_ host: Host, coordinator: Coordinator) { host.remove() }

    final class Coordinator: NSObject, UISearchResultsUpdating, UISearchBarDelegate, UIGestureRecognizerDelegate {
        var parent: LibraryNavSearch
        let controller = ReportingSearchController(searchResultsController: nil)
        private var outsideTap: UITapGestureRecognizer?
        var bar: UISearchBar { controller.searchBar }

        init(_ parent: LibraryNavSearch) {
            self.parent = parent
            super.init()
            controller.obscuresBackgroundDuringPresentation = false
            controller.hidesNavigationBarDuringPresentation = false
            controller.searchResultsUpdater = self
            bar.delegate = self
            bar.autocapitalizationType = .none
            bar.autocorrectionType = .no
            bar.returnKeyType = .search
        }
        func updateSearchResults(for searchController: UISearchController) {
            let t = searchController.searchBar.text ?? ""
            if t != parent.text { parent.text = t }
        }
        func searchBarSearchButtonClicked(_ searchBar: UISearchBar) { searchBar.resignFirstResponder() }

        // While the field is being edited, any tap outside it closes the keyboard.
        // The tap still reaches whatever was tapped (cancelsTouchesInView = false).
        func searchBarTextDidBeginEditing(_ searchBar: UISearchBar) {
            guard outsideTap == nil, let window = searchBar.window else { return }
            let tap = UITapGestureRecognizer(target: self, action: #selector(tappedOutside))
            tap.cancelsTouchesInView = false
            tap.delegate = self
            window.addGestureRecognizer(tap)
            outsideTap = tap
        }
        func searchBarTextDidEndEditing(_ searchBar: UISearchBar) {
            if let tap = outsideTap { tap.view?.removeGestureRecognizer(tap) }
            outsideTap = nil
        }
        @objc private func tappedOutside() { bar.resignFirstResponder() }

        /// A tab switch squeezes the field a little and lets it spring back, like
        /// a Liquid Glass control answering a touch (there is no public call that
        /// plays the glass's own touch response). The system spring, on the bar's
        /// layer only, so the navigation bar's layout never sees a transform.
        /// Checked in the iOS 27 simulator (at 4%; now 1.5%): in, a slight overshoot,
        /// settled in about half a second, running alongside the toolbar's glass morph.
        func squeeze() {
            guard !UIAccessibility.isReduceMotionEnabled else { return }
            let layer = bar.layer
            let now = layer.convertTime(CACurrentMediaTime(), from: nil)
            let squeezed = 0.985, inTime = 0.12
            let back = CASpringAnimation(perceptualDuration: 0.5, bounce: 0.5)
            back.keyPath = "transform.scale"
            back.fromValue = squeezed
            back.toValue = 1
            back.beginTime = now + inTime
            back.duration = back.settlingDuration
            back.fillMode = .backwards   // holds the squeezed size until it starts
            let inward = CABasicAnimation(keyPath: "transform.scale")
            inward.fromValue = 1
            inward.toValue = squeezed
            inward.beginTime = now
            inward.duration = inTime
            inward.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.add(back, forKey: "madeira.search.squeeze.back")
            layer.add(inward, forKey: "madeira.search.squeeze.in")   // added last: shown over the held spring
        }
        func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            !(touch.view?.isDescendant(of: bar) ?? false)
        }
        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    }

    final class Host: UIViewController {
        weak var coordinator: Coordinator?
        private weak var owner: UIViewController?
        override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); apply() }

        func apply() {
            guard let c = coordinator else { return }
            if c.bar.text != c.parent.text { c.bar.text = c.parent.text }
            if c.bar.placeholder != c.parent.placeholder {
                if c.bar.placeholder != nil {   // a tab switch: crossfade instead of jumping
                    let fade = CATransition(); fade.type = .fade; fade.duration = 0.25
                    c.bar.searchTextField.layer.add(fade, forKey: "madeira.search.fade")
                    c.squeeze()
                }
                c.bar.placeholder = c.parent.placeholder
            }
            // The NavigationStack's own view controller owns the navigation item.
            var vc: UIViewController? = self
            while let v = vc, !(v.parent is UINavigationController) { vc = v.parent }
            guard let target = vc else { return }
            owner = target
            let item = target.navigationItem
            if item.searchController !== c.controller { item.searchController = c.controller }
            if item.preferredSearchBarPlacement != .stacked { item.preferredSearchBarPlacement = .stacked }
            if item.hidesSearchBarWhenScrolling { item.hidesSearchBarWhenScrolling = false }
            // iOS 26 otherwise moves it to the bottom of an iPhone screen, beside the tab bar.
            if #available(iOS 26.0, *), item.searchBarPlacementAllowsToolbarIntegration {
                item.searchBarPlacementAllowsToolbarIntegration = false
            }
        }
        func remove() {
            coordinator?.bar.resignFirstResponder()
            if let owner, owner.navigationItem.searchController === coordinator?.controller { owner.navigationItem.searchController = nil }
        }
    }
}

struct SteamMatch: Decodable, Identifiable {
    let id: Int
    let name: String
    let tiny_image: String?
}

/// The public Steam store: title search and store artwork for an app ID. No
/// account, credentials, or private library access.
enum SteamCatalog {
    static func search(_ text: String) async throws -> [SteamMatch] {
        var url = URLComponents(string: "https://store.steampowered.com/api/storesearch/")!
        url.queryItems = [URLQueryItem(name: "term", value: text), URLQueryItem(name: "l", value: "english"), URLQueryItem(name: "cc", value: "US")]
        var request = URLRequest(url: url.url!); request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, data.count < 2_000_000 else {
            throw LibraryError.message("Steam search is unavailable. You can still edit the title and artwork manually.")
        }
        struct Results: Decodable { var items: [SteamMatch] }
        return Array(try JSONDecoder().decode(Results.self, from: data).items.prefix(30))
    }
    static func cover(_ id: Int) -> URL? { URL(string: "https://cdn.cloudflare.steamstatic.com/steam/apps/\(id)/library_600x900.jpg") }
    static func hero(_ id: Int) -> URL? { URL(string: "https://cdn.cloudflare.steamstatic.com/steam/apps/\(id)/library_hero.jpg") }
}

struct LibraryArtwork: View {
    let entry: LibraryEntry
    var backdrop = false
    var body: some View { IridiumGameArtwork(game: IridiumGame(windows: entry), backdrop: backdrop) }
}

/// A pseudo-random sequence from a seed (SplitMix64), so each card's "movie" is its own
/// but stays the same for the whole run.
struct AmbientRandom {
    private var state: UInt64
    init(seed: Int) { state = UInt64(bitPattern: Int64(seed)) &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func unit() -> Double {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Double(z >> 11) / Double(1 << 53)
    }
}

/// The light a TV's ambient LED strip throws on the wall as a film plays, for a still
/// piece of artwork, sampled around the ring of light (`samples` points, clockwise).
///
/// - Brightness: arcs of the ring flare up or fall into shadow independently, each at
///   its own place, width and strength, rising (sometimes at once, like a cut),
///   drifting and fading over two to six seconds; six at a time, a third of them
///   shadows, over a moderate base level, so the ring is never lit uniformly.
/// - Colour: the ring's colours travel. Two soft zones sweep around it, one showing
///   the artwork turned half round (its colours from the opposite side), one showing it
///   mirrored (left and right swapped), and at each scene cut they jump and change
///   strength; the whole light also drifts slightly in hue.
struct AmbientMovie {
    static let samples = 36
    struct Frame {
        var hue: Double
        var light: [Double]
        var turned: [Double]
        var mirrored: [Double]
    }
    private struct Scene { var length, level, hue, turned, turnedShift, mirrored, mirroredShift: Double }
    private struct Slot { var period, offset: Double }
    private let seed: Int
    private let scenes: [Scene]
    private let slots: [Slot]
    private let total: Double
    private let phase: Double
    private let turnSpeed: Double
    private let mirrorSpeed: Double

    init(seed: Int) {
        var r = AmbientRandom(seed: seed)
        var scenes: [Scene] = []
        for _ in 0..<12 {
            scenes.append(Scene(length: 3.2 + r.unit() * 5.0, level: 0.45 + r.unit() * 0.3, hue: (r.unit() - 0.5) * 24,
                                turned: 0.1 + r.unit() * 0.5, turnedShift: r.unit() * 2 * .pi,
                                mirrored: 0.1 + r.unit() * 0.45, mirroredShift: r.unit() * 2 * .pi))
        }
        self.scenes = scenes
        slots = (0..<6).map { _ in Slot(period: 2.0 + r.unit() * 4.5, offset: r.unit() * 10) }
        total = scenes.reduce(0) { $0 + $1.length }
        phase = r.unit() * total
        turnSpeed = (r.unit() < 0.5 ? -1 : 1) * (0.12 + r.unit() * 0.23)
        mirrorSpeed = (r.unit() < 0.5 ? -1 : 1) * (0.1 + r.unit() * 0.2)
        self.seed = seed
    }

    /// One flare or shadow on the ring, for one life of its slot.
    private func event(slot: Int, life: Int) -> (center: Double, width: Double, amount: Double, drift: Double, rise: Double) {
        var r = AmbientRandom(seed: seed &* 1_000_003 &+ slot &* 7_919 &+ life)
        let center = r.unit() * 2 * .pi
        let width = 0.25 + r.unit() * 1.5
        let amount = r.unit() < 0.35 ? -(0.2 + r.unit() * 0.3) : 0.3 + r.unit() * 0.5
        return (center, width, amount, (r.unit() - 0.5) * 1.4, 0.04 + r.unit() * 0.3)
    }

    func frame(at time: Double) -> Frame {
        let t = (time + phase).truncatingRemainder(dividingBy: total)
        var start = 0.0, i = 0
        while i < scenes.count - 1 && start + scenes[i].length <= t { start += scenes[i].length; i += 1 }
        let now = scenes[i], before = scenes[(i + scenes.count - 1) % scenes.count]
        let x = min(1, (t - start) / 0.4)            // a scene cut, eased over 0.4 s
        let k = x * x * (3 - 2 * x)
        func mix(_ a: Double, _ b: Double) -> Double { a + (b - a) * k }
        func mixAngle(_ a: Double, _ b: Double) -> Double { a + remainder(b - a, 2 * .pi) * k }
        let p = phase
        let level = mix(before.level, now.level) + 0.035 * sin(time * 1.7 + p) + 0.025 * sin(time * 3.9 + p * 1.9)
        let hue = mix(before.hue, now.hue) + 3 * sin(time * 0.35 + p)
        let turnedAt = mixAngle(before.turnedShift, now.turnedShift) + turnSpeed * time
        let mirroredAt = mixAngle(before.mirroredShift, now.mirroredShift) + mirrorSpeed * time
        let turnedStrength = mix(before.turned, now.turned), mirroredStrength = mix(before.mirrored, now.mirrored)

        var bumps: [(center: Double, width: Double, amount: Double)] = []
        for (n, slot) in slots.enumerated() {
            let lives = (time + slot.offset) / slot.period
            let f = lives - lives.rounded(.down)
            let e = event(slot: n, life: Int(lives.rounded(.down)))
            let env: Double
            if f < e.rise { let y = f / e.rise; env = y * y * (3 - 2 * y) }
            else { env = pow(1 - (f - e.rise) / (1 - e.rise), 1.6) }
            bumps.append((e.center + e.drift * f, e.width, e.amount * env))
        }

        let n = Self.samples
        var light = [Double](repeating: 0, count: n), turned = light, mirrored = light
        for s in 0..<n {
            let a = Double(s) / Double(n) * 2 * .pi
            var v = level
            for b in bumps {
                let d = remainder(a - b.center, 2 * .pi), sigma = b.width / 2
                v += b.amount * exp(-(d * d) / (2 * sigma * sigma))
            }
            light[s] = max(0.12, min(1, v))
            turned[s] = turnedStrength * pow(0.5 + 0.5 * cos(a - turnedAt), 2)
            mirrored[s] = mirroredStrength * pow(0.5 + 0.5 * cos(2 * (a - mirroredAt)), 2)
        }
        return Frame(hue: hue, light: light, turned: turned, mirrored: mirrored)
    }

    /// Values around the ring as an angular mask, closed at the seam.
    static func mask(_ values: [Double]) -> AngularGradient {
        var stops = values.enumerated().map { Gradient.Stop(color: .black.opacity($1), location: Double($0) / Double(values.count)) }
        stops.append(.init(color: .black.opacity(values[0]), location: 1))
        return AngularGradient(stops: stops, center: .center)
    }
}

/// The faint rays in a card's light: beams fanning out from the artwork's centre,
/// each its own width and brightness (seeded, so a card keeps its own). Subtle on
/// purpose: the gaps between them stay nearly as bright as the beams, and they are
/// softened, so the glow reads as light with a little texture, not as stripes.
struct AmbientRays: View {
    let seed: Int
    /// Degrees the beams are turned by; the glow sways them slowly.
    var turn: Double = 0
    /// The same beams, crisp and contrasty: the light focused down while its card is pressed.
    var sharp = false
    private static let count = 60

    var body: some View {
        let floor = sharp ? 0.1 : 0.72
        var r = AmbientRandom(seed: seed &* 31 &+ 7)
        var stops: [Gradient.Stop] = []
        var at = 0.0
        while at < 1 {
            let width = (0.5 + r.unit()) / Double(Self.count)
            let level = floor + (1 - floor) * pow(r.unit(), 0.7)
            stops.append(.init(color: .black.opacity(level), location: at))
            stops.append(.init(color: .black.opacity(level), location: min(1, at + width * 0.55)))
            at += width
        }
        stops.append(.init(color: stops[0].color, location: 1))
        return AngularGradient(stops: stops, center: .center, angle: .degrees(turn))
            .blur(radius: sharp ? 0.6 : 3)
    }
}

/// Ambient light around a card's artwork, as an LED strip behind a TV lights the wall:
/// the artwork itself, a little larger and blurred, so each edge's colours spill from
/// that edge. Three versions of it are drawn once each (drawingGroup): as it is, turned
/// half round, and mirrored, which have the same outline but the colours in other
/// places; AmbientMovie blends them around the ring and lights arcs of it, and only
/// those masks, a slight hue drift and the rays' sway move, at 30 frames a second.
/// Dark appearance adds the light (plusLighter), as light does on a dark wall; light
/// appearance tints more softly. Reduce Motion holds it still.
struct AmbientGlow: View {
    let image: Image
    let size: CGSize
    let seed: Int
    var dimmed = false
    /// The card is pressed: the light closes like a spotlight's aperture, drawing in
    /// toward the artwork with its rays turning crisp, and goes out behind the shrunken
    /// artwork; on release it opens back up slowly.
    var pressed = false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private func layer(_ angle: Double, _ mirror: Bool, frame: CGSize) -> some View {
        func art() -> some View {
            image.resizable().scaledToFill()
                .frame(width: size.width, height: size.height).clipped()
                .rotationEffect(.degrees(angle))
                .scaleEffect(x: mirror ? -1 : 1, y: 1)
        }
        // A soft wash on the wall, and the brighter band just past the edge where the
        // strip's light lands first.
        return ZStack {
            art().scaleEffect(1.09).blur(radius: size.width * 0.07)
            art().scaleEffect(1.03).blur(radius: size.width * 0.03).opacity(0.75)
        }
        .frame(width: frame.width, height: frame.height)
        // On a light page the blurred art's mid-tones read as grey: lifted and more
        // vivid there, it reads as coloured light.
        .saturation(dimmed ? 1.15 : (scheme == .dark ? 1.5 : 1.9))
        .brightness(scheme == .dark ? 0 : (dimmed ? 0.04 : 0.12))
        .drawingGroup()
    }

    var body: some View {
        // Kept tight, so neighbouring cards' light stays apart in the gaps between them.
        let spread = size.width * 0.17
        let frame = CGSize(width: size.width + spread * 2, height: size.height + spread * 2)
        let movie = AmbientMovie(seed: seed)
        let dark = scheme == .dark
        // A game that is not installed throws a fainter, less vivid light.
        let strength = (dark ? 0.92 : 0.8) * (dimmed ? 0.3 : 1)
        let plain = layer(0, false, frame: frame), turned = layer(180, false, frame: frame), mirrored = layer(0, true, frame: frame)
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let f = movie.frame(at: reduceMotion ? 0 : t)
            ZStack {
                plain
                turned.mask { AmbientMovie.mask(f.turned) }
                mirrored.mask { AmbientMovie.mask(f.mirrored) }
            }
            .compositingGroup()
            .hueRotation(.degrees(f.hue))
            // In the dark the light adds to the page (plusLighter): a very bright artwork's
            // light is brought down at the top (AmbientGlow.metal) so it does not glare.
            // ml1219: off on a light page, where a knee of 0 left every pixel as it was.
            .colorEffect(ShaderLibrary.ambientKnee(.float(0.3)), isEnabled: dark)
            .mask { AmbientMovie.mask(f.light) }
            .mask {
                let turn = reduceMotion ? 0 : 1.2 * sin(t * 0.12 + Double(seed % 97))
                ZStack {
                    AmbientRays(seed: seed, turn: turn).opacity(pressed ? 0 : 1)
                    AmbientRays(seed: seed, turn: turn, sharp: true).opacity(pressed ? 1 : 0)
                }
                // The rays sharpen first, then the light draws in and goes out.
                .animation(pressed ? .easeOut(duration: 0.2) : .easeIn(duration: 0.9), value: pressed)
            }
            // Closed, the light's outer edge sits inside the shrunken artwork.
            .scaleEffect(pressed ? LibraryCardArtworkPress.pressedScale * size.width / frame.width : 1)
            .animation(pressed ? .easeInOut(duration: 0.55) : .easeInOut(duration: 1.6), value: pressed)
            .opacity(strength * (pressed ? 0 : 1))
            .animation(pressed ? .easeIn(duration: 0.6) : .easeOut(duration: 1.3), value: pressed)
            .blendMode(dark ? .plusLighter : .normal)
        }
        .frame(width: frame.width, height: frame.height)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// What a card's glow is made of: the same artwork the card shows.
enum AmbientArt {
    case steam(Int)
    case library(LibraryEntry)
}

/// A grid card's artwork frame and what its glow is made of, reported up to the
/// library, which draws every glow in one layer behind all the cards
/// (AmbientGlowLayer): a card's own background would be painted over its
/// neighbours by the cards after it.
struct AmbientGlowItem: Identifiable {
    let id: String
    let seed: Int
    let art: AmbientArt
    var dimmed = false
    var pressed = false
    let bounds: Anchor<CGRect>
}

struct AmbientGlowKey: PreferenceKey {
    static let defaultValue: [AmbientGlowItem] = []
    static func reduce(value: inout [AmbientGlowItem], nextValue: () -> [AmbientGlowItem]) { value += nextValue() }
}

/// The library's ambient light: a glow behind every grid card that has reported
/// its frame (only the cards the lazy grids have built). MADEIRA_LIBRARY_AMBIENT=0
/// turns it off.
struct AmbientGlowLayer: View {
    static let enabled = MadeiraConfig.flag("MADEIRA_LIBRARY_AMBIENT")
    let items: [AmbientGlowItem]
    var body: some View {
        if Self.enabled {
            GeometryReader { proxy in
                var seen = Set<String>()
                let unique = items.filter { seen.insert($0.id).inserted }
                ForEach(unique) { item in AmbientGlowCard(item: item, frame: proxy[item.bounds]) }
            }
        }
    }
}

/// One card's glow, once its artwork is loaded.
private struct AmbientGlowCard: View {
    let item: AmbientGlowItem
    let frame: CGRect
    @State private var image: UIImage?
    var body: some View {
        ZStack {
            if let image = image ?? AmbientArtwork.cached(item.id) {
                AmbientGlow(image: Image(uiImage: image), size: frame.size, seed: item.seed, dimmed: item.dimmed, pressed: item.pressed)
            } else {
                Color.clear.frame(width: 1, height: 1)
            }
        }
        .position(x: frame.midX, y: frame.midY)
        .task(id: item.id) { if image == nil { image = await AmbientArtwork.load(item) } }
    }
}

/// A card's artwork for its glow: loaded once, shrunk (the glow blurs it anyway) and
/// kept, so the glow's three layers share one small bitmap instead of each decoding
/// the full artwork.
@MainActor
enum AmbientArtwork {
    private static let cache = NSCache<NSString, UIImage>()

    static func cached(_ id: String) -> UIImage? { cache.object(forKey: id as NSString) }

    static func load(_ item: AmbientGlowItem) async -> UIImage? {
        if let hit = cached(item.id) { return hit }
        var image: UIImage?
        switch item.art {
        case .steam(let appID):
            for url in SteamGamesRules.artwork(appID: appID, owned: { SteamOwnedLibrary.shared.game($0) }) {
                if let found = await fetch(url) { image = found; break }
            }
        case .library(let entry):
            if let name = entry.coverFile {
                image = UIImage(contentsOfFile: LibraryModel.documents
                    .appendingPathComponent("madeira-art/" + URL(fileURLWithPath: name).lastPathComponent).path)
            } else if let id = entry.steamID ?? entry.steamAppID, let url = SteamCatalog.cover(id) {
                image = await fetch(url)
            }
        }
        guard let image, image.size.width > 0 else { return nil }
        let size = CGSize(width: 96, height: (96 * image.size.height / image.size.width).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let small = UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        cache.setObject(small, forKey: item.id as NSString)
        return small
    }

    private static func fetch(_ url: URL) async -> UIImage? {
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return UIImage(data: data)
    }
}

/// Whether the app's liquid metal is on: Settings › Appearance › Liquid metal, kept in
/// madeira.cfg as env.MADEIRA_LIQUID_METAL (off, plain Liquid Glass, unless it is 1). It
/// covers the Desktop button's fill (LiquidMetalFill) and the bars' glass (GlassSkin), and
/// applies at once, fading between the two.
@MainActor final class LiquidMetalSetting: ObservableObject {
    static let shared = LiquidMetalSetting()
    @Published var on = MadeiraConfig.flag("MADEIRA_LIQUID_METAL", fallback: false) {
        didSet {
            guard on != oldValue else { return }
            MadeiraConfig.set("env.MADEIRA_LIQUID_METAL", on ? "1" : nil)
            if on { GlassSkin.shared.start(fadeIn: true) } else { GlassSkin.shared.stop() }
        }
    }
}

/// A flowing liquid-chrome fill (LiquidMetal.metal, a SwiftUI color shader): white
/// highlights, silver and navy, rainbow dispersion at the highlights' edges and a raised
/// rim, in a capsule (a rounded box of radius half its height). Animated at 60 frames a
/// second; held still with Reduce Motion. Its callers draw their previous fill when liquid
/// metal is off (LiquidMetalSetting).
struct LiquidMetalFill: View {
    @Environment(\.displayScale) private var displayScale
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            TimelineView(.animation(minimumInterval: 1.0 / 60, paused: reduceMotion)) { context in
                // Kept small, so the shader's float time stays precise.
                let time = Float(context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3600))
                Rectangle()
                    .colorEffect(ShaderLibrary.liquidMetal(.float2(geometry.size), .float(reduceMotion ? 0 : time),
                                                           .float(Float(displayScale)), .float(scheme == .light ? 1 : 0)))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct LibraryCardPressedKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    /// Whether the library card this view is in is being pressed (LibraryCardButtonStyle).
    var libraryCardPressed: Bool {
        get { self[LibraryCardPressedKey.self] }
        set { self[LibraryCardPressedKey.self] = newValue }
    }
}

/// The grid cards' button style: no highlight of its own; the card's artwork shows the
/// press (LibraryCardArtworkPress) and its ambient light closes around it.
struct LibraryCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.environment(\.libraryCardPressed, configuration.isPressed)
    }
}

extension View {
    /// A library card's button style: a grid card shows its press on its artwork
    /// (LibraryCardButtonStyle); a list row keeps the plain style.
    @ViewBuilder func libraryCardButtonStyle(grid: Bool) -> some View {
        if grid { buttonStyle(LibraryCardButtonStyle()) } else { buttonStyle(.plain) }
    }
}

/// A grid card's artwork: shrinks while its card is pressed and springs back on
/// release, and reports its frame (unscaled) and its press to the library's ambient
/// light (AmbientGlowLayer).
struct LibraryCardArtworkPress: ViewModifier {
    static let pressedScale: CGFloat = 0.94
    @Environment(\.libraryCardPressed) private var pressed
    let glow: (_ pressed: Bool, _ bounds: Anchor<CGRect>) -> AmbientGlowItem
    func body(content: Content) -> some View {
        content
            .scaleEffect(pressed ? Self.pressedScale : 1)
            .animation(pressed ? .spring(response: 0.26, dampingFraction: 0.86) : .spring(response: 0.42, dampingFraction: 0.58),
                       value: pressed)
            .anchorPreference(key: AmbientGlowKey.self, value: .bounds) { [glow(pressed, $0)] }
    }
}

struct LibraryBadges: View {
    let entry: LibraryEntry
    /// A state pill after the format pills (a Steam game's "Update").
    var note: String? = nil
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 4) { format; size }
            VStack(alignment: .leading, spacing: 4) { format; size }
        }
    }
    private var format: some View {
        HStack(spacing: 4) {
            if entry.bits == 32 || entry.bits == 64 { badge("\(entry.bits)-bit") }
            if entry.isBatch { badge("Batch") }   // ml1163
            if let api = LibraryRendererBadge.compact(entry.graphicsAPI) { badge(api) }
            if let note { badge(note) }
        }
    }
    @ViewBuilder private var size: some View {
        if let bytes = entry.folderBytes { badge(String(format: bytes < 1_000_000_000 ? "%.2f GB" : "%.1f GB", Double(bytes) / 1_000_000_000)) }
    }
    private func badge(_ text: String) -> some View {
        Text(text).font(.caption2.weight(.medium)).lineLimit(1).minimumScaleFactor(0.8)
            .padding(.horizontal, 5).padding(.vertical, 4)
            .background(.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
    }
}

/// JIT and Memory+ at the top of Settings, each with a green check or a red cross (the
/// developer interface's badges), and "Ready to play" beside them once both are there.
/// Checked every 2 s.
struct LibraryStatus: View {
    @State private var jit = false
    @State private var memory = false
    let ticks = Timer.publish(every: 2, on: .main, in: .common).autoconnect()
    var body: some View {
        HStack(spacing: 8) {
            badge("JIT", jit)
            badge("Memory+", memory)
            if jit && memory {
                Text("Ready to play").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                    .padding(.leading, 4)
            }
        }
        .onAppear { update() }.onReceive(ticks) { _ in update() }
    }
    private func badge(_ label: String, _ enabled: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: enabled ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(enabled ? Color.green : Color.red)
            Text(label).foregroundStyle(enabled ? .primary : .secondary)
        }
        .font(.footnote)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background((enabled ? Color.green : Color.red).opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
        .accessibilityElement(children: .ignore).accessibilityLabel("\(label): \(enabled ? "enabled" : "unavailable")")
    }
    private func update() { jit = StikJITHelper.ready; memory = EntitlementStatus.check().increasedMemory }
}

/// A section title with a count; with `collapsed` set, tapping the title
/// collapses or expands the section (the state is the caller's, persisted).
struct LibrarySectionHeader<Trailing: View>: View {
    let title: String
    var count: Int?
    var collapsed: Binding<Bool>? = nil
    @ViewBuilder var trailing: Trailing
    var body: some View {
        if let collapsed {
            HStack(alignment: .firstTextBaseline) {
                Button {
                    withAnimation(UIAccessibility.isReduceMotionEnabled ? nil : .easeInOut(duration: 0.2)) { collapsed.wrappedValue.toggle() }
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(title).font(.title2.bold())
                        if let count, count > 0 { Text("\(count)").font(.subheadline).foregroundStyle(.secondary) }
                        Image(systemName: "chevron.right").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                            .rotationEffect(.degrees(collapsed.wrappedValue ? 0 : 90))
                    }.contentShape(Rectangle()).frame(minHeight: 44)
                }.buttonStyle(.plain)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityValue(collapsed.wrappedValue ? "Collapsed" : "Expanded")
                Spacer()
                trailing
            }
        } else {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.title2.bold())
                if let count, count > 0 { Text("\(count)").font(.subheadline).foregroundStyle(.secondary) }
                Spacer()
                trailing
            }.accessibilityElement(children: .combine).accessibilityAddTraits(.isHeader)
        }
    }
}

/// A section's cards or rows in the library's layout ("cards", "compact",
/// "list" or "compactList"): every section of the library page uses it.
struct LibraryCells<Item: Identifiable, Cell: View>: View {
    let items: [Item]
    let layout: String
    let width: CGFloat
    @ViewBuilder let cell: (_ item: Item, _ list: Bool, _ dense: Bool) -> Cell
    var body: some View {
        if layout == "list" || layout == "compactList" {
            let dense = layout == "compactList"
            LazyVStack(spacing: dense ? 4 : 8) { ForEach(items) { item in cell(item, true, dense) } }
        } else {
            let compact = layout == "compact"
            let width = max(1, min(self.width, 1100) - 32)
            let count = max(1, Int((width + 12) / (compact ? 110 : 154)))
            let cardWidth = min(compact ? 115.0 : 164.0, (width - CGFloat(count - 1) * 12) / CGFloat(count))
            // The width the cards leave goes into the gaps (up to 34 pt), so the grid
            // nearly spans the margins and each card's ambient light keeps to its own space.
            let gap = count > 1 ? max(12, min(34, (width - CGFloat(count) * cardWidth) / CGFloat(count - 1))) : 12
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(cardWidth), spacing: gap, alignment: .top), count: count), alignment: .center, spacing: 18) {
                ForEach(items) { item in cell(item, false, false) }
            }.frame(maxWidth: .infinity, alignment: .center)
        }
    }
}

// MARK: - Group by rules (Foundation only; tests/host/check-library-groups.py compiles this part)

/// The library's Group by choice: "platform" is the sections (LibraryView);
/// "played" groups by when a game was last played, "installed" into Installed
/// and Not installed, and "none" is one grid. Those three list the games you
/// added and Steam's games together, each group in the library's Sort by order.
enum LibraryGrouping {
    enum Source: Hashable {
        case entry(UUID), steam(Int)
        var key: String {
            switch self {
            case .entry(let id): return "entry:" + id.uuidString
            case .steam(let appID): return "steam:\(appID)"
            }
        }
    }

    /// One game of any source, as far as the groups and the sort need it.
    struct Game: Identifiable, Equatable {
        let source: Source
        var title: String
        /// On disk; a Steam game being downloaded counts, as under the Steam title.
        var installed: Bool
        var lastPlayed: Date?
        var bytes: Int64?
        /// Its library entry's place in the library file (later is newer); nil without one.
        var position: Int?
        var id: Source { source }
    }

    struct Group: Identifiable, Equatable {
        let id: String
        /// nil: no header (Group by None).
        let title: String?
        var games: [Game]
    }

    /// Sort by ("played", "name", "added" or "size") as the library sorts the games
    /// you added: a game without a library entry sorts as never played, of unknown
    /// size and, for "added", after the games that have one; ties go by name.
    static func sorted(_ games: [Game], by sort: String) -> [Game] {
        games.sorted { a, b in
            switch sort {
            case "played":
                if a.lastPlayed != b.lastPlayed { return (a.lastPlayed ?? .distantPast) > (b.lastPlayed ?? .distantPast) }
            case "added":
                if a.position != b.position { return (a.position ?? -1) > (b.position ?? -1) }
            case "size":
                if a.bytes != b.bytes { return (a.bytes ?? -1) > (b.bytes ?? -1) }
            default:
                break
            }
            let order = a.title.localizedStandardCompare(b.title)
            return order == .orderedSame ? a.source.key < b.source.key : order == .orderedAscending
        }
    }

    /// The groups of a Group by choice other than "platform", in page order,
    /// without empty ones. Last played: today, the past 7 and 30 days (counted
    /// from the start of today), earlier, then never played.
    static func groups(_ games: [Game], by grouping: String, sort: String,
                       now: Date = Date(), calendar: Calendar = .current) -> [Group] {
        let games = sorted(games, by: sort)
        var groups: [Group]
        switch grouping {
        case "played":
            let today = calendar.startOfDay(for: now)
            let week = calendar.date(byAdding: .day, value: -6, to: today) ?? today
            let month = calendar.date(byAdding: .day, value: -29, to: today) ?? today
            groups = [Group(id: "today", title: "Today", games: []), Group(id: "week", title: "Past 7 days", games: []),
                      Group(id: "month", title: "Past 30 days", games: []), Group(id: "earlier", title: "Earlier", games: []),
                      Group(id: "never", title: "Never played", games: [])]
            for game in games {
                let index: Int
                if let played = game.lastPlayed {
                    index = played >= today ? 0 : played >= week ? 1 : played >= month ? 2 : 3
                } else {
                    index = 4
                }
                groups[index].games.append(game)
            }
        case "installed":
            groups = [Group(id: "installed", title: "Installed", games: games.filter(\.installed)),
                      Group(id: "notInstalled", title: "Not installed", games: games.filter { !$0.installed })]
        default:
            groups = [Group(id: "all", title: nil, games: games)]
        }
        return groups.filter { !$0.games.isEmpty }
    }

    /// The collapsed groups' ids, stored comma-separated ("played.today,installed.notInstalled").
    static func collapsed(_ stored: String) -> Set<String> {
        Set(stored.split(separator: ",").map(String.init))
    }

    static func storing(_ collapsed: Set<String>) -> String { collapsed.sorted().joined(separator: ",") }
}

// MARK: - Group by view

extension LibraryGrouping.Game {
    /// A game you added; `position` is its index in LibraryModel.entries.
    init(entry: LibraryEntry, position: Int) {
        self.init(source: .entry(entry.id), title: entry.title, installed: true,
                  lastPlayed: entry.lastPlayed, bytes: entry.folderBytes, position: position)
    }
}

/// The library page under a Group by other than Platform: the games you added
/// and Steam's games in one set of groups (LibraryGrouping). A card opens as in
/// its own section: a game you added or an installed Steam game its Game details
/// page, any other Steam game its download sheet. Not installed Steam games are
/// listed only while signed in.
struct LibraryGroupedGames<LocalCell: View>: View {
    let grouping: String
    let search: String
    var layout = "cards"
    var sort = "played"
    var width: CGFloat = 390
    /// Opens a game's Game details page (LibraryView's details sheet).
    let open: (LibraryEntry) -> Void
    /// A game you added: LibraryView's own card, with its controller focus.
    @ViewBuilder let localCell: (_ entry: LibraryEntry, _ list: Bool, _ dense: Bool) -> LocalCell
    @ObservedObject private var library = LibraryModel.shared
    @ObservedObject private var steamGames = SteamGamesModel.shared
    @ObservedObject private var steam = SteamOwnedLibrary.shared
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("madeiraLibraryCollapsedGroups") private var collapsedGroups = ""
    @State private var steamSheet: SteamSelection?

    private struct SteamSelection: Identifiable { let id: Int }

    private struct Sources {
        var games: [LibraryGrouping.Game] = []
        var entries: [UUID: LibraryEntry] = [:]
        var steam: [Int: SteamGamesRules.Item] = [:]
    }

    private var sources: Sources {
        var result = Sources()
        let query = search.trimmingCharacters(in: .whitespaces)
        var steamEntries: [Int: (position: Int, entry: LibraryEntry)] = [:]
        for (position, entry) in library.entries.enumerated() where entry.desktop != true {
            if let appID = entry.steamAppID { steamEntries[appID] = (position, entry) }
            else if query.isEmpty || entry.title.localizedCaseInsensitiveContains(query) {
                result.entries[entry.id] = entry
                result.games.append(LibraryGrouping.Game(entry: entry, position: position))
            }
        }
        if SteamGamesSection.shown {
            let enabled = SteamOwnedLibrary.enabled
            let downloading = Set(steam.downloads.keys)
            for item in SteamGamesRules.items(installed: steamGames.games, owned: enabled ? steam.owned : [], search: query) {
                let installed = item.installed != nil || downloading.contains(item.id)
                guard installed || (enabled && steam.signedIn) else { continue }
                let recorded = steamEntries[item.id]
                let steamPlayed = steam.playtime[item.id].flatMap {
                    $0.lastPlayed > 0 ? Date(timeIntervalSince1970: TimeInterval($0.lastPlayed)) : nil
                }
                result.steam[item.id] = item
                result.games.append(LibraryGrouping.Game(source: .steam(item.id), title: item.name, installed: installed,
                                                         lastPlayed: [recorded?.entry.lastPlayed, steamPlayed].compactMap { $0 }.max(),
                                                         bytes: recorded?.entry.folderBytes, position: recorded?.position))
            }
        }
        return result
    }

    var body: some View {
        let sources = self.sources
        let groups = LibraryGrouping.groups(sources.games, by: grouping, sort: sort)
        let collapsed = LibraryGrouping.collapsed(collapsedGroups)
        VStack(alignment: .leading, spacing: 24) {
            if groups.isEmpty {
                if search.isEmpty {
                    ContentUnavailableView("No Windows Games", systemImage: "gamecontroller", description: Text("Copy a game's folder into Madeira › wine › drive_c with the Files app, then tap + and choose its .exe."))
                } else {
                    Text("No games match your search.").foregroundStyle(.secondary)
                }
            }
            ForEach(groups) { group in
                let key = grouping + "." + group.id
                VStack(alignment: .leading, spacing: 14) {
                    if let title = group.title {
                        LibrarySectionHeader(title: title, count: group.games.count,
                                             collapsed: SteamGamesSection.collapsible ? collapsedBinding(key) : nil) { EmptyView() }
                    }
                    if !(collapsed.contains(key) && SteamGamesSection.collapsible) {
                        LibraryCells(items: group.games, layout: layout, width: width) { game, list, dense in
                            cell(game, sources, list: list, dense: dense)
                        }
                    }
                }
            }
        }
        // As the Steam section does: the library reappears after every session.
        .onAppear {
            steamGames.refresh()
            if SteamOwnedLibrary.enabled { steam.start(); steam.reconcileSession() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { steamGames.refresh(); if SteamOwnedLibrary.enabled { steam.reconcileSession() } }
        }
        .sheet(item: $steamSheet) { selection in
            SteamGameSheet(appID: selection.id) { entry in
                // Let the download sheet finish dismissing before presenting the details page.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { open(entry) }
            }
        }
        .alert("Steam", isPresented: Binding(get: { steam.error != nil }, set: { if !$0 { steam.error = nil } })) {
            Button("OK", role: .cancel) { steam.error = nil }
        } message: { Text(steam.error ?? "") }
    }

    private func collapsedBinding(_ key: String) -> Binding<Bool> {
        Binding(get: { LibraryGrouping.collapsed(collapsedGroups).contains(key) }, set: { on in
            var set = LibraryGrouping.collapsed(collapsedGroups)
            if on { set.insert(key) } else { set.remove(key) }
            collapsedGroups = LibraryGrouping.storing(set)
        })
    }

    @ViewBuilder private func cell(_ game: LibraryGrouping.Game, _ sources: Sources, list: Bool, dense: Bool) -> some View {
        switch game.source {
        case .entry(let id):
            if let entry = sources.entries[id] { localCell(entry, list, dense) }
        case .steam(let appID):
            if let item = sources.steam[appID] {
                Button {
                    if let installed = item.installed { open(library.steamEntry(installed, title: item.name)) }
                    else { steamSheet = SteamSelection(id: appID) }
                } label: { SteamGameCell(item: item, list: list, dense: dense) }
                    .libraryCardButtonStyle(grid: !list)
            }
        }
    }
}

struct LibraryView: View {
    private struct IridiumLibraryDetailSelection: Identifiable {
        let entry: LibraryEntry
        var page: String? = nil
        var id: UUID { entry.id }
    }

    @Environment(\.dismiss) private var iridiumDismiss

    @State private var iridiumPages: [String] = []
    @AppStorage(IridiumMenuSounds.settingsKey) private var menuSounds = true
    @State private var iridiumFocus = "Controls"
    @State private var iridiumGuided = false
    @FocusState private var iridiumKeyboard: Bool

    @ObservedObject private var model = LibraryModel.shared
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var liquidMetal = LiquidMetalSetting.shared
    var play: (LibraryEntry) -> Void
    var enableJIT: () -> Void
    @ObservedObject private var jitState = LibraryJITState.shared
    /// Madeira Dock's start, for Settings › Steam (Onboarding.swift).
    var startDock: (DockGame, Bool) -> Void = { _, _ in }
    /// First-run setup (Onboarding.swift).
    @ObservedObject private var onboarding = OnboardingModel.shared
    @ObservedObject private var jit = JITCoordinator.shared
    /// The library's error is a JIT connection problem with a fix to offer.
    private var jitProblem: JITCoordinator.ConnectionProblem? {
        jit.connectionProblem.flatMap { model.error == $0.message ? $0 : nil }
    }
    @State private var browser = false
    @State private var iridiumDetailSelection: IridiumLibraryDetailSelection?
    private var selected: LibraryEntry? {
        get { iridiumDetailSelection?.entry }
        nonmutating set { iridiumDetailSelection = newValue.map { .init(entry: $0) } }
    }
    @State private var search = ""
    /// The Settings tab's own search text, kept apart from the library's.
    @State private var settingsSearch = ""
    @State private var focused: UUID?
    @ObservedObject private var controller = LibraryController.shared
    @ObservedObject private var input = InputSettings.shared
    @State private var tab = 0

    init(play: @escaping (LibraryEntry) -> Void, enableJIT: @escaping () -> Void,
         startDock: @escaping (DockGame, Bool) -> Void = { _, _ in }, tab: Int = 0) {
        self.play = play; self.enableJIT = enableJIT; self.startDock = startDock
        _tab = State(initialValue: tab)
    }
    // The interface the next start uses (FrontendChoice).
    @State private var developerUI = !FrontendChoice.preferNew
    @State private var restartNotice = false
    @State private var settingsSheet: SettingsSheet?
    @State private var settingsRefresh = 0
    @AppStorage("madeiraLibraryLayout") private var layout = "cards"
    @AppStorage("madeiraLibrarySort") private var sort = "played"
    @AppStorage("madeiraLibraryGroup") private var group = "platform"
    @AppStorage("madeiraLibraryCollapsedGroups") private var collapsedGroups = ""
    // Collapsed state of the Other games section (MADEIRA_LIBRARY_COLLAPSE=0: no collapsing).
    @AppStorage("madeiraLibraryHideOthers") private var hideOthers = false
    // The sections follow the Steam section's games and sign-in (SteamGames.swift).
    @ObservedObject private var steamGames = SteamGamesModel.shared
    @ObservedObject private var steamLibrary = SteamOwnedLibrary.shared
    private var entries: [LibraryEntry] {
        // Steam games are listed in their own section (SteamGames.swift).
        let visible = model.entries.filter { $0.desktop != true && $0.steamAppID == nil && (search.isEmpty || $0.title.localizedCaseInsensitiveContains(search)) }
        if sort == "added" { return visible.reversed() }
        return visible.sorted {
            if sort == "played", $0.lastPlayed != $1.lastPlayed { return ($0.lastPlayed ?? .distantPast) > ($1.lastPlayed ?? .distantPast) }
            if sort == "size", $0.folderBytes != $1.folderBytes { return ($0.folderBytes ?? -1) > ($1.folderBytes ?? -1) }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }
    /// The games you added in the page's order, for the controller's focus. Grouping
    /// and sorting go game by game, so their order among the Steam games is the
    /// order without them.
    private var focusOrder: [LibraryEntry] {
        guard group != "platform" else { return entries }
        // A library file edited by hand (or written by a fork) may repeat an id: keep the first.
        let positions = Dictionary(model.entries.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        let byID = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let games = entries.map { LibraryGrouping.Game(entry: $0, position: positions[$0.id] ?? 0) }
        let collapsed = SteamGamesSection.collapsible ? LibraryGrouping.collapsed(collapsedGroups) : []
        return LibraryGrouping.groups(games, by: group, sort: sort)
            .filter { !collapsed.contains(group + "." + $0.id) }
            .flatMap(\.games).compactMap { game in
                if case .entry(let id) = game.source { return byID[id] }
                return nil
            }
    }
    var body: some View {
        // The system tab bar: on iOS 26 it is the floating Liquid Glass bar whose
        // glass selection slides between the tabs and follows a drag. Icons only; the
        // names stay for VoiceOver.
        NavigationStack(path: $iridiumPages) {
          ScrollViewReader { proxy in
            settings
            .iridiumPageSurface().navigationTitle("Settings")
            .toolbar { settingsToolbar }
            .navigationDestination(for: String.self) { page in
                switch page {
case "JIT & Memory": IridiumCapabilitiesView().iridiumPageSurface().navigationTitle("JIT & Memory")
                    .toolbar { settingsToolbar }.navigationBarBackButtonHidden()
                    .toolbar { ToolbarItem(placement: .topBarLeading) {
                        Button("Back", systemImage: "chevron.backward") { iridiumNavigate("back") }
                            .keyboardShortcut(.cancelAction)
                    } }
case "Display": iridiumDisplaySettings.iridiumPageSurface().navigationTitle("Display")
                    .toolbar { settingsToolbar }.navigationBarBackButtonHidden()
                    .toolbar { ToolbarItem(placement: .topBarLeading) {
                        Button("Back", systemImage: "chevron.backward") { iridiumNavigate("back") }
                            .keyboardShortcut(.cancelAction)
                    } }
case "Saves & Backups": Form { Group { SavesSection() }.iridiumRowSurface() }.iridiumPageSurface().navigationTitle("Saves & Backups")
                    .toolbar { settingsToolbar }.navigationBarBackButtonHidden()
                    .toolbar { ToolbarItem(placement: .topBarLeading) {
                        Button("Back", systemImage: "chevron.backward") { iridiumNavigate("back") }
                            .keyboardShortcut(.cancelAction)
                    } }
case "Steam": Form { Group { SteamSettingsSection(open: { settingsSheet = $0 }) }.iridiumRowSurface() }.iridiumPageSurface().navigationTitle("Steam")
                    .toolbar { settingsToolbar }.navigationBarBackButtonHidden()
                    .toolbar { ToolbarItem(placement: .topBarLeading) {
                        Button("Back", systemImage: "chevron.backward") { iridiumNavigate("back") }
                            .keyboardShortcut(.cancelAction)
                    } }
case "Windows Components": Form { Group { WineMonoSettingsSection() }.iridiumRowSurface() }.iridiumPageSurface().navigationTitle("Windows Components")
                    .toolbar { settingsToolbar }.navigationBarBackButtonHidden()
                    .toolbar { ToolbarItem(placement: .topBarLeading) {
                        Button("Back", systemImage: "chevron.backward") { iridiumNavigate("back") }
                            .keyboardShortcut(.cancelAction)
                    } }
case "Advanced Compatibility": Form { Group { if MadeiraConfig.flag("MADEIRA_RUNTIME_SETTINGS") { RuntimeMemorySyncSettings(open: { settingsSheet = $0 }, refresh: settingsRefresh) }
Section("Diagnostics") { Toggle("Detailed logging", isOn: $input.diagnostics) }
Section { Toggle("Desktop reflections", isOn: $liquidMetal.on) } header: { Text("Appearance") } footer: { Text("Adds moving reflections to Windows desktop controls.") } }.iridiumRowSurface() }.iridiumPageSurface().navigationTitle("Advanced Compatibility")
                    .toolbar { settingsToolbar }.navigationBarBackButtonHidden()
                    .toolbar { ToolbarItem(placement: .topBarLeading) {
                        Button("Back", systemImage: "chevron.backward") { iridiumNavigate("back") }
                            .keyboardShortcut(.cancelAction)
                    } }
case "Controls": IridiumControlsSettingsView(back: { iridiumNavigate("back") }).iridiumPageSurface().navigationTitle("Controls")
                    .toolbar { settingsToolbar }.navigationBarBackButtonHidden()
                    .toolbar { ToolbarItem(placement: .topBarLeading) {
                        Button("Back", systemImage: "chevron.backward") { iridiumNavigate("back") }
                            .keyboardShortcut(.cancelAction)
                    } }
case "Madeira · Windows": Form { Group { Section { ForEach(model.entries.filter { $0.desktop != true }) { entry in Button { selected = entry } label: { HStack { Text(IridiumArtworkModel.shared.title(IridiumGame(windows: entry))); Spacer(); Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary) } } }
if model.entries.filter({ $0.desktop != true }).isEmpty { Text("Add a Windows game to change its options.").foregroundStyle(.secondary) } } header: { Text("Games") } footer: { Text("Select a game to change its options.") }
Section("Preferences") { NavigationLink("Display", value: "Display").id("Display")
                    .listRowBackground(iridiumGuided && iridiumFocus == "Display" ? Color.white.opacity(0.2) : Color.white.opacity(0.07))
NavigationLink("Saves & Backups", value: "Saves & Backups").id("Saves & Backups")
                    .listRowBackground(iridiumGuided && iridiumFocus == "Saves & Backups" ? Color.white.opacity(0.2) : Color.white.opacity(0.07))
NavigationLink("Steam", value: "Steam").id("Steam")
                    .listRowBackground(iridiumGuided && iridiumFocus == "Steam" ? Color.white.opacity(0.2) : Color.white.opacity(0.07)) }
Section("Compatibility") { NavigationLink("Windows Components", value: "Windows Components").id("Windows Components")
                    .listRowBackground(iridiumGuided && iridiumFocus == "Windows Components" ? Color.white.opacity(0.2) : Color.white.opacity(0.07))
NavigationLink("Advanced Compatibility", value: "Advanced Compatibility").id("Advanced Compatibility")
                    .listRowBackground(iridiumGuided && iridiumFocus == "Advanced Compatibility" ? Color.white.opacity(0.2) : Color.white.opacity(0.07)) } }.iridiumRowSurface() }.iridiumPageSurface().navigationTitle("Madeira")
                    .toolbar { settingsToolbar }.navigationBarBackButtonHidden()
                    .toolbar { ToolbarItem(placement: .topBarLeading) {
                        Button("Back", systemImage: "chevron.backward") { iridiumNavigate("back") }
                            .keyboardShortcut(.cancelAction)
                    } }
case "Diagnostics": Form { Group { IridiumDiagnosticsSections()
RuntimeDiagnosticsExportSection() }.iridiumRowSurface() }.iridiumPageSurface().navigationTitle("Diagnostics")
                    .toolbar { settingsToolbar }.navigationBarBackButtonHidden()
                    .toolbar { ToolbarItem(placement: .topBarLeading) {
                        Button("Back", systemImage: "chevron.backward") { iridiumNavigate("back") }
                            .keyboardShortcut(.cancelAction)
                    } }
case "Credits": Form { Group { IridiumCreditsSections() }.iridiumRowSurface() }.iridiumPageSurface().navigationTitle("Credits")
                    .toolbar { settingsToolbar }.navigationBarBackButtonHidden()
                    .toolbar { ToolbarItem(placement: .topBarLeading) {
                        Button("Back", systemImage: "chevron.backward") { iridiumNavigate("back") }
                            .keyboardShortcut(.cancelAction)
                    } }
case "About": IridiumAboutView().iridiumPageSurface().navigationTitle("About")
                    .toolbar { settingsToolbar }.navigationBarBackButtonHidden()
                    .toolbar { ToolbarItem(placement: .topBarLeading) {
                        Button("Back", systemImage: "chevron.backward") { iridiumNavigate("back") }
                            .keyboardShortcut(.cancelAction)
                    } }
                default:
                    if let system = IridiumConsoleSystem.system(titled: page) {
                        Form { Group {
                            IridiumSystemGameSettings(platform: system.primaryPlatform, focus: iridiumGuided ? iridiumFocus : nil)
                        }.iridiumRowSurface() }.iridiumPageSurface().navigationTitle(system.runtime.name)
                            .toolbar { settingsToolbar }.navigationBarBackButtonHidden()
                            .toolbar { ToolbarItem(placement: .topBarLeading) {
                                Button("Back", systemImage: "chevron.backward") { iridiumNavigate("back") }
                                    .keyboardShortcut(.cancelAction)
                            } }
                    } else if let game = IridiumSystemGameSettings.game(for: page) {
                        IridiumConsoleOptions(game: game, embedded: true)
                    } else { EmptyView() }
                }
            }
            .onChange(of: iridiumPages) { old, pages in
                if old.count != pages.count { IridiumMenuSounds.play(pages.count > old.count ? .next : .back) }
                if !iridiumSettingsOrder.contains(iridiumFocus) { iridiumFocus = iridiumSettingsOrder.first ?? "" }
            }
            .onChange(of: iridiumFocus) { _, title in proxy.scrollTo(title, anchor: .center) }
          }
        }
        .focusable().focusEffectDisabled().focused($iridiumKeyboard)
            .onAppear { iridiumKeyboard = true }
            .onChange(of: iridiumPages) { _, pages in if !iridiumSettingsOrder.isEmpty { iridiumKeyboard = true } }
            .onKeyPress(.escape) { iridiumNavigate("back"); return .handled }
.onKeyPress(.upArrow) {
                guard !iridiumSettingsOrder.isEmpty else { return .ignored }
                iridiumNavigate("up"); return .handled
            }
.onKeyPress(.downArrow) {
                guard !iridiumSettingsOrder.isEmpty else { return .ignored }
                iridiumNavigate("down"); return .handled
            }
.onKeyPress(.leftArrow) {
                guard !iridiumSettingsOrder.isEmpty else { return .ignored }
                iridiumNavigate("left"); return .handled
            }
.onKeyPress(.rightArrow) {
                guard !iridiumSettingsOrder.isEmpty else { return .ignored }
                iridiumNavigate("right"); return .handled
            }
.onKeyPress(.return) {
                guard !iridiumSettingsOrder.isEmpty else { return .ignored }
                iridiumNavigate("accept"); return .handled
            }
        // On the tab view, not inside one tab's page: an alert attached to the Library
        // page cannot present while Settings is showing, so an error raised there (its
        // Enable JIT, for one) waited until the Library tab came back.
        .alert(jitProblem == nil ? "Library" : "Couldn't Enable JIT",
               isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            if let jitProblem { jitConnectionActions(jitProblem, retry: enableJIT) { model.error = nil } }
            Button("OK", role: .cancel) { model.error = nil }
        } message: { Text(model.error ?? "") }
        .sheet(item: $iridiumDetailSelection) { route in
            let entry = route.entry
            // The details page stays up until the session's starting screen takes
            // over (or an error needs the library's alert), instead of showing the
            // library for the moment a start spends preparing.
            LibraryDetail(iridiumInitialPage: route.page, entry: entry, play: { profile in
                play(profile)
                // Not while Play is still enabling JIT: the session's start, an error, or
                // JIT setup closes the page then.
                DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
                    if selected?.id == entry.id, model.startingJIT != entry.id { selected = nil }
                }
            })
        }
        .onChange(of: model.current) { _, current in if current != nil { selected = nil } }
        .onChange(of: model.error) { _, error in if error != nil { selected = nil } }
        .onChange(of: model.restartNotice) { _, notice in if notice != nil { selected = nil } }
        .onChange(of: model.jitNotice) { _, notice in if notice != nil { selected = nil } }
        .onChange(of: model.cloudNotice) { _, notice in if notice != nil { selected = nil } }
        .onChange(of: jit.showSetup) { _, show in if show { selected = nil } }
        .onChange(of: model.showDetail) { _, id in
            guard let id else { return }
            model.showDetail = nil
            selected = model.entries.first { $0.id == id }
        }
        .fullScreenCover(isPresented: onboarding.binding(for: .settings), onDismiss: { onboarding.presentationDidDismiss() }) { OnboardingView() }
        .onAppear {
            // An ended desktop session's surface never stays over the library.
            EndedSessionSurface.install(); EndedSessionSurface.hide(reason: "library-appeared")
            // First-run setup opens once on a new install.
            onboarding.presentIfNeeded(owner: .settings)
        }
        .onAppear {
            LogStore.shared.log("[library-sections] native-steam=\(SteamOwnedLibrary.enabled ? 1 : 0) sections=\(SteamGamesSection.shown ? 1 : 0) collapse=\(SteamGamesSection.collapsible ? 1 : 0)")
        }
        // ml1216: a session replaces the library (ContentView), and the skin's run-loop
        // observer, display link and view walks kept running on the main thread through
        // the whole game. Stop with the library; it starts again when the library returns
        // on either tab (start() does nothing while liquid metal is off).
        .onAppear {}
        .onDisappear { GlassSkin.shared.stop() }
        .onReceive(controller.commands) { [controlsOwnsCommands = iridiumPages.last == "Controls"] command in
            guard selected == nil, !browser, !onboarding.presented, settingsSheet == nil else { return }
            guard !controlsOwnsCommands else { return }
            iridiumNavigate(command)
        }
    }

    private func iridiumNavigate(_ command: String) {
        guard TouchControlsModel.shared.iridiumSettingsContext == nil else { return }
        if command == "back" {
            if !iridiumPages.isEmpty { iridiumPages.removeLast() } else { iridiumDismiss() }
            return
        }
        guard !iridiumSettingsOrder.isEmpty else { return }
        let order = iridiumSettingsOrder
        let index = order.firstIndex(of: iridiumFocus) ?? 0
        if ["left", "right", "up", "down"].contains(command) {
            iridiumGuided = true
            let step = command == "up" || command == "left" ? -1 : 1
            let next = order[min(max(index + step, 0), order.count - 1)]
            if next != iridiumFocus { IridiumMenuSounds.play(.focus); iridiumFocus = next }
        } else if command == "accept" {
            if iridiumFocus == "Menu sounds" { menuSounds.toggle() }
            else { iridiumPages.append(iridiumFocus) }
        }
    }

    private var iridiumSettingsOrder: [String] {
        switch iridiumPages.last {
        case nil: return ["Getting Started", "Controls", "JIT & Memory", "Menu sounds", "Madeira · Windows"] + IridiumConsoleSystem.all.map(\.title) + ["About"]
        case "Madeira · Windows": return ["Display", "Saves & Backups", "Steam", "Windows Components", "Advanced Compatibility"]
        default:
            guard let title = iridiumPages.last, let system = IridiumConsoleSystem.system(titled: title) else { return [] }
            return IridiumSystemGameSettings.routes(for: system.primaryPlatform)
        }
    }
    private var iridiumDisplaySettings: some View {
        Form { Group {
            DisplayRateSettings()
            Section {
                ForEach(model.entries.filter { $0.desktop != true }) { entry in
                    Button(IridiumArtworkModel.shared.title(IridiumGame(windows: entry))) { iridiumDetailSelection = .init(entry: entry, page: "Display") }
                }
                Button("Windows Desktop") { iridiumDetailSelection = .init(entry: model.entries.first { $0.id == LibraryEntry.desktopID } ?? LibraryEntry.desktopEntry, page: "Display") }
            } header: { Text("Games") } footer: { Text("Resolution, aspect and scaling, MetalFX, FPS limit and frame generation are set per game.") }
        }.iridiumRowSurface() }.iridiumPageSurface()
    }
    @ToolbarContentBuilder private var libraryToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Picker("Library layout", selection: $layout) {
                    Label("Cards", systemImage: "square.grid.2x2").tag("cards")
                    Label("Compact cards", systemImage: "square.grid.3x3").tag("compact")
                    Label("List", systemImage: "list.bullet").tag("list")
                    Label("Compact list", systemImage: "list.dash").tag("compactList")
                }
                Picker("Group by", selection: $group) {
                    Label("Last played", systemImage: "clock.arrow.circlepath").tag("played")
                    Label("Installed", systemImage: "arrow.down.circle").tag("installed")
                    Label("Platform", systemImage: "square.stack").tag("platform")
                    Label("None", systemImage: "square.grid.2x2").tag("none")
                }.pickerStyle(.menu)
                Picker("Sort by", selection: $sort) {
                    Label("Last played", systemImage: "clock").tag("played")
                    Label("Name", systemImage: "textformat.abc").tag("name")
                    Label("Recently added", systemImage: "plus").tag("added")
                    Label("Folder size", systemImage: "internaldrive").tag("size")
                }
            } label: { Label("Library options", systemImage: "line.3.horizontal.decrease") }
        }
        ToolbarItem(placement: .topBarTrailing) { Button { browser = true } label: { Label("Add executable", systemImage: "plus") } }
    }
    @ToolbarContentBuilder private var settingsToolbar: some ToolbarContent {
        ToolbarItem(placement: .confirmationAction) { Button("Done") { iridiumDismiss() } }
    }
    private func switchTab(to newTab: Int) {
        guard newTab != tab else { return }
        withAnimation(UIAccessibility.isReduceMotionEnabled ? nil : .default) { tab = newTab }
    }
    /// Settings search: a section shows when the search is empty or matches one of its words.
    private func settingsShow(_ words: String...) -> Bool {
        let q = settingsSearch.trimmingCharacters(in: .whitespaces)
        return q.isEmpty || words.contains { $0.localizedCaseInsensitiveContains(q) || q.localizedCaseInsensitiveContains($0) }
    }
    private var settings: some View {
        Form {
            Group {
            Section { if onboarding.available { Button("Getting Started", systemImage: "wand.and.stars") { onboarding.rerun() }.id("Getting Started") }
NavigationLink("Controls", value: "Controls").id("Controls")
                    .listRowBackground(iridiumGuided && iridiumFocus == "Controls" ? Color.white.opacity(0.2) : Color.white.opacity(0.07))
NavigationLink("JIT & Memory", value: "JIT & Memory").id("JIT & Memory")
                    .listRowBackground(iridiumGuided && iridiumFocus == "JIT & Memory" ? Color.white.opacity(0.2) : Color.white.opacity(0.07))
Toggle("Menu sounds", isOn: $menuSounds).id("Menu sounds")
                    .listRowBackground(iridiumGuided && iridiumFocus == "Menu sounds" ? Color.white.opacity(0.2) : Color.white.opacity(0.07))
                    .onChange(of: menuSounds) { _, enabled in if enabled { IridiumMenuSounds.play(.invoke) } else { IridiumMenuSounds.stop() } }
            }.iridiumRowSurface()
            Section("Systems") { NavigationLink("Madeira · Windows", value: "Madeira · Windows").id("Madeira · Windows")
                    .listRowBackground(iridiumGuided && iridiumFocus == "Madeira · Windows" ? Color.white.opacity(0.2) : Color.white.opacity(0.07))
ForEach(IridiumConsoleSystem.all) { system in
                NavigationLink(system.title, value: system.title).id(system.title)
                    .listRowBackground(iridiumGuided && iridiumFocus == system.title ? Color.white.opacity(0.2) : Color.white.opacity(0.07))
            } }.iridiumRowSurface()
            Section { NavigationLink("About", value: "About").id("About")
                    .listRowBackground(iridiumGuided && iridiumFocus == "About" ? Color.white.opacity(0.2) : Color.white.opacity(0.07)) }.iridiumRowSurface()
            }.iridiumRowSurface()
        }
        .alert("Restart Madeira", isPresented: $restartNotice) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Close Madeira from the app switcher and open it again to switch interfaces.")
        }
        // The Settings sheets hang off the Form, never off one of its rows: a Form
        // may rebuild its rows while a sheet slides up over it, and a sheet whose
        // owning row is rebuilt closes again at once.
        .sheet(item: $settingsSheet, onDismiss: { settingsRefresh += 1 }) { sheet in
            switch sheet {
            case .allSettings: AllSettingsView()
            case .steamSignIn: SteamSignInView()
            case .dock: MadeiraDockView(start: startDock)
            }
        }
    }
    private var library: some View {
        GeometryReader { viewport in
        ScrollViewReader { reader in
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                desktopButton
                // The library's sections, as in the fork: Steam (installed and downloading
                // Steam games, then Not installed), then Other games, the games you added.
                // Steam games start through Madeira Dock (SteamGames.swift); an installed one
                // opens its Game details page like any library game. Without the Steam
                // section the games you added are one grid.
                // Installed Steam games first, then the games you added, then the
                // account's Not installed games. With nothing installed (or
                // downloading) the games you added are the top section and the
                // whole Steam section, sign-in included, follows them.
                // Any other Group by choice lists every game in one set of groups.
                if group != "platform" {
                    LibraryGroupedGames(grouping: group, search: search, layout: layout, sort: sort, width: viewport.size.width,
                                        open: { selected = $0 }) { entry, list, dense in
                        libraryItem(entry, list: list, dense: dense)
                    }
                } else {
                let steamFirst = MadeiraDock.enabled && SteamGamesSection.hasInstalled
                if steamFirst {
                    SteamGamesSection(search: search, layout: layout, sort: sort, width: viewport.size.width,
                                      part: .installed, open: { selected = $0 })
                }
                if SteamGamesSection.shown {
                    VStack(alignment: .leading, spacing: 14) {
                        // Games are added with the + in the navigation bar.
                        LibrarySectionHeader(title: "Other games", count: entries.count,
                                             collapsed: SteamGamesSection.collapsible ? $hideOthers : nil) { EmptyView() }
                        if hideOthers && SteamGamesSection.collapsible {
                            EmptyView()
                        } else if entries.isEmpty {
                            Text(search.isEmpty
                                 ? "Copy a game's folder into Madeira › wine › drive_c with the Files app, then tap + and choose its .exe."
                                 : "No other games match your search.")
                                .foregroundStyle(.secondary)
                        } else {
                            cells(entries, width: viewport.size.width)
                        }
                    }
                    if MadeiraDock.enabled {
                        SteamGamesSection(search: search, layout: layout, sort: sort, width: viewport.size.width,
                                          part: steamFirst ? .notInstalled : .all, open: { selected = $0 })
                    }
                } else if model.entries.filter({ $0.desktop != true && $0.steamAppID == nil }).isEmpty {
                    ContentUnavailableView("No Windows Games", systemImage: "gamecontroller", description: Text("Copy a game's folder into Madeira › wine › drive_c with the Files app, then tap + and choose its .exe."))
                } else {
                    cells(entries, width: viewport.size.width)
                }
                }
            }
            // Ambient light behind the grid cards, in the content's own space so it scrolls with them.
            .backgroundPreferenceValue(AmbientGlowKey.self) { AmbientGlowLayer(items: $0) }
            .padding(16).frame(maxWidth: 1100).frame(maxWidth: .infinity)
        }
        .refreshable { await SteamGamesSection.refresh() }
        .onReceive(controller.commands) { command in
            guard tab == 0, selected == nil, !browser, !onboarding.presented else { return }
            let items = focusOrder
            let ids = [LibraryEntry.desktopID] + items.map(\.id)
            let index = ids.firstIndex(where: { $0 == focused }) ?? 0
            if command == "add" { browser = true }
            else if command == "accept" {
                if index == 0 { selected = model.entries.first(where: { $0.desktop == true }) ?? .desktopEntry }
                else { selected = items[index - 1] }
            }
            else if ["left", "right", "up", "down"].contains(command) {
                let delta = command == "left" || command == "up" ? -1 : 1
                withAnimation(UIAccessibility.isReduceMotionEnabled ? nil : .easeOut(duration: 0.18)) { focused = ids[(index + delta + ids.count) % ids.count] }
            }
        }
        .sheet(isPresented: $browser) {
            NavigationStack { ExecutableBrowser(folder: LibraryModel.drive) { entry in
                // madeira-bcd: the page shows the entry as stored, with its recommended settings.
                model.save(entry); browser = false; selected = model.entries.first { $0.id == entry.id } ?? entry
            } }
        }
        .onChange(of: scenePhase) { _, phase in if phase == .active { model.refreshFlag() } }
        .onAppear {
            if focused == nil { focused = LibraryEntry.desktopID }
            GlassSkin.shared.start()   // liquid metal on the navigation bar's glass pills
        }
        .onChange(of: focused) { _, id in
            if let id { withAnimation(UIAccessibility.isReduceMotionEnabled ? nil : .easeInOut(duration: 0.2)) { reader.scrollTo(id, anchor: .center) } }
        }
        }
        }
    }
    /// The Desktop button at the top of the page (both grids).
    private var desktopButton: some View {
        HStack {
            Button { selected = model.entries.first(where: { $0.desktop == true }) ?? .desktopEntry } label: {
                if liquidMetal.on {
                    // On the chrome's middle band (dark, or light in light mode), with a soft
                    // halo of the other tone for the moments a highlight passes under it.
                    let light = colorScheme == .light
                    Label("Desktop", systemImage: "desktopcomputer")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(light ? .black : .white)
                        .shadow(color: (light ? Color.white : .black).opacity(0.75), radius: 2.5)
                        .padding(.horizontal, 14).frame(minHeight: 44)
                        .background(LiquidMetalFill())
                        // ml1217: the fill does not hit-test, so without this only the
                        // glyphs took a tap (the plain fill's Capsule did).
                        .contentShape(Capsule())
                } else {
                    Label("Desktop", systemImage: "desktopcomputer")
                        .font(.subheadline.weight(.medium)).padding(.horizontal, 14).frame(minHeight: 44)
                        .background(Color(uiColor: .secondarySystemGroupedBackground), in: Capsule())
                }
            }.buttonStyle(.plain)
                .animation(UIAccessibility.isReduceMotionEnabled ? nil : .easeInOut(duration: 0.4), value: liquidMetal.on)
                .id(LibraryEntry.desktopID)
                .overlay(RoundedRectangle(cornerRadius: 22).stroke(focused == LibraryEntry.desktopID && controller.connected ? Color.cyan : .clear, lineWidth: 3))
        }
    }
    private func cells(_ items: [LibraryEntry], width viewportWidth: CGFloat) -> some View {
        LibraryCells(items: items, layout: layout, width: viewportWidth) { entry, list, dense in
            libraryItem(entry, list: list, dense: dense)
        }
    }
    private func libraryItem(_ entry: LibraryEntry, list: Bool, dense: Bool = false) -> some View {
        Button { selected = entry } label: {
            Group {
                if list && dense {
                    // One short row per game.
                    HStack(spacing: 10) {
                        LibraryArtwork(entry: entry).frame(width: 28, height: 42).clipShape(RoundedRectangle(cornerRadius: 5))
                        Text(entry.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                        Spacer(minLength: 6)
                        LibraryBadges(entry: entry).foregroundStyle(.secondary).fixedSize()
                    }.padding(.horizontal, 8).padding(.vertical, 5)
                        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
                } else if list {
                    HStack(spacing: 14) {
                        LibraryArtwork(entry: entry).frame(width: 48, height: 72).clipShape(RoundedRectangle(cornerRadius: 8))
                        VStack(alignment: .leading, spacing: 8) {
                            Text(entry.title).font(.headline).lineLimit(2); LibraryBadges(entry: entry).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                    }.padding(10).background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        LibraryArtwork(entry: entry).aspectRatio(2.0 / 3.0, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 12))
                            .modifier(LibraryCardArtworkPress { pressed, bounds in
                                AmbientGlowItem(id: "entry-\(entry.id)", seed: entry.id.hashValue, art: .library(entry), pressed: pressed, bounds: bounds)
                            })
                        Text(entry.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                        LibraryBadges(entry: entry).foregroundStyle(.secondary)
                    }.padding(4)
                }
            }.foregroundStyle(.primary)
        }.libraryCardButtonStyle(grid: !list)
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(focused == entry.id && controller.connected ? Color.accentColor : .clear, lineWidth: 2))
            .id(entry.id)
            .task(id: entry.id, priority: .utility) { await model.refreshMetadata(entry.id) }
    }
}

struct ExecutableBrowser: View {
    let folder: URL
    var select: (LibraryEntry) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var files: [URL] = []
    @State private var error: String?
    var body: some View {
        List {
            if let error { Text(error).foregroundStyle(.red) }
            ForEach(files, id: \.path) { file in
                if file.hasDirectoryPath {
                    NavigationLink { ExecutableBrowser(folder: file, select: select) } label: { Label(file.lastPathComponent, systemImage: "folder") }
                } else {
                    Button { do { select(try LibraryModel.inspect(file)) } catch { self.error = error.localizedDescription } } label: {
                        Label(file.lastPathComponent, systemImage: file.pathExtension.lowercased() == "exe" ? "app.dashed" : "terminal")
                    }
                }
            }
            if files.isEmpty && error == nil { Text("No executables here. Use Add Game to import a game, or choose another folder.").foregroundStyle(.secondary) }
        }.iridiumPageSurface().navigationTitle(folder.lastPathComponent)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        .task {
            do {
                // ml1163: .bat and .cmd files are listed too (they run through cmd.exe).
                files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles)
                    .map { url in
                        var directory: ObjCBool = false
                        _ = FileManager.default.fileExists(atPath: url.path, isDirectory: &directory)
                        return URL(fileURLWithPath: url.path, isDirectory: directory.boolValue)
                    }
                    .filter { ($0.hasDirectoryPath || LibraryModel.programExtensions.contains($0.pathExtension.lowercased())) && IridiumGameStorage.windowsRelative($0, drive: LibraryModel.drive) != nil }
                    .sorted { if $0.hasDirectoryPath != $1.hasDirectoryPath { return $0.hasDirectoryPath }; return $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            } catch { self.error = error.localizedDescription }
        }
    }
}

private struct LibraryPlayStyle: ButtonStyle {
    var pending: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.padding(.horizontal, 18).padding(.vertical, 10)
            .foregroundStyle(pending ? Color.white : Color.black)
            .background(pending ? Color(uiColor: .darkGray) : Color.white.opacity(configuration.isPressed ? 0.8 : 1),
                        in: Capsule())
    }
}

struct LibraryDetail: View {
    var iridiumInitialPage: String? = nil
    @State private var iridiumInitialPageOpened = false

    @State private var iridiumPages: [String] = []
    @State private var iridiumFocus = "Controls"
    @State private var iridiumGuided = false
    @FocusState private var iridiumKeyboard: Bool

    @State private var entry: LibraryEntry

    init(iridiumInitialPage: String? = nil, entry: LibraryEntry, play: @escaping (LibraryEntry) -> Void) {
        self.iridiumInitialPage = iridiumInitialPage; self.play = play
        _entry = State(initialValue: entry)
    }

    private func iridiumNavigate(_ command: String) {
        if command == "back" {
            if !iridiumPages.isEmpty { iridiumPages.removeLast() } else { model.save(entry); dismiss() }
            return
        }
        guard iridiumPages.isEmpty else { return }
        let order = ["Rename & Artwork", "Library Entry", "Controls", "Display", "Files & Saves", "Advanced", "Favorites"].filter { entry.desktop != true || !["Rename & Artwork", "Library Entry", "Favorites"].contains($0) }
        let index = order.firstIndex(of: iridiumFocus) ?? 0
        if ["left", "right", "up", "down"].contains(command) {
            iridiumGuided = true
            let step = command == "up" || command == "left" ? -1 : 1
            iridiumFocus = order[min(max(index + step, 0), order.count - 1)]
        } else if command == "accept" {
            if iridiumFocus == "Favorites" { IridiumFavoriteButton.toggle(entry) }
            else if iridiumFocus == "Library Entry" { iridiumLibraryAction() }
            else { iridiumPages.append(iridiumFocus) }
        }
    }

    private func iridiumLibraryAction() {
        guard !IridiumImportCoordinator.shared.blocksLaunch, model.current == nil, !model.launching else { return }
        if let appID = entry.steamAppID, model.hiddenSteamApps.contains(appID) {
            if let game = model.steamInstall(entry) { model.upsertSteam(game, title: entry.title) }
        } else { remove = true }
    }

    var play: (LibraryEntry) -> Void
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var model = LibraryModel.shared
    @State private var importCover = false
    /// madeira-bcd: this game's own switches as the fork stores them (reloadBCD).
    @State private var bcd = BCDGameValues()
    @State private var findCover = false
    @State private var remove = false
    /// madeira-bcd: Madeira's recommended settings for this game, nil for none
    /// (GameRecommendations.swift), and the question before Reset to Recommended.
    @State private var recommended: GameRecommendation?
    @State private var confirmReset = false
    @State private var leaving = false
    @State private var error: String?
    @State private var copiedLink = false
    /// Where Play is on screen: the starting screen grows out of it (LaunchCurtain).
    @State private var playFrame: CGRect = .zero
    /// Settings › Sync engine, read when the details open: the fastsync switches
    /// below only apply while it is Fastsync.
    @State private var syncEngine = SyncEngine.current
    /// madeira-bcd: one storage for a game's own options -- where the fork keeps
    /// them and BCDLaunch exports them at every launch (library, Madeira Dock,
    /// Home Screen shortcuts): AVX, NVIDIA and Wine's C++ runtime in LibraryPrefs,
    /// the game's config lines in its GameProfiles.swift file. This page's
    /// controls read and write them; the entry fields upstream keeps for the
    /// same options (avx, reportNVIDIA, config) are moved into them once.
    private func reloadBCD() { bcd = BCDGameValues(windowsPath: entry.windowsPath) }
    private func migrateEntryOptions() {
        let path = entry.windowsPath
        let file = GameProfile(windowsPath: path)
        var moved: [String] = []
        if entry.avx == true { LibraryPrefs.setAVX(true, for: path); moved.append("avx") }
        if entry.reportNVIDIA == true { LibraryPrefs.setNvidia(true, for: path); moved.append("nvidia") }
        if let config = entry.config, !config.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // The entry's lines first, the file's after: a key both set keeps the file's value.
            let old = file.text
            file.text = config + (config.hasSuffix("\n") ? "" : "\n") + old
            moved.append("config")
        }
        guard !moved.isEmpty else { return }
        entry.avx = nil; entry.reportNVIDIA = nil; entry.config = nil
        model.save(entry)
        LogStore.shared.log("[bcd] \(entry.title): moved \(moved.joined(separator: ",")) into the game's own settings")
    }
    /// madeira-bcd: a game seen for the first time gets Madeira's recommended settings,
    /// which this page then shows (GameRecommendationsApply.swift).
    private func prepareRecommendation() {
        recommended = GameRecommendations.recommendation(for: entry)
        // A copy the library has not stored (a Steam game's first page) is a new entry.
        let isNew = !model.entries.contains { $0.id == entry.id }
        if GameRecommendations.prepare(&entry, new: isNew) { model.save(entry) }
    }
    /// Reset to Recommended: the recommendation's config and switches, written at once.
    private func resetToRecommended() {
        recommended = GameRecommendations.reset(&entry)
        model.save(entry)
        reloadBCD()
    }
    /// "None", or how many keys this game's own config sets.
    static func configSummary(_ config: String?) -> String {
        let count = MadeiraConfig.parse(config ?? "").count
        return count == 0 ? "None" : count == 1 ? "1 setting" : "\(count) settings"
    }
    private func start() {
        guard !leaving else { return }
        // A Steam game starts through Madeira Dock (ContentView.launchLibraryEntry)
        // once its files are complete and Dock can sign in; "The game" once its
        // program is chosen (no client or sign-in involved).
        if let appID = entry.steamAppID {
            if SteamOwnedLibrary.shared.downloads[appID] != nil {
                error = "This game's update has not finished. Resume it and wait for it to complete before playing."; return
            }
            let installed = SteamGamesModel.shared.games.first { $0.id == appID }?.installed ?? false
            if entry.startsSteamGameDirectly {
                if let blocker = SteamDirectStart.blocker(installed: installed, program: entry.steamProgram) { error = blocker; return }
            } else if let blocker = SteamGamesRules.blocker(installed: installed, client: MadeiraDock.clientInstalled, signedIn: SteamSignIn.isSignedIn) {
                error = blocker; return
            }
        }
        leaving = true
        let steamCover = entry.coverFile == nil ? entry.steamAppID : nil
        LaunchCurtain.shared.begin(from: playFrame, appID: steamCover, artwork: steamCover.flatMap { id in
            SteamGamesRules.artwork(appID: id) { SteamOwnedLibrary.shared.game($0) }.first
        })
        let profile = entry
        // Give the pressed state a display turn before saving and handing off.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            model.save(profile); play(profile)
        }
    }
    /// A Steam game without a chosen cover shows Steam's store artwork.
    @ViewBuilder private func artwork(backdrop: Bool) -> some View {
        LibraryArtwork(entry: entry, backdrop: backdrop)
    }
    var body: some View {
      ScrollViewReader { proxy in
        NavigationStack(path: $iridiumPages) {
            Form {
                Group {
                Section {
                    IridiumGameOptionsHeader(game: IridiumGame(windows: entry))
                    if let played = entry.lastPlayed { LabeledContent("Last Played", value: played.formatted(.relative(presentation: .named))) }
                    if DockOffline.enabled, let appID = entry.steamAppID, !entry.startsSteamGameDirectly { DockOfflineMark(appID: appID) }
                            Button(action: start) {
                                HStack(spacing: 10) {
                                    // Enabling JIT can take seconds with nothing else on screen.
                                    if model.startingJIT == entry.id {
                                        ProgressView().tint(.white)
                                        Text("Starting JIT").fontWeight(.semibold)
                                    } else {
                                        Image(systemName: "play.fill"); Text("Play").fontWeight(.semibold)
                                    }
                                }.frame(minWidth: 100, minHeight: 30)
                            }
                            .buttonStyle(LibraryPlayStyle(pending: leaving)).disabled(leaving)
                }.listRowBackground(Color.clear)
                Section("Runtime") { LabeledContent("Emulator", value: "Madeira"); LibraryBadges(entry: entry) }

                Section("Library") {
                    if entry.desktop != true { NavigationLink("Rename & Artwork", value: "Rename & Artwork").id("Rename & Artwork")
                    .listRowBackground(iridiumGuided && iridiumFocus == "Rename & Artwork" ? Color.white.opacity(0.2) : Color.white.opacity(0.07))
                        if let appID = entry.steamAppID, model.hiddenSteamApps.contains(appID) {
                            Button("Add to Library", action: iridiumLibraryAction)
                                .disabled(IridiumImportCoordinator.shared.blocksLaunch || model.steamInstall(entry) == nil)
                                .id("Library Entry").listRowBackground(iridiumGuided && iridiumFocus == "Library Entry" ? Color.white.opacity(0.2) : Color.white.opacity(0.07))
                        } else {
                            Button("Remove from Library", role: .destructive, action: iridiumLibraryAction)
                                .disabled(IridiumImportCoordinator.shared.blocksLaunch || model.current != nil || model.launching)
                                .id("Library Entry").listRowBackground(iridiumGuided && iridiumFocus == "Library Entry" ? Color.white.opacity(0.2) : Color.white.opacity(0.07))
                        }
                    }
                }.iridiumRowSurface()
                Section("Controls") { NavigationLink("Controls", value: "Controls").id("Controls")
                    .listRowBackground(iridiumGuided && iridiumFocus == "Controls" ? Color.white.opacity(0.2) : Color.white.opacity(0.07)) }.iridiumRowSurface()
                Section("Display") { NavigationLink("Display", value: "Display").id("Display")
                    .listRowBackground(iridiumGuided && iridiumFocus == "Display" ? Color.white.opacity(0.2) : Color.white.opacity(0.07)) }.iridiumRowSurface()
                Section("Files & Saves") { NavigationLink("Files & Saves", value: "Files & Saves").id("Files & Saves")
                    .listRowBackground(iridiumGuided && iridiumFocus == "Files & Saves" ? Color.white.opacity(0.2) : Color.white.opacity(0.07)) }.iridiumRowSurface()
                Section("Compatibility") { NavigationLink("Advanced", value: "Advanced").id("Advanced")
                    .listRowBackground(iridiumGuided && iridiumFocus == "Advanced" ? Color.white.opacity(0.2) : Color.white.opacity(0.07)) }.iridiumRowSurface()
                if entry.desktop != true { Section { IridiumFavoriteButton(entry: entry).id("Favorites") }.iridiumRowSurface() }
                // madeira-bcd: always last, for every entry, the Desktop too (GameRecommendationsApply.swift).
                Section {
                    Button(recommended == nil ? "Clear Game Configuration" : "Restore Game Configuration", systemImage: "arrow.counterclockwise") { confirmReset = true }
                        .confirmationDialog(GameRecommendations.question(recommended, desktop: entry.desktop == true),
                                            isPresented: $confirmReset, titleVisibility: .visible) {
                            Button("Reset", role: .destructive) { resetToRecommended() }
                        }
                } footer: {
                    Text("Restores configuration and any recommended compatibility/display values. Keeps controls, artwork, files and saves.")
                }
                if let error { Section { Text(error).foregroundStyle(.red) } }
                }.iridiumRowSurface()
            }
.navigationDestination(for: String.self) { page in
                switch page {
case "Rename & Artwork":
                    IridiumArtworkEditor(game: IridiumGame(windows: entry), embedded: true,
                                         onBack: {
                                             if iridiumPages.last == "Rename & Artwork" { iridiumNavigate("back") }
                                         })
                        .navigationBarBackButtonHidden()
                    case "Controls": Form { Group {
                Section {
                    IridiumGameControlsButton(target: .init(platform: .windows, title: IridiumArtworkModel.shared.title(IridiumGame(windows: entry)), gameID: entry.id,
                        windowsLayout: entry.controls.map { IridiumControlLayoutState(controls: $0, visible: entry.touchControls,
                            size: entry.controlSize ?? 1, opacity: entry.controlOpacity ?? 0.7, zones: entry.zones) }))
                }
                 Section("On screen") {
                    Toggle("Performance overlay", isOn: $entry.performance)
                    Toggle("Live logs", isOn: $entry.liveLogs)
                    Toggle("Touch controls", isOn: $entry.touchControls)
                    if GamepadInput.keyboardMouseAvailable {
                        ControllerModeChoice(mode: $entry.controllerMode)
                        if entry.controllerMode == "keys" {
                            NavigationLink("Controller binds") {
                                Form { ControllerBindsPage(binds: $entry.controllerBinds, mouseVertical: $entry.padMouseVertical) }
                                    .iridiumPageSurface().navigationTitle("Controller binds")
                                    .toolbar {
                                        Button("Reset") { entry.controllerBinds = nil; entry.padMouseVertical = nil }
                                            .disabled(entry.controllerBinds == nil && entry.padMouseVertical == nil)
                                    }
                            }
                        }
                    }
                    LabeledContent("Control opacity") {
                        Slider(value: Binding(get: { entry.controlOpacity ?? 0.7 }, set: { entry.controlOpacity = $0 }), in: 0.15...1)
                    }
                    LabeledContent("Control size") {
                        Slider(value: Binding(get: { entry.controlSize ?? 1 }, set: { entry.controlSize = $0 }), in: 0.5...2)
                    }
                    Text("Edit layouts and reusable profiles above.").font(.caption).foregroundStyle(.secondary)
                    if GamepadInput.keyboardMouseAvailable {
                        Text("DirectInput supports older games. Changes apply next launch.").font(.caption).foregroundStyle(.secondary)
                        Text("Map the controller to keys and pointer movement under Controller Binds.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                // madeira-bcd: this game's config is its own GameProfiles.swift file
                // (Application Support/GameConfigs/<hash>.cfg), the file every launch of
                // the game exports as MADEIRA_CFG_GAME. Lines an entry saved in upstream's
                // `config` field are moved into it when the page opens (migrateEntryOptions).
 }.iridiumRowSurface() }.iridiumPageSurface().navigationTitle("Controls")
                    .navigationBarBackButtonHidden()
                    .toolbar { ToolbarItem(placement: .topBarLeading) {
                        Button("Back", systemImage: "chevron.backward") { iridiumNavigate("back") }
                            .keyboardShortcut(.cancelAction)
                    } }
case "Display": Form { Group {                 Section("Resolution & Scaling") {
                    // The Windows screen the game renders for (and the Desktop's size).
                    // ml1172: this device's choices (ResolutionChoices), grouped.
                    let groups = ResolutionChoices.groups()
                    let metalFX = ResolutionChoices.metalFX(in: groups)
                    Picker("Resolution", selection: $entry.resolution) {
                        ForEach(groups, id: \.title) { group in
                            Section(group.title) {
                                ForEach(group.choices, id: \.value) { Text($0.label).tag($0.value) }
                            }
                        }
                        // The screen's shape at 480 lines, which MetalFX 1.5× brings to 720.
                        if let shape = metalFX, entry.metalFXUpscale == 1.5 || entry.resolution == shape.value {
                            Text(shape.label).tag(shape.value)
                        }
                        // A size none of them has, so the picker never shows a blank choice.
                        if entry.resolution != metalFX?.value, let saved = ResolutionChoices.extra(entry.resolution, in: groups, note: "saved") {
                            Text(saved.label).tag(entry.resolution)
                        }
                    }
                    Picker("Aspect & scaling", selection: Binding(get: { entry.displayMode.rawValue }, set: { entry.display = $0 })) {
                        ForEach(DisplayMode.allCases, id: \.rawValue) { Text($0.label).tag($0.rawValue) }
                    }
                }
                Section("Rendering") {
                    Picker("MetalFX upscaling", selection: $entry.metalFXUpscale) {
                        Text("Off").tag(Double?.none)
                        Text("1.5×").tag(Double?.some(1.5))
                        Text("2×").tag(Double?.some(2))
                    }
                    Picker("D3D9 anisotropic filtering", selection: Binding(get: { entry.anisotropyLimit ?? 0 }, set: { entry.anisotropyLimit = $0 == 0 ? nil : $0 })) {
                        Text("Application default").tag(0)
                        ForEach([1, 2, 4, 8], id: \.self) { Text("Up to \($0)×").tag($0) }
                    }
                }
                Section("Frame Rate") {
                    FPSChoice(mode: $entry.fpsMode)
                    Toggle("Frame generation (experimental)", isOn: Binding(get: { entry.frameGeneration ?? false }, set: { entry.frameGeneration = $0 ? true : nil }))
                    if entry.frameGeneration == true {
                        Text("Generates extra frames. FPS limits are ignored while enabled.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
 }.iridiumRowSurface() }.iridiumPageSurface().navigationTitle("Display")
                    .navigationBarBackButtonHidden()
                    .toolbar { ToolbarItem(placement: .topBarLeading) {
                        Button("Back", systemImage: "chevron.backward") { iridiumNavigate("back") }
                            .keyboardShortcut(.cancelAction)
                    } }
case "Files & Saves": Form { Group { if let appID = entry.steamAppID { SteamCloudSection(appID: appID) }
                // A link that starts this game from a Home Screen icon (SavesAndShortcuts.swift).
                if entry.desktop != true {
                    Section {
                        Button {
                            UIPasteboard.general.string = ShortcutRouter.link(for: entry.windowsPath)
                            copiedLink = true
                        } label: {
                            Label(copiedLink ? "Link copied" : "Copy Home Screen shortcut link",
                                  systemImage: copiedLink ? "checkmark" : "link")
                        }
                    } header: { Text("Home Screen") } footer: {
                        Text("In the Shortcuts app: new shortcut, Open URLs, paste the link, then Share › Add to Home Screen.")
                    }
                }
                if entry.steamAppID != nil {
                    Section {
                        Text(entry.launchWindowsPath).font(.caption.monospaced()).textSelection(.enabled)
                        if entry.startsSteamGameDirectly, !entry.launchArguments.isEmpty {
                            Text(entry.launchArguments).font(.caption.monospaced()).textSelection(.enabled)
                        }
                    } header: { Text("Executable") } footer: {
                        Text(entry.startsSteamGameDirectly
                             ? "The game starts this program directly, without Steam."
                             : "Valve's client starts the game's default Steam launch option from this folder.")
                    }
                } else if entry.desktop != true {
                    Section("Executable") { Text(entry.windowsPath).font(.caption.monospaced()).textSelection(.enabled) }
                }
 }.iridiumRowSurface() }.iridiumPageSurface().navigationTitle("Files & Saves")
                    .navigationBarBackButtonHidden()
                    .toolbar { ToolbarItem(placement: .topBarLeading) {
                        Button("Back", systemImage: "chevron.backward") { iridiumNavigate("back") }
                            .keyboardShortcut(.cancelAction)
                    } }
case "Advanced": Form { Group {                 // ml1163: how the program starts. Not for the Desktop entry, nor for a Steam
                // game started through Madeira Dock, whose desktop and command are Dock's:
                // there these choices would do nothing.
                if entry.usesLaunchOptions {
                    Section {
                        Picker("Start", selection: Binding(get: { entry.runsInDesktop ? "desktop" : "direct" }, set: {
                            entry.launchMode = $0 == "desktop" ? "desktop" : nil
                        })) {
                            Text("Directly").tag("direct")
                            Text("In the Wine desktop").tag("desktop")
                        }
                        TextField("Working folder (default: the program's folder)", text: Binding(get: { entry.workingDirectory ?? "" }, set: {
                            entry.workingDirectory = $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0
                        })).autocorrectionDisabled().textInputAutocapitalization(.never).font(.body.monospaced())
                        Toggle("Start Windows services first", isOn: Binding(get: { entry.startServices == true }, set: {
                            entry.startServices = $0 ? true : nil
                        }))
                    } header: { Text("Launch") } footer: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Start the game on its own, or use the Wine desktop for launchers and desktop windows.")
                            Text("Use a Windows path for the working folder. Enable Windows services only if your launcher needs them.")
                            if !entry.runsInDesktop && (entry.isBatch || entry.startServices == true) {
                                // Wine stops with its first process (the ml1163 open risk).
                                Text("Started directly, Wine stops when its first program exits, so a batch file that starts the game and exits closes the game too. Start it in the Wine desktop instead.")
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                }
                // A Steam game starts with Steam's own launch option through Madeira Dock.
                if entry.desktop != true && entry.steamAppID == nil {
                    Section {
                        TextField("Launch arguments", text: $entry.arguments, axis: .vertical)
                            .font(.body.monospaced()).lineLimit(1...4)
                            .autocorrectionDisabled().textInputAutocapitalization(.never)
                        LaunchFlagChips(arguments: $entry.arguments)
                        // What the next start runs (ml1163: in the Wine desktop, a batch file or
                        // the services batch, what starts the program).
                        Text(entry.commandPreview)
                            .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    } header: { Text("Launch arguments") } footer: {
                        Text("Applied when this game starts. The command above includes your selected flags.")
                    }
                }
                Section {
                    Toggle("Reduced-precision x87", isOn: $entry.reducedX87)
                    // Exported for this game only when chosen (applyEnvironment).
                    // madeira-bcd: AVX, NVIDIA and Wine's C++ runtime are LibraryPrefs, which
                    // BCDLaunch exports.
                    Toggle("AVX and AVX2", isOn: Binding(get: { bcd.avx }, set: { on in
                        bcd.avx = on; LibraryPrefs.setAVX(on, for: entry.windowsPath)
                    }))
                    // Exported for this game only when chosen (applyEnvironment).
                    Picker("CPU cores reported", selection: Binding(get: { entry.cpuCount ?? 0 }, set: { entry.cpuCount = $0 == 0 ? nil : $0 })) {
                        Text("Automatic").tag(0)
                        ForEach([1, 2, 4, 6], id: \.self) { Text("\($0)").tag($0) }
                    }
                    Toggle("Report an NVIDIA GPU", isOn: Binding(get: { bcd.nvidia }, set: { on in
                        bcd.nvidia = on; LibraryPrefs.setNvidia(on, for: entry.windowsPath)
                    }))
                    Toggle("Wine's C++ runtime", isOn: Binding(get: { bcd.wineVCRT }, set: { on in
                        bcd.wineVCRT = on; LibraryPrefs.setWineVCRT(on, for: entry.windowsPath)
                    }))
                    // Fastsync-only switches: shown for every game, usable only while
                    // Settings › Sync engine is Fastsync.
                    Group {
                        Toggle("Fast synchronization", isOn: Binding(get: { entry.fastSync ?? true }, set: { entry.fastSync = $0 }))
                        Toggle("Fast semaphore waits (experimental)",
                               isOn: Binding(get: { entry.semaphoreFastPath ?? false }, set: { entry.semaphoreFastPath = $0 }))
                    }
                    .disabled(syncEngine != .fastsync)
                    if syncEngine != .fastsync {
                        Text("Fast synchronization and fast semaphore waits are Fastsync options. Choose Fastsync in Settings → Madeira → Advanced Compatibility to use them.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } header: { Text("Compatibility & performance") } footer: {
                    Text("Use compatibility options when a game needs them. Changes apply next launch; precision changes may require restarting Iridium.")
                }
                Section {
                    NavigationLink {
                        LibraryGameConfigEditor(text: Binding(get: { bcd.configText }, set: { text in
                            bcd.configText = text
                            GameProfile(windowsPath: entry.windowsPath).text = text
                        }))
                        .onDisappear { reloadBCD() }
                    } label: {
                        LabeledContent("This game's config", value: Self.configSummary(bcd.configText))
                    }
                } header: { Text("Advanced") } footer: {
                    Text("Keys here override shared settings for this game. Changes apply next launch.")
                }

if entry.steamAppID != nil { SteamEntrySection(entry: $entry) { leaving = true; dismiss() } } }.iridiumRowSurface() }.iridiumPageSurface().navigationTitle("Advanced")
                    .navigationBarBackButtonHidden()
                    .toolbar { ToolbarItem(placement: .topBarLeading) {
                        Button("Back", systemImage: "chevron.backward") { iridiumNavigate("back") }
                            .keyboardShortcut(.cancelAction)
                    } }
                default: EmptyView()
                }
            }

            .iridiumPageSurface().navigationTitle("Game Options").navigationBarTitleDisplayMode(.inline)
            .focusable().focusEffectDisabled().focused($iridiumKeyboard)
            .onAppear { iridiumKeyboard = true }
            .onChange(of: iridiumPages) { _, pages in if pages.isEmpty { iridiumKeyboard = true } }
            .onKeyPress(.escape, phases: .down) { _ in
                guard iridiumPages.last != "Rename & Artwork" else { return .ignored }
                iridiumNavigate("back"); return .handled
            }
.onKeyPress(.upArrow) {
                guard iridiumPages.isEmpty else { return .ignored }
                iridiumNavigate("up"); return .handled
            }
.onKeyPress(.downArrow) {
                guard iridiumPages.isEmpty else { return .ignored }
                iridiumNavigate("down"); return .handled
            }
.onKeyPress(.leftArrow) {
                guard iridiumPages.isEmpty else { return .ignored }
                iridiumNavigate("left"); return .handled
            }
.onKeyPress(.rightArrow) {
                guard iridiumPages.isEmpty else { return .ignored }
                iridiumNavigate("right"); return .handled
            }
.onKeyPress(.return) {
                guard iridiumPages.isEmpty else { return .ignored }
                iridiumNavigate("accept"); return .handled
            }

            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { model.save(entry); dismiss() } } }
            .task {
                if entry.graphicsAPI == nil, entry.desktop != true, let url = try? LibraryModel.executable(entry.relativePath) { entry.graphicsAPI = LibraryModel.graphicsImports(url) }
            }
            // Play's checks read the installed games and Dock's client state, which the
            // Steam page refreshed when it was on this page.
            .onAppear { if entry.steamAppID != nil { MadeiraDockModel.shared.refresh(); SteamGamesModel.shared.refresh() } }
            // madeira-bcd: the game's own switches and config file, and its recommended settings.
            .onAppear {
                migrateEntryOptions()
                prepareRecommendation()
                reloadBCD()
                if !iridiumInitialPageOpened { iridiumInitialPageOpened = true; if let iridiumInitialPage { iridiumPages = [iridiumInitialPage] } }
            }
            .onDisappear { if !leaving { model.save(entry) } }
            .confirmationDialog("Remove this game from the library? Its files and saves will stay.", isPresented: $remove, titleVisibility: .visible) {
                Button("Remove from Library", role: .destructive) { leaving = true; model.remove(entry.id); dismiss() }
            }
            .onReceive(LibraryController.shared.commands) { command in
                guard iridiumPages.last != "Rename & Artwork" else { return }
                guard !leaving, !findCover, !importCover, !remove, !confirmReset else { return }
                iridiumNavigate(command)
                if command == "play" { start() }
            }
        }.onChange(of: iridiumFocus) { _, title in proxy.scrollTo(title, anchor: .center) }
      }
    }
}

/// madeira-bcd: a game's own options as the fork stores them (LibraryDetail):
/// LibraryPrefs' switches and the GameProfiles.swift file's lines.
struct BCDGameValues {
    var avx = false, nvidia = false, wineVCRT = false
    var configText = ""
    init() {}
    init(windowsPath: String) {
        avx = LibraryPrefs.avx(windowsPath)
        nvidia = LibraryPrefs.nvidia(windowsPath)
        wineVCRT = LibraryPrefs.wineVCRT(windowsPath)
        configText = GameProfile(windowsPath: windowsPath).text
    }
}

/// Game details › This game's config: the game's own lines in madeira.cfg's
/// syntax, applied at its next start. madeira-bcd: LibraryDetail binds it to the
/// game's GameProfiles.swift file (Application Support/GameConfigs), which every
/// launch exports as MADEIRA_CFG_GAME (BCDLaunch, MadeiraConfig.applyGame).
struct LibraryGameConfigEditor: View {
    @Binding var text: String
    var body: some View {
        Form {
            Group {
            Section {
                TextEditor(text: $text)
                    .font(.caption.monospaced()).frame(minHeight: 260)
                    .autocorrectionDisabled().textInputAutocapitalization(.never)
            } footer: {
                Text("One key = value per line, as in madeira.cfg; lines starting with # are comments. Examples: fence-chain = 6, dxmt = d3d11.mipClampBC=1, env.FEX_MULTIBLOCK = 1.")
            }
            }.iridiumRowSurface()
        }
        .iridiumPageSurface().navigationTitle("This game's config").navigationBarTitleDisplayMode(.inline)
    }
}

/// Game details › Find on Steam: searches the public store by title; choosing
/// a result gives the entry that app's name and store artwork.
struct SteamSearchView: View {
    @State private var query: String
    var select: (SteamMatch) -> Void

    init(query: String, select: @escaping (SteamMatch) -> Void) {
        _query = State(initialValue: query); self.select = select
    }
    @Environment(\.dismiss) private var dismiss
    @State private var results: [SteamMatch] = []
    @State private var error: String?
    @State private var loading = false
    @State private var submitted = ""
    var body: some View {
        NavigationStack {
            List {
                if loading { ProgressView("Searching Steam…") }
                if let error { Text(error).foregroundStyle(.secondary) }
                ForEach(results) { match in
                    Button { select(match); dismiss() } label: {
                        HStack {
                            AsyncImage(url: URL(string: match.tiny_image ?? "")) { $0.resizable().scaledToFit() } placeholder: { Image(systemName: "gamecontroller") }.frame(width: 70, height: 40)
                            Text(match.name).foregroundStyle(.primary)
                        }
                    }
                }
            }.iridiumPageSurface().navigationTitle("Find on Steam")
            .searchable(text: $query, prompt: "Title").onSubmit(of: .search) { submitted = query }
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onAppear { submitted = query }
            .task(id: submitted) {
                guard !submitted.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                loading = true; error = nil
                do { let found = try await SteamCatalog.search(submitted); try Task.checkCancellation(); results = found; if found.isEmpty { error = "No matches. Try a different title." } }
                catch is CancellationError { return }
                catch { self.error = error.localizedDescription }
                loading = false
            }
        }
    }
}

/// Keyboard-and-mouse mode: one row per controller input with a menu of what it
/// does, saved to the game. Used as a page of the Session menu (live: the driver
/// takes each change at once) and as a sheet from Game details. Rows the player
/// has not changed show the layout's or the template's action and are not stored.
struct ControllerBindsPage: View {
    @Binding var binds: [String: ControlAction]?
    /// Vertical speed of the right-stick mouse, 1 = as horizontal; nil = 1.
    @Binding var mouseVertical: Double?
    /// The active layout's own bindings, so an unchanged row shows what really
    /// happens in this session; Game details passes none.
    var controls: [TouchControl] = []

    private static let groups: [(String, [String])] = [
        ("Sticks", ["LS", "RS"]),
        ("Face", ["A", "B", "X", "Y"]),
        ("Bumpers & triggers", ["LB", "RB", "LT", "RT"]),
        ("D-pad", ["D↑", "D↓", "D←", "D→"]),
        ("System", ["Menu", "View", "L3", "R3"]),
    ]

    var body: some View {
        ForEach(Self.groups, id: \.0) { group in
            Section(group.0) {
                ForEach(group.1, id: \.self) { name in row(name) }
            }
        }
        if effective("RS").stickKeys == nil {
            Section("Right stick as mouse") {
                LabeledContent("Vertical speed") {
                    HStack {
                        Slider(value: Binding(get: { mouseVertical ?? 1 }, set: { mouseVertical = abs($0 - 1) < 0.01 ? nil : $0 }), in: 0.25...1.5, step: 0.05)
                        Text("\(Int(((mouseVertical ?? 1) * 100).rounded()))%").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 44, alignment: .trailing)
                    }
                }
                .id("controls.mapping.vertical")
                .setupControllerTarget("controls.mapping.vertical", order: 900, action: { changeMouseVertical(1) }, adjust: changeMouseVertical)
                Text("Relative to horizontal. Games scale the camera's pitch and yaw differently from a mouse; lower this if the view climbs faster than it turns.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        Section {
            Button("Reset all to defaults", role: .destructive) { reset() }
                .id("controls.mapping.reset")
                .setupControllerTarget("controls.mapping.reset", order: 1000, action: reset)
                .disabled(!changed)
            Text("Defaults: left stick WASD, right stick mouse, RT and LT click, D-pad arrows, A Space, B Ctrl, X E, Y R, LB Q, RB F, L3 Shift, R3 C, Start Esc, Select Tab. A touch control's own controller binding (control editor) applies when a row is at its default.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    func controllerTargets(page: String, reveal: @escaping (String) -> Void) -> [SetupControllerTarget] {
        func row(_ id: String, _ order: Int, enabled: Bool = true, action: @escaping () -> Void, adjust: ((Int) -> Void)? = nil) -> SetupControllerTarget {
            .init(id: id, page: page, order: order, frame: .zero, enabled: enabled, action: action, adjust: adjust, reveal: { reveal(id) })
        }
        var rows = Self.groups.flatMap(\.1).enumerated().map { index, name in
            row("controls.bind.\(name)", 100 + index, action: { cycleBinding(name, direction: 1) }, adjust: { cycleBinding(name, direction: $0) })
        }
        if effective("RS").stickKeys == nil {
            rows.append(row("controls.mapping.vertical", 900, action: { changeMouseVertical(1) }, adjust: changeMouseVertical))
        }
        rows.append(row("controls.mapping.reset", 1000, enabled: changed, action: reset))
        return rows
    }
    private func changeMouseVertical(_ direction: Int) {
        let value = min(1.5, max(0.25, (mouseVertical ?? 1) + Double(direction) * 0.05))
        mouseVertical = abs(value - 1) < 0.01 ? nil : value
    }
    private func cycleBinding(_ name: String, direction: Int) {
        let actions: [ControlAction]
        if name == "LS" || name == "RS" { actions = [.none, .joystickWASD, .joystickArrows] }
        else {
            let keys = Array(0x41...0x5A) + Array(0x30...0x39) + Array(0x70...0x7B)
                + [0x1B, 0x09, 0x10, 0x11, 0x12, 0x20, 0x0D, 0x08, 0x14,
                   0x26, 0x28, 0x25, 0x27, 0x2D, 0x2E, 0x24, 0x23, 0x21, 0x22,
                   0xBD, 0xBB, 0xDB, 0xDD, 0xDC, 0xBA, 0xDE, 0xBC, 0xBE, 0xBF, 0xC0]
                + Array(0x60...0x69) + [0x6A, 0x6B, 0x6D, 0x6E, 0x6F]
            actions = [.mouseLeft, .mouseRight] + keys.map { .key(Int32($0)) } + [.keyboardToggle, .none]
        }
        let values: [ControlAction?] = [nil] + actions.map { Optional.some($0) }
        var table = binds ?? [:]
        table[name] = SetupControllerPolicy.cycled(table[name], in: values, direction: direction)
        binds = table.isEmpty ? nil : table
    }

    /// Anything to reset: a bound row or a vertical speed other than 1.
    var changed: Bool { !(binds ?? [:]).isEmpty || mouseVertical != nil }
    func reset() { binds = nil; mouseVertical = nil }

    /// What the input does in this session: the table's entry, else the layout's, else the template's.
    private func effective(_ name: String) -> ControlAction {
        let fromLayout = PadBindings.build(controls: controls)
        return binds?[name] ?? (name == "LS" ? fromLayout.leftStick : name == "RS" ? fromLayout.rightStick : fromLayout.buttons[name] ?? .none)
    }

    private func row(_ name: String) -> some View {
        let effective = effective(name)
        let changed = binds?[name] != nil
        return LabeledContent(PadBindings.displayName(name)) {
            Menu {
                if name == "LS" || name == "RS" {
                    pick(name, name == "RS" ? "Mouse" : "Nothing", .none)
                    pick(name, "WASD", .joystickWASD)
                    pick(name, "Arrow keys", .joystickArrows)
                } else {
                    pick(name, "Left click", .mouseLeft)
                    pick(name, "Right click", .mouseRight)
                    Menu("Letters") { ForEach(0x41...0x5A, id: \.self) { vk in pick(name, String(UnicodeScalar(UInt8(vk))), .key(Int32(vk))) } }
                    Menu("Numbers") { ForEach(0x30...0x39, id: \.self) { vk in pick(name, String(UnicodeScalar(UInt8(vk))), .key(Int32(vk))) } }
                    Menu("Function keys") { ForEach(0...11, id: \.self) { i in pick(name, "F\(i + 1)", .key(Int32(0x70 + i))) } }
                    Menu("Modifiers & editing") {
                        pick(name, "Escape", .key(0x1B)); pick(name, "Tab", .key(0x09)); pick(name, "Shift", .key(0x10))
                        pick(name, "Ctrl", .key(0x11)); pick(name, "Alt", .key(0x12)); pick(name, "Space", .key(0x20))
                        pick(name, "Enter", .key(0x0D)); pick(name, "Backspace", .key(0x08)); pick(name, "Caps Lock", .key(0x14))
                    }
                    Menu("Navigation") {
                        pick(name, "↑", .key(0x26)); pick(name, "↓", .key(0x28)); pick(name, "←", .key(0x25)); pick(name, "→", .key(0x27))
                        pick(name, "Insert", .key(0x2D)); pick(name, "Delete", .key(0x2E)); pick(name, "Home", .key(0x24))
                        pick(name, "End", .key(0x23)); pick(name, "Page Up", .key(0x21)); pick(name, "Page Down", .key(0x22))
                    }
                    Menu("Symbols") {
                        pick(name, "-", .key(0xBD)); pick(name, "=", .key(0xBB)); pick(name, "[", .key(0xDB)); pick(name, "]", .key(0xDD))
                        pick(name, "\\", .key(0xDC)); pick(name, ";", .key(0xBA)); pick(name, "'", .key(0xDE)); pick(name, ",", .key(0xBC))
                        pick(name, ".", .key(0xBE)); pick(name, "/", .key(0xBF)); pick(name, "`", .key(0xC0))
                    }
                    Menu("Numpad") {
                        ForEach(0...9, id: \.self) { i in pick(name, "Numpad \(i)", .key(Int32(0x60 + i))) }
                        pick(name, "Numpad *", .key(0x6A)); pick(name, "Numpad +", .key(0x6B)); pick(name, "Numpad −", .key(0x6D))
                        pick(name, "Numpad .", .key(0x6E)); pick(name, "Numpad /", .key(0x6F))
                    }
                    pick(name, "Show keyboard", .keyboardToggle)
                    pick(name, "Nothing", .none)
                }
                if changed {
                    Divider()
                    Button("Default") { binds?[name] = nil; if binds?.isEmpty == true { binds = nil } }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(Self.describe(effective, input: name))
                        .foregroundStyle(changed ? .primary : .secondary)
                    Image(systemName: "chevron.up.chevron.down").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .id("controls.bind.\(name)")
        .setupControllerTarget("controls.bind.\(name)", order: 100 + (Self.groups.flatMap(\.1).firstIndex(of: name) ?? 0),
            action: { cycleBinding(name, direction: 1) }, adjust: { cycleBinding(name, direction: $0) })
    }

    private func pick(_ name: String, _ title: String, _ action: ControlAction) -> some View {
        Button(title) {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            var table = binds ?? [:]
            table[name] = action
            binds = table
        }
    }

    /// Row text for an action, in the words the menu uses.
    static func describe(_ action: ControlAction, input: String) -> String {
        switch action {
        case .none:            return input == "RS" ? "Mouse" : "Nothing"
        case .mouseLeft:       return "Left click"
        case .mouseRight:      return "Right click"
        case .joystickWASD:    return "WASD"
        case .joystickArrows:  return "Arrow keys"
        case .keyboardToggle:  return "Show keyboard"
        case .pad(let n):      return n
        case .key(let vk):     return keyName(vk)
        }
    }
    static func keyName(_ vk: Int32) -> String {
        switch vk {
        case 0x20: return "Space"
        case 0x0D: return "Enter"
        case 0x09: return "Tab"
        case 0x1B: return "Escape"
        case 0x10: return "Shift"
        case 0x11: return "Ctrl"
        case 0x12: return "Alt"
        case 0x08: return "Backspace"
        case 0x14: return "Caps Lock"
        case 0x2D: return "Insert"
        case 0x2E: return "Delete"
        case 0x24: return "Home"
        case 0x23: return "End"
        case 0x21: return "Page Up"
        case 0x22: return "Page Down"
        case 0x70...0x7B: return "F\(vk - 0x6F)"
        case 0x60...0x69: return "Numpad \(vk - 0x60)"
        case 0x6A: return "Numpad *"
        case 0x6B: return "Numpad +"
        case 0x6D: return "Numpad −"
        case 0x6E: return "Numpad ."
        case 0x6F: return "Numpad /"
        default:   return ControlAction.keyLabel(vk)
        }
    }
}

/// Game details: whether a Steam game that Valve's client starts (Madeira Dock)
/// can start without a connection (DockOffline.Mark). Steam's offline sign-in
/// belongs to the account: once Valve's client has reported that it can sign the
/// account in offline, every installed game can start that way, and the client
/// answers the license question from the list it cached. Only a game whose
/// per-user program Steam prepares on its first start still needs that one start
/// online. Tapping the line explains it; an offline start is always Steam's
/// decision at that moment.
struct DockOfflineMark: View {
    let appID: Int
    @State private var explain = false
    /// The game's install record lists per-user executables (read once; it scans the library).
    @State private var preparedOnline = false
    var body: some View {
        let mark = DockOffline.mark(appID, preparedOnline: preparedOnline)
        let ready: Bool = { if case .ready = mark { return true } else { return false } }()
        Button { explain = true } label: {
            // Not a Label: inside a Form row a Label takes the list's wide icon column,
            // which leaves the text far from its symbol.
            HStack(spacing: 5) {
                Image(systemName: ready ? "checkmark.circle.fill" : "wifi.exclamationmark")
                Text(Self.line(mark))
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(ready ? Color.green : Color.secondary)
        }
        .buttonStyle(.plain)
        .task { preparedOnline = MadeiraDock.games(drive: MadeiraDock.drive).first { $0.id == appID }?.customExecutables ?? false }
        .alert(ready ? "Can be played offline" : "Not ready for offline play yet", isPresented: $explain) {
            Button("OK", role: .cancel) {}
        } message: { Text(Self.explanation(mark)) }
    }
    static func line(_ mark: DockOffline.Mark) -> String {
        switch mark {
        case .ready: return "Can be played offline"
        case .needsFirstStart: return "Start once online to play offline"
        case .needsOnline: return "Start a game online to play offline"
        }
    }
    static func explanation(_ mark: DockOffline.Mark) -> String {
        switch mark {
        case .ready(let saved):
            return "Steam signed in online on this device on \(saved.formatted(date: .abbreviated, time: .omitted)) and can now sign this account in without a connection. With no internet, Madeira asks Steam to start the game offline; Steam checks its saved sign-in and its saved list of your licenses each time. Its offline sign-in expires after a while, so start a game online now and then. A game that needs its own servers still needs them."
        case .needsFirstStart:
            return "Steam can sign this account in offline, but it prepares this game's program for your account the first time it starts, and that needs a connection. Start this game once while you are online."
        case .needsOnline:
            return "Steam has not saved an offline sign-in on this device yet. Start any Steam game once while you are online; after that, installed games can start without a connection."
        }
    }
}

/// Game details and the Session menu: how a physical controller reaches the game.
struct ControllerModeChoice: View {
    @Binding var mode: String?
    var body: some View {
        LabeledContent("Controller") {
            Picker("Controller", selection: Binding(get: { mode ?? "" }, set: { mode = $0.isEmpty ? nil : $0 })) {
                Text("XInput").tag("")
                Text("XInput and DirectInput").tag("dinput")
                Text("Keyboard and mouse").tag("keys")
            }.pickerStyle(.menu).labelsHidden()
        }
        .id("controls.mapping.mode")
        .setupControllerValue("controls.mapping.mode", order: 0,
            selection: Binding(get: { mode ?? "" }, set: { mode = $0.isEmpty ? nil : $0 }), values: ["", "dinput", "keys"])
    }
    func controllerTarget(page: String, reveal: @escaping (String) -> Void) -> SetupControllerTarget {
        let change: (Int) -> Void = { direction in
            let value = SetupControllerPolicy.cycled(mode ?? "", in: ["", "dinput", "keys"], direction: direction)
            mode = value.isEmpty ? nil : value
        }
        return .init(id: "controls.mapping.mode", page: page, order: 0, frame: .zero, enabled: true,
            action: { change(1) }, adjust: change, reveal: { reveal("controls.mapping.mode") })
    }
}

/// Game details › Launch arguments: one chip per common flag, highlighted when
/// the arguments contain it; a tap adds or removes it. -dx9 to -dx12 exclude each
/// other, as do -windowed and -fullscreen. Quoted arguments are kept whole.
struct LaunchFlagChips: View {
    @Binding var arguments: String
    static let flags = ["-dx11", "-dx12", "-dx10", "-dx9", "-windowed", "-fullscreen", "-nosplash"]

    /// The arguments split at unquoted spaces and tabs, quotes kept.
    static func tokens(_ text: String) -> [String] {
        var out: [String] = [], current = "", quoted = false
        for character in text {
            if character == "\"" { quoted.toggle() }
            if !quoted && (character == " " || character == "\t") {
                if !current.isEmpty { out.append(current); current = "" }
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }
    static func contains(_ text: String, _ flag: String) -> Bool {
        tokens(text).contains { $0.caseInsensitiveCompare(flag) == .orderedSame }
    }
    static func toggled(_ text: String, _ flag: String) -> String {
        var parts = tokens(text)
        if contains(text, flag) {
            parts.removeAll { $0.caseInsensitiveCompare(flag) == .orderedSame }
        } else {
            let renderers = ["-dx9", "-dx10", "-dx11", "-dx12"]
            if renderers.contains(flag) { parts.removeAll { renderers.contains($0.lowercased()) } }
            if flag == "-windowed" { parts.removeAll { $0.lowercased() == "-fullscreen" } }
            if flag == "-fullscreen" { parts.removeAll { $0.lowercased() == "-windowed" } }
            parts.append(flag)
        }
        return parts.joined(separator: " ")
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Self.flags, id: \.self) { flag in
                    let on = Self.contains(arguments, flag)
                    Button(flag) { arguments = Self.toggled(arguments, flag) }
                        .buttonStyle(.bordered).tint(on ? Color.accentColor : Color.gray)
                        .font(.caption.monospaced())
                        .accessibilityValue(on ? "On" : "Off")
                }
            }
        }
    }
}

struct FPSChoice: View {
    @Binding var mode: Int
    var body: some View {
        HStack { Text("FPS limit"); Spacer(); Picker("FPS limit", selection: $mode) {
            // 30 needs DXMT's 30 FPS cap (ProMotionIntent.has30Cap); a saved 30 stays selectable.
            if ProMotionIntent.has30Cap || mode == 3 { Text("30 FPS").tag(3) }
            // 40 needs DXMT's 40 FPS cap and a 120 Hz panel (ProMotionIntent.has40Cap).
            if ProMotionIntent.has40Cap || mode == 4 { Text("40 FPS").tag(4) }
            Text("60 FPS").tag(1); Text("Display maximum").tag(0); Text("Uncapped").tag(2)
        }.labelsHidden().pickerStyle(.menu) }
    }
}

/// Holding the display at its maximum refresh rate in the 60 FPS limit
/// (madeira.cfg env.MADEIRA_PROMOTE = 1, off by default; see ProMotionIntent).
/// Applies from the next session start or FPS limit change.
struct DisplayRateSettings: View {
    @State private var hold = ProMotionIntent.holdMaximum

    var body: some View {
        Section {
            Toggle("Hold the display at its maximum rate", isOn: Binding(get: { hold }, set: { on in
                hold = on
                MadeiraConfig.set("env.MADEIRA_PROMOTE", on ? "1" : nil)
                LogStore.shared.log("[runtime-settings] promote=\(on ? 1 : 0)")
            }))
        } header: { Text("Display") } footer: {
            Text("Keeps supported displays at their highest refresh rate during games. Uses more power.")
        }
    }
}

/// One row of Settings › Credits: a person, their GitHub account and what they did.
struct MadeiraCredit: View {
    let name: String
    let handle: String
    let role: String
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(name).font(.body.weight(.semibold))
                if let url = URL(string: "https://github.com/\(handle)") {
                    Link("@\(handle)", destination: url).font(.subheadline)
                }
            }
            Text(role).font(.subheadline).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// Settings › Memory & sync: the JIT pool (madeira.cfg pool), the video memory
/// budget (vram-mb), the file-backed swap tier (swap-mb, off by default, and
/// env.MADEIRA_SWAP_COVERAGE, which allocations it backs) and the in-process sync
/// engine (SyncEngine: fastsync by default, madsync or Wine's own). All are read when Madeira starts,
/// so changes apply after a restart. "All settings" opens every other option.
/// MADEIRA_RUNTIME_SETTINGS=0 hides this section.
/// A sheet opened from Settings; LibraryView presents it from the Form itself.
enum SettingsSheet: String, Identifiable {
    case allSettings, steamSignIn, dock
    var id: String { rawValue }
}

/// The in-process synchronisation engine, one per session. Fastsync is the default:
/// madeira.cfg with neither inproc-sync nor env.MADEIRA_FASTSYNC, for which the app
/// exports MADEIRA_FASTSYNC=auto (WineProcessBridge.m). Madsync is inproc-sync = 1;
/// Wine standard sync is inproc-sync = 0 without a fastsync value, as it was written
/// while madsync was the default. Mirrors madeira_cfg_sync_engine (build/madeira_cfg.h).
/// Wine reads both once per app run, and never runs fastsync while madsync is on.
enum SyncEngine: String, CaseIterable, Identifiable {
    case madsync, fastsync, wine
    var id: String { rawValue }
    var label: String {
        switch self {
        case .madsync: return "Madsync"
        case .fastsync: return "Fastsync (default)"
        case .wine: return "Wine standard sync"
        }
    }
    /// The MADEIRA_FASTSYNC values Wine treats as "fastsync on" (sync.c, event.c).
    static let fastsyncValues: Set<String> = ["1", "on", "yes", "auto", "cells"]
    static var current: SyncEngine {
        let inproc = MadeiraConfig.get("inproc-sync")
        if inproc != nil && MadeiraConfig.bool("inproc-sync", default: false) { return .madsync }
        if let fast = MadeiraConfig.get("env.MADEIRA_FASTSYNC") { return fastsyncValues.contains(fast) ? .fastsync : .wine }
        return inproc == nil ? .fastsync : .wine
    }
    static func apply(_ engine: SyncEngine) {
        switch engine {
        case .madsync: MadeiraConfig.set("inproc-sync", "1"); MadeiraConfig.set("env.MADEIRA_FASTSYNC", nil)
        case .fastsync: MadeiraConfig.set("inproc-sync", nil); MadeiraConfig.set("env.MADEIRA_FASTSYNC", nil)
        case .wine: MadeiraConfig.set("inproc-sync", "0"); MadeiraConfig.set("env.MADEIRA_FASTSYNC", nil)
        }
    }
}

struct RuntimeMemorySyncSettings: View {
    /// Opens a Settings sheet (LibraryView owns the presentation).
    var open: (SettingsSheet) -> Void = { _ in }
    /// Bumped when a Settings sheet closes, so the rows re-read madeira.cfg.
    var refresh = 0
    /// The keys this section and Settings › Graphics own; All settings and the Settings
    /// search leave them out.
    static let featuredKeys: Set<String> = Set(["pool", "vram-mb", "swap-mb", "env.MADEIRA_SWAP_COVERAGE", "inproc-sync",
                                                "env.MADEIRA_FASTSYNC", "eco"])
    // ml1241: 256 (the launch's lower bound) for the pool, 512 and 1024 for video memory
    // (winemetal accepts vram-mb >= 256), at the user's request.
    static let poolChoices = [0, 256, 512, 640, 768, 1024, 1152]          // 0 = the standard 896 MB
    static let vramChoices = [0, 512, 1024, 1536, 2048, 3072, 4096, 4352, 4608, 5120, 6144]   // 0 = automatic
    static let swapChoices = [0, 1024, 2048, 3072, 4096]
    /// The stored value "" (no key) and "classic" are the same rules, unless
    /// madeira.cfg has swap-mode = 2 (then no key means broad, ml1257).
    static let coverageChoices: [(String, String)] = [
        ("", "Large allocations (8 MB+)"), ("blocks", "All allocations of 1 MB+"), ("wide", "1 MB+ and overflow"),
        ("broad", "Whole reservations 4 MB+ (broad)"),
    ]
    @State private var poolMB = Self.intKey("pool")
    @State private var vramMB = Self.intKey("vram-mb")
    @State private var swapMB = Self.intKey("swap-mb")
    @State private var coverage = Self.currentCoverage()
    @State private var engine = SyncEngine.current
    @State private var eco = MadeiraConfig.bool("eco", default: false)
    @State private var changed = false

    /// The configured value in MB, shown as itself even when it is not one of the choices.
    static func intKey(_ key: String) -> Int { Int(MadeiraConfig.get(key) ?? "") ?? 0 }
    static func currentCoverage() -> String {
        let v = (MadeiraConfig.get("env.MADEIRA_SWAP_COVERAGE") ?? "").lowercased()
        if v.isEmpty { return swapModeBroad ? "broad" : "" }
        return v == "classic" ? "" : v
    }
    /// ml1257: madeira.cfg swap-mode = 2 selects broad coverage when
    /// env.MADEIRA_SWAP_COVERAGE is unset (virtual_ios.c ios_swap_config).
    static var swapModeBroad: Bool { (Int(MadeiraConfig.get("swap-mode") ?? "") ?? 1) >= 2 }
    static func gb(_ mb: Int) -> String {
        String(format: "%g GB", Double(mb) / 1024)   // 1.5, 4, 4.25 ...
    }

    private func mbPicker(_ title: String, key: String, value: Binding<Int>, choices: [Int],
                          zero: String, label: @escaping (Int) -> String) -> some View {
        Picker(title, selection: Binding(get: { value.wrappedValue }, set: { mb in
            value.wrappedValue = mb; changed = true
            MadeiraConfig.set(key, mb > 0 ? String(mb) : nil)
            LogStore.shared.log("[runtime-settings] \(key)=\(mb)")
        })) {
            ForEach(choices, id: \.self) { mb in Text(mb == 0 ? zero : label(mb)).tag(mb) }
            if !choices.contains(value.wrappedValue) { Text("\(value.wrappedValue) MB").tag(value.wrappedValue) }
        }
    }

    var body: some View {
        Section {
            mbPicker("Code translation memory", key: "pool", value: $poolMB, choices: Self.poolChoices,
                     zero: "Default (896 MB)", label: { "\($0) MB" })
            mbPicker("Video memory", key: "vram-mb", value: $vramMB, choices: Self.vramChoices,
                     zero: "Automatic", label: Self.gb)
            mbPicker("Extra storage for memory", key: "swap-mb", value: $swapMB, choices: Self.swapChoices,
                     zero: "Off", label: Self.gb)
            Picker("Memory fallback coverage", selection: Binding(get: { coverage }, set: { mode in
                coverage = mode; changed = true
                // With swap-mode = 2 no key means broad, so classic is written out.
                MadeiraConfig.set("env.MADEIRA_SWAP_COVERAGE", mode.isEmpty ? (Self.swapModeBroad ? "classic" : nil) : mode)
                LogStore.shared.log("[runtime-settings] swap-coverage=\(mode.isEmpty ? "classic" : mode)")
            })) {
                ForEach(Self.coverageChoices, id: \.0) { Text($0.1).tag($0.0) }
                if !Self.coverageChoices.contains(where: { $0.0 == coverage }) { Text(coverage).tag(coverage) }
            }
            .disabled(swapMB == 0)
            Picker("Synchronization method", selection: Binding(get: { engine }, set: { choice in
                engine = choice; changed = true
                SyncEngine.apply(choice)
                LogStore.shared.log("[runtime-settings] sync-engine=\(choice.rawValue)")
            })) {
                ForEach(SyncEngine.allCases) { Text($0.label).tag($0) }
            }
            Toggle("Lower power priority", isOn: Binding(get: { eco }, set: { on in
                eco = on; changed = true
                MadeiraConfig.set("eco", on ? "1" : nil)
                LogStore.shared.log("[runtime-settings] eco=\(on ? 1 : 0)")
            }))
            Button { open(.allSettings) } label: {
                Label("All Compatibility Options", systemImage: "slider.horizontal.3")
            }
        } header: { Text("Advanced Runtime Tuning") } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("Code translation memory is reserved when a game starts. Low values can prevent large games from running.")
                Text("Video memory is reported to the game. Automatic is recommended; high values can cause memory-related exits.")
                Text("Memory fallback uses storage when RAM runs short. It can slow games down.")
                Text("Change synchronization only if a game needs it.")
                Text("Lower power priority reduces speed and power use.")
                if changed { Text("Close and reopen Iridium to apply these changes.").foregroundStyle(.orange) }
            }
        }
        .onChange(of: refresh) { _, _ in
            poolMB = Self.intKey("pool"); vramMB = Self.intKey("vram-mb"); swapMB = Self.intKey("swap-mb")
            coverage = Self.currentCoverage(); engine = SyncEngine.current
            eco = MadeiraConfig.bool("eco", default: false)
        }
    }
}

struct LibraryPointerSettings: View {
    @AppStorage(IridiumTouchMouseMode.settingsKey) private var mode = IridiumTouchMouseMode.trackpad.rawValue
    @AppStorage("IridiumMouseSensitivity") private var sensitivity = 1.0
    var body: some View {
        if TouchMouseGate.mode == .off {
            Text("Touch mouse is disabled by MADEIRA_TOUCH_MOUSE=0. Remove that override and restart Iridium to use these modes.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Picker("Touch mouse", selection: $mode) {
            Text("Off").tag(IridiumTouchMouseMode.off.rawValue)
            Text("Trackpad").tag(IridiumTouchMouseMode.trackpad.rawValue)
            Text("Direct").tag(IridiumTouchMouseMode.direct.rawValue)
        }.pickerStyle(.segmented)
            .id("controls.mouse.mode")
            .setupControllerTarget("controls.mouse.mode", order: 300, action: { changeMode(1) }, adjust: changeMode)
            .onChange(of: mode) { _, _ in MetalBackedView.keyboardTarget?.iridiumReleasePointer() }
        Text(mode == IridiumTouchMouseMode.off.rawValue ? "Touch gestures do not send mouse input. Controller and hardware pointer input remain available." : mode == IridiumTouchMouseMode.direct.rawValue
            ? "Tap where you want to click. Hold and move to drag. Two fingers right-click or scroll."
            : "Drag anywhere between controls to move the pointer. Tap to click; hold to drag. Two fingers right-click or scroll.")
            .font(.caption).foregroundStyle(.secondary)
        if mode == IridiumTouchMouseMode.trackpad.rawValue {
            LabeledContent("Pointer speed") { Slider(value: $sensitivity, in: 0.25...4) }
                .id("controls.mouse.speed")
                .setupControllerTarget("controls.mouse.speed", order: 310, action: { changeSpeed(1) }, adjust: changeSpeed)
        }
    }
    private func changeMode(_ direction: Int) { mode = SetupControllerPolicy.cycled(mode, in: IridiumTouchMouseMode.allCases.map(\.rawValue), direction: direction) }
    private func changeSpeed(_ direction: Int) { sensitivity = min(4, max(0.25, sensitivity + Double(direction) * 0.25)) }
    func controllerTargets(page: String, reveal: @escaping (String) -> Void) -> [SetupControllerTarget] {
        var rows = [SetupControllerTarget(id: "controls.mouse.mode", page: page, order: 300, frame: .zero, enabled: true,
            action: { changeMode(1) }, adjust: changeMode, reveal: { reveal("controls.mouse.mode") })]
        if mode == IridiumTouchMouseMode.trackpad.rawValue {
            rows.append(.init(id: "controls.mouse.speed", page: page, order: 310, frame: .zero, enabled: true,
                action: { changeSpeed(1) }, adjust: changeSpeed, reveal: { reveal("controls.mouse.speed") }))
        }
        return rows
    }
}


struct LibraryPillGlass: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    func body(content: Content) -> some View {
        if reduceTransparency { content.background(Color(uiColor: .secondarySystemBackground), in: Capsule()) }
        else if #available(iOS 26, *) { content.glassEffect(.regular.interactive(), in: Capsule()) }
        else { content.background(.regularMaterial, in: Capsule()) }
    }
}

// Keep drag state in this small view. Global translation remains stable while
// the view moves; local coordinates feed its own movement back in.
struct LibraryFloatingItem: View {
    let isMenu: Bool
    let viewport: CGSize
    let insets: EdgeInsets
    @ObservedObject private var model = LibraryModel.shared
    @AppStorage private var nx: Double
    @AppStorage private var ny: Double
    @GestureState private var drag = CGSize.zero
    @State private var measured = CGSize(width: 48, height: 48)
    @State private var faded = false
    @State private var touched = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(isMenu: Bool, viewport: CGSize, insets: EdgeInsets) {
        self.isMenu = isMenu; self.viewport = viewport; self.insets = insets
        _nx = AppStorage(wrappedValue: isMenu ? 0.92 : 0.25, isMenu ? "madeiraLibraryMenuX" : "madeiraLibraryMetricsX")
        _ny = AppStorage(wrappedValue: isMenu ? 0.12 : 0.08, isMenu ? "madeiraLibraryMenuY" : "madeiraLibraryMetricsY")
    }
    private func position(_ translation: CGSize) -> CGPoint {
        let left = insets.leading + measured.width / 2 + 8
        let top = insets.top + measured.height / 2 + 8
        return CGPoint(x: min(max(left, viewport.width * nx + translation.width), max(left, viewport.width - insets.trailing - measured.width / 2 - 8)),
                       y: min(max(top, viewport.height * ny + translation.height), max(top, viewport.height - insets.bottom - measured.height / 2 - 8)))
    }
    private func record(_ rect: CGRect) {
        if isMenu { model.menuButtonRect = rect } else { model.performanceRect = rect }
    }
    var body: some View {
        let center = position(drag)
        let rect = CGRect(x: center.x - measured.width / 2, y: center.y - measured.height / 2, width: measured.width, height: measured.height)
        Group {
            if isMenu {
                IridiumPlayerMenuButton(visible: !model.menu) { touched += 1; model.showMenu() }
                    .frame(width: 48, height: 48).opacity(model.menu ? 0 : 1)
                    .allowsHitTesting(!model.menu).accessibilityHidden(model.menu)
            } else { LibraryMetrics().accessibilityHint("Drag to move") }
        }
        .frame(maxWidth: isMenu ? 48 : max(48, min(390, viewport.width - insets.leading - insets.trailing - 16)))
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
                nx = end.x / max(1, viewport.width); ny = end.y / max(1, viewport.height); touched += 1
            }
        })
        .offset(x: center.x - measured.width / 2, y: center.y - measured.height / 2)
        .onAppear { record(rect) }.onChange(of: rect) { _, value in record(value) }
        .onDisappear { record(.zero) }
        .task(id: touched) {
            guard isMenu else { return }
            faded = false
            do { try await Task.sleep(for: .seconds(3)); withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.5)) { faded = true } } catch { }
        }
    }
}

/// Everything the library draws over a running session: the starting screen,
/// the menu button, the performance overlay, live logs and the in-game menu.
/// It lives in TouchControlsOverlay's window, which is above the game surface.
struct LibraryHUD: View {
    @ObservedObject private var iridiumController = IridiumPhysicalController.shared
    /// Top offset for the overlays pinned to the top edge. This HUD ignores the
    /// safe area, and with the game view in portrait its reported top inset can
    /// be zero while the status bar is showing; the larger of the reported inset
    /// and the visible status bar's height is used.
    static func topInset(_ geo: GeometryProxy) -> CGFloat {
        let bar = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }?.statusBarManager?.statusBarFrame.height ?? 0
        return max(geo.safeAreaInsets.top, bar)
    }
    @ObservedObject private var model = LibraryModel.shared
    @ObservedObject private var controls = TouchControlsModel.shared
    /// A Madeira Dock start: its status, failure and Show desktop (DockStartScreen).
    @ObservedObject private var dockStart = DockStartScreen.shared
    private let sessionTools = MadeiraConfig.flag("MADEIRA_SESSION_TOOLS")
    /// The in-game menu's Diagnostics (frame capture, GPU sync), for testing: off
    /// unless madeira.cfg sets env.MADEIRA_SESSION_DIAGNOSTICS = 1. A capture
    /// writes render-target pixels to Documents/capture, which Files shows.
    private let sessionDiagnostics = MadeiraConfig.flag("MADEIRA_SESSION_DIAGNOSTICS", fallback: false)
    /// The developer overlay's ECO and F pills, which a library session does not
    /// show; read again each time the menu opens.
    @State private var eco = madeira_get_eco() != 0
    @State private var fenceMode = FPSOverlayFenceMode.current
    @State private var launchVisible = false
    /// The starting screen came up under the Play button's flood (LaunchCurtain): the
    /// cover's frame it gathers into, and whether it has landed there.
    @State private var curtained = false
    @State private var coverFrame: CGRect = .zero
    /// The artwork the launch flood carried (cover and backdrop), shown here as well.
    @ObservedObject private var curtain = LaunchCurtain.shared
    /// The Session menu's Controller binds page (keyboard-and-mouse mode).
    @State private var bindsPage = false
    @State private var menuPage = "Session"
    @State private var menuFocus = "Resume"
    @State private var menuGuided = false
    @State private var confirmClose = false
    @State private var closeConfirmation = IridiumCloseConfirmation()
    @State private var menuContentHeight: CGFloat = 650
    @FocusState private var menuKeyboard: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                if model.startingScreen, let entry = model.startingEntry {
                    // Keep the screen visible if its motion is interrupted.
                    Color.black.ignoresSafeArea()
                    launchBackdrop(entry).scaleEffect(launchVisible || reduceMotion ? 1 : 1.12)
                        .overlay(.black.opacity(0.65)).ignoresSafeArea()
                        .animation(reduceMotion ? .easeOut(duration: 0.15) : .easeOut(duration: 1.1), value: launchVisible)
                    launchView(entry, geometry: geo)
                }
                if !model.startingScreen && model.performance { LibraryFloatingItem(isMenu: false, viewport: geo.size, insets: geo.safeAreaInsets) }
                if model.liveLogs && !model.startingScreen { LibraryLiveLogs().frame(maxWidth: 550, maxHeight: 140).padding(.top, Self.topInset(geo) + 60).padding(.horizontal, 12).allowsHitTesting(false) }
                if !model.sessionMessage.isEmpty && !model.startingScreen { Text(model.sessionMessage).font(.caption).padding(10).background(.regularMaterial, in: Capsule()).frame(maxWidth: .infinity).padding(.top, Self.topInset(geo) + 12).allowsHitTesting(false) }
                if !model.startingScreen { LibraryFloatingItem(isMenu: true, viewport: geo.size, insets: geo.safeAreaInsets) }
                if model.menu {
                    Color.black.opacity(0.5).ignoresSafeArea().onTapGesture { model.menu = false }.allowsHitTesting(!confirmClose).transition(.opacity)
                    (bindsPage ? AnyView(bindsMenu) : AnyView(menu))
                        .allowsHitTesting(!confirmClose).accessibilityHidden(confirmClose)
                        .frame(width: min(460, geo.size.width - 32),
                               height: min(bindsPage ? 650 : menuContentHeight, min(650, geo.size.height - geo.safeAreaInsets.top - geo.safeAreaInsets.bottom - 24)))
                        .modifier(IridiumGlassSurface(radius: 28))
                        .position(x: geo.size.width / 2, y: geo.size.height / 2)
                        .transition(reduceMotion ? .opacity : .scale(scale: 0.94).combined(with: .opacity))
                }
                if confirmClose {
                    IridiumPlayerCloseConfirmation(selection: closeConfirmation.selection,
                        message: "Requests a normal game exit. Confirm any in-game prompt. Unsaved progress may be lost.",
                        cancel: { iridiumCancelClose() },
                        close: { confirmClose = false; model.requestQuit() }, command: iridiumMenuNavigate)
                }
            }
            .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.85), value: model.menu)
            .onAppear {
                // Under the Play button's flood (LaunchCurtain): once laid out, hand the
                // cover's frame over and let the flood gather into it. Otherwise the
                // parts arrive in turn (LaunchEntrance).
                if model.startingScreen, LaunchCurtain.shared.covering {
                    curtained = true
                    // Drawn at once, without its own entrance: the flood is the entrance,
                    // and it runs on Core Animation while this thread starts the session.
                    var now = Transaction(); now.disablesAnimations = true
                    withTransaction(now) { launchVisible = true }
                    let style = launchWideEnabled && geo.size.width > geo.size.height
                        ? LaunchCurtain.CoverStyle(corner: 20, shadowOpacity: 0.55, shadowRadius: 15, shadowOffset: CGSize(width: 0, height: 14))
                        : LaunchCurtain.CoverStyle(corner: 14, shadowOpacity: 0.33, shadowRadius: 10, shadowOffset: .zero)
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(160))
                        LaunchCurtain.shared.handOff(to: coverFrame, style: style, landed: {})
                    }
                } else {
                    withAnimation(.easeOut(duration: reduceMotion ? 0.15 : 0.35)) { launchVisible = true }
                }
            }
            .preferredColorScheme(.dark)
        }.ignoresSafeArea()
        .onAppear { model.saveCurrentProfile() }
        .onChange(of: model.menu) { _, open in
            LibraryController.shared.configure(enabled: model.enabled, ownsInput: open)
            if !open { bindsPage = false; menuPage = "Session"; menuFocus = "Resume"; confirmClose = false }
            if !open { model.saveCurrentProfile() }
            if open { eco = madeira_get_eco() != 0; fenceMode = FPSOverlayFenceMode.current }
        }
        .onReceive(LibraryController.shared.commands) { command in
            if confirmClose { iridiumMenuNavigate(command) }
            else if command == "menu" { if model.menu { model.menu = false } else { model.showMenu() } }
            else if model.menu { iridiumMenuNavigate(command) }
        }
    }
    /// Landscape: the cover large on the left, the title, status and controls beside it
    /// (launchWideView). MADEIRA_LAUNCH_WIDE=0 keeps the centred column in landscape too.
    private let launchWideEnabled = MadeiraConfig.flag("MADEIRA_LAUNCH_WIDE")   // 0: the starting screen is one centred column in landscape too
    @ViewBuilder private func launchView(_ entry: LibraryEntry, geometry geo: GeometryProxy) -> some View {
        if launchWideEnabled && geo.size.width > geo.size.height {
            launchWideView(entry, geometry: geo)
        } else {
            launchColumnView(entry, geometry: geo)
        }
    }
    private func launchColumnView(_ entry: LibraryEntry, geometry geo: GeometryProxy) -> some View {
        let compact = geo.size.height < 500
        let available = max(0, geo.size.height - geo.safeAreaInsets.top - geo.safeAreaInsets.bottom)
        // A landscape phone would have the live log below the fold; it goes
        // beside the status there instead.
        let showLogs = model.launchLogs
        let sideLogs = showLogs && compact && geo.size.width > geo.size.height
        return HStack(spacing: 12) {
        VStack(spacing: 0) {
        ScrollView {
            VStack(spacing: compact ? 10 : 18) {
                launchCover(entry).frame(width: compact ? 90 : 120, height: compact ? 135 : 180)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { coverFrame = $0; LaunchCurtain.shared.track($0) }
                Text(entry.title).font(.title2.bold()).multilineTextAlignment(.center)
                    .modifier(LaunchEntrance(visible: launchVisible, step: 1, rise: CGSize(width: 0, height: 14), still: curtained))
                if dockStart.failure == nil {
                    ProgressView().tint(.white).modifier(LaunchEntrance(visible: launchVisible, step: 2, still: curtained))
                }
                if let failure = dockStart.failure {
                    Text("Madeira Dock stopped").font(.headline)
                    Text(failure).font(.caption).multilineTextAlignment(.center).frame(maxWidth: 360)
                } else if dockStart.active {
                    // What the Dock start is waiting for, from the host's report, and what it
                    // does with the game's one-time installs.
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        VStack(spacing: 8) {
                            Text(dockStatus).foregroundStyle(.white.opacity(0.8)).multilineTextAlignment(.center)
                            if let note = DockInstallers.note {
                                Text(note).font(.caption).foregroundStyle(.white.opacity(0.6)).multilineTextAlignment(.center).frame(maxWidth: 360)
                            }
                            Text("\(Int(context.date.timeIntervalSince(model.startingSince)))s")
                                .font(.caption.monospacedDigit()).foregroundStyle(.white.opacity(0.4))
                        }
                    }
                    .frame(minHeight: 96, alignment: .top)
                    .modifier(LaunchEntrance(visible: launchVisible, step: 2, still: curtained))
                } else {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        VStack(spacing: 8) {
                            Text(launchIdleStatus).foregroundStyle(.white.opacity(0.7))
                            Text("\(Int(context.date.timeIntervalSince(model.startingSince)))s")
                                .font(.caption.monospacedDigit()).foregroundStyle(.white.opacity(0.4))
                        }
                    }.modifier(LaunchEntrance(visible: launchVisible, step: 2, still: curtained))
                }
                IridiumLaunchMemoryView().frame(maxWidth: 360)
                // The starting screen's controls are one row of glyph-only buttons, so a
                // short screen does not push them below the fold. The words stay as
                // VoiceOver labels. A stopped Dock start can be closed; while a Dock start
                // holds the desktop back, Show desktop reveals it.
                HStack(spacing: 14) {
                    if dockStart.failure != nil {
                        launchGlyph("Close session", "stop.circle") { model.requestQuit() }
                    }
                    launchGlyph(showLogs ? "Hide live log" : "Show live log", "text.alignleft", on: showLogs) {
                        model.toggleLaunchLogs()
                    }
                    if dockStart.holding {
                        launchGlyph("Show desktop", "macwindow") { dockStart.showDesktop(model) }
                            .accessibilityHint("Shows the Windows desktop")
                    }
                }.modifier(LaunchEntrance(visible: launchVisible, step: 3, still: curtained))
                if model.launchSlow && !dockStart.holding {
                    Button("Show game view") { model.showGameView(reason: "button") }.frame(minHeight: 44)
                }
                if showLogs && !sideLogs {
                    LibraryLiveLogs().frame(maxWidth: 550).frame(height: compact ? 90 : 120).clipped()
                }
            }.padding(16).frame(maxWidth: .infinity).frame(minHeight: available)
        }
        }.frame(maxWidth: .infinity)
        if sideLogs {
            LibraryLiveLogs().frame(width: min(420, geo.size.width * 0.45)).frame(height: max(0, available - 32)).clipped()
                .padding(.trailing, 16 + geo.safeAreaInsets.trailing)
        }
        }
        .frame(width: geo.size.width, height: available)
        .padding(.top, geo.safeAreaInsets.top).foregroundStyle(.white).transition(.opacity)
    }
    /// The landscape starting screen: a large cover left of centre, and beside it the
    /// title, what the start is doing in smaller type, and the same glyph row as the
    /// column (close session, live log, show desktop). The live log opens under the row.
    private func launchWideView(_ entry: LibraryEntry, geometry geo: GeometryProxy) -> some View {
        let available = max(0, geo.size.height - geo.safeAreaInsets.top - geo.safeAreaInsets.bottom)
        let showLogs = model.launchLogs
        let short = available < 440
        let coverHeight = min(max(available * (showLogs ? 0.6 : 0.68), 150), 470)
        let leading = max(geo.safeAreaInsets.leading + 28, geo.size.width * 0.09)
        return HStack(alignment: .center, spacing: max(28, geo.size.width * 0.045)) {
            launchCover(entry).frame(width: coverHeight * 2 / 3, height: coverHeight)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.white.opacity(0.14), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.55), radius: 30, y: 14)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { coverFrame = $0; LaunchCurtain.shared.track($0) }
                .modifier(LaunchEntrance(visible: launchVisible, step: 0, rise: CGSize(width: -36, height: 0), scale: 0.86, still: curtained))
            ScrollView {
            VStack(alignment: .leading, spacing: short ? 10 : 14) {
                Text(entry.title).font(.system(size: short ? 28 : 38, weight: .bold))
                    .lineLimit(2).minimumScaleFactor(0.6)
                    .modifier(LaunchEntrance(visible: launchVisible, step: 1, rise: CGSize(width: 22, height: 0), still: curtained))
                launchWideStatus.modifier(LaunchEntrance(visible: launchVisible, step: 2, rise: CGSize(width: 22, height: 0), still: curtained))
                IridiumLaunchMemoryView().frame(maxWidth: 440)
                HStack(spacing: 12) {
                    if dockStart.failure != nil {
                        launchGlyph("Close session", "stop.circle") { model.requestQuit() }
                    }
                    launchGlyph(showLogs ? "Hide live log" : "Show live log", "text.alignleft", on: showLogs) {
                        model.toggleLaunchLogs()
                    }
                    if dockStart.holding {
                        launchGlyph("Show desktop", "macwindow") { dockStart.showDesktop(model) }
                            .accessibilityHint("Shows the Windows desktop")
                    }
                    if model.launchSlow && !dockStart.holding {
                        Button("Show game view") { model.showGameView(reason: "button") }
                            .font(.subheadline.weight(.semibold)).buttonStyle(.bordered).tint(.white)
                            .buttonBorderShape(.capsule).frame(minHeight: 44)
                    }
                }
                .padding(.top, short ? 2 : 6)
                .modifier(LaunchEntrance(visible: launchVisible, step: 3, rise: CGSize(width: 22, height: 0), still: curtained))
                if showLogs {
                    LibraryLiveLogs().frame(height: min(170, available * 0.3)).frame(maxWidth: 520)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .frame(maxWidth: 520, alignment: .leading)
            .animation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.86), value: showLogs)
            }.scrollBounceBehavior(.basedOnSize).frame(maxWidth: 520)
            Spacer(minLength: 0)
        }
        .padding(.leading, leading).padding(.trailing, geo.safeAreaInsets.trailing + 24)
        .frame(width: geo.size.width, height: available)
        .padding(.top, geo.safeAreaInsets.top).foregroundStyle(.white)
    }
    /// The landscape status: a small spinner and one line of what the start is doing,
    /// the one-time-install note and the elapsed time under it; or why the Dock stopped.
    @ViewBuilder private var launchWideStatus: some View {
        if let failure = dockStart.failure {
            VStack(alignment: .leading, spacing: 6) {
                Text("Madeira Dock stopped").font(.headline)
                Text(failure).font(.subheadline).foregroundStyle(.white.opacity(0.75)).frame(maxWidth: 440, alignment: .leading)
            }
        } else {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let status = dockStart.active ? dockStatus : launchIdleStatus
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small).tint(.white)
                        Text(status).font(.subheadline).foregroundStyle(.white.opacity(0.78))
                            .contentTransition(.opacity).animation(.easeInOut(duration: 0.3), value: status)
                    }
                    if dockStart.active, let note = DockInstallers.note {
                        Text(note).font(.caption).foregroundStyle(.white.opacity(0.6)).frame(maxWidth: 440, alignment: .leading)
                    }
                    Text("\(Int(context.date.timeIntervalSince(model.startingSince)))s")
                        .font(.caption.monospacedDigit()).foregroundStyle(.white.opacity(0.4))
                }
            }
        }
    }
    /// A round glyph button for the starting screen's control row.
    private func launchGlyph(_ label: String, _ symbol: String, on: Bool = false,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 19, weight: .semibold))
                .frame(width: 46, height: 46)
                .background(Circle().fill(Color.white.opacity(on ? 0.32 : 0.16)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain).foregroundStyle(.white)
        .accessibilityLabel(label)
    }

    /// The starting screen's cover and backdrop: a Dock start shows the game's
    /// Steam artwork by App ID, any other session its library artwork. A Steam game
    /// without its own cover shows Steam's while it gets ready too, and the cover the
    /// launch flood carried when there is one (the same pixels it lands on).
    private func launchSteamID(_ entry: LibraryEntry) -> Int? {
        dockStart.appID ?? (entry.coverFile == nil ? entry.steamAppID : nil)
    }
    @ViewBuilder private func launchCover(_ entry: LibraryEntry) -> some View {
        if let image = curtain.cover(for: launchSteamID(entry)) {
            Image(uiImage: image).resizable().scaledToFill()
        } else if let appID = launchSteamID(entry) { SteamGameArtwork(appID: appID) } else { LibraryArtwork(entry: entry) }
    }
    @ViewBuilder private func launchBackdrop(_ entry: LibraryEntry) -> some View {
        if let image = curtain.hero(for: launchSteamID(entry)) {
            GeometryReader { g in
                Image(uiImage: image).resizable().scaledToFill().frame(width: g.size.width, height: g.size.height).clipped()
            }
        } else if let appID = launchSteamID(entry) { SteamLaunchBackdrop(appID: appID) } else { LibraryArtwork(entry: entry, backdrop: true) }
    }
    /// What the start is doing before the Dock reports (or for a game without Dock).
    private var launchIdleStatus: String {
        if let entry = model.preparing { return model.startingJIT == entry.id ? "Enabling JIT…" : "Getting ready…" }
        return model.launchSlow ? "Still starting…" : "Starting your game…"
    }

    /// What the Dock start is doing (DockStartStatus), read once a second.
    private var dockStatus: String {
        MainActor.assumeIsolated {
            let progress = DockInstallers.poll(drive: MadeiraDock.drive)
            // The host starts at once, or after this start's one-time installs finished.
            let hostDue = DockInstallers.finishedAt ?? model.launchStartedAt
            return DockStartStatus.text(MadeiraDock.pollReport().fields, installers: DockInstallers.script != nil,
                                        installerProgress: progress, installsFinished: DockInstallers.finishedAt != nil,
                                        waited: Date().timeIntervalSince(hostDue),
                                        restartHint: DockInstallers.installsOnly ? DockInstallers.closingWords : nil)
        }
    }

    /// Controller binds, as a page of the Session menu: a Form, so the rows read
    /// like Game details; the driver takes each change at once (model.controllerBinds).
    private var bindsMenu: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Session", systemImage: "chevron.left") { bindsPage = false }.buttonStyle(.borderless)
                Spacer()
                Text("Controller binds").font(.headline)
                Spacer()
                Button("Reset") { model.controllerBinds = [:]; model.padMouseVertical = 1; model.saveCurrentProfile() }
                    .buttonStyle(.borderless).disabled(model.controllerBinds.isEmpty && model.padMouseVertical == 1)
                Button("Done") { model.menu = false }.buttonStyle(.bordered)
            }.padding(.horizontal, 22).padding(.top, 22).padding(.bottom, 8)
            Form {
                Group {
                ControllerBindsPage(binds: Binding(get: { model.controllerBinds.isEmpty ? nil : model.controllerBinds },
                                                   set: { model.controllerBinds = $0 ?? [:]; model.saveCurrentProfile() }),
                                    mouseVertical: Binding(get: { model.padMouseVertical == 1 ? nil : model.padMouseVertical },
                                                           set: { model.padMouseVertical = $0 ?? 1; model.saveCurrentProfile() }),
                                    controls: controls.controls)
                }.iridiumRowSurface()
            }.scrollContentBackground(.hidden)
        }
    }

    private var menu: some View {
      ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                IridiumPlayerMenuHeader(title: menuPage,
                    subtitle: menuPage == "Session" ? "Windows" : nil,
                    back: menuPage == "Session" ? nil : { iridiumMenuNavigate("back") },
                    done: { model.menu = false })
                if menuPage == "Session" {
                    IridiumSessionMenuActions(windows: true, focused: menuGuided ? menuFocus : nil, activate: iridiumMenuActivate)
                }
                if menuPage == "Log" { RuntimeDiagnosticsLogContent().frame(minHeight: 250) }
                if menuPage == "Control Settings" {
                // The controls come first, the easiest to reach; the overlay settings last.
                Toggle("Touch controls", isOn: $controls.visible)
                // The named layouts (Xbox controller, custom ones) live here in a session: this
                // menu replaces the overlay's top bar, where the same menu sits outside the library.
                if controls.visible && ControlPresetsModel.enabled {
                    ControlLayoutMenu(style: .row) { openedEditor in
                        model.saveCurrentProfile()
                        if openedEditor { model.menu = false }
                    }
                }
                LabeledContent("Opacity") { Slider(value: $model.opacity, in: 0.15...1) }
                LabeledContent("Size") { Slider(value: $controls.sizeScale, in: 0.5...2) }
                Button("Edit controls", systemImage: "slider.horizontal.3") { controls.visible = true; controls.editing = true; model.menu = false }
                if GamepadInput.keyboardMouseAvailable {
                    ControllerModeChoice(mode: Binding(get: { model.controllerMode }, set: { model.controllerMode = $0; model.saveCurrentProfile() }))
                    if model.controllerMode == "keys" {
                        Button("Controller binds", systemImage: "gamecontroller") { bindsPage = true }
                    } else if model.controllerMode == "dinput" {
                        // ml1240: the DirectInput device exists only from the launch on.
                        Text("XInput and DirectInput applies to the next launch.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                Divider()
                }
                if menuPage == "Controls" {
                    iridiumMenuButton(controls.visible ? "Hide Touch Controls" : "Show Touch Controls", symbol: "hand.tap")
                    if GamepadInput.enabled && iridiumController.isActive {
                        iridiumMenuButton(iridiumController.forceTouchVisible ? "Use Controller" : "Use Touch Controls", symbol: "gamecontroller")
                        Text("Touch controls hide automatically with a controller. A temporary override lasts until it disconnects.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    iridiumMenuButton("Control Settings", symbol: "slider.horizontal.3")
                }
                if menuPage == "Performance" {
                FPSChoice(mode: Binding(get: { model.fpsMode }, set: { model.setFPS($0) }))
                // Saved to the game with the rest of the session's profile.
                // MADEIRA_SESSION_TOOLS=0 hides it.
                if sessionTools {
                    LabeledContent("Aspect & scaling") {
                        Picker("Aspect & scaling", selection: $model.displayMode) {
                            ForEach(DisplayMode.allCases, id: \.self) { mode in Label(mode.label, systemImage: mode.symbol).tag(mode) }
                        }.pickerStyle(.menu).labelsHidden()
                    }
                }
                Divider()
                }
                if menuPage == "Advanced" {
                // ml1133's ECO switch, live: the same as the developer overlay's ECO pill.
                Text("CPU").font(.headline)
                Toggle("Lower power priority", isOn: Binding(get: { eco }, set: { on in eco = on; madeira_set_eco(on ? 1 : 0) }))
                Text("Runs the game's threads at a low priority, on the efficiency cores: cooler and slower. Use it while a game loads and turn it off to play.")
                    .font(.caption).foregroundStyle(.secondary)
                Divider()
                }
                if menuPage == "Control Settings" {
                Text("Mouse & pointer").font(.headline)
                LibraryPointerSettings()
                Divider()
                }
                if menuPage == "Performance" {
                Toggle("Performance overlay", isOn: $model.performance)
                if model.performance {
                    ForEach(["FPS", "Frame time", "CPU", "GPU", "RAM", "Battery", "Thermal"], id: \.self) { field in
                        Toggle(field, isOn: Binding(get: { model.overlayFields.contains(field) }, set: { on in
                            model.overlayFields.removeAll { $0 == field }; if on { model.overlayFields.append(field) }
                        })).font(.subheadline)
                    }
                }
                // The developer overlay's CAP and F pills (FPSOverlay), for library
                // sessions: only with MADEIRA_SESSION_DIAGNOSTICS=1 (and not with
                // MADEIRA_SESSION_TOOLS=0).
                }
                if menuPage == "Advanced", sessionTools && sessionDiagnostics {
                    Divider()
                    Text("Diagnostics").font(.headline)
                    Button("Capture the next frame", systemImage: "camera.viewfinder") {
                        model.menu = false
                        // After the menu has gone, so the frame shows what the player saw.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                            madeira_capture_request(1)
                            LogStore.shared.log("[capture] frame capture requested from the in-game menu")
                        }
                    }
                    LabeledContent("GPU sync") {
                        Picker("GPU sync", selection: Binding(get: { fenceMode }, set: { mode in
                            fenceMode = mode; FPSOverlayFenceMode.current = mode
                            madeira_set_fence_mode(Int32(mode == 0 ? 7 : mode))
                        })) {
                            Text("F1").tag(1); Text("F6").tag(6); Text("F5").tag(5); Text("F0").tag(0)
                        }.pickerStyle(.segmented).frame(maxWidth: 220)
                    }
                    Text("Both apply to Direct3D 12 games only. Capture writes the render passes of the next frame to Documents/capture and its draw list to the log. GPU sync: F1 makes every pass wait for the one before (the default), F6 waits only where the game's barriers ask, F5 makes render passes wait at the fragment stage, F0 has no sync at all (expect flicker; for tests).")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let appID = model.activeEntry?.steamAppID, SteamOwnedLibrary.cloudQuitEnabled {
                    Divider()
                    SteamCloudQuitRow(appID: appID)
                }
                Divider()
                // Red label and symbol; the menu's .primary style would otherwise win.
                iridiumMenuButton("Close Game", symbol: "stop.circle").foregroundStyle(.red)
                Text("Requests a normal game exit. Confirm any game prompt.").font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(22)
                .foregroundStyle(.primary)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { menuContentHeight = $0 }
        }
        .scrollIndicators(.visible)
        .tint(Color(red: 0.66, green: 0.82, blue: 0.76))
        .focusable().focusEffectDisabled().focused($menuKeyboard)
        .onAppear { menuKeyboard = true }
        .onKeyPress(.escape, phases: .down) { _ in iridiumMenuNavigate("back"); return .handled }
        .onKeyPress(.leftArrow) { guard IridiumPlayerMenuNavigation.ownsCommands(page: menuPage, nativeEditor: bindsPage) else { return .ignored }; iridiumMenuNavigate("left"); return .handled }
        .onKeyPress(.rightArrow) { guard IridiumPlayerMenuNavigation.ownsCommands(page: menuPage, nativeEditor: bindsPage) else { return .ignored }; iridiumMenuNavigate("right"); return .handled }
        .onKeyPress(.upArrow) { guard IridiumPlayerMenuNavigation.ownsCommands(page: menuPage, nativeEditor: bindsPage) else { return .ignored }; iridiumMenuNavigate("up"); return .handled }
        .onKeyPress(.downArrow) { guard IridiumPlayerMenuNavigation.ownsCommands(page: menuPage, nativeEditor: bindsPage) else { return .ignored }; iridiumMenuNavigate("down"); return .handled }
        .onKeyPress(.return, phases: .down) { _ in guard IridiumPlayerMenuNavigation.ownsCommands(page: menuPage, nativeEditor: bindsPage) else { return .ignored }; iridiumMenuNavigate("accept"); return .handled }
        .onChange(of: menuFocus) { _, title in proxy.scrollTo(title, anchor: .center) }

      }
    }
    private func iridiumMenuButton(_ title: String, symbol: String) -> some View {
        IridiumPlayerMenuRow(title: title, symbol: symbol,
                            selected: menuGuided && menuFocus == title,
                            destructive: title == "Close Game") { iridiumMenuActivate(title) }
    }
    private func iridiumMenuActivate(_ title: String) {
        switch title {
        case "Resume": model.menu = false
        case "Volume": break
        case "Controls": menuPage = "Controls"; menuFocus = controls.visible ? "Hide Touch Controls" : "Show Touch Controls"
        case "Hide Touch Controls", "Show Touch Controls":
            controls.visible.toggle(); menuFocus = controls.visible ? "Hide Touch Controls" : "Show Touch Controls"
        case "Use Touch Controls":
            controls.visible = true; iridiumController.forceTouchVisible = true; menuFocus = "Use Controller"
        case "Use Controller": iridiumController.forceTouchVisible = false; menuFocus = "Use Touch Controls"
        case "Show Device Keyboard": model.menu = false; LibraryKeyboard.show()
        case "View Log": menuPage = "Log"
        case "Close Game": closeConfirmation = IridiumCloseConfirmation(); menuKeyboard = false; confirmClose = true
        default: menuPage = title
        }
    }
    private func iridiumCancelClose() { confirmClose = false; menuKeyboard = true }
    private func iridiumMenuNavigate(_ command: String) {
        if confirmClose {
            switch closeConfirmation.receive(command) {
            case .cancel: iridiumCancelClose()
            case .close: confirmClose = false; model.requestQuit()
            case .pending: break
            }
            return
        }
        if command == "back" {
            if bindsPage { bindsPage = false }
            else if menuPage == "Control Settings" { menuPage = "Controls"; menuFocus = "Control Settings" }
            else if menuPage != "Session" { menuPage = "Session"; menuFocus = "Controls" }
            else { model.menu = false }
            return
        }
        guard !bindsPage else { return }
        if menuPage == "Controls" {
            let order = IridiumPlayerMenuNavigation.touchControlItems(enabled: controls.visible,
                controller: GamepadInput.enabled && iridiumController.isActive, overrideEnabled: iridiumController.forceTouchVisible, includeSettings: true)
            if ["up", "down", "left", "right"].contains(command) {
                menuGuided = true
                menuFocus = IridiumPlayerMenuNavigation.next(menuFocus, order: order, command: command)
            } else if command == "accept" { iridiumMenuActivate(order.contains(menuFocus) ? menuFocus : order[0]) }
            return
        }
        guard menuPage == "Session" else { return }
        if menuFocus == "Volume", command == "left" || command == "right" {
            IridiumGameAudio.shared.adjust(command); return
        }
        let order = IridiumSessionMenuActions.items(windows: true).map { $0.0 } + ["Close Game"]
        if ["up", "down", "left", "right"].contains(command) {
            menuGuided = true
            menuFocus = IridiumPlayerMenuNavigation.next(menuFocus, order: order, command: command)
        } else if command == "accept" { iridiumMenuActivate(menuFocus) }
    }
}

struct LibraryLiveLogs: View {
    @ObservedObject private var logs = LogStore.shared
    var body: some View {
        // Rows are coalesced by signature; insertion order isn't recency.
        // Show the latest updates so a repeating wait still looks live.
        GeometryReader { geo in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(logs.entries.sorted { $0.lastTimestamp < $1.lastTimestamp }.suffix(200))) {
                        Text($0.lastRaw).font(.system(size: 9, design: .monospaced)).lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: max(0, geo.size.height - 16), alignment: .topLeading)
            }.defaultScrollAnchor(.bottom).padding(8)
        }.background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 10)).foregroundStyle(.white)
            .accessibilityLabel("Live diagnostic log")
    }
}

struct LibraryMetrics: View {
    @ObservedObject private var model = LibraryModel.shared
    @State private var lastCount: UInt64 = 0
    @State private var lastTime = Date()
    @State private var fps = 0.0
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
    private let ticks = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    var body: some View {
        Text(parts.joined(separator: "  ·  "))
            .font(.caption.monospacedDigit().weight(.medium)).padding(.horizontal, 12).padding(.vertical, 8)
            .background(.black.opacity(0.8), in: Capsule()).foregroundStyle(.white)
            .onAppear {
                lastCount = madeira_get_present_count(); lastTime = Date(); UIDevice.current.isBatteryMonitoringEnabled = true
                applyGPUMeter()
            }
            .onDisappear { UIDevice.current.isBatteryMonitoringEnabled = false; madeira_gpu_meter_enable(0) }
            .onChange(of: model.overlayFields) { _, _ in applyGPUMeter() }
            .onReceive(ticks) { now in
                let count = madeira_get_present_count(); let dt = now.timeIntervalSince(lastTime)
                let frames = count >= lastCount ? count - lastCount : 0
                fps = Double(frames) / max(0.001, dt); lastCount = count; lastTime = now
                var info = task_vm_info_data_t(); var size = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
                let result = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &size) } }
                if result == KERN_SUCCESS { memory = Int(info.phys_footprint / 1048576) }
                battery = UIDevice.current.batteryLevel < 0 ? -1 : Int(UIDevice.current.batteryLevel * 100)
                let state = ProcessInfo.processInfo.thermalState
                if state != thermal {
                    LogStore.shared.log("[thermal] \(DeviceLoadDiagnostics.thermalName(thermal)) -> \(DeviceLoadDiagnostics.thermalName(state)) at \(String(format: "%.0f", fps)) FPS")
                    thermal = state
                }
                if model.overlayFields.contains("CPU") { cpu = cpuMeter.sample() }
                if model.overlayFields.contains("GPU") {
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
        madeira_gpu_meter_enable(model.overlayFields.contains("GPU") ? 1 : 0)
        lastGPUBusy = madeira_gpu_meter_busy_seconds(); lastGPUBuffers = madeira_gpu_meter_cmdbufs(); gpu = -1
    }
    private var parts: [String] {
        var result: [String] = []
        if model.overlayFields.contains("FPS") { result.append(String(format: "%.0f FPS", fps)) }
        if model.overlayFields.contains("Frame time") { result.append(fps > 0 ? String(format: "%.1f ms avg", 1000 / fps) : "— ms") }
        if model.overlayFields.contains("CPU") {
            result.append(cpu.map { String(format: "CPU %.0f%% (top %.0f%%)", $0.total, $0.top) } ?? "CPU —")
        }
        if model.overlayFields.contains("GPU") {
            if gpu < 0 { result.append("GPU —") }
            else if gpuFrameMs > 0 { result.append(String(format: "GPU %.0f%% (%.1f ms)", gpu, gpuFrameMs)) }
            else { result.append(String(format: "GPU %.0f%%", gpu)) }
        }
        if model.overlayFields.contains("RAM") { result.append("\(memory) MB") }
        if model.overlayFields.contains("Battery"), battery >= 0 { result.append("\(battery)%") }
        if model.overlayFields.contains("Thermal") {
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

// A key window is required for UIKit text input; the rendering placeholder lives
// beneath separate presentation and control windows and cannot reliably own it.
enum LibraryKeyboard {
    static var window: UIWindow?
    static weak var previous: UIWindow?
    static var input: LibraryKeyInput?
    static func show() {
        // MADEIRA_FRONTEND_KEYBOARD=0: the game view's own keyboard instead.
        if !MadeiraConfig.flag("MADEIRA_FRONTEND_KEYBOARD") { MetalBackedView.toggleKeyboard(); return }
        guard window == nil, let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first(where: { $0.activationState == .foregroundActive }) else { return }
        previous = scene.windows.first(where: { $0.isKeyWindow })
        let w = LibraryKeyboardWindow(windowScene: scene)
        w.windowLevel = .normal + 102; w.backgroundColor = .clear; w.tintColor = UIColor(red: 0.66, green: 0.82, blue: 0.76, alpha: 1)
        let controller = UIViewController(); controller.view.backgroundColor = .clear
        w.rootViewController = controller
        let v = LibraryKeyInput(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        controller.view.addSubview(v); input = v; window = w
        w.makeKeyAndVisible(); v.becomeFirstResponder()
        fputs("[frontend-keyboard] key-window input activated\n", stderr)
    }
    static func hide() {
        HardwareInput.shared.cancelPaste()
        if window != nil { fputs("[frontend-keyboard] key-window input deactivated\n", stderr) }
        input?.releaseModifiers(); input?.resignFirstResponder(); window?.isHidden = true
        window = nil; input = nil; previous?.makeKey(); previous = nil
    }
}
final class LibraryKeyboardWindow: UIWindow {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }
}
final class LibraryKeyInput: UIView, UIKeyInput {
    override var keyCommands: [UIKeyCommand]? {
        let command = UIKeyCommand(input: "v", modifierFlags: .command, action: #selector(paste(_:)))
        command.wantsPriorityOverSystemBehavior = true
        return [command]
    }
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)) { return HardwareInput.shared.canPaste && UIPasteboard.general.hasStrings }
        return super.canPerformAction(action, withSender: sender)
    }
    override func paste(_ sender: Any?) {
        HardwareInput.shared.pasteClipboard()
    }

    var hasText: Bool { true }
    override var canBecomeFirstResponder: Bool { true }
    private var held = Set<Int32>()
    private weak var accessoryRow: UIStackView?
    var keyboardType: UIKeyboardType { get { .asciiCapable } set {} }
    var autocorrectionType: UITextAutocorrectionType { get { .no } set {} }
    var autocapitalizationType: UITextAutocapitalizationType { get { .none } set {} }
    private lazy var accessoryBar = makeAccessoryBar()
    override var inputAccessoryView: UIView? { accessoryBar }
    private func makeAccessoryBar() -> UIView {
        let scroll = UIScrollView(frame: CGRect(x: 0, y: 0, width: 650, height: 52)); scroll.backgroundColor = .secondarySystemBackground
        let row = UIStackView(); row.axis = .horizontal; row.spacing = 5
        accessoryRow = row
        for (title, key) in [("Paste", -1), ("Esc", 0x1b), ("Ctrl", 0x11), ("Shift", 0x10), ("Alt", 0x12), ("Tab", 0x09), ("Enter", 0x0d), ("←", 0x25), ("↑", 0x26), ("↓", 0x28), ("→", 0x27), ("Done", 0)] {
            let button = UIButton(type: .system); button.configuration = .tinted(); button.setTitle(title, for: .normal)
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 48).isActive = true
            button.addAction(UIAction { [weak self, weak button] _ in
                guard let self else { return }
                if key == -1 { HardwareInput.shared.pasteClipboard(); return }
                HardwareInput.shared.cancelPaste()
                let vk = Int32(key)
                if key == 0 { LibraryKeyboard.hide() }
                else if [0x10, 0x11, 0x12].contains(key) {
                    if self.held.contains(vk) { self.held.remove(vk); winios_post_key(vk, 0) }
                    else { self.held.insert(vk); winios_post_key(vk, 1) }
                    button?.isSelected = self.held.contains(vk)
                } else { self.press(vk) }
            }, for: .touchUpInside)
            row.addArrangedSubview(button)
        }
        scroll.addSubview(row); row.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([row.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 8), row.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -8), row.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 4), row.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -4), row.heightAnchor.constraint(equalToConstant: 44)])
        return scroll
    }
    private func press(_ vk: Int32) { winios_post_key(vk, 1); winios_post_key(vk, 0) }
    func insertText(_ text: String) {
        if HardwareInput.shared.handlesTyping { return }
        HardwareInput.shared.cancelPaste()
        for ch in text {
            guard let (vk, shift) = MetalBackedView.vkForChar(ch) else { continue }
            let temporary = shift && !held.contains(0x10)
            if temporary { winios_post_key(0x10, 1) }; press(vk); if temporary { winios_post_key(0x10, 0) }
        }
    }
    func deleteBackward() {
        if !HardwareInput.shared.handlesTyping { HardwareInput.shared.cancelPaste(); press(0x08) }
    }
    func releaseModifiers() {
        for key in held { winios_post_key(key, 0) }
        held.removeAll()
        for case let button as UIButton in accessoryRow?.arrangedSubviews ?? [] { button.isSelected = false }
    }
}

/// A desktop session (the Desktop entry) draws through Winios's compositor view,
/// a plain UIView the native side adds straight onto the app window, above the
/// SwiftUI root view, and never hides. The game view (MetalHostView) is hidden
/// when a session ends; the compositor was not, so the ended session's frozen
/// desktop covered the library. The library hides that view when the session
/// ends and shows it again when the next one begins. [library-surface] logs
/// both. MADEIRA_LIBRARY_HIDE_ENDED_DESKTOP=0 leaves it alone.
enum EndedSessionSurface {
    private static var watch: AnyCancellable?
    private static var hiddenByUs = false

    @MainActor static func install() {
        guard watch == nil else { return }
        watch = LibraryModel.shared.$current.receive(on: DispatchQueue.main).sink { current in
            MainActor.assumeIsolated {
                if current == nil { hide(reason: "session-ended") } else { show() }
            }
        }
    }

    @MainActor static func hide(reason: String) {
        guard MadeiraConfig.flag("MADEIRA_LIBRARY_HIDE_ENDED_DESKTOP"), LibraryModel.shared.enabled,
              LibraryModel.shared.current == nil, wine_process_is_running() == 0 else { return }
        guard winios_compositor_set_hidden(1) != 0 else { return }
        hiddenByUs = true
        LogStore.shared.log("[library-surface] hid ended desktop reason=\(reason)")
    }

    @MainActor static func show() {
        guard hiddenByUs else { return }
        hiddenByUs = false
        _ = winios_compositor_set_hidden(0)
        LogStore.shared.log("[library-surface] desktop shown for the new session")
    }
}

struct IridiumCreditsSections: View {
    var body: some View {
IridiumSoftwareCreditsSections()
    }
}
