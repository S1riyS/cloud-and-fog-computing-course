'use strict';
require('../lib/otel');
const http = require('http');
const crypto = require('crypto');
const express = require('express');
const log = require('../lib/log');
const m = require('../lib/metrics');

const PORT = +process.env.PORT || 3001;
const ORDERS = { host: process.env.ORDERS_HOST || 'orders', port: +process.env.ORDERS_PORT || 3002 };
const UPSTREAM_TIMEOUT_MS = 5000;

const app = express();
app.use(express.json());
app.get('/health', (_q, r) => r.send('ok'));
app.get('/metrics', m.handler);
app.use(m.middleware);
app.use((req, res, next) => {
  req.rid = req.get('x-request-id') || crypto.randomUUID();
  res.set('x-request-id', req.rid);
  const t0 = Date.now();
  res.on('finish', () => log.info('request', {
    request_id: req.rid, method: req.method, path: req.originalUrl.split('?')[0],
    status: res.statusCode, duration_ms: Date.now() - t0, user_id: req.userId }));
  next();
});

function upstream(method, path, body, rid) {
  return new Promise((resolve, reject) => {
    const data = body ? JSON.stringify(body) : null;
    const headers = { 'x-request-id': rid };
    if (data) { headers['content-type'] = 'application/json'; headers['content-length'] = Buffer.byteLength(data); }
    const req = http.request({ ...ORDERS, path, method, headers, timeout: UPSTREAM_TIMEOUT_MS }, (res) => {
      let buf = '';
      res.on('data', (c) => { buf += c; });
      res.on('end', () => resolve({ status: res.statusCode, body: buf }));
    });
    req.on('timeout', () => req.destroy(Object.assign(new Error('upstream timeout'), { code: 'ETIMEDOUT' })));
    req.on('error', reject);
    if (data) req.write(data);
    req.end();
  });
}

async function proxy(req, res, method, path, body) {
  try {
    const r = await upstream(method, path, body, req.rid);
    res.status(r.status).type('json').send(r.body);
  } catch (e) {
    log.error('upstream failed', { request_id: req.rid, error: e.message, code: e.code });
    res.status(e.code === 'ETIMEDOUT' ? 504 : 502).json({ error: 'upstream_unavailable' });
  }
}

app.get('/api/users/:id/history', (req, res) => { req.userId = +req.params.id; proxy(req, res, 'GET', `/users/${req.userId}/history`); });
app.get('/api/users/:id/stats', (req, res) => { req.userId = +req.params.id; proxy(req, res, 'GET', `/users/${req.userId}/stats`); });
app.post('/api/checkout', (req, res) => { req.userId = +req.body.user_id; proxy(req, res, 'POST', '/orders', req.body); });

app.listen(PORT, () => log.info('gateway listening', { port: PORT }));
