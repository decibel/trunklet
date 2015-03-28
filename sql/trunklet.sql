/*
 * Author: Jim C. Nasby
 * Created at: 2015-01-11 17:47:56 -0600
 *
 */

SET client_min_messages = warning;

-- Set a safe search_path
SET search_path = pg_catalog;

CREATE ROLE trunklet__dependency;

-- Register our variants
SELECT variant.register( 'trunklet_template', '{}' );
SELECT variant.register( 'trunklet_parameter', '{}' );
SELECT variant.register( 'trunklet_return', '{}' );

CREATE SCHEMA _trunklet;
GRANT USAGE ON SCHEMA _trunklet TO trunklet__dependency;
COMMENT ON SCHEMA _trunklet IS $$Internal use functions for the trunklet extension.$$;

CREATE SCHEMA _trunklet_functions;
-- TODO: Create a trunklet__usage role and use it here instead of public
GRANT USAGE ON SCHEMA _trunklet_functions TO public; -- Languages currently created as role that calls trunklet.template_language__add()
COMMENT ON SCHEMA _trunklet_functions IS $$Schema that contains support functions for languages registered in trunklet. Not intended for general use.$$;

CREATE SCHEMA trunklet;
GRANT USAGE ON SCHEMA trunklet TO public;

-- See also pgtemp.exec_as in test/core/functions.sql
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
  , parameter_type regtype NOT NULL
  , template_type regtype NOT NULL
  -- I don't think we'll need these fields, but better safe than sorry
  , process_function_options text NOT NULL
  , process_function_body text NOT NULL
  , extract_parameters_options text NOT NULL
  , extract_parameters_body text NOT NULL
);
COMMENT ON COLUMN _trunklet.language.parameter_type IS $$Data type used to pass parameters to templates in this language.$$;
COMMENT ON COLUMN _trunklet.language.parameter_type IS $$Data type used by templates in this language.$$;
-- TODO: Add AFTER UPDATE trigger to re-validate the type of all stored templates for a language if template_type changes
CREATE OR REPLACE FUNCTION _trunklet.language__get(
  language_name _trunklet.language.language_name%TYPE
) RETURNS _trunklet.language STABLE LANGUAGE plpgsql AS $body$
DECLARE
  v_return _trunklet.language;
BEGIN
  SELECT * INTO STRICT v_return
    FROM _trunklet.language l
    WHERE l.language_name = language__get.language_name
  ;
  RETURN v_return;
EXCEPTION
  WHEN no_data_found THEN
    RAISE EXCEPTION 'language "%" not found', language_name
      USING ERRCODE = 'no_data_found'
    ;
END
$body$;
CREATE OR REPLACE FUNCTION _trunklet.language__get_id(
  language_name _trunklet.language.language_name%TYPE
) RETURNS _trunklet.language.language_id%TYPE STABLE LANGUAGE sql AS $body$
SELECT (_trunklet.language__get( $1 )).language_id
$body$;


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
      , parameter_type
      , template_type
      , process_function_options
      , process_function_body
      , extract_parameters_options
      , extract_parameters_body
    FROM _trunklet.language
;

CREATE OR REPLACE FUNCTION trunklet.template_language__add(
  language_name _trunklet.language.language_name%TYPE
  , parameter_type _trunklet.language.parameter_type%TYPE
  , template_type _trunklet.language.template_type%TYPE
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
        , parameter_type
        , template_type
        , process_function_options
        , process_function_body
        , extract_parameters_options
        , extract_parameters_body
      )
    SELECT
      language_name
      , parameter_type
      , template_type
      , process_function_options
      , process_function_body
      , extract_parameters_options
      , extract_parameters_body
    RETURNING language.language_id
    INTO STRICT fn.language_id
  ;

  RAISE DEBUG 'variant.variant(trunklet_template) allowed types: %'
    , array_to_string( array( SELECT * FROM variant.add_type( 'trunklet_template', template_type::text ) ), ', ' )
  ;
  RAISE DEBUG 'variant.variant(trunklet_parameter) allowed types: %'
    , array_to_string( array( SELECT * FROM variant.add_type( 'trunklet_parameter', parameter_type::text ) ), ', ' )
  ;
  RAISE DEBUG 'variant.variant(trunklet_return) allowed types: %'
    , array_to_string( array( SELECT * FROM variant.add_type( 'trunklet_return', parameter_type::text ) ), ', ' )
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
  , parameter_type _trunklet.language.parameter_type%TYPE
  , template_type _trunklet.language.template_type%TYPE
  , process_function_options _trunklet.language.process_function_options%TYPE
  , process_function_body _trunklet.language.process_function_body%TYPE
  , extract_parameters_options _trunklet.language.extract_parameters_options%TYPE
  , extract_parameters_body _trunklet.language.extract_parameters_body%TYPE
) FROM public;



/*
 * TEMPLATES
 */
CREATE TABLE _trunklet.template(
  template_id serial NOT NULL PRIMARY KEY
  , language_id int NOT NULL REFERENCES _trunklet.language
  , template_name text NOT NULL CHECK(_trunklet.name_sanity( 'template_name', template_name ))
  , template_version int NOT NULL
  , template variant.variant(trunklet_template) NOT NULL
  , CONSTRAINT template__u_template_name__template_version UNIQUE( template_name, template_version )
);
GRANT REFERENCES ON _trunklet.template TO trunklet__dependency;

