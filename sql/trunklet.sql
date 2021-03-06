/*
 * Author: Jim C. Nasby
 * Created at: 2015-01-11 17:47:56 -0600
 *
 */

/*
 * Using temp objects will result in the extension being dropped after session
 * end. Create a real schema and then explicitly drop it instead.
 */
CREATE SCHEMA __trunklet;

CREATE TABLE __trunklet.old_settings AS
  SELECT name, setting
    FROM pg_catalog.pg_settings
    WHERE name IN ('client_min_messages')-- This doesn't actually work as expected :( , 'search_path')
;
SET client_min_messages = warning;
-- PG apparently truncates the path to a single element, so our reset doesn't work :( SET LOCAL search_path = pg_catalog;

DO $do$
BEGIN
  CREATE ROLE trunklet__dependency;
EXCEPTION
	WHEN duplicate_object THEN
		-- TODO: Ensure options are what we expect
		NULL;
END
$do$;

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
CREATE OR REPLACE FUNCTION _trunklet.language__get_loose(
  language_id _trunklet.language.language_id%TYPE
) RETURNS _trunklet.language STABLE LANGUAGE sql AS $body$
  SELECT * FROM _trunklet.language l WHERE l.language_id = language__get_loose.language_id
$body$;
CREATE OR REPLACE FUNCTION _trunklet.language__get(
  language_id _trunklet.language.language_id%TYPE
) RETURNS _trunklet.language STABLE LANGUAGE plpgsql AS $body$
DECLARE
  ret _trunklet.language;
BEGIN
  SELECT INTO STRICT ret * FROM _trunklet.language__get_loose(language_id);

  IF ret IS NULL THEN
    RAISE EXCEPTION 'language id % not found', language_id
      USING ERRCODE = 'no_data_found'
    ;
  END IF;

  RETURN ret;
END
$body$;
CREATE OR REPLACE FUNCTION _trunklet.language__get(
  language_name _trunklet.language.language_name%TYPE
) RETURNS _trunklet.language STABLE LANGUAGE plpgsql AS $body$
DECLARE
  v_return _trunklet.language;
BEGIN
  RAISE DEBUG 'language__get(%)', language_name;
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


CREAtE OR REPLACE FUNCTION _trunklet.verify_type(
  language_name _trunklet.language.language_name%TYPE
  , allowed_type regtype
  , supplied_type regtype
  , which_type text
) RETURNS void LANGUAGE plpgsql AS $body$
DECLARE
  sql text;
BEGIN
  /* Old variant code
  IF supplied_type <> allowed_type THEN
    RAISE EXCEPTION '%s for language "%" must by of type "%"', which_type, language_name, allowed_type
      USING ERRCODE = 'data_exception'
    ;
  END IF;
  */

  /*
   * This isn't strictly the same as what we previously did with variant. In
   * this version, we just verify that you can cast from one type to the next.
   * I think that's probably good enough.
   */
  sql := format(
    $$SELECT CAST( CAST( NULL AS %s ) AS %s )$$
    , supplied_type
    , allowed_type
  );
  RAISE DEBUG 'sql = %', sql;
  EXECUTE sql;
END
$body$;

CREATE OR REPLACE FUNCTION _trunklet.function_name(
  language_id _trunklet.language.language_id%TYPE
  , function_type text
) RETURNS text IMMUTABLE LANGUAGE sql AS $body$
SELECT format(
  'language_id_%s__%s'
  -- text version of language_id that is 0 padded. btrim shouldn't be necessary but is.
  , btrim( to_char(
      language_id
      -- Get a string of 0's long enough to hold a max-sized int
      , repeat( '0', length( (2^31-1)::int::text ) )
    ) )
  , function_type
);
$body$;

CREATE OR REPLACE FUNCTION _trunklet._language_function__drop(
  language_id _trunklet.language.language_id%TYPE
  , function_type text
  , function_arguments text
  , ignore_missing boolean DEFAULT NULL
) RETURNS void LANGUAGE plpgsql AS $body$
DECLARE
  func_name CONSTANT text := _trunklet.function_name( language_id, function_type );
  func_full_name CONSTANT text := format(
    -- Name template
    $name$_trunklet_functions.%1$s(%s)
    $name$
    , func_name
    , function_arguments
  );
  c_sql CONSTANT text := format(
    $temp$DROP FUNCTION %1$s;$temp$
    , func_full_name
  );
BEGIN
  IF ignore_missing THEN
    BEGIN
      PERFORM _trunklet.exec(c_sql);
    EXCEPTION WHEN undefined_function THEN
      NULL;
    END;
  ELSE
    PERFORM _trunklet.exec(c_sql);
  END IF;
