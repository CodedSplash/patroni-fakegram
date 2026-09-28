#!/bin/sh
set -eu

export PGHOST="${PGHOST:-haproxy}"
export PGPORT="${PGPORT:-5000}"
export PGDATABASE=postgres
export PGCONNECT_TIMEOUT=5

app_db="${APP_DB_NAME:-fakegram}"
app_user="${APP_DB_USER:-fakegram}"
app_password="${APP_DB_PASSWORD:?APP_DB_PASSWORD is required}"
app_createdb="${APP_DB_CREATEDB:-false}"
dbz_user="${DEBEZIUM_DB_USER:-debezium}"
dbz_password="${DEBEZIUM_DB_PASSWORD:?DEBEZIUM_DB_PASSWORD is required}"
dbz_publication="${DEBEZIUM_PUBLICATION:-dbz_publication}"
attempts="${INIT_MAX_ATTEMPTS:-60}"
attempt=1

until [ "$(psql -tAc 'SELECT NOT pg_is_in_recovery()' 2>/dev/null)" = "t" ]; do
  if [ "$attempt" -ge "$attempts" ]; then
    echo "[db-init] primary is not available at $PGHOST:$PGPORT" >&2
    exit 1
  fi
  echo "[db-init] waiting for primary at $PGHOST:$PGPORT (attempt $attempt/$attempts)"
  attempt=$((attempt + 1))
  sleep 3
done

psql -v ON_ERROR_STOP=1 \
  -v app_db="$app_db" \
  -v app_user="$app_user" \
  -v app_password="$app_password" \
  -v app_createdb="$app_createdb" \
  -v dbz_user="$dbz_user" \
  -v dbz_password="$dbz_password" \
  -v dbz_publication="$dbz_publication" <<'SQL'
SELECT format('CREATE ROLE %I LOGIN', :'app_user')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'app_user') \gexec

SELECT format(
  'ALTER ROLE %I WITH LOGIN %s PASSWORD %L',
  :'app_user',
  CASE WHEN :'app_createdb' = 'true' THEN 'CREATEDB' ELSE 'NOCREATEDB' END,
  :'app_password'
) \gexec

SELECT format('CREATE ROLE %I LOGIN REPLICATION', :'dbz_user')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'dbz_user') \gexec

SELECT format('ALTER ROLE %I WITH LOGIN REPLICATION PASSWORD %L', :'dbz_user', :'dbz_password') \gexec

SELECT format('CREATE DATABASE %I OWNER %I ENCODING %L TEMPLATE template0', :'app_db', :'app_user', 'UTF8')
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = :'app_db') \gexec

SELECT format('REVOKE ALL ON DATABASE %I FROM PUBLIC', :'app_db') \gexec
SELECT format('GRANT CONNECT, TEMPORARY ON DATABASE %I TO %I', :'app_db', :'app_user') \gexec
SELECT format('GRANT CONNECT ON DATABASE %I TO %I', :'app_db', :'dbz_user') \gexec

\connect :app_db

SELECT format('GRANT USAGE ON SCHEMA public TO %I', :'dbz_user') \gexec
SELECT format('GRANT SELECT ON ALL TABLES IN SCHEMA public TO %I', :'dbz_user') \gexec
SELECT format(
  'ALTER DEFAULT PRIVILEGES FOR ROLE %I IN SCHEMA public GRANT SELECT ON TABLES TO %I',
  :'app_user',
  :'dbz_user'
) \gexec

SELECT format('CREATE PUBLICATION %I FOR ALL TABLES', :'dbz_publication')
WHERE NOT EXISTS (SELECT 1 FROM pg_publication WHERE pubname = :'dbz_publication') \gexec
SQL

echo "[db-init] database '$app_db', roles '$app_user' and '$dbz_user', publication '$dbz_publication' are ready"
