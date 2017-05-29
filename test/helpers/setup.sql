BEGIN;
\i test/helpers/tap_setup.sql
--CREATE EXTENSION IF NOT EXISTS variant;

-- No IF NOT EXISTS because we'll be confused if we're not loading the new stuff
--\i sql/trunklet.sql
CREATE EXTENSION trunklet;

/*
CREATE EXTENSION trunklet VERSION '0.2.1';
ALTER EXTENSION trunklet UPDATE;
 */

\i test/core/functions.sql
