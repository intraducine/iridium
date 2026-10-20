"""Build 43 migration test fixture; not used by application preparation.

Owned PSP consumer of the pinned helper; Windows' script is unchanged."""
from pathlib import Path
import base64
import madeira_jit_observability as diagnostics

ROOT = Path(__file__).resolve().parents[1]
SUPPORT = ROOT / 'iridium/apps/ios/MadeiraSupport/IridiumPSPHelperProtocol.swift'


def replace(text, old, new):
    if text.count(old) != 1:
        raise ValueError('PSP helper hook changed: ' + old[:100])
    return text.replace(old, new)


def script():
    text = diagnostics.apply('madeira-jit.js', (ROOT / 'ci/fixtures/madeira-build43/app/Madeira/madeira-jit.js').read_text())
    prelude = r'''
// IRIDIUM_PSP_PREPARED_V2: fixed fresh arenas, no late growth or fault-policy change.
let pspSequence = 0;
const pspAllocations = [];
let pspAllocationFailed = false;
let pid;
let pspPhase = 0, pspCode = 0, pspLength = 0, pspFieldCount = 0;
let pspNotes = 0;
const pspIssuePhases = new Set();
function pspNote(phase, code, reply, terminal = false) {
    if (reply !== undefined) {
        pspLength = typeof reply === 'string' ? Math.min(65535, reply.length) : 0;
        pspFieldCount = 0;
        if (typeof reply === 'string') {
            for (let i = 0; i < Math.min(2048, reply.length); i++) {
                if (reply[i] === ';') pspFieldCount = Math.min(255, pspFieldCount + 1);
            }
        }
    }
    pspPhase = phase; pspCode = code;
    if (code < 2) { if (pspNotes >= 96) return; pspNotes++; }
    else {
        if (pspIssuePhases.has(phase) && !terminal) return;
        pspIssuePhases.add(phase);
    }
    log(`IRPSP2 phase=${phase} code=${code} length=${pspLength} fields=${pspFieldCount} version=2`);
}
function pspSend(phase, command) {
    // The page loop has 1072 ACKs. Persist its entry and any anomaly only.
    if (phase !== 15 || pspPhase !== 15) pspNote(phase, 0, '');
    let reply;
    try { reply = send_command(command); }
    catch (error) { pspNote(phase, 2, undefined, true); throw error; }
    if (reply !== 'OK' || phase !== 15) {
        const code = reply === '' || reply == null ? 24
            : (phase === 2 || phase === 3) && reply !== 'OK' ? 25 : 1;
        pspNote(phase, code, reply);
    }
    return reply;
}
function pspEvent(event, sequence, bytes, address) {
    log(`IRPSP1 event=${event} seq=${sequence} bytes=${bytes} addr=${address.toString(16).padStart(16, '0')} version=2`);
}
function pspFatal(code) {
    pspNote(pspPhase, code, undefined, true);
    pspEvent('terminal', pspSequence, 0, 0n);
    throw new Error('PSP helper protocol failed.');
}
function pspAck(reply) { if (reply !== 'OK') pspFatal(18); }
function pspStop(reply) {
    return typeof reply === 'string' && reply.length <= 2048 && /^T[0-9a-fA-F]{2}/.test(reply) && reply.endsWith(';');
}
function pspFields(reply) {
    if (!pspStop(reply)) {
        pspFatal(typeof reply !== 'string' ? 3 : reply.length > 2048 ? 4
            : !/^T[0-9a-fA-F]{2}/.test(reply) ? 5 : 6);
    }
    const fields = reply.slice(3).split(';'); fields.pop();
    if (!fields.length) pspFatal(7);
    const seen = new Set();
    function thread(value) {
        if (!/^(?:[0-9a-f]+|p[0-9a-f]+\.[0-9a-f]+)$/i.test(value)) pspFatal(10);
        if (/^p/i.test(value) && BigInt('0x' + value.slice(1).split('.')[0]) !== BigInt(pid)) pspFatal(11);
    }
    for (const field of fields) {
        const pair = /^([a-z0-9_-]+):([^;]+)$/i.exec(field);
        if (!pair) pspFatal(8);
        const key = pair[1].toLowerCase(), value = pair[2];
        if (seen.has(key) && key !== 'medata' && key !== 'memory') {
            // Fixed categories only; never persist a remote key or value.
            pspFatal(key === 'thread' ? 31 : key === 'threads' ? 32 : key === 'process' ? 33
                : key === 'metype' ? 34 : ['00', '01', '10', '20'].includes(key) ? 35
                : /^[0-9a-f]{2}$/i.test(key) ? 36 : 37);
        }
        seen.add(key);
        // debugserver expedites multiple stack chunks. Validate their shape,
        // then ignore them; they never supply an arena, register or ownership.
        if (key === 'memory' && !/^0x[0-9a-f]{1,16}=(?:[0-9a-f]{2})+$/i.test(value)) pspFatal(38);
        if (key === 'thread') thread(value);
        if (key === 'threads') value.split(',').forEach(thread);
        if (key === 'process' && (!/^[0-9a-f]+$/i.test(value) || BigInt('0x' + value) !== BigInt(pid))) pspFatal(12);
        if (key === 'fork' || key === 'vfork') pspFatal(13);
        if (key === 'metype' && !/^[0-9a-f]{1,8}$/i.test(value)) pspFatal(14);
    }
    return fields;
}
function pspRegisters(reply, protocol) {
    const fields = pspFields(reply);
    for (const key of (protocol ? ['thread', '20', '10', '00', '01', '02', '03'] : ['thread', '20'])) {
        const values = fields.filter(field => field.startsWith(key + ':'));
        if (values.length !== 1) pspFatal(15);
        const value = values[0].slice(key.length + 1);
        if (key === 'thread') {
            if (!/^(?:[0-9a-f]+|p[0-9a-f]+\.[0-9a-f]+)$/i.test(value)) pspFatal(10);
            if (/^p/i.test(value) && BigInt('0x' + value.slice(1).split('.')[0]) !== BigInt(pid)) pspFatal(11);
        } else if (!/^[0-9a-f]{16}$/i.test(value)) pspFatal(16);
    }
    if (protocol) {
        const pc = littleEndianHexStringToNumber(fields.find(field => field.startsWith('20:')).slice(3));
        if ((pc & 3n) !== 0n || pc > 0xfffffffffffffffbn) pspFatal(17);
    }
}
'''
    text = replace(text, 'function ulog(msg) { if (logBudget > 0) { logBudget--; log(msg); } }',
                   'function ulog(msg) {} // PSP persists only typed allowlisted records.')
    text = replace(text, 'let pid = get_pid();', 'pid = get_pid();')
    text = replace(text, 'iridiumJITSetup("attach", attachResponse);', 'iridiumJITSetup("attach", attachResponse);\npspFields(attachResponse);')
    text = replace(text, 'let detached = false;', "pspEvent('ready', 0, 0, 0n);\nlet detached = false;")
    text = replace(text, '    let tidMatch = /T[0-9a-f]+thread:(?<tid>[0-9a-f]+);/.exec(brkResponse);', '''    pspRegisters(brkResponse);
    let tidMatch = /(?:^|;)thread:(?<tid>(?:[0-9a-f]+|p[0-9a-f]+\\.[0-9a-f]+));/i.exec(brkResponse.slice(3));''')
    text = replace(text, '    send_command(`P20=${pcPlus4};thread:${tid};`);', '    pspAck(send_command(`P20=${pcPlus4};thread:${tid};`));')
    text = replace(text, '        send_command(`P0=${numberToLittleEndianHexString(0n)};thread:${tid};`);', '        pspAck(send_command(`P0=${numberToLittleEndianHexString(0n)};thread:${tid};`));')
    text = replace(text, '    if (!isBrk) {', '    if (!isBrk || brkResponse.slice(0, 3).toLowerCase() !== \"t05\" || metype !== 6) {')
    text = replace(text, '    let brkImm = extractBrkImmediate(instrU32);', '''    let brkImm = extractBrkImmediate(instrU32);
    if (brkImm !== 0xf00d) pspFatal(19);
    if (brkImm === 0xf00d) {
        const command = littleEndianHexStringToNumber(brkResponse.slice(3).split(';').find(field => field.startsWith('10:')).slice(3));
        if (command !== 0n && command !== 1n) pspFatal(20);
        pspRegisters(brkResponse, true);
        const fields = brkResponse.slice(3).split(';');
        const reg = key => littleEndianHexStringToNumber(fields.find(field => field.startsWith(key + ':')).slice(3));
        if (reg('02') !== 2n) pspFatal(40);
        const sequence = pspSequence + 1;
        if (command === 0n) {
            if (reg('00') !== 0n || reg('01') !== 0n || reg('03') !== 0n) pspFatal(41);
        } else if (pspAllocationFailed || sequence > 4 || reg('00') !== 0n ||
                   reg('03') !== BigInt(sequence) || reg('01') !== (sequence === 1 ? 16777216n : 262144n)) pspFatal(41);
    }''')
    text = replace(text, '(brkImm !== 0xf00d && brkImm !== 0x69)', '(brkImm !== 0xf00d)')
    text = replace(text, '    // Genuine BRK from here on — the protocol path.', '    // Genuine BRK from here on — the protocol path.')
    text = replace(text, '            send_command(`D`);\n            detached = true;', '''            pspAck(send_command(`D`));
            pspEvent('detach.ack', pspSequence, 0, 0n);
            detached = true;''')
    a = text.index('            let addr = x0;')
    b = text.index('\n        } else if (x16Num === 3n)', a)
    text = text[:a] + r'''
            const sequence = pspSequence + 1;
            let address = 0n, prepared = false;
            const allocation = send_command(`_M${x1.toString(16)},rx`);
            if (typeof allocation === 'string' && /^E[0-9a-f]{2}$/i.test(allocation)) {
                pspNote(17, 39, allocation);
                log(`IRPSP3 code=39 seq=${sequence} error=${parseInt(allocation.slice(1), 16)} version=2`);
            } else {
                if (typeof allocation !== 'string' || !/^[0-9a-f]{1,16}$/i.test(allocation)) pspFatal(42);
                address = BigInt('0x' + allocation);
                if (address === 0n || address >= (1n << 36n) || (address & 16383n) !== 0n ||
                    x1 > (1n << 36n) - address) pspFatal(42);
                if (pspAllocations.some(a => address < a.address + a.bytes && a.address < address + x1)) pspFatal(43);
                pspAllocations.push({address, bytes: x1});
                pspEvent('allocated', sequence, Number(x1), address);
                prepared = true;
                for (let offset = 0n; offset < x1; offset += 16384n) {
                    const response = send_command(`M${(address + offset).toString(16)},1:69`);
                    if (response !== 'OK') {
                        // Only a complete error reply is a synchronized definitive failure.
                        if (typeof response !== 'string' || !/^E[0-9a-f]{2}$/i.test(response)) pspFatal(21);
                        pspNote(15, 23, response);
                        log(`IRPSP3 code=23 seq=${sequence} error=${parseInt(response.slice(1), 16)} version=2`);
                        prepared = false; break;
                    }
                }
            }
            pspAllocationFailed = !prepared;
            pspAck(send_command(`P0=${numberToLittleEndianHexString(prepared ? address : 0n)};thread:${tid};`));
            if (prepared) pspSequence = sequence;
            pspEvent(prepared ? 'prepared' : 'prepare.failed', sequence, Number(x1), address);
''' + text[b:]
    # No page-zero operation; allocation is restricted to the four owned requests.
    a = text.index('        } else if (x16Num === 3n)')
    text = text[:a] + '\n        }\n    }\n}\n'
    # Fixed command families only; no outgoing command or reply enters telemetry.
    for old, phase in (
        ('send_command(`vAttach;', 1), ('send_command(`QSetIgnoredExceptions:', 2),
        ('send_command(`QPassSignals:', 3), ('send_command(`c`)', 4),
        ('send_command(`vCont;', 5), ('send_command(`C${', 6),
        ('send_command(`m${', 8), ('send_command(`k`)', 10),
        ('send_command(`P20=', 12), ('send_command(`P0=${numberToLittleEndianHexString(0n)}', 13),
        ('send_command(`D`)', 14), ('send_command(`M${', 15), ('send_command(`_M${', 17),
        ('send_command(`P0=${numberToLittleEndianHexString(prepared ?', 16),
    ):
        if old not in text:
            raise ValueError('PSP diagnostic command hook changed: ' + old)
        text = text.replace(old, old.replace('send_command(', f'pspSend({phase}, '))
    if 'send_command(' in text:
        raise ValueError('Unclassified PSP command')
    return prelude + '\ntry {\n' + text + '''
} catch (error) {
    if (pspCode < 2) pspNote(pspPhase, 26, undefined, true);
    throw error;
}
'''