CREATE OR REPLACE FUNCTION _trunklet.template__get(
  language_name _trunklet.language.language_name%TYPE
  , template_name _trunklet.template.template_name%TYPE
  , template_version _trunklet.template.template_version%TYPE DEFAULT 1
) RETURNS _trunklet.template LANGUAGE plpgsql AS $body$
DECLARE
  v_language_id CONSTANT _trunklet.language.language_id%TYPE := _trunklet.language__get_id( language_name );
  r _trunklet.template;
BEGIN
  SELECT * INTO STRICT r
    FROM _trunklet.template t
    WHERE t.language_id = v_language_id
      AND t.template_name = template__get.template_name
      AND t.template_version = template__get.template_version
  ;

  RETURN r;
EXCEPTION
  WHEN no_data_found THEN
    RAISE EXCEPTION 'template with language "%", template name "%" and version % not found'
        , language_name
        , template_name
        , template_version
      USING ERRCODE = 'no_data_found'
    ;
END
$body$;
REVOKE ALL ON FUNCTION _trunklet.template__get(
  language_name _trunklet.language.language_name%TYPE
  , template_name _trunklet.template.template_name%TYPE
  , template_version _trunklet.template.template_version%TYPE
) FROM public;

CREATE OR REPLACE FUNCTION trunklet.template__add(
  language_name _trunklet.language.language_name%TYPE
  , template_name _trunklet.template.template_name%TYPE
  , template_version _trunklet.template.template_version%TYPE 
  , template _trunklet.template.template%TYPE 
) RETURNS _trunklet.template.template_id%TYPE SECURITY DEFINER LANGUAGE sql AS $body$
INSERT INTO _trunklet.template(
      language_id
      , template_name
      , template_version
      , template
    )
  SELECT 
      _trunklet.language__get_id( $1 )
      , $2
      , $3
      , $4
  RETURNING template_id
;
$body$;
CREATE OR REPLACE FUNCTION trunklet.template__add(
  language_name _trunklet.language.language_name%TYPE
  , template_name _trunklet.template.template_name%TYPE
  , template _trunklet.template.template%TYPE 
) RETURNS _trunklet.template.template_id%TYPE LANGUAGE sql AS $body$
SELECT trunklet.template__add( $1, $2, 1, $3 )
$body$;

CREATE OR REPLACE FUNCTION trunklet.template__remove(
  template_id _trunklet.template.template_id%TYPE
) RETURNS void SECURITY DEFINER LANGUAGE sql AS $body$
DELETE FROM _trunklet.template WHERE template_id = $1
$body$;
CREATE OR REPLACE FUNCTION trunklet.template__remove(
  language_name _trunklet.language.language_name%TYPE
  , template_name _trunklet.template.template_name%TYPE
  , template_version _trunklet.template.template_version%TYPE DEFAULT 1
) RETURNS void SECURITY DEFINER LANGUAGE sql AS $body$
SELECT trunklet.template__remove( (_trunklet.template__get( $1, $2, $3 )).template_id )
$body$;

CREATE OR REPLACE FUNCTION trunklet.template__dependency__add(
  table_name text
  , field_name name
) RETURNS void LANGUAGE plpgsql AS $body$
DECLARE
  -- Do this to sanitize input
  o_table CONSTANT regclass := table_name;
BEGIN
  PERFORM _trunklet.exec( format( 'ALTER TABLE %s ADD FOREIGN KEY( %I ) REFERENCES _trunklet.template', table_name, field_name ) );
END
$body$;
CREATE OR REPLACE FUNCTION _trunklet.attnum__get(
  table_name regclass
  , field_name name
) RETURNS pg_attribute.attnum%TYPE LANGUAGE plpgsql AS $body$
DECLARE
  v_attnum pg_attribute.attnum%TYPE;
BEGIN
  SELECT attnum INTO STRICT v_attnum
    FROM pg_attribute WHERE attrelid = table_name AND attname = field_name
  ;
  
  RETURN v_attnum;
EXCEPTION
  WHEN no_data_found THEN
    RAISE EXCEPTION 'column "%" does not exist', field_name
      USING ERRCODE = 'undefined_column'
    ;
END
$body$;

CREATE OR REPLACE FUNCTION trunklet.template__dependency__remove(
  table_name text
  , field_name name
) RETURNS void LANGUAGE plpgsql AS $body$
DECLARE
  -- Do this to sanitize input
  o_table CONSTANT regclass := table_name;
  o_template CONSTANT regclass := '_trunklet.template';
  v_constraint_name name;

  -- Set these here so we don't accidentally re-trap 
  v_conkey smallint[] := array[ _trunklet.attnum__get( o_table, field_name ) ];
  v_confkey smallint[] := array[ _trunklet.attnum__get( o_template, 'template_id' ) ];
BEGIN
  BEGIN
    SELECT conname INTO STRICT v_constraint_name
      FROM pg_constraint
      WHERE contype = 'f'
        AND conrelid = o_table
        AND confrelid = o_template
        AND conkey = array[ _trunklet.attnum__get( o_table, field_name ) ]
        AND confkey = array[ _trunklet.attnum__get( o_template, 'template_id' ) ]
    ;
  EXCEPTION
    WHEN no_data_found THEN
      RAISE EXCEPTION 'no template dependency on %.%', table_name, field_name
        USING ERRCODE = 'undefined_object'
      ;
  END;

  PERFORM _trunklet.exec( format( 'ALTER TABLE %s DROP CONSTRAINT %I', table_name, v_constraint_name ) );
END
$body$;

-- vi: expandtab sw=2 ts=2
