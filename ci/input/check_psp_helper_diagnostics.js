// Synthetic replies only. Run unchanged in Node and the SDK's JavaScriptCore.
function check(value, message) { if (!value) throw Error(message); }
function le(x) {
    let out = '';
    for (let i = 0; i < 8; i++) { out += Number(x & 255n).toString(16).padStart(2, '0'); x >>= 8n; }
    return out;
}
function stop(command = 1n, address = 0x400000000n, bytes = 16777216n) {
    const seq=command===0n?0n:(address-0x400000000n)/0x2000000n+1n;
    return `T05metype:6;thread:p7b.1;20:${le(0x100000000n)};10:${le(command)};00:${le(0n)};01:${le(command===0n?0n:bytes)};02:${le(2n)};03:${le(seq)};`;
}
function run(script, options = {}) {
    const calls = [], logs = [], stops = (options.stops || ['W00']).slice();
    let failed = false, allocations=0;
    const send = command => {
        calls.push(command);
        for (const prefix of Object.keys(options.replies || {})) {
            if (!command.startsWith(prefix)) continue;
            const answer = options.replies[prefix];
            if (answer && answer.thrown) throw Error('synthetic SDK failure');
            return answer;
        }
        if (options.match && command.startsWith(options.match)) {
            if (options.thrown) throw Error('synthetic SDK failure');
            return options.answer;
        }
        if (command.startsWith('vAttach')) return options.attach === undefined ? 'T05thread:1;' : options.attach;
        if (command === 'c') return stops.length ? stops.shift() : 'W00';
        if (command.startsWith('vCont;C') || command.startsWith('C')) return 'W00';
        if (command.startsWith('_M')) return (0x400000000n+BigInt(allocations++)*0x2000000n).toString(16);
        if (command.startsWith('m')) return options.instruction === undefined ? 'a0013ed4' : options.instruction;
        return 'OK';
    };
    try { new Function('get_pid', 'send_command', 'log', script)(() => {
        if (options.pidThrown) throw Error('synthetic SDK failure');
        return 123;
    }, send, s => logs.push(s)); }
    catch (error) {
        failed = true;
        check(/PSP helper protocol failed|synthetic SDK failure/.test(String(error)), 'unexpected script exception');
    }
    for (const s of logs.filter(s => s.startsWith('IRPSP2 '))) {
        check(/^IRPSP2 phase=\d+ code=\d+ length=\d+ fields=\d+ version=2$/.test(s) && s.length <= 160, 'unbounded telemetry');
    }
    for (const s of logs.filter(s => s.startsWith('IRPSP3 '))) {
        check(/^IRPSP3 code=(22|23|39) seq=[1-5] error=\d{1,3} version=2$/.test(s) && s.length <= 96, 'unbounded preparation failure');
    }
    function has(phase, code) { return logs.some(s => s.startsWith(`IRPSP2 phase=${phase} code=${code} `)); }
    check(!logs.some(s => s.includes('SECRET') || s.includes('T05metype') || s.includes('synthetic SDK failure')), 'remote data leaked');
    return { calls, logs, failed, has };
}
const cases = [];
function scenario(options, phase, code) {
    const result = run(source, options);
    check(result.has(phase, code), `missing phase ${phase} code ${code}`);
    cases.push(options);
    return result;
}
scenario({ pidThrown: true }, 0, 26);
for (const [attach, code] of [
    [null, 3], ['T05' + 'x'.repeat(2046) + ';', 4], ['S05thread:1;', 5],
    ['T05thread:1', 6], ['T05garbage;', 8], ['T05thread:1;thread:1;', 31],
    ['T05thread:p7b.;', 10], ['T05thread:p7c.1;', 11], ['T05thread:1;process:7c;', 12],
    ['T05thread:1;fork:p7c.1;', 13], ['T05thread:1;metype:SECRET;', 14]
]) {
    const r = scenario({ attach }, 1, code);
    check(r.failed && r.calls.length === 1, 'attach rejection changed');
}
for (const [field, code] of [['threads:p7b.1;', 32], ['process:7b;', 33], ['metype:6;', 34],
    ['20:0000000001000000;', 35], ['02:0000000000000000;', 36], ['reason:signal;', 37]]) {
    scenario({ attach: 'T05thread:1;' + field + field }, 1, code);
}
for (const value of ['0x1000=', '0x1000=0', '0x1000=gg', '1000=00', '0x10000000000000000=00', '0x1000=00:SECRET']) {
    scenario({ attach: 'T05thread:1;memory:' + value + ';' }, 1, 38);
}
// Construct a public-protocol-shaped 44-field/879-character synthetic stop.
// Values are invented; no device packet, stack bytes or identifiers are copied.
function expedited(command = 1n, address = 0x400000000n, bytes = 16777216n) {
    let result = 'T05';
    for (let i = 0; i <= 32; i++) {
        const value = i===0 ? 0n : i===1 ? (command===0n?0n:bytes) : i===2 ? 2n : i===3 ? (command===0n?0n:(address-0x400000000n)/0x2000000n+1n) : i===16 ? command : i===32 ? 0x100000000n:0n;
        result += i.toString(16).padStart(2, '0') + ':' + le(value) + ';';
    }
    result += '21:00000000;thread:p7b.1;name:fixture;qaddr:1000;reason:signal;metype:6;mecount:2;medata:1;medata:0;';
    result += 'memory:0x1000=' + '12'.repeat(16) + ';memory:0x2000=' + '34'.repeat(16) + ';';
    check(result.length <= 879, 'synthetic shape grew');
    result = result.replace('name:fixture;', 'name:fixture' + 'x'.repeat(879 - result.length) + ';');
    check(result.length === 879 && result.split(';').length - 1 === 44, 'synthetic summary shape');
    return result;
}
const memoryCase = { attach: expedited(), stops: [expedited(), expedited(1n, 0x402000000n, 262144n),
    expedited(1n, 0x404000000n, 262144n), expedited(1n, 0x406000000n, 262144n), expedited(0n)] };
