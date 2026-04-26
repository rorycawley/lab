-- Static application user. Credentials for this user are stored verbatim in
-- OpenBao at kv/data/postgres and read by /query/static.
CREATE ROLE appuser WITH LOGIN PASSWORD 'apppass';
GRANT CONNECT ON DATABASE pocdb TO appuser;
GRANT pg_read_all_data TO appuser;

-- The vaultadmin role already exists (POSTGRES_USER). It is the privileged
-- user OpenBao's database secrets engine uses to CREATE/DROP short-lived
-- roles for /query/dynamic.
ALTER ROLE vaultadmin CREATEROLE;
