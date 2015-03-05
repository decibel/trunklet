\set ECHO none
BEGIN;
\i test/helpers/tap_setup.sql
\i sql/trunklet.sql
\i test/core/functions.sql

-- Needed for now due to bug in pgtap-core.sql
SET client_min_messages = WARNING;

SELECT * FROM runtests( '_trunklet_test'::name );
