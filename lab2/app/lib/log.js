'use strict';
// Структурные логи: одна JSON-строка на событие, в stdout и в /logs/<service>.log (читает Filebeat).
const fs = require('fs');
const { trace, context } = require('@opentelemetry/api');

const service = process.env.SERVICE || 'app';
const mode = process.env.LOG_TIME_MODE || 'utc_iso';
const logDir = process.env.LOG_DIR || '/logs';
let stream = null;
try {
  fs.mkdirSync(logDir, { recursive: true });
  stream = fs.createWriteStream(`${logDir}/${service}.log`, { flags: 'a' });
  stream.on('error', () => { stream = null; });
} catch (_) { /* пишем только в stdout */ }

const p = (n, w = 2) => String(n).padStart(w, '0');

function stamp(d = new Date()) {
  if (mode === 'local_naive') {
    return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}T${p(d.getHours())}:` +
           `${p(d.getMinutes())}:${p(d.getSeconds())}.${p(d.getMilliseconds(), 3)}`;
  }
  return d.toISOString();
}

function write(level, message, fields) {
  const span = trace.getSpan(context.active());
  const sc = span && span.spanContext();
  const rec = { ts: stamp(), level, service, message,
                ...(sc ? { trace_id: sc.traceId, span_id: sc.spanId } : {}), ...fields };
  const line = JSON.stringify(rec);
  process.stdout.write(line + '\n');
  if (stream) stream.write(line + '\n');
}

module.exports = {
  info: (m, f) => write('info', m, f),
  warn: (m, f) => write('warn', m, f),
  error: (m, f) => write('error', m, f),
};
