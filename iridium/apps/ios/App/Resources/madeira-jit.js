// Madeira JIT Script for StikDebug
// Handles BRK #0xf00d (universal protocol) with x16-based command dispatch.
//
// ml346 (v2): soft-signal stops (EXC_SOFT_SIGNAL) forward the ORIGINAL signo
// from medata[1] and are never guarded; raw fault stops forward a mapped
// signal with a kill-not-detach last resort (detach leaves the task port
// registered but unserviced -> parked threads).
// ml345: only genuine BRK instructions are skipped (pc+4). The debugger holds
// the TASK-level exception port, so every fault the app's own Mach handler
// declines (KERN_FAILURE) lands HERE — the old "ALWAYS advance PC" behavior
// skip-stepped real crashes instruction by instruction (and zeroed x0),
// silently corrupting threads until they wandered into data (ml344: a
// 4,000-fault +4 walk through shared-cache data ending in a bogus guest
// exception). Non-BRK stops are now handed back to the process as a unix
// signal so wine's sigaction handlers run; if the signal cannot be delivered
// the script detaches so the process dies visibly instead of wandering.

// StikJIT 1.9's batch formatter keeps only nine address digits. Keep the
// complete address and check each reply, including on 512 GB address maps.
function iridiumPrepareRegion(address, length) {
    const limit = 1n << 64n;
    if (address <= 0n || length <= 0n || length > (1n << 32n) ||
        address >= limit || length > limit - address) return false;
    const end = address + length;
    for (let page = address & ~0x3fffn; page < end; page += 0x4000n) {
        if (send_command(`M${page.toString(16)},1:69`) !== 'OK') return false;
    }
    return true;
}

function littleEndianHexStringToNumber(hexStr) {
    const bytes = [];
    for (let i = 0; i < hexStr.length; i += 2) {
        bytes.push(parseInt(hexStr.substr(i, 2), 16));
    }
    let num = 0n;
    for (let i = 7; i >= 0; i--) {
        num = (num << 8n) | BigInt(bytes[i] || 0);
    }
    return num;
}

function numberToLittleEndianHexString(num) {
    const bytes = [];
    for (let i = 0; i < 8; i++) {
        bytes.push(Number(num & 0xFFn));
        num >>= 8n;
    }
    return bytes.map(b => b.toString(16).padStart(2, '0')).join('');
}

function littleEndianHexToU32(hexStr) {
    return parseInt(hexStr.match(/../g).reverse().join(''), 16);
}

function extractBrkImmediate(u32) {
    return (u32 >> 5) & 0xFFFF;
}

let pid = get_pid();
log(`Madeira JIT: pid = ${pid}`);

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

let attachResponse = send_command(`vAttach;${pid.toString(16)}`);
iridiumJITSetup("attach", attachResponse);

// ml355: STOP SERVICING ANYTHING BUT BRK.
//
// Every signal and fault stop costs several synchronous protocol round-trips
// on StikDebug's side. Wine signals constantly (thread suspend/resume), so the
// v2 script burned 27s CPU in ~60s and iOS killed StikDebug itself with the
// scene-update watchdog (0x8BADF00D) — which tore down the debug session and
// left Madeira to be SIGKILLed with no crash report. That is the "instant
// vanish, empty StikDebug log" the user kept seeing.
//
// Both packets below are best-effort; on an older stub they simply fail and
// the fault/signal paths further down still work as before.
//   QSetIgnoredExceptions — debugserver stops intercepting these Mach
//     exceptions, so they reach the app's OWN handlers (wine registers
//     thread-level ports for BAD_ACCESS+BAD_INSTRUCTION, and anything it
//     declines becomes a normal BSD signal into wine's sigaction handlers).
//   QPassSignals — deliver signals to the inferior without stopping. SIGTRAP
//     is deliberately EXCLUDED: BRK arrives that way and is our whole job.
{
    let ign = send_command(`QSetIgnoredExceptions:EXC_BAD_ACCESS;EXC_BAD_INSTRUCTION`);
    iridiumJITSetup("ignore", ign);
    let sigs = [];
    for (let s = 1; s <= 31; s++) if (s !== 5) sigs.push(s.toString(16));
    let pass = send_command(`QPassSignals:${sigs.join(';')}`);
    iridiumJITSetup("pass", pass);
}

