'use strict';
// Трассировка OpenTelemetry. Экспорт: OTLP/HTTP (адрес и сэмплер задаются переменными OTEL_*).
const { NodeSDK } = require('@opentelemetry/sdk-node');
const { OTLPTraceExporter } = require('@opentelemetry/exporter-trace-otlp-proto');
const { Resource } = require('@opentelemetry/resources');
const { HttpInstrumentation } = require('@opentelemetry/instrumentation-http');
const { ExpressInstrumentation } = require('@opentelemetry/instrumentation-express');
const { PgInstrumentation } = require('@opentelemetry/instrumentation-pg');
const { IORedisInstrumentation } = require('@opentelemetry/instrumentation-ioredis');

const service = process.env.SERVICE || 'app';
const skip = new Set(['/health', '/metrics']);

const sdk = new NodeSDK({
  resource: new Resource({ 'service.name': service, 'deployment.environment': 'lab2' }),
  traceExporter: new OTLPTraceExporter(),
  instrumentations: [
    new HttpInstrumentation({ ignoreIncomingRequestHook: (req) => skip.has(req.url) }),
    new ExpressInstrumentation(),
    new PgInstrumentation(),
    new IORedisInstrumentation(),
  ],
});
sdk.start();
process.on('SIGTERM', () => sdk.shutdown().finally(() => process.exit(0)));
