\set ECHO none
\i test/helpers/setup.sql

-- Needed for now due to bug in pgtap-core.sql
SET client_min_messages = WARNING;
--SET client_min_messages = debug;

SELECT * FROM runtests( '_trunklet_test'::name );