let detached = false;
let pending = null;        // stop packet returned by a continue we already sent
let lastFaultKey = null;   // "tid:pc" of the last non-BRK stop
let faultRepeats = 0;
let faultLogs = 0;
let sigLogs = 0;
// Hard ceiling on UI log lines: each log() drives a SwiftUI update, and it is
// scene-update stalls that the watchdog kills for. Use ulog() everywhere
// inside the stop loop; bare log() only for the few startup lines.
let logBudget = 40;
function ulog(msg) { if (logBudget > 0) { logBudget--; log(msg); } }

function looksLikeStop(resp) {
    return typeof resp === 'string' && /^[TSWX]/.test(resp);
}

// Forward a unix signal to the stopped thread and remember the next stop.
// Returns true if the continue was accepted.
function forwardSignal(sig, tid) {
    let sigHex = sig.toString(16).padStart(2, '0');
    let resp = send_command(`vCont;C${sigHex}:${tid};c`);
    if (!looksLikeStop(resp)) {
        resp = send_command(`C${sigHex}`);
    }
    if (looksLikeStop(resp)) {
        pending = resp;
        return true;
    }
    return false;
}

while (!detached) {
    let brkResponse = pending !== null ? pending : send_command(`c`);
    pending = null;
    iridiumJITStop(brkResponse);
    // StikJIT returns an empty string after a transport error. Do not resend forever.
    if (typeof brkResponse !== 'string' || brkResponse === '' || /^E[0-9a-f]{2}$/i.test(brkResponse)) {
        throw new Error('JIT debugger connection ended without a stop reply.');
    }

    // W/X = inferior exited; nothing left to debug.
    if (typeof brkResponse === 'string' && /^[WX]/.test(brkResponse)) {
        ulog(`Madeira JIT: inferior exited (${brkResponse})`);
        detached = true;
        continue;
    }

    let tidMatch = /T[0-9a-f]+thread:(?<tid>[0-9a-f]+);/.exec(brkResponse);
    let tid = tidMatch ? tidMatch.groups['tid'] : null;
    let pcMatch = /20:(?<reg>[0-9a-f]{16});/.exec(brkResponse);
    let pc = pcMatch ? pcMatch.groups['reg'] : null;

    if (!tid || !pc) {
        ulog(`Madeira JIT: failed to parse, continuing`);
        continue;
    }

    let pcNum = littleEndianHexStringToNumber(pc);

    // medata values are hex WITHOUT 0x prefix (ml345 run: EXC_SOFT_SIGNAL
    // printed as "10003"). metype is a small integer, same either way.
    let metypeMatch = /metype:([0-9a-f]+);/.exec(brkResponse);
    let metype = metypeMatch ? parseInt(metypeMatch[1], 16) : 0;
    let medata = [];
    let mre = /medata:([0-9a-fx]+);/g, mm;
    while ((mm = mre.exec(brkResponse)) !== null) medata.push(parseInt(mm[1], 16));

    // EXC_SOFTWARE / EXC_SOFT_SIGNAL (metype 5, medata[0]=0x10003): the
    // kernel is routing a unix SIGNAL through the debugger — pthread_kill,
    // wine's suspend signals, fault-conversion signals, all of it. This is
    // not a fault and not ours to judge: forward the ORIGINAL signo
    // (medata[1]) untouched, never count repeats (wine legitimately retries
    // same-pc faults), never detach. v1 misdelivered these as SIGSEGV and
    // then detached on wine's boot-time retry loop (ml345).
    if (metype === 5) {
        let signo = (medata.length > 1 && medata[1] >= 1 && medata[1] <= 31) ? medata[1] : 0;
        if (sigLogs < 8 || (sigLogs % 500) === 0) {
            ulog(`Madeira JIT: soft-signal tid=${tid} pc=0x${pcNum.toString(16)} ` +
                `signo=${signo || '?'} (#${sigLogs})`);
        }
        sigLogs++;
        if (signo === 0 || !forwardSignal(signo, tid)) {
            // Unknown signo or C unsupported: plain continue and trust the
            // stub to deliver the pending signal on resume.
            let resp = send_command(`c`);
            if (looksLikeStop(resp)) pending = resp;
        }
        continue;
    }

    let instrHex = send_command(`m${pcNum.toString(16)},4`);
    let insnOk = typeof instrHex === 'string' && /^[0-9a-fA-F]{8}$/.test(instrHex);
    let instrU32 = insnOk ? littleEndianHexToU32(instrHex) : 0;
    // BRK #imm16 = 1101 0100 001 imm16 00000
    let isBrk = insnOk && ((instrU32 & 0xFFE0001F) >>> 0) === 0xD4200000;

    if (!isBrk) {
        iridiumJITStop(brkResponse, "first.fault", pc, insnOk, instrU32);
        // A raw fault stop escalated past the app's Mach handler. Never skip
        // it. Deliver it back to the process as a unix signal so the app's
        // sigaction handlers (wine segv/bus/ill) get an honest shot at it.
        let key = `${tid}:${pc}`;
        faultRepeats = (key === lastFaultKey) ? faultRepeats + 1 : 1;
        lastFaultKey = key;

        let kcode = medata.length > 0 ? medata[0] : 0;

        // EXC_RESOURCE (metype 11) is a task-level advisory, not a thread
        // fault — MEMORY/HIGH_WATERMARK fires when phys_footprint crosses
        // the jetsam limit (kcode bits 12:0 = limit in MB; ml359 saw 4096).
        // The old default injected SIGSEGV into whatever thread the stop
        // named, crashing an innocent thread at the worst moment. Log and
        // resume with no signal.
        if (metype === 11) {
            ulog(`Madeira JIT: EXC_RESOURCE tid=${tid} kcode=${kcode.toString(16)} ` +
                `(memory HWM ${kcode & 0x1fff} MB?) — continuing, no signal`);
            let resp = send_command(`c`);
            if (looksLikeStop(resp)) pending = resp;
            continue;
        }

        let sig = 11;                                  // SIGSEGV default
        if (metype === 1) sig = (kcode === 1) ? 11 : 10; // BAD_ACCESS: INVALID→SEGV, PROT→BUS
        else if (metype === 2) sig = 4;                // BAD_INSTRUCTION → SIGILL
        else if (metype === 3) sig = 8;                // ARITHMETIC → SIGFPE
        else if (metype === 6) sig = 5;                // BREAKPOINT (non-BRK) → SIGTRAP

        if (faultLogs < 16) {
            faultLogs++;
            ulog(`Madeira JIT: fault (not BRK) tid=${tid} pc=0x${pcNum.toString(16)} ` +
                `insn=${insnOk ? instrU32.toString(16).padStart(8, '0') : `<${instrHex}>`} ` +
                `metype=${metype} kcode=${kcode.toString(16)} -> sig ${sig} (repeat ${faultRepeats})`);
        }

        // NEVER detach here: with the StikDebug window still open the task
        // exception port stays registered but unserviced, and every later
        // escalated fault parks its thread forever (ml345 wedged steam.exe's
        // main thread exactly this way). If the fault truly cannot be
        // delivered, kill the inferior — a visible death with logs intact.
        if (faultRepeats >= 8) {
            ulog(`Madeira JIT: fault at pc=0x${pcNum.toString(16)} undeliverable after ` +
                `${faultRepeats} tries — killing inferior (visible death beats a parked thread)`);
            send_command(`k`);
            detached = true;
            continue;
        }

        if (!forwardSignal(sig, tid)) {
            // Forwarding rejected: plain continue; if the same stop recurs
            // the guard above eventually kills.
            let resp = send_command(`c`);
            if (looksLikeStop(resp)) pending = resp;
        }
        continue;
    }

    // Genuine BRK from here on — the protocol path.
    lastFaultKey = null;
    faultRepeats = 0;

    let brkImm = extractBrkImmediate(instrU32);

    // Advance PC past the BRK so it cannot re-fire
    let pcPlus4 = numberToLittleEndianHexString(pcNum + 4n);
    send_command(`P20=${pcPlus4};thread:${tid};`);

    let x16Match = /10:(?<reg>[0-9a-f]{16});/.exec(brkResponse);
    let x16 = x16Match ? x16Match.groups['reg'] : null;

    // Skip unknown BRK immediates (PC already advanced)
    if ((brkImm !== 0xf00d && brkImm !== 0x69) || !x16) {
        // Set x0=0 (failure/skip indicator) so app's SIGTRAP fallback works
        send_command(`P0=${numberToLittleEndianHexString(0n)};thread:${tid};`);
        continue;
    }

    ulog(`Madeira JIT: BRK #0x${brkImm.toString(16)}`);

    // Parse x0 and x1
    let x0Match = /00:(?<reg>[0-9a-f]{16});/.exec(brkResponse);
    let x1Match = /01:(?<reg>[0-9a-f]{16});/.exec(brkResponse);
    let x0 = x0Match ? littleEndianHexStringToNumber(x0Match.groups['reg']) : 0n;
    let x1 = x1Match ? littleEndianHexStringToNumber(x1Match.groups['reg']) : 0n;
    let x16Num = littleEndianHexStringToNumber(x16);

    if (brkImm === 0xf00d) {
        ulog(`Madeira JIT: x16 = ${x16Num}`);

        if (x16Num === 0n) {
            // CMD_DETACH
            ulog(`Madeira JIT: detach`);
            if (send_command(`D`) !== 'OK') throw new Error('JIT detach was not acknowledged.');
            detached = true;

        } else if (x16Num === 1n) {
            // CMD_PREPARE_REGION
            ulog(`Madeira JIT: prepare addr=0x${x0.toString(16)} size=0x${x1.toString(16)}`);

            let addr = x0;
            if (x0 === 0n && x1 > 0n && x1 <= (1n << 32n)) {
                let allocResp = send_command(`_M${x1.toString(16)},rx`);
                if (typeof allocResp === 'string' && /^[0-9a-f]{1,16}$/i.test(allocResp)) {
                    const allocated = BigInt(`0x${allocResp}`);
                    if (allocated > 0n && (allocated & 0x3fffn) === 0n) addr = allocated;
                    ulog(`Madeira JIT: allocated at 0x${addr.toString(16)}`);
                }
            }

            if (addr !== 0n && x1 !== 0n) {
                const prepared = iridiumPrepareRegion(addr, x1);
                ulog(`Madeira JIT: prepared = ${prepared}`);
                if (!prepared) addr = 0n;
            }

            send_command(`P0=${numberToLittleEndianHexString(addr)};thread:${tid};`);

        } else if (x16Num === 3n) {
            // CMD_MAP_PAGE_ZERO: Map a page at address 0 with TEB data.
            // x0 = TEB address, x1 = size (0x4000 = 16KB iOS page)
            // The app can't map page 0 itself (kernel refuses). The debugger
            // may have different privileges to create this mapping.
            ulog(`Madeira JIT: map page zero, TEB=0x${x0.toString(16)} size=0x${x1.toString(16)}`);

            let success = 0n;

            // Try allocating RW memory at address 0 via _M with fixed address
            // StikDebug's _M command: _M<size>,<perms> — but doesn't support fixed addr
            // Try GDB memory allocation: mmap via the debugger's task port
            // Use vCont or direct Mach calls if available

            // Approach 1: Try writing TEB data to address 0 directly.
            // If the hardware zero page is writable via the debugger, this works.
            if (x0 !== 0n && x1 !== 0n) {
                // Read TEB data from the app's memory
                let tebPage = x0 & ~0x3FFFn;  // align to 16KB page
                let tebOff = x0 - tebPage;

                // Try to write TEB data at address 0 via GDB M command
                // Read 256 bytes from TEB (enough for PEB pointer at offset 0x60)
                let tebData = send_command(`m${x0.toString(16)},100`);
                if (tebData && tebData.length > 0) {
                    // Write it to address 0+tebOff
                    let writeResp = send_command(`M${tebOff.toString(16)},${(tebData.length/2).toString(16)}:${tebData}`);
                    ulog(`Madeira JIT: write TEB to page0 offset 0x${tebOff.toString(16)}: ${writeResp}`);
                    if (writeResp === 'OK') {
                        success = 1n;
                    }
                }
            }

            send_command(`P0=${numberToLittleEndianHexString(success)};thread:${tid};`);
        }

    } else if (brkImm === 0x69) {
        // Legacy protocol
        ulog(`Madeira JIT: legacy BRK 0x69, x0=0x${x0.toString(16)}`);
        const prepared = x0 !== 0n && iridiumPrepareRegion(x0, x1);
        send_command(`P0=${numberToLittleEndianHexString(prepared ? x0 : 0n)};thread:${tid};`);
    }
}
