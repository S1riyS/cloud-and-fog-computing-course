#set page(paper: "a4", margin: (x: 1.6cm, y: 1.5cm), numbering: "1")
#set text(font: ("Times New Roman", "Liberation Serif"), size: 12pt, lang: "ru")
#set par(justify: false, leading: 0.65em)
#set heading(numbering: none)
#show heading: set block(above: 1em, below: 0.4em)
#show heading.where(level: 1): set text(size: 14pt)
#show heading.where(level: 2): set text(size: 12pt)
#set figure(gap: 0.4em)
#show figure.caption: set text(size: 10pt)

#align(center)[
  #text(size: 16pt, weight: "bold")[Практическая работа 3] \
  Сквозная трассировка микросервисов
]

= 2.1. Здоровый запрос

Трасса `f22f161`, `GET /api/checkout`, 158,31 мс, HTTP 200.

#figure(
  image("images/1_healthy_trace.png", width: 100%),
  caption: [Трасса `f22f161`.],
)

== Вопросы

- Сколько всего спанов содержит трасса? *13*.
- Каким HTTP-заголовком передался контекст? *`traceparent`*. В Jaeger значения нет, поэтому в `service-b` добавлен лог всех заголовков запроса (`console.log(req.headers)`). В логе: `00-36a6fd22152fbc03652f308df54b390a-8d17a26a3c1230f0-01`.
- Сколько занял SQL `SELECT * FROM orders ...`? *832 мкс*.

#figure(
  image("images/2_headers.png", width: 100%),
  caption: [Лог заголовков входящего запроса в `service-b`.],
)

#pagebreak()

= 2.2. Узкое место

Трасса `e24d797`, 2,07 с, HTTP 200.

#figure(
  image("images/3_bottleneck.png", width: 100%),
  caption: [Трасса `e24d797`. Длинный спан — `GET /process-order` сервиса `service-b-orders` (2,01 с).],
)

== Вопросы

- На каком сервисе и компоненте задержка? *`service-b-orders`*, обработчик *`GET /process-order`* (2,01 с).
- Причина — медленный SQL или код Node.js? *Код Node.js*: `setTimeout` (`delay = 2000`). `pg.query` в конце таймлайна занял 3,73 мс, между 56 мс и 2058 мс дочерних спанов нет.

= 2.3. Ошибка 500

Трасса `f49cd4a`, 2,06 с, HTTP 500, 10 спанов.

#figure(
  image("images/4_error_trace.png", width: 100%),
  caption: [Трасса `f49cd4a`. Лог спана `GET /process-order`.],
)

== Вопросы

- Какой сервис сгенерировал ошибку? *`service-b-orders`* (`GET /process-order`, статус 500).
- Какой `exception.message` в логе спана? *`Payment gateway timeout error`* (`/app/index.js:32:34`).
- Дошёл ли запрос до PostgreSQL? Нет: спанов, связанных с БД нет

= Исправление

В `service-b/index.js` поставлено `isError = false`.

После `docker-compose up -d --build service-b` все 10 запросов вернули `SUCCESS`. Ошибок 500 нет.

#figure(
  image("images/5_fix.png", width: 100%),
  caption: [10 запросов после пересборки `service-b`: все ответы `SUCCESS`.],
)

= Выводы

Задержка ~2 с — `setTimeout` в `service-b-orders`, SQL занимает единицы миллисекунд. Ошибка 500 — тот же сервис, `Payment gateway timeout error`, до базы запрос не доходит. После пересборки `service-b` с `isError = false` серия из 10 запросов прошла без 500.
