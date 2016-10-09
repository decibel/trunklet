\set ECHO none
\i test/helpers/setup.sql

SHOW lc_collate;
 SELECT DISTINCT quote_ident(n.nspname) || '.' || quote_ident(p.proname) COLLATE "C" AS pname
          FROM pg_catalog.pg_proc p
          JOIN pg_catalog.pg_namespace n ON p.pronamespace = n.oid
         WHERE nspname = '_trunklet_test'
            AND proname ~ '^test_'
        ORDER BY pname;
 SELECT DISTINCT quote_ident(n.nspname) || '.' || quote_ident(p.proname)  AS pname
          FROM pg_catalog.pg_proc p
          JOIN pg_catalog.pg_namespace n ON p.pronamespace = n.oid
         WHERE nspname = '_trunklet_test'
            AND proname ~ '^test_'
        ORDER BY pname;

/*
SET client_min_messages = debug;
SELECT no_plan();
SELECT * FROM _trunklet_test.test_process();
\du
*/
-- Needed for now due to bug in pgtap-core.sql
SET client_min_messages = WARNING;

SELECT * FROM runtests( '_trunklet_test'::name );
