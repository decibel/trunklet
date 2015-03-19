/*
 * Author: Jim C. Nasby
 * Created at: 2015-01-11 17:47:56 -0600
 *
 */

SET client_min_messages = warning;

-- Register our variants
SELECT variant.register( 'trunklet_template', '{}' );
SELECT variant.register( 'trunklet_parameter', '{}' );
SELECT variant.register( 'trunklet_return', '{}' );

CREATE SCHEMA _trunklet;

CREATE SCHEMA _trunklet_functions;
-- TODO: Create a trunklet__usage role and us it here instead of public
GRANT USAGE ON SCHEMA _trunklet_functions TO public; -- Languages currently created as extension owner
COMMENT ON SCHEMA _trunklet_functions IS $$Schema that contains support functions for languages registered in trunklet. Not intended for general use.$$;

CREATE SCHEMA trunklet;
GRANT USAGE ON SCHEMA trunklet TO public;

CREATE OR REPLACE FUNCTION _trunklet.exec(
  sql text
) RETURNS void LANGUAGE plpgsql AS $f$
BEGIN
  RAISE DEBUG 'Executing SQL %s', sql;
  EXECUTE sql;
END
$f$;

CREATE OR REPLACE FUNCTION _trunklet.name_sanity(
  field_name text
  , value text
) RETURNS boolean LANGUAGE plpgsql AS $body$
DECLARE
  error CONSTANT text := CASE
    WHEN value IS NULL THEN 'be NULL'
    WHEN value = '' THEN 'be blank'
    -- (?n) means use newline sensitive mode
    WHEN value ~ '(?n)^\s' THEN 'begin with whitespace'
    WHEN value ~ '(?n)\s$' THEN 'end with whitespace'
  END;
BEGIN
  IF error IS NULL THEN
    RETURN true;
  END IF;

  RAISE EXCEPTION '% must not %', field_name, error
    USING ERRCODE = 'invalid_parameter_value'
  ;
END
$body$;

CREATE TABLE _trunklet.language(
  language_id     serial    PRIMARY KEY NOT NULL
  , language_name varchar(100)  UNIQUE NOT NULL CHECK(_trunklet.name_sanity( 'language_name', language_name ))
  -- I don't think we'll need these fields, but better safe than sorry
  , process_function_options text NOT NULL
  , process_function_body text NOT NULL
  , extract_parameters_options text NOT NULL
  , extract_parameters_body text NOT NULL
);
CREATE OR REPLACE FUNCTION _trunklet.language__get_id(
  language_name _trunklet.language.language_name%TYPE
) RETURNS _trunklet.language.language_id%TYPE LANGUAGE plpgsql AS $body$
DECLARE
  v_id _trunklet.language.language_id%TYPE;
BEGIN
  SELECT INTO STRICT v_id
      language_id
    FROM _trunklet.language l
    WHERE l.language_name = language__get_id.language_name
  ;
  RETURN v_id;
EXCEPTION
  WHEN no_data_found THEN
    RAISE EXCEPTION 'language "%" not found', language_name
      USING ERRCODE = 'no_data_found'
    ;
END
$body$;
REVOKE ALL ON FUNCTION _trunklet.language__get_id(
  language_name _trunklet.language.language_name%TYPE
) FROM public;


CREATE OR REPLACE FUNCTION _trunklet.create_language_function(
  language_id _trunklet.language.language_id%TYPE
  , language_name text
  , return_type text
  , function_options text
  , function_body text
  , function_type text
) RETURNS void LANGUAGE plpgsql AS $body$
DECLARE
  -- text version of language_id that is 0 padded. btrim shouldn't be necessary but is.
  formatted_id CONSTANT text := btrim( to_char(
    language_id
    -- Get a string of 0's long enough to hold a max-sized int
    , repeat( '0', length( (2^31-1)::int::text ) )
  ) );

  func_name CONSTANT text := format( 'language_id_%s__%s', formatted_id, function_type );
  func_full_name CONSTANT text := format(
    -- Name template
    $name$_trunklet_functions.%1$s(
    template variant.variant(trunklet_template)
    , parameters variant.variant(trunklet_parameter)[]
  )
    $name$
    , func_name
  );

BEGIN
  RAISE DEBUG 'func_full_name = %', func_full_name;
  PERFORM _trunklet.exec(
    /*
     * This is the SQL string we'll use to actually create the function.
     */
    format(

      -- Actual function creation template
      $temp$
CREATE OR REPLACE FUNCTION %1$s RETURNS %2$s %3$s AS %4$L;
COMMENT ON FUNCTION %1$s IS $$%5$s function for trunklet language "%6$s". Not intended for general use.$$;
$temp$

      -- Parameters for function template
      , func_full_name
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
   *
   * Note that regprocedure pukes on variant.variant as a type name. That means
   * we can't easily get our exact procedure, though in this case proname alone
   * should be unique. We ultimately just need to ensure there's no SECDEF
   * procedures at all...
   */
  IF EXISTS( SELECT 1 FROM pg_proc WHERE proname = func_name AND prosecdef ) THEN
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

CREATE OR REPLACE FUNCTION trunklet.template_language__add(
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
  PERFORM _trunklet.name_sanity( 'language_name', language_name );

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

  PERFORM _trunklet.create_language_function(
    language_id
    , language_name
    , 'text'
    , process_function_options
    , process_function_body
    , 'process'
  );

  PERFORM _trunklet.create_language_function(
    language_id
    , language_name
    , 'variant.variant(trunklet_parameter)'
    , extract_parameters_options
    , extract_parameters_body
    , 'extract_parameters'
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



/*
 * TEMPLATES
 */
CREATE TABLE _trunklet.template(
  language_id int NOT NULL REFERENCES _trunklet.language
  , template_name text NOT NULL CHECK(_trunklet.name_sanity( 'template_name', template_name ))
  , template_version int NOT NULL
  , template variant.variant(trunklet_template)[] NOT NULL
  , CONSTRAINT template__u_template_name__template_version UNIQUE( template_name, template_version )
);

/*
CREATE OR REPLACE FUNCTION trunklet.template__store(
  language_name _trunklet.language.language_name%TYPE
  , template_name text
  , template_version int
  , template variant(trunklet_template)[]
) RETURNS _trunklet.template.template_id%TYPE LANGUAGE sql AS $body$
INSERT INTO _trunklet.template(
      language_id
      , template_name
      , template_version
      , template
    )
  SELECT 
      _trunklet.language__get_id( language_name )
      , template_name
      , template_version
      , template
  RETURNING template_id
;
$body$;
*/

-- vi: expandtab sw=2 ts=2
