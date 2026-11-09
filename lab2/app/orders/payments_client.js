'use strict';
// Клиент платёжного сервиса (модуль http).
const http = require('http');

const target = { host: process.env.PAYMENTS_HOST || 'payments', port: +process.env.PAYMENTS_PORT || 3003, path: '/charge' };

function charge(body, timeoutMs, ctx) {
  return new Promise((resolve, reject) => {
    const data = JSON.stringify(body);
    const req = http.request({ ...target, method: 'POST', timeout: timeoutMs, headers: {
      'content-type': 'application/json', 'content-length': Buffer.byteLength(data), 'x-request-id': ctx.requestId } }, (res) => {
      let buf = '';
      res.on('data', (c) => { buf += c; });
      res.on('end', () => (res.statusCode < 300 ? resolve(JSON.parse(buf)) : reject(new Error(`payments status ${res.statusCode}`))));
    });
    req.on('timeout', () => req.destroy(new Error('payments timeout')));
    req.on('error', reject);
    req.write(data);
    req.end();
  });
}

module.exports = { charge };
