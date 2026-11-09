'use strict';
// Метрики Prometheus: HTTP-счётчик, гистограмма задержек и системные метрики процесса.
const client = require('prom-client');
const service = process.env.SERVICE || 'app';

client.collectDefaultMetrics({ labels: { service } });

const requests = new client.Counter({
  name: 'http_requests_total', help: 'HTTP-запросы', labelNames: ['service', 'route', 'status'] });
const duration = new client.Histogram({
  name: 'http_request_duration_seconds', help: 'Длительность HTTP-запросов', labelNames: ['service', 'route'],
  buckets: [0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10] });

function middleware(req, res, next) {
  const end = duration.startTimer();
  res.on('finish', () => {
    const route = req.route ? (req.baseUrl || '') + req.route.path : 'unmatched';
    requests.inc({ service, route, status: res.statusCode });
    end({ service, route });
  });
  next();
}

async function handler(_req, res) {
  res.set('Content-Type', client.register.contentType);
  res.end(await client.register.metrics());
}

module.exports = { client, middleware, handler };
