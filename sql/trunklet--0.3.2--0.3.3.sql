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

DROP FUNCTION _trunklet._language_function__drop(
  language_id _trunklet.language.language_id%TYPE
  , function_type text
  , function_arguments text
);
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

DROP FUNCTION trunklet.template_language__remove(
  language_id _trunklet.language.language_id%TYPE
  , cascade boolean
);
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
DROP FUNCTION trunklet.template_language__remove(
  language_name _trunklet.language.language_name%TYPE
  , cascade boolean
);
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
