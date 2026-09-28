# FakeGram — PostgreSQL HA (Patroni)

Кластер PostgreSQL для [Fakegram-backend](https://github.com/CodedSplash/Fakegram-backend): Patroni + etcd + HAProxy.

| Режим | Состав | Порты на хосте |
|-------|--------|----------------|
| `dev`  | 1× etcd, 1× Patroni, HAProxy, db-init | `5000` primary, `5001` replicas, `7000` HAProxy stats, `8008` Patroni REST |
| `prod` | 3× etcd, 3× Patroni, HAProxy, db-init | те же порты, но только на `127.0.0.1` (`PG_BIND_ADDRESS`) |

Приложения подключаются **только через HAProxy**:

* из контейнеров — `pg-haproxy:5000` в общей сети `fakegram-db-network`;
* с хоста (dev) — `localhost:5000`.

## Запуск

```bash
cd fakegram

# dev
docker compose --env-file .env.dev -f docker-compose.yml -f docker-compose.dev.yml up -d --build

# prod
cp .env.prod.example .env.prod   # заполнить пароли
docker compose --env-file .env.prod -f docker-compose.yml -f docker-compose.prod.yml up -d --build
```

Кластер Patroni нужно поднимать **раньше** бэкенда: он создаёт сеть `fakegram-db-network`,
которую бэкенд подключает как `external`.

## Что происходит при старте

1. etcd поднимается и становится `healthy`.
2. Patroni-узлы регистрируются в etcd, один из них инициализирует кластер (`initdb`) и становится лидером.
3. HAProxy (confd следит за `/service/fakegram` в etcd) направляет `:5000` на лидера, `:5001` — на реплики.
4. `db-init` (одноразовый, идемпотентный) через HAProxy создаёт/обновляет:
   * роль приложения `APP_DB_USER` и БД `APP_DB_NAME` (владелец — эта роль);
   * роль `DEBEZIUM_DB_USER` с `REPLICATION` и `SELECT` на таблицы `public` (включая будущие);
   * публикацию `dbz_publication FOR ALL TABLES` для Debezium.

## Логическая репликация (Debezium)

`patroni.yml` задаёт `wal_level=logical`, `hot_standby_feedback=on` и **постоянный логический слот**
`debezium_fakegram` (`pgoutput`, БД `fakegram`). Patroni создаёт слот на лидере и копирует его на реплики,
поэтому после failover Debezium продолжает чтение с новым лидером без потери позиции.

`max_slot_wal_keep_size=4GB` защищает диск: если Debezium долго не читает слот, слот будет инвалидирован
(потребуется новый snapshot), а диск не переполнится.

> Имя БД `fakegram` для слота зашито в `patroni.yml` (Patroni не подставляет переменные в YAML).
> Если меняете `APP_DB_NAME`, поменяйте и `bootstrap.dcs.slots.debezium_fakegram.database`.

> Секция `bootstrap.dcs` применяется только при первой инициализации кластера. Для уже созданного кластера
> параметры меняются через `patronictl edit-config`.

## Полезные команды

```bash
docker compose -f docker-compose.yml -f docker-compose.dev.yml exec patroni1 patronictl list
docker compose -f docker-compose.yml -f docker-compose.prod.yml exec patroni1 patronictl switchover
docker compose -f docker-compose.yml -f docker-compose.dev.yml run --rm db-init
docker compose -f docker-compose.yml -f docker-compose.dev.yml down -v   # удалить кластер вместе с данными
```
