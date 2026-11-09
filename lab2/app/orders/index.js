'use strict';
require('../lib/otel');
const express = require('express');
const { Pool } = require('pg');
const Redis = require('ioredis');
const log = require('../lib/log');
const m = require('../lib/metrics');
const { sleep } = require('../lib/util');
const payments = require('./payments_client');

const PORT = +process.env.PORT || 3002;
const POOL_MAX = +process.env.ORDERS_DB_POOL_MAX || 10;
const CACHE_TTL = +process.env.ORDERS_CACHE_TTL_SEC;          // TTL чеков в памяти, 0 = не истекают
const RETRY_MAX = +process.env.PAYMENTS_RETRY_MAX || 0;
const BACKOFF_MS = +process.env.PAYMENTS_RETRY_BACKOFF_MS || 0;
const PAYMENT_TIMEOUT_MS = +process.env.PAYMENTS_TIMEOUT_MS || 2000;
const RISK_CHECK_MS = 500;            // проверка антифрода при оформлении заказа
const RECEIPT_BYTES = 160 * 1024;     // «чек» с реквизитами, хранится в памяти процесса
const HISTORY_TTL_SEC = 120;
const SLOW_QUERY_MS = 300;

const pool = new Pool({ host: process.env.DB_HOST || 'postgres', user: 'app', password: 'app', database: 'shop',
                        max: POOL_MAX, connectionTimeoutMillis: 2000, idleTimeoutMillis: 30000 });
pool.on('error', (e) => log.error('pg pool error', { error: e.message }));
const redis = new Redis({ host: process.env.REDIS_HOST || 'redis', maxRetriesPerRequest: 1,
                          commandTimeout: 500, enableOfflineQueue: false });
redis.on('error', (e) => log.warn('redis error', { error: e.message }));

const { client } = m;
new client.Gauge({ name: 'db_pool_max', help: 'Размер пула соединений', collect() { this.set(POOL_MAX); } });
new client.Gauge({ name: 'db_pool_in_use', help: 'Занятые соединения пула', collect() { this.set(pool.totalCount - pool.idleCount); } });
new client.Gauge({ name: 'db_pool_waiting', help: 'Запросы, ожидающие соединение', collect() { this.set(pool.waitingCount); } });
const cacheHits = new client.Counter({ name: 'cache_hits_total', help: 'Попадания в кэш', labelNames: ['cache'] });
const cacheMisses = new client.Counter({ name: 'cache_misses_total', help: 'Промахи кэша', labelNames: ['cache'] });
const receipts = new Map();
new client.Gauge({ name: 'receipt_cache_entries', help: 'Чеки в памяти', collect() { this.set(receipts.size); } });
if (CACHE_TTL > 0) setInterval(() => { const now = Date.now(); for (const [k, v] of receipts) if (v.exp < now) receipts.delete(k); }, 5000).unref();

// Справочник товаров: описания подмешиваются в ответ и кэшируются вместе с ним.
const CATALOG = Object.fromEntries(Array.from({ length: 12 }, (_, i) =>
  [`sku-${i}`, `Описание товара ${i}: ${'lorem ipsum '.repeat(35)}`]));

async function timed(name, rid, fn) {
  const t0 = Date.now();
  try { return await fn(); } finally {
    const d = Date.now() - t0;
    if (d > SLOW_QUERY_MS) log.warn('slow query', { query: name, duration_ms: d, request_id: rid });
  }
}

async function chargeWithRetry(body, ctx) {
  let last;
  for (let attempt = 0; attempt <= RETRY_MAX; attempt++) {
    try { return await payments.charge(body, PAYMENT_TIMEOUT_MS, ctx); } catch (e) {
      last = e;
      log.warn('payment attempt failed', { attempt: attempt + 1, of: RETRY_MAX + 1, error: e.message,
                                           order_id: body.order_id, request_id: ctx.requestId });
      if (attempt < RETRY_MAX && BACKOFF_MS > 0) await sleep(BACKOFF_MS * (attempt + 1));
    }
  }
  throw last;
}

