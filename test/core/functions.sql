CREATE SCHEMA _trunklet_test;
SET search_path = _trunklet_test, tap, "$user";

/*
 * NOTE! DO NOT use CREATE OR REPLACE FUNCTION in here. If you do that and
 * accidentally try to define the same function twice you'll never detect that
 * mistake!
 */

/*
CREATE FUNCTION test_
() RETURNS SETOF text LANGUAGE plpgsql AS $body$
DECLARE
BEGIN
END
$body$;
*/

/*
 * _trunklet.name_sanity()
 */
CREATE FUNCTION run__name_sanity(
  text
) RETURNS text LANGUAGE sql AS $body$
  SELECT $$SELECT _trunklet.name_sanity( 'field_name', $$
    || quote_nullable($1) || ' )'
$body$;

CREATE FUNCTION test__name_sanity
() RETURNS SETOF text LANGUAGE plpgsql AS $body$
DECLARE
  t text;
  a text[];

  -- Base test for NULL
  tests text[] := array[
    [NULL, 'be NULL' ]
    , [ '', 'be blank' ]
  ];
BEGIN
  -- Build a set of tests for every kind of whitespace
  FOREACH t IN ARRAY array[E'\t', E'\n', E' ']
  LOOP
    tests := tests || array[
      [ t, 'begin with whitespace' ]
      , [ t || 'moo', 'begin with whitespace' ]
      , [ 'moo' || t, 'end with whitespace' ]
    ];
  END LOOP;

  -- Now run the tests
  FOREACH a SLICE 1 IN ARRAY tests
  LOOP
    RETURN NEXT throws_ok(
      run__name_sanity(a[1])
      , '22023'
      , 'field_name must not ' || a[2]
    );
  END LOOP;
END
$body$;

/*
 * TABLE _trunklet.language
 */
CREATE FUNCTION language_name_type(
) RETURNS name LANGUAGE sql AS $$SELECT 'character varying(100)'::name$$;

CREATE FUNCTION test__table_language
() RETURNS SETOF text LANGUAGE plpgsql AS $body$
DECLARE
  c_schema CONSTANT name := '_trunklet';
  c_name CONSTANT name := 'language';
BEGIN
  -- Mostly for sanity of our test code
  RETURN NEXT col_type_is(
    c_schema, c_name
    , 'language_name'::name -- Cast to get the correct test function
    , language_name_type()
  );

  RETURN NEXT throws_ok(
    format(
      $$INSERT INTO %I.%I
          ( language_name
            , parameter_type
            , template_type
            , process_function_options, process_function_body
            , extract_parameters_options, extract_parameters_body
          )
        VALUES(
          ''
          , 'text'
          , 'text'
          , '', ''
          , '', ''
        )
      $$
      , c_schema, c_name
    )
    , '22023'
    , $$language_name must not be blank$$
    , format(
        $$Verify CHECK constraint on %I.%I.language_name$$
        , c_schema, c_name
      )
  );
END
$body$;

/*
 * LANGUAGE FACTORY
 */
CREATE FUNCTION bogus_language_name(
) RETURNS text LANGUAGE sql AS $$SELECT 'bogus template language that does not exist'::text$$;
CREATE FUNCTION get_test_language_name(
) RETURNS text LANGUAGE sql AS $$SELECT 'Our internal test language'::text$$;
CREATE FUNCTION get_test_language_id(
) RETURNS int LANGUAGE plpgsql AS $body$
BEGIN
  BEGIN
  PERFORM trunklet.template_language__add(
      get_test_language_name()
      , 'text[][]'
      , 'text'
      , 'LANGUAGE sql'
      , $$SELECT ''::text$$
      , 'LANGUAGE sql'
      , $$SELECT ''::text::variant.variant$$
    );
  EXCEPTION
    -- TODO: incorrect return value
    WHEN no_data_found THEN
      NULL;
  END;
  RETURN _trunklet.language__get_id( get_test_language_name() );
END
$body$;

/*
 * FUNCTION _trunklet.language__get_id
 */
CREATE FUNCTION test_language__get_id
--\i test/helpers/f1.sql
() RETURNS SETOF text LANGUAGE plpgsql AS $body$
DECLARE
BEGIN
  RETURN NEXT function_privs_are(
    '_trunklet', 'language__get_id'
    , ('{' || language_name_type() || '}')::text[]
    , 'public', NULL::text[]
  );

  RETURN NEXT throws_ok(
    format( $$SELECT _trunklet.language__get_id( %L )$$, bogus_language_name() )
    , 'P0002'
    , format( $$language "%s" not found$$, bogus_language_name() )
  );
END
$body$;

/*
 * VIEW template_language
 */
CREATE FUNCTION test_template_language
--\i test/helpers/f1.sql
() RETURNS SETOF text LANGUAGE plpgsql AS $body$
DECLARE
  c_schema CONSTANT name := 'trunklet';
  c_name CONSTANT name := 'template_language';
  a_columns CONSTANT name[] := '{ language_name, parameter_type, template_type, process_function_options, process_function_body, extract_parameters_options, extract_parameters_body }';
  v_columns CONSTANT text := array_to_string( a_columns, ', ' );
  v_col name;
BEGIN
  -- Verify view exists
  RETURN NEXT has_view(
    c_schema, c_name
    -- Necessary because has_view(schema,view) doesn't exist
    , format( $$View %I.%I should exist$$, c_schema, c_name )
  );

  -- Verify columns exist
  RETURN NEXT columns_are(
    c_schema, c_name
    , a_columns
  );

  -- Check permissions
  RETURN NEXT table_privs_are(
      c_schema, c_name
      , 'public', NULL::text[]
  );
  -- Not worth checking owner privs

  BEGIN -- bag_eq blows up if view doesn't actually exist
  -- Sanity check results
  RETURN NEXT bag_eq(
    format( $$SELECT %s FROM %I.%I$$, v_columns, c_schema, c_name )
    , format( $$SELECT %s FROM _trunklet.language$$, v_columns )
    , $$template_language returns same results as _trunklet.language$$
  );
  EXCEPTION
    WHEN undefined_table THEN
      NULL;
  END;
END
$body$;

/*
 * language__add()
 */
-- NOTE: These default values won't actually work
CREATE FUNCTION run_template_language__add(
  text
  , text = $$text[][]$$
  , text = $$text$$
  , text = $$LANGUAGE sql$$
  , text = $$SELECT ''$$
  , text = $$LANGUAGE sql$$
  , text = $$SELECT ''$$
) RETURNS text LANGUAGE sql AS $body$
  SELECT 'SELECT trunklet.template_language__add( '
    || quote_nullable($1) || ', '
    || quote_nullable($2) || ', '
    || quote_nullable($3) || ', '
    || quote_nullable($4) || ', '
    || quote_nullable($5) || ', '
    || quote_nullable($6) || ', '
    || quote_nullable($7) || ' )'
$body$;

CREATE FUNCTION test_template_language__add
--\i test/helpers/f1.sql
() RETURNS SETOF text LANGUAGE plpgsql AS $body$
DECLARE
  lang text := 'test';
  process_options text := 'LANGUAGE sql';
  process_body text := $$SELECT ''$$;

  extract_options text := process_options;
  extract_body text := process_body;

BEGIN
  RETURN NEXT throws_ok(
    run_template_language__add( NULL )
    , '22023'
    , $$language_name must not be NULL$$
  );

  RETURN NEXT ok(
    get_test_language_id() IS NOT NULL
    , 'Verify we can create test language'
  );
  RETURN NEXT ok(
    EXISTS(SELECT 1 FROM variant.allowed_types( 'trunklet_template' ) WHERE allowed_type = 'text'::regtype)
    , 'Verify type added to registered variant "trunklet_template"'
  );
  RETURN NEXT ok(
    EXISTS(SELECT 1 FROM variant.allowed_types( 'trunklet_parameter' ) WHERE allowed_type = 'text[]'::regtype)
    , 'Verify type added to registered variant "trunklet_parameter"'
  );
  RETURN NEXT ok(
    EXISTS(SELECT 1 FROM variant.allowed_types( 'trunklet_return' ) WHERE allowed_type = 'text[]'::regtype)
    , 'Verify type added to registered variant "trunklet_return"'
  );

  RETURN NEXT function_privs_are(
    'trunklet', 'template_language__add'
    , ('{ ' || language_name_type() || ', regtype, regtype, text, text, text, text }')::text[]
    , 'public', NULL::text[]
  );
END
$body$;

/*
 * TABLE _trunklet.template
 */
CREATE FUNCTION test__table_template
() RETURNS SETOF text LANGUAGE plpgsql AS $body$
DECLARE
  c_schema CONSTANT name := '_trunklet';
  c_name CONSTANT name := 'template';
  c_language_id CONSTANT int := get_test_language_id();
BEGIN
  RETURN NEXT ok(
    c_language_id IS NOT NULL
    , 'c_language_id IS NOT NULL'
  );

  RETURN NEXT col_is_unique(
    c_schema, c_name
    , '{template_name, template_version}'::name[]
    , '(template_name, template_version) should be unique'
  );

  RETURN NEXT throws_ok(
    format(
      $$INSERT INTO %I.%I(
            language_id
            , template_name
            , template_version
            , template
          )
          SELECT language_id
              , ''
              , 1
              , ''::text
            FROM _trunklet.language
            LIMIT 1
      $$
      , c_schema, c_name
    )
    , '22023'
    , $$template_name must not be blank$$
    , format(
        $$Verify CHECK constraint on %I.%I.template_name$$
        , c_schema, c_name
      )
  );
END
$body$;

/*
 * FUNCTION trunklet.template__add
 */
CREATE FUNCTION test_template__add
() RETURNS SETOF text LANGUAGE plpgsql AS $body$
DECLARE
BEGIN
  PERFORM get_test_language_id();

  RETURN NEXT lives_ok(
    /*
     * Need to explicitly cast to variant because PG doesn't consider this to
     * be an assignment cast. Even if it did, it ignores typmod in function
     * parameters. :(
     */
    $$SELECT trunklet.template__add( get_test_language_name(), 'test template', 'test 1'::text::variant.variant(trunklet_template) )$$
    , 'Create test template v1'
  );
  RETURN NEXT lives_ok(
    $$SELECT trunklet.template__add( get_test_language_name(), 'test template', 2, 'test 2'::text::variant.variant(trunklet_template) )$$
    , 'Create test template v1'
  );

  RETURN NEXT bag_eq(
    -- Need to cast variant to text because it doesn't have an equality operator family
    $$SELECT language_name, template_version, template::text FROM _trunklet.template t JOIN _trunklet.language l USING( language_id ) WHERE template_name = 'test template'$$
    , $$SELECT get_test_language_name(), i, ('test ' || i) FROM generate_series(1,2) AS i(i)$$
    , $$Verify template__add results$$
  );
END
$body$;

-- vi: expandtab sw=2 ts=2
