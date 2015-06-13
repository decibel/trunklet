\i test/helpers/psql.sql

CREATE SCHEMA tap;
GRANT USAGE ON SCHEMA tap TO public;
SET search_path = tap;
CREATE EXTENSION IF NOT EXISTS pgtap SCHEMA tap;

\pset format unaligned
\pset tuples_only true
\pset pager
