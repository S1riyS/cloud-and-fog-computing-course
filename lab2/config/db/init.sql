CREATE TABLE orders (
  id         bigserial PRIMARY KEY,
  user_id    int            NOT NULL,
  item       text           NOT NULL,
  amount     numeric(10, 2) NOT NULL,
  status     text           NOT NULL DEFAULT 'paid',
  created_at timestamptz    NOT NULL DEFAULT now()
);

INSERT INTO orders (user_id, item, amount, created_at)
SELECT (g % :users) + 1, 'sku-' || (g % 12), round((random() * 990 + 10)::numeric, 2),
       now() - (g || ' seconds')::interval
FROM generate_series(1, :rows) g;

CREATE INDEX idx_orders_user_id ON orders (user_id);

-- Отчёт по пользователю: число заказов и «рейтинг» (имитация тяжёлой аналитики).
CREATE FUNCTION user_report(uid int) RETURNS TABLE (orders_count bigint, score bigint) AS $$
  SELECT (SELECT count(*) FROM orders WHERE user_id = uid),
         (SELECT count(*) FROM generate_series(1, 150000) g WHERE md5(g::text || uid::text) < '1')
$$ LANGUAGE sql STABLE;

ANALYZE orders;
