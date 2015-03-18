/*
 * Author: Jim C. Nasby
 * Created at: 2015-01-11 17:47:56 -0600
 *
 */

SET client_min_messages = warning;

CREATE SCHEMA _trunklet;

CREATE SCHEMA _trunklet_functions;
GRANT USAGE, CREATE ON SCHEMA _trunklet_functions TO public;
COMMENT ON SCHEMA _trunklet_functions IS $$Schema that contains support functions for languages registered in trunklet. Not intended for general use.$$;

CREATE SCHEMA trunklet;
GRANT USAGE ON SCHEMA trunklet TO public;

CREATE FUNCTION _trunklet.exec(
  sql text
) RETURNS void LANGUAGE plpgsql AS $f$
BEGIN
  RAISE DEBUG 'Executing SQL %s', sql;
  EXECUTE sql;
END
$f$;

CREATE OR REPLACE FUNCTION _trunklet.language_name__sanity(
  language_name text
) RETURNS boolean LANGUAGE plpgsql AS $body$
DECLARE
  error CONSTANT text := CASE
    WHEN language_name IS NULL THEN 'be NULL'
    WHEN language_name = '' THEN 'be blank'
    -- (?n) means use newline sensitive mode
    WHEN language_name ~ '(?n)^\s' THEN 'begin with whitespace'
    WHEN language_name ~ '(?n)\s$' THEN 'end with whitespace'
  END;
BEGIN
  IF error IS NULL THEN
    RETURN true;
  END IF;

  RAISE EXCEPTION 'language_name must not %', error
    USING ERRCODE = 'invalid_parameter_value'
  ;
END
$body$;

CREATE TABLE _trunklet.language(
  language_id     serial    PRIMARY KEY NOT NULL
  , language_name varchar(100)  UNIQUE NOT NULL CHECK(_trunklet.language_name__sanity(language_name))
  -- I don't think we'll need these fields, but better safe than sorry
  , process_function_options text NOT NULL
  , process_function_body text NOT NULL
  , extract_parameters_options text NOT NULL
  , extract_parameters_body text NOT NULL
);


CREATE FUNCTION _trunklet.create_function(
  language_id _trunklet.language.language_id%TYPE
  , language_name text
  , return_type text
  , function_options text
  , function_body text
  , function_type text
) RETURNS void LANGUAGE plpgsql AS $body$
DECLARE
  -- text version of langueg_id that is 0 padded
  formatted_id CONSTANT text := to_char(
    language_id
    -- Get a string of 0's long enough to hold a max-sized int
    , repeat( '0', length( (2^31-1)::int::text ) )
  );

  func_name CONSTANT text := format( 'language_id_%s__%s', formatted_id, function_type );
  func_full_name CONSTANT text := format(
    -- Name template
    $name$_trunklet_functions.%1$s(
    template variant(trunklet_template)
    , parameters variant(trunklet_parameter)[]
  )
    $name$
    , func_name
  );

BEGIN
  PERFORM _trunklet.exec(
    /*
     * This is the SQL string we'll use to actually create the function.
     */
    format(

      -- Actual function creation template
      $temp$
CREATE FUNCTION %1$s RETURNS %2$I %3$s AS %4$L;
COMMENT ON FUNCTION %1$s IS $$%5$s function for trunklet language "$$ || %6$L || $$". Not intended for general use.$$;
$temp$

      -- Parameters for function template
      , funk_full_name
      , return_type
      , function_options
      , function_body
      , function_type
      , language_name
    )
  );

  /*
   * The language functions could be executed by any random user, so make
   * certain that they're not security definer.
   */
  IF ( SELECT prosecdef FROM pg_proc WHERE oid = func_full_name::regprocedure ) THEN
    RAISE EXCEPTION 'language functions may not be SECURITY DEFINER'
      USING DETAIL = format( 'language %s, %s function', language_name, function_type )
    ;
  END IF;
END
$body$;

CREATE OR REPLACE VIEW trunklet.template_language AS
  SELECT
      language_name
      , process_function_options
      , process_function_body
      , extract_parameters_options
      , extract_parameters_body
    FROM _trunklet.language
;

CREATE FUNCTION trunklet.template_language__add(
  language_name _trunklet.language.language_name%TYPE
  , process_function_options _trunklet.language.process_function_options%TYPE
  , process_function_body _trunklet.language.process_function_body%TYPE
  , extract_parameters_options _trunklet.language.extract_parameters_options%TYPE
  , extract_parameters_body _trunklet.language.extract_parameters_body%TYPE
) RETURNS void LANGUAGE plpgsql AS $body$
<<fn>>
DECLARE
  language_id _trunklet.language.language_id%TYPE;
BEGIN
  -- Do explicit sanity check for better error messages
  PERFORM _trunklet.language_name__sanity(language_name);

  INSERT INTO _trunklet.language(
        language_name
        , process_function_options
        , process_function_body
        , extract_parameters_options
        , extract_parameters_body
      )
    SELECT
      language_name
      , process_function_options
      , process_function_body
      , extract_parameters_options
      , extract_parameters_body
    RETURNING language.language_id
    INTO STRICT fn.language_id
  ;

  PERFORM _trunklet.create_function(
    language_id
    , language_name
    , 'text'
    , process_function_options
    , process_function_body
    , 'process'
  );

  PERFORM _trunklet.create_function(
    language_id
    , language_name
    , 'variant.variant(trunklet_parameter)'
    , extract_parameters_options
    , extract_parameters_body
    , 'extract parameters'
  );
END
$body$;
REVOKE ALL ON FUNCTION trunklet.template_language__add(
  language_name _trunklet.language.language_name%TYPE
  , process_function_options _trunklet.language.process_function_options%TYPE
  , process_function_body _trunklet.language.process_function_body%TYPE
  , extract_parameters_options _trunklet.language.extract_parameters_options%TYPE
  , extract_parameters_body _trunklet.language.extract_parameters_body%TYPE
) FROM public;

-- vi: expandtab sw=2 ts=2
