"""Build 43 migration test fixture; not used by application preparation.

Bounded diagnostic overlay over pinned Madeira; debugger commands are unchanged."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
HELPER = 'MadeiraJITHelper/MadeiraJITHelper.swift'
SCRIPT = 'Madeira/madeira-jit.js'
MESSAGES = 'Madeira/JITBuiltInMessages.swift'
HOST = 'Madeira/JITBuiltInHost.swift'


def replace(text, old, new):
    if text.count(old) != 1:
        raise ValueError('Madeira JIT diagnostic hook changed: ' + old[:80])
    return text.replace(old, new)


SCRIPT_DIAGNOSTICS = r'''
// Iridium observability only: bounded private fault locations, no raw packet,
// thread ID, pairing data or arbitrary instruction bytes.
const iridiumJITSeen = {};
function iridiumJITSetup(stage, response) {
    let status = response === 'OK' ? 'ok' : response === '' || response == null ? 'empty'
        : typeof response === 'string' && /^E[0-9a-fA-F]{2}$/.test(response) ? 'error'
        : typeof response === 'string' && /^[TS][0-9a-fA-F]{2}/.test(response) ? 'stop' : 'other';
    log(`IRJIT2 stage=setup.${stage} status=${status}`);
}
function iridiumJITStop(response, requestedStage, pc, insnOk, instrU32) {
    if (typeof response !== 'string' || response.length > 2048) return;
    const match = /^([TSWX])([0-9a-fA-F]{2})/.exec(response);
    if (!match) return;
    const exited = match[1] === 'W' || match[1] === 'X';
    const stage = exited ? 'first.exit' : requestedStage || 'first.stop';
    if (iridiumJITSeen[stage]) return;
    iridiumJITSeen[stage] = true;
    const kind = match[1] === 'W' ? 'exit' : match[1] === 'X' ? 'signal' : 'stop';
    const byte = parseInt(match[2], 16);
    const signal = kind === 'exit' || byte > 31 ? 0 : byte;
    const fields = response.slice(3); // T/S and its signal precede the first field.
    const exceptionMatch = /(?:^|;)metype:([^;]*);/.exec(fields);
    const exceptionValue = exceptionMatch && /^[0-9a-fA-F]{1,8}$/.test(exceptionMatch[1]) ? parseInt(exceptionMatch[1], 16) : 0;
    const exception = exceptionValue <= 13 ? exceptionValue : 0;
    const codeMatch = /(?:^|;)medata:([^;]*);/.exec(fields);
    const codeValue = codeMatch && /^[0-9a-fA-F]{1,8}$/.test(codeMatch[1]) ? parseInt(codeMatch[1], 16) : 0;
    const code = exited ? byte : codeValue <= 255 ? codeValue : 0;
    let detail = '';
    if (stage === 'first.fault' && kind === 'stop') {
        const pcValue = pc == null ? 'missing' : typeof pc === 'string' && /^[0-9a-fA-F]{16}$/.test(pc)
            ? BigInt('0x' + pc.match(/../g).reverse().join('')).toString(16).padStart(16, '0') : 'invalid';
        const parts = fields.split(';');
        let count = 0, address = 'missing';
        for (let i = 0; i < parts.length; ++i) {
            if (!parts[i].startsWith('medata:')) continue;
            count = Math.min(3, count + 1);
            if (count === 2) {
                const value = parts[i].slice(7);
                address = i < parts.length - 1 && /^(?:0x)?[0-9a-f]{1,16}$/i.test(value)
                    ? BigInt('0x' + value.replace(/^0x/i, '')).toString(16).padStart(16, '0') : 'invalid';
            }
        }
        const instruction = insnOk !== true ? 'unreadable' : instrU32 === 0x52800540 ? 'mov42'
            : instrU32 === 0x528000e0 ? 'mov7' : instrU32 === 0xd65f03c0 ? 'ret' : 'other';
        detail = ` pc=${pcValue} addr=${address} md=${count > 2 ? 'more' : count} insn=${instruction}`;
    }
    // Only a bounded typed tuple, privately persisted by the helper. No raw reply.
    log(`IRJIT2 stage=${stage} kind=${kind} signal=${signal} exception=${exception} code=${code}${detail}`);
}
'''


def apply(name, text):
    if name == 'JITBuiltInMessages.swift':
        text = replace(text, '        case resetDDI', '        case resetDDI\n        case diagnostics')
        text = replace(text, '    let scriptBase64: String?',
                       '    let scriptBase64: String?\n    var diagnosticAttemptID: String? = nil')
        text = replace(text, 'pairingData: pairingData, scriptBase64: scriptBase64)',
                       'pairingData: pairingData, scriptBase64: scriptBase64,\n'
                       '                          diagnosticAttemptID: IridiumJITHelperSnapshot.newAttemptID())')
        text = replace(text, '    struct Response: Codable, Sendable {', '''    static var diagnostics: MadeiraJITRequest {
        MadeiraJITRequest(operation: .diagnostics, targetPID: nil, pairingData: nil,
                          scriptBase64: nil, diagnosticAttemptID: IridiumJITHelperSnapshot.newAttemptID())
    }

    struct Response: Codable, Sendable {''')
        text = replace(text, '        let txmPresent: Bool?',
                       '        let txmPresent: Bool?\n        var diagnosticAttemptID: String? = nil\n'
                       '        var diagnosticRecords: [String]? = nil')
        text += '\n' + (ROOT / 'iridium/apps/ios/MadeiraSupport/IridiumJITHelperSnapshot.swift').read_text()
    if name == 'JITBuiltInHost.swift':
        text = replace(text, '    static func send(_ request:', '''    /// Diagnostic requests neither prepare nor enable JIT. A timeout releases the
    /// caller even if the extension cannot finish; late responses are ignored.
    static func diagnosticSnapshot() async -> [String]? {
        let request = MadeiraJITRequest.diagnostics
        return await withCheckedContinuation { continuation in
            send(request) { result in
                guard case .success(let response) = result, response.success,
                      response.diagnosticAttemptID == request.diagnosticAttemptID,
                      let records = response.diagnosticRecords, records.count <= 32,
                      records.allSatisfy(IridiumJITHelperSnapshot.validRecord) else {
                    continuation.resume(returning: nil); return
                }
                continuation.resume(returning: records)
            }
        }
    }

    static func send(_ request:''')
        text = replace(text, '            LogStore.shared.log("[jit-helper] \\(message)", level: .error)',
                       '            if request.operation != .diagnostics { LogStore.shared.log("[jit-helper] \\(message)", level: .error) }')
        text = replace(text, '        let helper = HelperRequest(', '''        if request.operation == .enable, let attempt = request.diagnosticAttemptID,
           IridiumJITHelperSnapshot.validAttemptID(attempt) {
            RuntimeDiagnosticLogFiles.writeConsoleLine("[PSP helper] attempt=\\(attempt) stage=request.enable")
        }
        let helper = HelperRequest(''')
        text = replace(text, '        helper.begin(data: data, identifier: identifier, started: started)', '''        helper.begin(data: data, identifier: identifier, started: started)
        if request.operation == .diagnostics {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { helper.diagnosticTimeout() }
        }''')
        text = replace(text, '                LogStore.shared.log("[jit-helper] \\(self.operation): started \\(identifier) as pid \\(self.shim.pid(forRequestIdentifier: uuid))")',
                       '                if self.operation != "diagnostics" {\n'
                       '                    LogStore.shared.log("[jit-helper] \\(self.operation): started \\(identifier) as pid \\(self.shim.pid(forRequestIdentifier: uuid))")\n'
                       '                }')
        text = replace(text, '    private func returned(_ payload: Data?) {', '''    func diagnosticTimeout() {
        end(.failure(Self.error(9, "Helper diagnostics were unavailable.")))
    }

    private func returned(_ payload: Data?) {
        guard completion != nil else { return }''')
        text = replace(text, '        guard let payload, let response =',
                       '        guard let payload, operation != "diagnostics" || payload.count <= 16384, let response =')
        text = replace(text, '        LogStore.shared.log("[jit-helper] \\(operation): finished success=\\(response.success ? 1 : 0)")',
                       '        if operation != "diagnostics" { LogStore.shared.log("[jit-helper] \\(operation): finished success=\\(response.success ? 1 : 0)") }')
        text = replace(text, '        if case .failure(let error) = result {',
                       '        if operation != "diagnostics", case .failure(let error) = result {')
    if name == 'madeira-jit.js':
        text = replace(text, 'let attachResponse =', SCRIPT_DIAGNOSTICS + '\nlet attachResponse =')
        text = replace(text, 'log(`Madeira JIT: attached = ${attachResponse}`);',
                       'iridiumJITSetup("attach", attachResponse);')
        for variable, stage, old in (
            ('ign', 'ignore', "log(`Madeira JIT: QSetIgnoredExceptions -> ${ign || '(unsupported)'}`);"),
            ('pass', 'pass', "log(`Madeira JIT: QPassSignals -> ${pass || '(unsupported)'}`);"),
        ):
            text = replace(text, old, f'iridiumJITSetup("{stage}", {variable});')
        text = replace(text, '    pending = null;\n', '    pending = null;\n    iridiumJITStop(brkResponse);\n')
        text = replace(text, '    if (!isBrk) {',
                       '    if (!isBrk) {\n        iridiumJITStop(brkResponse, "first.fault", pc, insnOk, instrU32);')
    if name == 'MadeiraJITHelper.swift':
        text = replace(text, '        let manager = FileManager.default', '''        if request.operation == .diagnostics {
            guard let attempt = request.diagnosticAttemptID, IridiumJITHelperSnapshot.validAttemptID(attempt) else {
                return .init(success: false, message: "Invalid helper diagnostic request.", txmPresent: nil)
            }
            let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            return .init(success: true, message: "Helper diagnostic snapshot.", txmPresent: nil,
                         diagnosticAttemptID: attempt,
                         diagnosticRecords: directory.map { IridiumJITHelperSnapshot.read(in: $0) } ?? [])
        }
        let manager = FileManager.default''')
        text = replace(text, '            case .resetDDI:', '            case .resetDDI, .diagnostics:')
        text = replace(text, '                try StikJIT.enableJIT(',
                       '                let diagnostic = IridiumJITHelperDiagnostic(attemptID: request.diagnosticAttemptID ?? IridiumJITHelperSnapshot.newAttemptID())\n                try StikJIT.enableJIT(')
        text = replace(text, 'progress: { NSLog("[MadeiraJIT] %@", $0) })',
                       'progress: { diagnostic.receive($0) })')
        # A live debugger can occupy the serialized work queue until app death.
        # Read-only retrieval must still complete without waiting for that work.
        text = replace(text, '        MadeiraJITWork.queue.async {', '''        let diagnosticRequest = data.flatMap { try? JSONDecoder().decode(MadeiraJITRequest.self, from: $0) }?.operation == .diagnostics
        let queue = diagnosticRequest ? DispatchQueue.global(qos: .utility) : MadeiraJITWork.queue
        queue.async {''')
        text += '\n' + (ROOT / 'iridium/apps/ios/MadeiraSupport/IridiumJITHelperDiagnostic.swift').read_text()
    return text
