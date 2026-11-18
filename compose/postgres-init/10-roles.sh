#!/bin/sh
set -eu
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname postgres \
  -v owner="$OSTROM_OWNER" -v owner_pw="$OSTROM_OWNER_PASSWORD" \
  -v app="$OSTROM_APP" -v app_pw="$OSTROM_APP_PASSWORD" \
  -v db="$OSTROM_DB" -v polis_pw="$OSTROM_POLIS_PASSWORD" <<'SQL'
CREATE ROLE :"owner" LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS PASSWORD :'owner_pw';
CREATE ROLE :"app" LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS PASSWORD :'app_pw';
CREATE DATABASE :"db" OWNER :"owner";
REVOKE ALL ON DATABASE :"db" FROM PUBLIC;
GRANT CONNECT, TEMPORARY ON DATABASE :"db" TO :"app";
CREATE ROLE polis LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS PASSWORD :'polis_pw';
CREATE DATABASE polis OWNER polis;
REVOKE ALL ON DATABASE polis FROM PUBLIC;
\connect :"db"
REVOKE ALL ON SCHEMA public FROM PUBLIC;
ALTER SCHEMA public OWNER TO :"owner";
GRANT USAGE ON SCHEMA public TO :"app";
ALTER DEFAULT PRIVILEGES FOR ROLE :"owner" IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO :"app";
ALTER DEFAULT PRIVILEGES FOR ROLE :"owner" IN SCHEMA public GRANT USAGE, SELECT ON SEQUENCES TO :"app";
ALTER DEFAULT PRIVILEGES FOR ROLE :"owner" IN SCHEMA public GRANT EXECUTE ON FUNCTIONS TO :"app";
-- Same block as the pre-upgrade Job (database-roles-job.yaml), idempotent (S2-43).
SELECT 'CREATE ROLE ostrom_tenant NOLOGIN NOSUPERUSER NOBYPASSRLS'
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'ostrom_tenant') \gexec
ALTER ROLE :"owner" CREATEROLE;
GRANT ostrom_tenant TO :"owner" WITH ADMIN OPTION;
GRANT ostrom_tenant TO :"app";
SELECT 'CREATE ROLE ostrom_router NOLOGIN NOSUPERUSER NOBYPASSRLS'
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'ostrom_router') \gexec
GRANT ostrom_router TO :"owner" WITH ADMIN OPTION;
\connect :"db"
GRANT USAGE ON SCHEMA public TO ostrom_tenant;
-- AUDIT-RLS R8: the migrations' history is written by its owner alone. Any other role (the serving role, ostrom_tenant
-- that it inherits, PUBLIC) holding more than SELECT, on the table or a column, loses it all and keeps SELECT.
-- A named dollar quote: Kubernetes reads a doubled dollar sign in a container's args as one (the pre-upgrade Job).
DO $lock$
DECLARE r record;
BEGIN
  FOR r IN
    SELECT quote_ident(c.relname) AS tbl,
      CASE WHEN g.grantee = 0 THEN 'PUBLIC' ELSE quote_ident(pg_get_userbyid(g.grantee)) END AS name,
      bool_or(g.privilege_type = 'SELECT' AND NOT g.on_column) AS reads
    FROM pg_class c
    CROSS JOIN LATERAL (
      SELECT a.grantee, a.privilege_type, false AS on_column FROM aclexplode(c.relacl) a
      UNION ALL
      SELECT a.grantee, a.privilege_type, true FROM pg_attribute t, aclexplode(t.attacl) a WHERE t.attrelid = c.oid
    ) g
    WHERE c.relkind = 'r' AND c.relnamespace = 'public'::regnamespace AND c.relname LIKE 'flyway\_%'
      AND g.grantee <> c.relowner
    GROUP BY c.relname, g.grantee
    HAVING bool_or(g.privilege_type <> 'SELECT' OR g.on_column)
  LOOP
    EXECUTE format('REVOKE ALL ON public.%s FROM %s CASCADE', r.tbl, r.name);
    IF r.reads THEN
      EXECUTE format('GRANT SELECT ON public.%s TO %s', r.tbl, r.name);
    END IF;
  END LOOP;
END
$lock$;
SQL

