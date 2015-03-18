-- No status messages
\set QUIET true

-- Verbose error messages
\set VERBOSITY verbose

-- Revert all changes on failure.
\set ON_ERROR_ROLLBACK 1
\set ON_ERROR_STOP true

CREATE SCHEMA tap;
SET search_path = tap;
\i test/helpers/pgtap-core.sql

\pset format unaligned
\pset tuples_only true
\pset pager
