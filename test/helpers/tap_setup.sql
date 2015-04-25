\i test/helpers/psql.sql

CREATE SCHEMA tap;
SET search_path = tap;
\i test/helpers/pgtap-core.sql
\i test/helpers/pgtap-schema.sql

\pset format unaligned
\pset tuples_only true
\pset pager
