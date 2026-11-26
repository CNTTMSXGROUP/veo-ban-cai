import { writeSync } from 'node:fs';
import { DatabaseSync } from 'node:sqlite';

const prepare = DatabaseSync.prototype.prepare;
DatabaseSync.prototype.prepare = function (sql) {
    const statement = prepare.call(this, sql);
    if (sql !== 'UPDATE versions SET plan_json = ? WHERE project_id = ? AND n = ?') return statement;
    const run = statement.run.bind(statement);
    statement.run = (...args) => {
        const result = run(...args);
        if (args[2] === 0) {
            writeSync(1, JSON.stringify({ write: Number(result.changes), transaction: this.isTransaction }) + '\n');
            Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0);
        }
        return result;
    };
    return statement;
};
