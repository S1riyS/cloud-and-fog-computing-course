'use strict';
// Нагрузочный генератор: фиксированный объём запросов (не времени) по детерминированному профилю.
// Профиль: WARMUP_REQ запросов (спокойная фаза) при BASE_RPS, BURST_REQ при BURST_RPS (всплеск), TAIL_REQ при BASE_RPS.
// Результат (подписанный JSON) пишется в /evidence; ошибки = ответы 5xx и сетевые сбои/таймауты.
const http = require('http');
const fs = require('fs');
const crypto = require('crypto');

const E = process.env;
const phase = process.argv.includes('--phase') ? process.argv[process.argv.indexOf('--phase') + 1] : 'before';
if (!['before', 'after'].includes(phase)) { console.error('--phase before|after'); process.exit(2); }
const TARGET = new URL(E.TARGET || 'http://gateway:3001');
const SEED = String(E.RUN_SEED);
const USERS = +E.USERS, BASE = +E.BASE_RPS, BURST = +E.BURST_RPS;
const W = +E.WARMUP_REQ, B = +E.BURST_REQ, T = +E.TAIL_REQ, TOTAL = W + B + T;
const REQ_TIMEOUT_MS = 10000;
const MIX = { calm: { checkout: 0.25, history: 0.65 }, burst: { checkout: 0.45, history: 0.20 } };  // остальное: stats

function mulberry32(a) { return () => { a |= 0; a = (a + 0x6D2B79F5) | 0; let t = Math.imul(a ^ (a >>> 15), 1 | a);
  t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t; return ((t ^ (t >>> 14)) >>> 0) / 4294967296; }; }
const rnd = mulberry32(parseInt(crypto.createHash('sha256').update(SEED).digest('hex').slice(0, 8), 16));

// расписание (открытая модель): запрос i уходит в момент t[i] независимо от ответов
const plan = []; let t = 0;
for (let i = 0; i < TOTAL; i++) {
  const burst = i >= W && i < W + B;
  const mix = burst ? MIX.burst : MIX.calm, x = rnd();
  const kind = x < mix.checkout ? 'checkout' : x < mix.checkout + mix.history ? 'history' : 'stats';
  const user = 1 + Math.floor(rnd() * USERS);
  plan.push({ at: t, kind, user, item: `sku-${Math.floor(rnd() * 12)}`, amount: Math.round((10 + rnd() * 990) * 100) / 100, burst });
  t += 1000 / (burst ? BURST : BASE);
}

const agent = new http.Agent({ keepAlive: true, maxSockets: Infinity });
const results = [];
let startMs, burstStartMs = null, sent = 0, done = 0, timer;

function send(p) {
  const t0 = Date.now();
  const body = p.kind === 'checkout' ? JSON.stringify({ user_id: p.user, item: p.item, amount: p.amount }) : null;
  const path = p.kind === 'checkout' ? '/api/checkout' : `/api/users/${p.user}/${p.kind}`;
  const headers = body ? { 'content-type': 'application/json', 'content-length': Buffer.byteLength(body) } : {};
  const fin = (status) => { results.push({ user: p.user, status, ms: Date.now() - t0, end: Date.now() }); if (++done === TOTAL) finish(); };
  const req = http.request({ hostname: TARGET.hostname, port: TARGET.port, path, method: body ? 'POST' : 'GET', headers, agent, timeout: REQ_TIMEOUT_MS },
    (res) => { res.resume(); res.on('end', () => fin(res.statusCode)); });
  req.on('timeout', () => { req.destroy(); });
  req.on('error', () => fin(0));
  if (body) req.write(body);
  req.end();
}

const iso = (ms) => new Date(ms).toISOString().slice(0, 19) + 'Z';
function canonical(o) { return JSON.stringify(Object.fromEntries(Object.keys(o).sort().map((k) => [k, o[k]]))); }

function finish() {
  clearInterval(timer);
  const errs = results.filter((r) => r.status === 0 || r.status >= 500).sort((a, b) => a.end - b.end);
  const lat = results.map((r) => r.ms).sort((a, b) => a - b);
  const payload = {
    phase, run_id: `${phase}-${Date.now().toString(36)}-${crypto.randomBytes(3).toString('hex')}`,
    seed_tag: crypto.createHash('sha256').update(SEED).digest('hex').slice(0, 16),
    n_total: TOTAL, n_5xx: errs.length, users_affected: new Set(errs.map((r) => r.user)).size,
    first_5xx_utc: errs.length ? iso(errs[0].end) : '', start_utc: iso(startMs), end_utc: iso(Date.now()),
    burst_start_utc: burstStartMs ? iso(burstStartMs) : '', p95_ms: lat[Math.floor(lat.length * 0.95)] || 0,
  };
  payload.sig = crypto.createHmac('sha256', SEED).update(canonical(payload)).digest('hex');
  const file = `/evidence/${phase === 'before' ? 'loadgen_result.json' : 'loadgen_after.json'}`;
  fs.writeFileSync(file, JSON.stringify(payload, null, 2));
  console.log(`\nГотово: запросов ${TOTAL}, ошибок ${payload.n_5xx}, p95 ${payload.p95_ms} мс. Результат: ${file}`);
  if (phase === 'before') {
    const ticket = payload.n_5xx
      ? `Обращение в поддержку: около ${payload.first_5xx_utc.slice(11, 16)} UTC часть пользователей получила ошибки 5xx.\n` +
        `Установите причину и восстановите цепочку событий по трём источникам (трейсы, логи, метрики).`
      : 'Ошибок не зафиксировано. Выполните reset.sh, затем up.sh и повторите прогон.';
    console.log(`\n=== ТИКЕТ ===\n${ticket}\n=============`);
    fs.writeFileSync('/evidence/ticket.txt', ticket + '\n');
  }
  process.exit(0);
}

function get(path) {
  return new Promise((resolve) => {
    const req = http.request({ hostname: TARGET.hostname, port: TARGET.port, path, agent, timeout: 60000 }, (res) => { res.resume(); res.on('end', resolve); });
    req.on('timeout', () => req.destroy()); req.on('error', resolve); req.end();
  });
}

// Прогрев: заполняем кэш истории по всем пользователям (в измерение не входит), чтобы «холодный» кэш не искажал прогон.
async function prewarm() {
  console.log(`Прогрев кэша: ${USERS} пользователей...`);
  let next = 1;
  await Promise.all([0, 1, 2].map(async () => { while (next <= USERS) await get(`/api/users/${next++}/history`); }));
}

function start() {
console.log(`Фаза ${phase}: ${TOTAL} запросов (спокойная фаза ${W}, всплеск ${B}, хвост ${T}). Ожидаемая длительность ≈ ${Math.round(t / 1000)} с.`);
startMs = Date.now();
timer = setInterval(() => {
  const now = Date.now() - startMs;
  while (sent < TOTAL && plan[sent].at <= now) {
    if (plan[sent].burst && burstStartMs === null) burstStartMs = Date.now();
    send(plan[sent++]);
    if (sent % 200 === 0) console.log(`  отправлено ${sent}/${TOTAL}, ответов ${done}`);
  }
}, 10);
}

prewarm().then(start);
