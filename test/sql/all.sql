\set ECHO none
\i test/helpers/setup.sql

/*
SET client_min_messages = debug;
SELECT no_plan();
SELECT * FROM _trunklet_test.test_process();
\du
*/
-- Needed for now due to bug in pgtap-core.sql
SET client_min_messages = WARNING;

SHOW lc_collate;
SELECT * FROM runtests( '_trunklet_test'::name );
