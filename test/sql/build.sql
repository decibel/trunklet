\set ECHO none
--CREATE EXTENSION IF NOT EXISTS variant;

\i test/helpers/psql.sql

BEGIN;
\i sql/trunklet.sql
ROLLBACK;