def apply(name, text):
    if name == 'JITNetwork.swift':
        start = text.index('    func restoreIfNeeded(completion:')
        end = text.index('    /// At launch:', start)
        text = text[:start] + '''    func restoreIfNeeded(completion: @escaping () -> Void) {
        restorePSP { _ in completion() }
    }

''' + text[end:]
        text = replace(text, '    /// At launch: a run that ended', '''    /// PSP keeps the debt until correlated success. A void callback is not proof.
    var pspRecoveryPending: Bool { pending != nil || waiting != nil }

    func restorePSP(completion: @escaping (Outcome) -> Void) {
        guard let input = pending else { completion(.done("")); return }
        guard waiting == nil else { completion(.failed("Network restoration is already active.")); return }
        run(input) { [weak self] outcome in
            if case .done = outcome, self?.pending == input { self?.pending = nil }
            completion(outcome)
        }
    }

    /// At launch: a run that ended''')
        # An owed restoration belongs to the attempt, even if the setting changed.
        text = replace(text, 'guard pending != nil, enabled else { return }', 'guard pending != nil else { return }')
    elif name == 'JITSetup.swift':
        text = replace(text, '    /// LocalDevVPN\'s loopback first', '''    /// PSP owns a distinct script and the original helper completion. Existing
    /// foreign readiness is never permission to issue our BRK protocol.
    var pspRecoveryPending: Bool { JITNetworkShortcut.shared.pspRecoveryPending }

    func beginPSP(attempt: String, hash: String, script: Data,
                  shouldProceed: @escaping () -> Bool,
                  started: @escaping () -> Void,
                  final: @escaping (Bool, Result<MadeiraJITRequest.Response, Error>) -> Void) -> UUID? {
        guard enableRequest == nil, !busy, !pspRecoveryPending, resolvedMethod == .builtIn,
              SigningStatus.current.debuggable, ir_psp_self_trace_clear(),
              IridiumJITHelperSnapshot.validAttemptID(attempt),
              let pairing = try? JITPairingFileStore.data() else { return nil }
        let owner = UUID(); enableRequest = owner; busy = true
        ensureLoopback(then: { [weak self] _ in
            guard self?.enableRequest == owner, shouldProceed() else {
                final(false, .failure(CancellationError())); return
            }
            var request = MadeiraJITRequest.enable(targetPID: getpid(), pairingData: pairing,
                                                   scriptBase64: script.base64EncodedString())
            request.diagnosticAttemptID = attempt
            request.pspProtocolVersion = 2; request.pspAttemptID = attempt; request.pspScriptSHA256 = hash
            guard ir_psp_self_trace_clear() else { final(false, .failure(CancellationError())); return }
            MadeiraBuiltInJIT.send(request, started: started, completion: { final(true, $0) })
        }, stopped: { message in
            final(false, .failure(NSError(domain: "IridiumPSPJIT", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: message])))
        })
        return owner
    }

    func restorePSP(owner: UUID, completion: @escaping (Bool) -> Void) {
        guard enableRequest == owner else { completion(false); return }
        JITNetworkShortcut.shared.restorePSP { [weak self] result in
            guard let self, enableRequest == owner else { completion(false); return }
            if case .done = result { completion(true) } else { completion(false) }
        }
    }

    func releasePSP(owner: UUID) {
        guard enableRequest == owner else { return }
        enableRequest = nil; busy = false
    }

    /// LocalDevVPN's loopback first''')
    elif name == 'StikJITHelper.swift':
        encoded = base64.b64encode(script().encode()).decode()
        text = replace(text, 'enum StikJITHelper {', 'enum StikJITHelper {\n    static let pspScriptData = Data(base64Encoded: "' + encoded + '")!')
    elif name == 'JITBuiltInMessages.swift':
        text = replace(text, '    let scriptBase64: String?\n    var diagnosticAttemptID: String? = nil', '''    let scriptBase64: String?
    var diagnosticAttemptID: String? = nil
    var pspProtocolVersion: Int? = nil
    var pspAttemptID: String? = nil
    var pspScriptSHA256: String? = nil''')
        text = replace(text, '        var diagnosticRecords: [String]? = nil', '        var diagnosticRecords: [String]? = nil\n        var pspReceipt: IridiumPSPHelperReceipt? = nil')
        text += '\n' + SUPPORT.read_text()
    elif name == 'JITBuiltInHost.swift':
        text = replace(text, '                continuation.resume(returning: records)', '''                if let receipt = response.pspReceipt, receipt.valid {
                    RuntimeDiagnosticLogFiles.writeConsoleLine(receipt.publicSummary)
                }
                continuation.resume(returning: records)''')
        text = replace(text, '    static func send(_ request:', '''    static func pspSnapshot(attempt: String, completion: @escaping (IridiumPSPHelperReceipt?) -> Void) {
        var request = MadeiraJITRequest.diagnostics
        request.pspAttemptID = attempt
        send(request) { result in
            guard case .success(let response) = result, response.success,
                  response.diagnosticAttemptID == request.diagnosticAttemptID,
                  let receipt = response.pspReceipt, receipt.valid, receipt.attempt == attempt else { completion(nil); return }
            completion(receipt)
        }
    }

    static func send(_ request:''')
    elif name == 'MadeiraJITHelper.swift':
        text = 'import CryptoKit\n' + text
        text = replace(text, 'diagnosticRecords: directory.map { IridiumJITHelperSnapshot.read(in: $0) } ?? [])', '''diagnosticRecords: directory.map { IridiumJITHelperSnapshot.read(in: $0) } ?? [],
                         pspReceipt: IridiumPSPHelperJournal.read().flatMap { receipt in
                             request.pspAttemptID == nil || request.pspAttemptID == receipt.attempt ? receipt : nil
                         })''')
        text = replace(text, '        let manager = FileManager.default', '        var pspJournal: IridiumPSPHelperJournal?\n        let manager = FileManager.default')
        text = replace(text, '                let diagnostic = IridiumJITHelperDiagnostic(', '''                if request.pspProtocolVersion != nil {
                    guard request.pspProtocolVersion == 2,
                          let attempt = request.pspAttemptID, IridiumJITHelperSnapshot.validAttemptID(attempt),
                          request.diagnosticAttemptID == attempt,
                          let script = Data(base64Encoded: scriptBase64), script.count <= 65536,
                          String(decoding: script, as: UTF8.self).contains("IRIDIUM_PSP_PREPARED_V2"),
                          let expected = request.pspScriptSHA256,
                          SHA256.hash(data: script).map({ String(format: "%02x", $0) }).joined() == expected else {
                        throw NSError(domain: "IridiumPSPHelper", code: 1)
                    }
                    let journal = IridiumPSPHelperJournal(attempt: attempt, hash: expected, pid: targetPID)
                    guard journal.healthy else { throw NSError(domain: "IridiumPSPHelper", code: 2) }
                    pspJournal = journal
                }
                let diagnostic = IridiumJITHelperDiagnostic(''')
        text = replace(text, 'progress: { diagnostic.receive($0) })', 'progress: { diagnostic.receive($0); pspJournal?.receive($0) })\n                pspJournal?.sdkReturned(clean: true)')
        text = replace(text, '''                        NSLog("[MadeiraJIT] prepare: %@", String(describing: $0))''',
                       '''                        if pspJournal == nil { NSLog("[MadeiraJIT] prepare: %@", String(describing: $0)) }''')
        text = replace(text, '                return .init(success: true,\n                             message: "Madeira detached cleanly from its built-in JIT helper.",', '''                if let pspJournal {
                    let receipt = pspJournal.receipt
                    return .init(success: pspJournal.healthy && receipt.sdkReturnedClean,
                                 message: "PSP helper operation returned.", txmPresent: StikJIT.isTXMPresent,
                                 diagnosticAttemptID: request.diagnosticAttemptID, pspReceipt: receipt)
                }
                return .init(success: true,
                             message: "Madeira detached cleanly from its built-in JIT helper.",''')
        text = replace(text, '        } catch {\n            return .init(success: false, message: error.localizedDescription,', '''        } catch {
            if let pspJournal {
                pspJournal.sdkReturned(clean: false)
                return .init(success: false, message: "PSP helper failed; restart may be required.",
                             txmPresent: StikJIT.isTXMPresent, diagnosticAttemptID: request.diagnosticAttemptID,
                             pspReceipt: pspJournal.receipt)
            }
            return .init(success: false, message: error.localizedDescription,''')
    return text
