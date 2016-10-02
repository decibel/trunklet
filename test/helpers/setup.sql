BEGIN;
\i test/helpers/tap_setup.sql
--CREATE EXTENSION IF NOT EXISTS variant;

-- No IF NOT EXISTS because we'll be confused if we're not loading the new stuff
--\i sql/trunklet.sql
CREATE EXTENSION trunklet;

\i test/core/functions.sql
