'use strict';
require('../lib/otel');
const crypto = require('crypto');
const express = require('express');
const log = require('../lib/log');
const m = require('../lib/metrics');
const { sleep } = require('../lib/util');

const PORT = +process.env.PORT || 3003;
const CONCURRENCY = +process.env.PAYMENTS_CONCURRENCY || 16;

// Платёжный шлюз обрабатывает не более CONCURRENCY операций одновременно, остальные ждут в очереди.
let active = 0;
const waiters = [];
const acquire = () => new Promise((resolve) => { if (active < CONCURRENCY) { active++; resolve(); } else waiters.push(resolve); });
const release = () => { const next = waiters.shift(); if (next) next(); else active--; };

const calls = new m.client.Counter({ name: 'payments_calls_total', help: 'Запросы на списание' });
new m.client.Gauge({ name: 'payments_in_flight', help: 'Операции в обработке', collect() { this.set(active); } });
new m.client.Gauge({ name: 'payments_queue_length', help: 'Запросы в очереди', collect() { this.set(waiters.length); } });

const app = express();
app.use(express.json());
app.get('/health', (_q, r) => r.send('ok'));
app.get('/metrics', m.handler);
app.use(m.middleware);

app.post('/charge', async (req, res) => {
  calls.inc();
  const rid = req.get('x-request-id');
  await acquire();
  try {
    await sleep(160 + Math.random() * 40);   // обработка у платёжного провайдера
    const chargeId = crypto.randomUUID();
    log.info('charge processed', { order_id: req.body.order_id, request_id: rid, charge_id: chargeId });
    res.json({ status: 'ok', charge_id: chargeId });
  } finally { release(); }
});

app.listen(PORT, () => log.info('payments listening', { port: PORT, concurrency: CONCURRENCY }));
