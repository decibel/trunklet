/*
 * Author: Jim C. Nasby
 * Created at: 2015-01-11 17:47:56 -0600
 *
 */

SET client_min_messages = warning;

CREATE SCHEMA _trunklet;
CREATE SCHEMA trunklet;
GRANT USAGE ON SCHEMA trunklet TO public;

CREATE OR REPLACE FUNCTION _trunklet.language_sanity(
  language text
) RETURNS void LANGUAGE plpgsql AS $body$
DECLARE
  error CONSTANT text := CASE
    WHEN language IS NULL THEN 'be NULL'
    WHEN language = '' THEN 'be blank'
    -- (?n) means use newline sensitive mode
    WHEN language ~ '(?n)^\s' THEN 'begin with whitespace'
    WHEN language ~ '(?n)\s$' THEN 'end with whitespace'
  END;
BEGIN
  IF error IS NULL THEN
    RETURN;
  END IF;

  RAISE EXCEPTION 'language must not %', error
    USING ERRCODE = 'invalid_parameter_value'
  ;
END
$body$;

-- vi: expandtab sw=2 ts=2
