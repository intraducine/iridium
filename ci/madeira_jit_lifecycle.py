"""Single-flight JIT and correlated Shortcut callbacks over the pinned frontend."""


def replace(text, old, new):
    if text.count(old) != 1:
        raise ValueError('Madeira JIT lifecycle changed: ' + old[:100])
    return text.replace(old, new)


def apply(name, text):
    if name == 'ContentView.swift':
        text = replace(text, '    private func enableJIT() {', '''    private func enableJIT() {
        guard jitStatus != .testing else { return }''')
    if name == 'JITSetup.swift':
        text = replace(text, '    private var loopbackAnswered: Bool?',
                       '    private var enableRequest: UUID?\n    private var loopbackAnswered: Bool?')
        text = replace(text, '    func enable(completion: @escaping (Result<Void, Error>) -> Void) {', '''    func enable(completion: @escaping (Result<Void, Error>) -> Void) {
        guard enableRequest == nil, !busy else {
            LogStore.shared.log("[jit-request] ignored overlapping enable request")
            completion(.failure(NSError(domain: "MadeiraJIT", code: 15,
                userInfo: [NSLocalizedDescriptionKey: "A JIT request is already running."])))
            return
        }
        let token = UUID()
        enableRequest = token
        busy = true
        let finish: (Result<Void, Error>) -> Void = { [weak self] result in
            guard let self, enableRequest == token else { return }
            enableRequest = nil
            busy = false
            completion(result)
        }''')
        start = text.index('    func enable(completion:')
        end = text.index('    /// LocalDevVPN', start)
        body = text[start:end]
        # Keep the busy rejection and the original completion in finish itself.
        offset = body.index('        guard SigningStatus')
        prefix, flow = body[:offset], body[offset:]
        flow = flow.replace('completion(', 'finish(')
        flow = replace(flow, '        ensureLoopback(then:', '        var resultReceived = false\n        ensureLoopback(then:')
        flow = replace(flow, '            self?.enableResolved { result in', '''            self?.enableResolved { result in
                guard !resultReceived else { return }
                resultReceived = true''')
        flow = replace(flow, '        }, stopped: { [weak self] message in', '''        }, stopped: { [weak self] message in
            guard !resultReceived else { return }
            resultReceived = true''')
        flow = replace(flow, '''                if restoreOnFailure, case .failure = result {
                    JITNetworkShortcut.shared.restoreIfNeeded {}
                }
                finish(result)''', '''                if restoreOnFailure, case .failure = result {
                    JITNetworkShortcut.shared.restoreIfNeeded { finish(result) }
                } else { finish(result) }''')
        flow = replace(flow, '''            JITNetworkShortcut.shared.restoreIfNeeded {}
            finish(.failure(NSError(domain: "MadeiraJIT", code: 14,
                                        userInfo: [NSLocalizedDescriptionKey: message])))''', '''            JITNetworkShortcut.shared.restoreIfNeeded {
                finish(.failure(NSError(domain: "MadeiraJIT", code: 14,
                    userInfo: [NSLocalizedDescriptionKey: message])))
            }''')
        text = text[:start] + prefix + flow + text[end:]
        text = replace(text, '    func connectWithShortcut() {', '''    func connectWithShortcut() {
        guard enableRequest == nil, !busy else { return }''')
        text = replace(text, '    func prepareBuiltIn() {', '''    func prepareBuiltIn() {
        guard enableRequest == nil, !busy else { return }''')
    if name == 'JITNetwork.swift':
        text = replace(text, '    private var waiting: ((Outcome) -> Void)?',
                       '    private var requestID: UUID?\n    private var waiting: ((Outcome) -> Void)?')
        text = replace(text, '    func start(completion: @escaping (Outcome) -> Void) {', '''    func start(completion: @escaping (Outcome) -> Void) {
        guard waiting == nil else { completion(.failed("a shortcut operation is already running")); return }''')
        text = replace(text, '''        finish(.failed("superseded"))
        var c = URLComponents()''', '''        guard waiting == nil else { completion(.failed("a shortcut operation is already running")); return }
        let token = UUID()
        requestID = token
        var c = URLComponents()''')
        for route in ('success', 'error', 'cancel'):
            text = replace(text, f'"madeira://jit-network/{route}"',
                           f'"madeira://jit-network/{route}?request=\\(token.uuidString)"')
        text = replace(text, '''            if !opened { MainActor.assumeIsolated { self?.finish(.failed("Shortcuts could not be opened")) } }''', '''            if !opened { MainActor.assumeIsolated {
                guard self?.requestID == token else { return }
                self?.finish(.failed("Shortcuts could not be opened"))
            } }''')
        text = replace(text, '''        switch url.path {
        case "/success":''', '''        guard let requestID, value("request") == requestID.uuidString else {
            LogStore.shared.log("[jit-shortcut] ignored callback from an earlier operation")
            return true
        }
        switch url.path {
        case "/success":''')
        text = replace(text, 'MainActor.assumeIsolated { self?.finish(.failed("the shortcut did not return within 60 s")) }', """MainActor.assumeIsolated {
                guard self?.requestID == token else { return }
                self?.finish(.failed("the shortcut did not return within 60 s"))
            }""")
        text = replace(text, '        run(input) { _ in completion() }', """        run(input) { [weak self] outcome in
            if case .failed = outcome, self?.pending == nil { self?.pending = input }
            completion()
        }""")
        text = replace(text, '        self.waiting = nil', '        self.waiting = nil\n        requestID = nil')
    return text