const memoryResult = run(source, memoryCase);
check(!memoryResult.failed && memoryResult.calls.filter(s => s.startsWith('M')).length === 1072
    && memoryResult.calls.at(-1) === 'D', 'expedited metadata blocked owned flow');
check(!memoryResult.logs.some(s => s.includes('memory:') || s.includes('12121212') || s.includes('34343434')), 'expedited memory leaked');
check(!memoryResult.calls.some(s => /^m(?:1000|2000),/.test(s) || /^M(?:1000|2000),/.test(s)), 'expedited memory was adopted');
for (const packet of [expedited().replace('thread:p7b.1;', 'thread:p7c.1;'),
    expedited() + '20:0000000001000000;', expedited() + 'metype:6;',
    expedited().replace('memory:0x1000=', 'memory:0x10000000000000000=')]) {
    const r = run(source, { attach: expedited(), stops: [packet] });
    check(r.failed && !r.calls.some(s => s.startsWith('P') || s.startsWith('M') || s === 'D'), 'memory metadata bypassed strict stop refusal');
}
for (const options of [
    { stops: [expedited().replace('T05', 'T0a').replace('metype:6;', 'metype:1;')] },
    { stops: [expedited().replace('12'.repeat(16), 'a0013ed4'.repeat(4))], instruction: '00000000' }
]) {
    const r = run(source, { attach: expedited(), ...options });
    check(r.calls.some(s => s.startsWith('vCont;C')) && !r.calls.some(s => s.startsWith('P') || s.startsWith('M') || s === 'D'), 'expedited bytes authorized a BRK operation');
}
if (baseline !== null) {
    const old = run(baseline, memoryCase);
    check(old.failed && old.calls.length === 1, 'previous parser did not reproduce duplicate memory rejection');
}
for (const [packet, phase, code] of [
    [stop().replace(/20:[^;]+;/, ''), 4, 15], [stop().replace(/20:[^;]+;/, '20:00;'), 4, 16],
    [stop().replace(/20:[^;]+;/, `20:${le(0x100000001n)};`), 8, 17], [stop(3n), 8, 20]
]) scenario({ stops: [packet] }, phase, code);
scenario({ stops: [stop()], instruction: 'c0013ed4' }, 8, 19);
for (const [match, phase, options] of [
    ['vAttach', 1, {}], ['QSetIgnoredExceptions', 2, {}], ['QPassSignals', 3, {}],
    ['c', 4, {}], ['vCont;', 5, { stops: [stop().replace('T05metype:6;', 'T0ametype:1;')] }],
    ['m', 8, { stops: [stop()] }], ['P20=', 12, { stops: [stop()] }],
    ['D', 14, { stops: [stop(0n)] }], ['M', 15, { stops: [stop()] }],
    ['P0=', 16, { stops: [stop()] }], ['_M', 17, { stops: [stop()] }]
]) {
    scenario({ ...options, match, thrown: true }, phase, 2);
}
const fault = stop().replace('T05metype:6;', 'T0ametype:1;');
scenario({ stops: [fault], replies: { 'vCont;': '', C: { thrown: true } } }, 6, 2);
scenario({ stops: Array(8).fill(fault), replies: { 'vCont;': '', C: '' }, match: 'k', thrown: true }, 10, 2);
for (const [match, phase] of [['QSetIgnoredExceptions', 2], ['QPassSignals', 3]]) {
    const r = scenario({ match, answer: '' }, phase, 24);
    check(!r.failed && r.logs.some(s => s.includes('event=ready')), 'optional setup acceptance changed');
    scenario({ match, answer: 'E01' }, phase, 25);
}
for (const [match, phase, stops] of [['P20=', 12, [stop()]], ['P0=', 16, [stop()]], ['D', 14, [stop(0n)]]]) {
    const r = scenario({ match, answer: 'E01', stops }, phase, 18);
    check(r.failed, 'ACK rejection changed');
}
scenario({ match: 'M', answer: 'E0SECRET', stops: [stop()] }, 15, 21);
scenario({ match: 'M', answer: 'E01', stops: [stop(), stop(0n)] }, 15, 23);
scenario({ stops: [stop(1n, 0n), stop(0n)] }, 8, 41);
const success = run(source, { stops: [stop(), stop(1n, 0x402000000n, 262144n), stop(1n, 0x404000000n, 262144n), stop(1n, 0x406000000n, 262144n), stop(0n)] });
check(!success.failed && success.calls.filter(s => s.startsWith('M')).length === 1072, 'arena flow changed');
check(success.logs.filter(s => s.startsWith('IRPSP2 phase=15 ')).length === 4, 'page ACK telemetry is not bounded per arena');
cases.push({ stops: [stop(), stop(0n)] });
// Compare every outgoing command, existing ownership event and final result to
// the frozen previous script. Telemetry must not change debugger decisions.
for (const options of baseline === null ? [] : cases) {
    function projection(r) { return JSON.stringify([r.calls, r.logs.filter(s => s.startsWith('IRPSP1 ')), r.failed]); }
    const current = run(source, options), previous = run(baseline, options);
    if (current.has(1, 38)) {
        check(current.failed && !previous.failed, 'malformed expedited memory was not newly refused');
        continue;
    }
    check(projection(current) === projection(previous), 'behavior differs outside expedited memory correction');
}
// The legacy zero-register branch is unreachable after the owned-BRK gate;
// its command wrapper still has a fixed phase if that branch changes later.
const wrapperLogs = [];
try {
    new Function('send_command', 'log', source.slice(0, source.indexOf('\ntry {\n')) + '\npspSend(13, "fixture");')(
        () => { throw Error('synthetic SDK failure'); }, s => wrapperLogs.push(s));
} catch (error) { check(String(error).includes('synthetic SDK failure'), 'wrapper exception changed'); }
check(wrapperLogs.some(s => s.startsWith('IRPSP2 phase=13 code=2 ')), 'zero-register command boundary');
const budgetLogs = []; let budgetCalls = 0;
try {
    new Function('send_command', 'log', source.slice(0, source.indexOf('\ntry {\n')) + '\nfor(let i=0;i<1000;i++) pspSend(4, "fixture"); pspFatal(18);')(
        () => { budgetCalls++; return 'W00'; }, s => budgetLogs.push(s));
} catch (error) { check(String(error).includes('PSP helper protocol failed'), 'budget exception changed'); }
check(budgetCalls === 1000 && budgetLogs.filter(s => s.startsWith('IRPSP2 ')).length === 97, 'normal telemetry budget');
check(budgetLogs.some(s => s.startsWith('IRPSP2 phase=4 code=18 ')), 'terminal reason lost after budget');
console.log(`PASS ${cases.length} helper diagnostic scenarios; repeated memory and malformed chunks; bounded page telemetry${baseline === null ? '' : '; prior-script parity outside expedited memory correction'}`);