END
$body$;
CREATE OR REPLACE FUNCTION _trunklet._language_function__create(
  language_id _trunklet.language.language_id%TYPE
  , language_name _trunklet.language.language_name%TYPE
  , function_type text
  , return_type text
  , function_arguments text
  , function_options text
  , function_body text
) RETURNS void LANGUAGE plpgsql AS $body$
DECLARE
  func_name CONSTANT text := _trunklet.function_name( language_id, function_type );
  func_full_name CONSTANT text := format(
    -- Name template
    $name$_trunklet_functions.%1$s(%s)
    $name$
    , func_name
    , function_arguments
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

  PERFORM _trunklet._language_function__create(
    language_id
    , language_name
    , 'process'
    , 'text'
    , format(
      $args$
    template %s
    , parameters %s
$args$
      , template_type
      , parameter_type
    )
    , process_function_options
    , process_function_body
  );

  PERFORM _trunklet._language_function__create(
    language_id
    , language_name
    , 'extract_parameters'
    , parameter_type::text
    , format(
      $args$
    parameters %s
    , extract_list text[]
$args$
      , parameter_type
    )
    , extract_parameters_options
    , extract_parameters_body
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

CREATE OR REPLACE FUNCTION trunklet.template_language__remove(
  language_id _trunklet.language.language_id%TYPE
  , cascade boolean DEFAULT NULL
  , ignore_missing_functions boolean DEFAULT NULL
) RETURNS void LANGUAGE plpgsql AS $body$
DECLARE
  r record;
BEGIN
  r := _trunklet.language__get(language_id); -- Throws error if language doesn't exist
  RAISE DEBUG 'Removing language "%" (language_id %)', r.language_name, language_id;

  DECLARE
    v_schema name;
    v_table name;
    v_constraint name;
    v_detail text;
  BEGIN
    IF cascade THEN
      DELETE FROM _trunklet.template WHERE template.language_id = template_language__remove.language_id;
    END IF;

    DELETE FROM _trunklet.language WHERE language.language_id = template_language__remove.language_id;
  EXCEPTION WHEN foreign_key_violation THEN
    GET STACKED DIAGNOSTICS
      v_schema := SCHEMA_NAME
      , v_table := TABLE_NAME
      , v_constraint := CONSTRAINT_NAME
      , v_detail := PG_EXCEPTION_DETAIL
    ;
    RAISE DEBUG E'caught exception foreign_key_violation: schema "%", table "%", constraint "%"\n  detail: %', v_schema, v_table, v_constraint, v_detail;

    IF (v_schema, v_table, v_constraint) = ('_trunklet', 'template', 'template_language_id_fkey' ) THEN
      RAISE 'cannot drop language "%" because stored templates depend on it', r.language_name
        USING HINT = 'Set cascade to TRUE to forcibly remove these templates.'
          , ERRCODE = 'foreign_key_violation'
      ;
    ELSEIF cascade THEN
      RAISE 'drop of language "%" violates foreign key constraint "%" on table "%"'
          , r.language_name
          , v_constraint
          , format( '%I.%I', v_schema, v_table )::regclass -- Cast schema.table to regclass to get better formatting
        USING DETAIL = v_detail
          , ERRCODE = 'foreign_key_violation'
        /*
         * We intentionally don't supply a hint here. The only odd info we
         * could provide would be to suggest calling
         * template__dependency__remove(), but a user that has permissions for
         * that should already know well enough what's going on here.
         */
      ;
    ELSE
      RAISE; -- No clue what happened, so just punt.
    END IF;
  END;

  PERFORM _trunklet._language_function__drop(
    language_id
    , 'process'
    , ignore_missing => ignore_missing_functions
    , function_arguments => format(
      $args$
    template %s
    , parameters %s
$args$
      , r.template_type
      , r.parameter_type
    )
  );

  PERFORM _trunklet._language_function__drop(
    language_id
    , 'extract_parameters'
    , ignore_missing => ignore_missing_functions
    , function_arguments => format(
      $args$
    parameters %s
    , extract_list text[]
$args$
      , r.parameter_type
    )
  );
END
$body$;
REVOKE ALL ON FUNCTION trunklet.template_language__remove(
  language_id _trunklet.language.language_id%TYPE
  , cascade boolean
  , boolean
) FROM public;
CREATE OR REPLACE FUNCTION trunklet.template_language__remove(
  language_name _trunklet.language.language_name%TYPE
  , cascade boolean DEFAULT NULL
  , ignore_missing_functions boolean DEFAULT NULL
) RETURNS void LANGUAGE sql AS $body$
SELECT trunklet.template_language__remove(
  _trunklet.language__get_id(language_name) -- Will throw error if language doesn't exist
  , cascade
  , ignore_missing_functions
)
$body$;
REVOKE ALL ON FUNCTION trunklet.template_language__remove(
  language_name _trunklet.language.language_name%TYPE
  , cascade boolean
  , boolean
) FROM public;



/*
 * TEMPLATES
 */
CREATE TABLE _trunklet.template(
  template_id serial NOT NULL PRIMARY KEY
  , language_id int NOT NULL REFERENCES _trunklet.language
  , template_name text NOT NULL CHECK(_trunklet.name_sanity( 'template_name', template_name ))
  , template_version int NOT NULL
  , template text NOT NULL -- TODO: Trigger to ensure template will cast to intended type
  , CONSTRAINT template__u_template_name__template_version UNIQUE( template_name, template_version )
);
GRANT REFERENCES ON _trunklet.template TO trunklet__dependency;

CREATE OR REPLACE FUNCTION _trunklet.template__get(
  template_id _trunklet.template.template_id%TYPE
  , loose boolean DEFAULT false
) RETURNS _trunklet.template LANGUAGE plpgsql AS $body$
DECLARE
  r _trunklet.template;
BEGIN
  SELECT * INTO STRICT r
    FROM _trunklet.template t
    WHERE t.template_id = template__get.template_id
  ;

  RETURN r;
EXCEPTION
  WHEN no_data_found THEN
    IF loose THEN
      RETURN NULL;
    ELSE
      RAISE EXCEPTION 'template not found'
        USING ERRCODE = 'no_data_found'
          , DETAIL = format( 'template id %s', template_id )
      ;
    END IF;
END
$body$;
REVOKE ALL ON FUNCTION _trunklet.template__get(
  template_id _trunklet.template.template_id%TYPE
  , loose boolean
) FROM public;
CREATE OR REPLACE FUNCTION _trunklet.template__get(
  template_name _trunklet.template.template_name%TYPE
  , template_version _trunklet.template.template_version%TYPE DEFAULT 1
  , loose boolean DEFAULT false
) RETURNS _trunklet.template LANGUAGE plpgsql AS $body$
DECLARE
  r _trunklet.template;
BEGIN
  SELECT * INTO STRICT r
    FROM _trunklet.template t
    WHERE t.template_name = template__get.template_name
      AND t.template_version = template__get.template_version
  ;

  RETURN r;
EXCEPTION
  WHEN no_data_found THEN
    IF loose THEN
      RETURN NULL;
    ELSE
      RAISE EXCEPTION 'template name "%" at version % not found'
          , template_name
          , template_version
        USING ERRCODE = 'no_data_found'
      ;
    END IF;
END
$body$;
REVOKE ALL ON FUNCTION _trunklet.template__get(
  template_name _trunklet.template.template_name%TYPE
  , template_version _trunklet.template.template_version%TYPE
  , loose boolean
) FROM public;

CREATE OR REPLACE FUNCTION trunklet.template__add(
  language_name _trunklet.language.language_name%TYPE
  , template_name _trunklet.template.template_name%TYPE
  , template_version _trunklet.template.template_version%TYPE 
  , template _trunklet.template.template%TYPE 
) RETURNS _trunklet.template.template_id%TYPE

-- !!!!!!!
SECURITY DEFINER SET search_path=pg_catalog
-- !!!!!!

LANGUAGE sql AS $body$
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
) RETURNS void

-- !!!!!!!
SECURITY DEFINER SET search_path=pg_catalog
-- !!!!!!

LANGUAGE sql AS $body$
DELETE FROM _trunklet.template WHERE template_id = $1
$body$;
CREATE OR REPLACE FUNCTION trunklet.template__remove(
  template_name _trunklet.template.template_name%TYPE
  , template_version _trunklet.template.template_version%TYPE DEFAULT 1
) RETURNS void

-- !!!!!!!
SECURITY DEFINER SET search_path=pg_catalog
-- !!!!!!

LANGUAGE sql AS $body$
SELECT trunklet.template__remove( (_trunklet.template__get( template_name, template_version )).template_id )
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

CREATE OR REPLACE FUNCTION trunklet.process_language(
  language_name _trunklet.language.language_name%TYPE
  , template text
  , parameters anyelement
) RETURNS text LANGUAGE plpgsql

-- !!!!!!!
SECURITY DEFINER SET search_path = pg_catalog
-- !!!!!!!

AS $body$
DECLARE
/*
 * !!!!! SECURITY DEFINER !!!!!
 */

  r_language _trunklet.language;
  sql text;
  v_return text;
BEGIN
  -- Can't do this during DECLARE (0A000: default value for row or record variable is not supported)
  r_language := _trunklet.language__get( language_name );

/*
 * !!!!! SECURITY DEFINER !!!!!
 */
  PERFORM _trunklet.verify_type( language_name, r_language.template_type, pg_catalog.pg_typeof(template), 'template' );
  PERFORM _trunklet.verify_type( language_name, r_language.parameter_type, pg_catalog.pg_typeof(parameters), 'parameter' );

  sql := format(
    'SELECT _trunklet_functions.%s( CAST($1 AS %s), CAST($2 AS %s) )'
    , _trunklet.function_name( r_language.language_id, 'process' )
    , r_language.template_type
    , r_language.parameter_type
  );
  RAISE DEBUG E'execute %\nUSING %, %', sql, template, parameters;
  EXECUTE sql INTO STRICT v_return USING template, parameters;
  RAISE DEBUG '% returned %', sql, v_return;

  RETURN v_return;
END
$body$;

CREATE OR REPLACE FUNCTION trunklet.process(
  template_id _trunklet.template.template_id%TYPE
  , parameters anyelement
) RETURNS text LANGUAGE SQL
-- !!!
SECURITY DEFINER SET search_path = pg_catalog
-- !!!
AS $body$
SELECT trunklet.process_language(
      -- language_id comes from template__get() below
      (_trunklet.language__get(language_id)).language_name
      , template
      , parameters
    )
  FROM _trunklet.template__get( template_id )
$body$;
CREATE OR REPLACE FUNCTION trunklet.process(
  template_name _trunklet.template.template_name%TYPE
  , template_version _trunklet.template.template_version%TYPE
  , parameters anyelement
) RETURNS text LANGUAGE SQL
-- !!!
SECURITY DEFINER SET search_path = pg_catalog
-- !!!
AS $body$
SELECT trunklet.process_language(
      -- language_id comes from template__get() below
      (_trunklet.language__get(language_id)).language_name
      , template
      , parameters
    )
  FROM _trunklet.template__get( template_name, template_version )
$body$;
CREATE OR REPLACE FUNCTION trunklet.process(
  template_name _trunklet.template.template_name%TYPE
  , parameters anyelement
) RETURNS text LANGUAGE SQL AS $body$
SELECT trunklet.process( template_name, 1, parameters )
$body$;


/*
 * trunklet.execute_into()
 */
CREATE OR REPLACE FUNCTION trunklet.execute_into__language(
  language_name _trunklet.language.language_name%TYPE
  , template text
  , parameters anyelement
) RETURNS anyelement LANGUAGE plpgsql AS $body$
DECLARE
  sql CONSTANT text := trunklet.process_language(language_name, template, parameters);

  r record;
BEGIN
  -- Define the structure of r
  EXECUTE format('SELECT NULL::%s AS out', pg_typeof(parameters)) INTO STRICT r;

  RAISE DEBUG E'execute %', sql;
  EXECUTE sql INTO STRICT r.out;
  RAISE DEBUG '% returned %', sql, r.out;

  RETURN r.out;
END
$body$;
CREATE OR REPLACE FUNCTION trunklet.execute_into(
  template_id _trunklet.template.template_id%TYPE
  , parameters anyelement
) RETURNS anyelement LANGUAGE plpgsql AS $body$
DECLARE
  sql CONSTANT text := trunklet.process(template_id, parameters);

  r record;
BEGIN
  -- Define the structure of r
  EXECUTE format('SELECT NULL::%s AS out', pg_typeof(parameters)) INTO STRICT r;

  RAISE DEBUG E'execute %', sql;
  EXECUTE sql INTO STRICT r.out;
  RAISE DEBUG '% returned %', sql, r.out;

  RETURN r.out;
END
$body$;
CREATE OR REPLACE FUNCTION trunklet.execute_into(
  template_name _trunklet.template.template_name%TYPE
  , template_version _trunklet.template.template_version%TYPE
  , parameters anyelement
) RETURNS anyelement LANGUAGE plpgsql AS $body$
DECLARE
  sql CONSTANT text := trunklet.process(template_name, template_version, parameters);

  r record;
BEGIN
  -- Define the structure of r
  EXECUTE format('SELECT NULL::%s AS out', pg_typeof(parameters)) INTO STRICT r;

  RAISE DEBUG E'execute %', sql;
  EXECUTE sql INTO STRICT r.out;
  RAISE DEBUG '% returned %', sql, r.out;

  RETURN r.out;
END
$body$;
CREATE OR REPLACE FUNCTION trunklet.execute_into(
  template_name _trunklet.template.template_name%TYPE
  , parameters anyelement
) RETURNS anyelement LANGUAGE SQL AS $body$
SELECT trunklet.execute_into( template_name, 1, parameters )
$body$;





/*
 * trunklet.execute_text()
 */
CREATE OR REPLACE FUNCTION trunklet.execute_text__language(
  language_name _trunklet.language.language_name%TYPE
  , template text
  , parameters anyelement
) RETURNS text LANGUAGE plpgsql AS $body$
DECLARE
  sql CONSTANT text := trunklet.process_language(language_name, template, parameters);

  out text;
BEGIN
  RAISE DEBUG E'execute %', sql;
  EXECUTE sql INTO STRICT out;
  RAISE DEBUG '% returned %', sql, out;

  RETURN out;
END
$body$;
CREATE OR REPLACE FUNCTION trunklet.execute_text(
  template_id _trunklet.template.template_id%TYPE
  , parameters anyelement
) RETURNS anyelement LANGUAGE plpgsql AS $body$
DECLARE
  sql CONSTANT text := trunklet.process(template_id, parameters);

  out text;
BEGIN
  RAISE DEBUG E'execute %', sql;
  EXECUTE sql INTO STRICT out;
  RAISE DEBUG '% returned %', sql, out;

  RETURN out;
END
$body$;
CREATE OR REPLACE FUNCTION trunklet.execute_text(
  template_name _trunklet.template.template_name%TYPE
  , template_version _trunklet.template.template_version%TYPE
  , parameters anyelement
) RETURNS anyelement LANGUAGE plpgsql AS $body$
DECLARE
  sql CONSTANT text := trunklet.process(template_name, template_version, parameters);

  out text;
BEGIN
  RAISE DEBUG E'execute %', sql;
  EXECUTE sql INTO STRICT out;
  RAISE DEBUG '% returned %', sql, out;

  RETURN out;
END
$body$;
CREATE OR REPLACE FUNCTION trunklet.execute_text(
  template_name _trunklet.template.template_name%TYPE
  , parameters anyelement
) RETURNS anyelement LANGUAGE SQL AS $body$
SELECT trunklet.execute_text( template_name, 1, parameters )
$body$;




/*
 * trunklet.extract_parameters()
 */
CREATE OR REPLACE FUNCTION trunklet.extract_parameters(
  language_name _trunklet.language.language_name%TYPE
  , parameters anyelement
  , extract_list text[]
) RETURNS anyelement LANGUAGE plpgsql

-- !!!!!!!
SECURITY DEFINER SET search_path = pg_catalog
-- !!!!!!!

AS $body$
DECLARE
  r_language _trunklet.language;

  sql text;
  r record;
BEGIN
  -- Can't do this during DECLARE (0A000: default value for row or record variable is not supported)
  r_language := _trunklet.language__get( language_name );

  PERFORM _trunklet.verify_type( language_name, r_language.parameter_type, pg_catalog.pg_typeof(parameters), 'parameter' );

  sql := format(
    'SELECT _trunklet_functions.%s( CAST($1 AS %s), $2 )::%s AS out'
    , _trunklet.function_name( r_language.language_id, 'extract_parameters' )
    , r_language.parameter_type
    , pg_typeof(parameters)
  );
  RAISE DEBUG 'EXECUTE % USING %, %'
    , sql
    , parameters, extract_list
  ;
  EXECUTE sql
    INTO STRICT r
    USING parameters, extract_list
  ;

  RETURN r.out;
END
$body$;
/*
CREATE OR REPLACE FUNCTION trunklet.extract_parameters(
  language_name _trunklet.language.language_name%TYPE
  , parameters anyarray
  , extract_list text[]
) RETURNS anyarray LANGUAGE plpgsql AS $body$
DECLARE
  r record;
BEGIN
  EXECUTE format(
      $$SELECT trunklet.extract_parameters($1, $2, $3)::%s AS out$$
      , pg_typeof(parameters)
    )
    INTO r 
    USING language_name, parameters::text, extract_list
  ;
  RETURN r.out;
END
$body$;
*/


SELECT _trunklet.exec(
    format(
      'SET %I = %L'
      , name
      , setting
    )
  )
  FROM __trunklet.old_settings
;
DROP TABLE __trunklet.old_settings;
DROP SCHEMA __trunklet;

-- vi: expandtab sw=2 ts=2
