/*
 * Using temp objects will result in the extension being dropped after session
 * end. Create a real schema and then explicitly drop it instead.
 */
CREATE SCHEMA __trunklet;

CREATE TABLE __trunklet.old_settings AS
  SELECT name, setting
    FROM pg_catalog.pg_settings
    WHERE name IN ('client_min_messages', 'search_path')
;
SET client_min_messages = warning;
SET search_path = pg_catalog;

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


CREATE OR REPLACE FUNCTION _trunklet._language_function__drop(
  language_id _trunklet.language.language_id%TYPE
  , function_type text
  , function_arguments text
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
  PERFORM _trunklet.exec(
    format(
      $temp$DROP FUNCTION %1$s;$temp$
      , func_full_name
    )
  );
END
$body$;

DROP FUNCTION _trunklet.create_language_function(
  language_id _trunklet.language.language_id%TYPE
  , language_name _trunklet.language.language_name%TYPE
  , return_type text
  , function_arguments text
  , function_options text
  , function_body text
  , function_type text
);

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
    , format(
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
    , format(
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
) FROM public;
CREATE OR REPLACE FUNCTION trunklet.template_language__remove(
  language_name _trunklet.language.language_name%TYPE
  , cascade boolean DEFAULT NULL
) RETURNS void LANGUAGE sql AS $body$
SELECT trunklet.template_language__remove(
  _trunklet.language__get_id(language_name) -- Will throw error if language doesn't exist
  , cascade
)
$body$;
REVOKE ALL ON FUNCTION trunklet.template_language__remove(
  language_name _trunklet.language.language_name%TYPE
  , cascade boolean
) FROM public;


DROP TABLE __trunklet.old_settings;
DROP SCHEMA __trunklet;

-- vi: expandtab sw=2 ts=2
