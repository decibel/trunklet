\set ECHO none
\i test/pgxntool/setup.sql

SELECT plan(
    0

    +1 -- verify search_path
);

CREATE TEMP TABLE before AS
  SELECT current_setting('search_path')
;

SHOW search_path;

CREATE EXTENSION trunklet;-- CASCADE;

CREATE TEMP TABLE after AS
  SELECT current_setting('search_path')
;

-- Forcibly reset it so we know tap will work
SET search_path=public,tap;

SELECT is(
  (SELECT current_setting FROM after)
  , (SELECT current_setting FROM before)
  , 'verify search_path has not changed'
);

\i test/pgxntool/finish.sql

-- vi: expandtab ts=2 sw=2
