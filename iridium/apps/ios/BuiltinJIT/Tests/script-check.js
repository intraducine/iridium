const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const source = fs.readFileSync(path.join(__dirname, '../Helper/madeira-jit.js'), 'utf8');
for (const attach of ['T05thread:1;', 'E01', '']) {
    const logs = [], commands = [];
    const run = () => vm.runInNewContext(source, {
        get_pid: () => 123,
        log: text => logs.push(text),
        send_command: command => {
            commands.push(command);
            if (command.startsWith('vAttach;')) return attach;
            if (command === 'c') return 'W00';
            return 'OK';
        }
    }, {timeout: 1000});
    if (attach.startsWith('T')) {
        run();
        assert.equal(logs.filter(x => x === 'IRIDIUM_SCRIPT_LISTENING').length, 1);
        assert(commands.indexOf('QPassSignals:1;2;3;4;6;7;8;9;a;b;c;d;e;f;10;11;12;13;14;15;16;17;18;19;1a;1b;1c;1d;1e;1f') > 0);
    } else {
        assert.throws(run, /Debugger attach rejected/);
        assert(!logs.includes('IRIDIUM_SCRIPT_LISTENING'));
        assert(!commands.includes('c'));
    }
}
console.log('PASS: script readiness follows accepted attach; rejected and disconnected attach never start preparation');