const app = express();
app.use(express.json());
app.get('/health', (_q, r) => r.send('ok'));
app.get('/metrics', m.handler);
app.use(m.middleware);

const h = (fn) => (req, res) => fn(req, res).catch((e) => {
  const poolErr = /timeout exceeded when trying to connect/.test(e.message);
  log.error(poolErr ? 'db connection acquire timeout' : 'request failed',
            { error: e.message, path: req.path, request_id: req.get('x-request-id') });
  res.status(poolErr ? 503 : 500).json({ error: poolErr ? 'db_unavailable' : 'internal' });
});

app.get('/users/:id/history', h(async (req, res) => {
  const uid = +req.params.id, rid = req.get('x-request-id'), key = `hist:${uid}`;
  let cached = null;
  try { cached = await redis.get(key); } catch (e) { log.warn('cache get failed', { error: e.message, request_id: rid }); }
  if (cached) { cacheHits.inc({ cache: 'history' }); return res.type('json').send(cached); }
  cacheMisses.inc({ cache: 'history' });
  log.info('cache miss', { key, request_id: rid });
  const report = await timed('user_report', rid, () => pool.query('SELECT * FROM user_report($1)', [uid]));
  const rows = await timed('recent_orders', rid, () => pool.query(
    'SELECT id, item, amount, status, created_at FROM orders WHERE user_id = $1 ORDER BY id DESC LIMIT 20', [uid]));
  const body = JSON.stringify({ user_id: uid, report: report.rows[0],
    orders: rows.rows.map((r) => ({ ...r, description: CATALOG[r.item] })) });
  redis.set(key, body, 'EX', HISTORY_TTL_SEC).catch((e) => log.warn('cache set failed', { error: e.message, request_id: rid }));
  res.type('json').send(body);
}));

app.get('/users/:id/stats', h(async (req, res) => {
  const uid = +req.params.id, rid = req.get('x-request-id');
  const r = await timed('user_stats', rid, () => pool.query(
    'SELECT count(*)::int AS orders, coalesce(sum(amount), 0)::float AS total FROM orders WHERE user_id = $1', [uid]));
  res.json({ user_id: uid, ...r.rows[0] });
}));

app.post('/orders', h(async (req, res) => {
  const { user_id: uid, item, amount } = req.body;
  const rid = req.get('x-request-id');
  const conn = await pool.connect();
  let orderId;
  try {                                   // резервирование заказа: соединение занято на время проверки
    await conn.query('BEGIN');
    const r = await conn.query(
      "INSERT INTO orders (user_id, item, amount, status) VALUES ($1, $2, $3, 'pending') RETURNING id", [uid, item, amount]);
    orderId = r.rows[0].id;
    await sleep(RISK_CHECK_MS);
    await conn.query('COMMIT');
  } catch (e) { await conn.query('ROLLBACK').catch(() => {}); throw e; } finally { conn.release(); }
  log.info('order created', { order_id: orderId, user_id: uid, request_id: rid });

  try {
    await chargeWithRetry({ order_id: orderId, user_id: uid, amount }, { requestId: rid });
  } catch (e) {
    await pool.query("UPDATE orders SET status = 'failed' WHERE id = $1", [orderId]);
    log.error('payment failed', { order_id: orderId, error: e.message, request_id: rid });
    return res.status(502).json({ error: 'payment_failed', order_id: orderId });
  }
  await pool.query("UPDATE orders SET status = 'paid' WHERE id = $1", [orderId]);
  receipts.set(orderId, { data: Buffer.alloc(RECEIPT_BYTES, 'r'), exp: CACHE_TTL > 0 ? Date.now() + CACHE_TTL * 1000 : Infinity });
  log.info('order paid', { order_id: orderId, user_id: uid, request_id: rid });
  res.status(201).json({ order_id: orderId, status: 'paid' });
}));

app.listen(PORT, () => log.info('orders listening', { port: PORT, pool_max: POOL_MAX }));
