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
 * schemas
 */
CREATE FUNCTION test_schemas
() RETURNS SETOF text LANGUAGE plpgsql AS $body$
DECLARE
BEGIN
  RETURN NEXT schema_privs_are(
    'trunklet'
    , 'public'
    , array[ 'USAGE' ]
  );

  RETURN NEXT schema_privs_are(
    '_trunklet'
    , 'public'
    , array[ NULL ]
  );
  RETURN NEXT schema_privs_are(
    '_trunklet'
    , 'trunklet__dependency'
    , array[ 'USAGE' ]
  );

  RETURN NEXT schema_privs_are(
    '_trunklet_functions'
    , 'public'
    , array[ 'USAGE' ]
  );
END
$body$;

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
      , parameter_type := 'text[]'
      , template_type := 'text'
      , process_function_options := 'LANGUAGE plpgsql'
      , process_function_body := $process$
DECLARE
  v_args CONSTANT text := array_to_string( array( SELECT ', ' || quote_nullable(a) FROM unnest(parameters::text[]) a(a) ), '' );
  sql CONSTANT text := format( 'SELECT format( %L%s )', template::text, v_args );
  v_return text;
BEGIN
  RAISE DEBUG 'EXECUTE INTO using sql %', sql;
  EXECUTE sql INTO v_return;
  RETURN v_return;
END
$process$
      , extract_parameters_options := 'LANGUAGE sql'
      , extract_parameters_body := $extract$SELECT ''::text::variant.variant$extract$
    );
  EXCEPTION
    -- TODO: incorrect return value
    WHEN no_data_found OR unique_violation THEN
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
  p CONSTANT text := 'language__get_id: ';
  v_id CONSTANT int := get_test_language_id();
  template CONSTANT text := $$SELECT _trunklet.language__get_id( %L )$$;
BEGIN
  RETURN NEXT is(
    _trunklet.language__get_id( get_test_language_name() )
    , v_id
    , p || 'returns correct id'
  );

  RETURN NEXT throws_ok(
    format( template, bogus_language_name() )
    , 'P0002'
    , format( $$language "%s" not found$$, bogus_language_name() )
    , p || 'throws language not found'
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
  , text = $$text[]$$
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

  RETURN NEXT table_privs_are(
    c_schema, c_name
    , 'public'
    , NULL::text[]
  );
  RETURN NEXT table_privs_are(
    c_schema, c_name
    , 'trunklet__dependency'
    , '{REFERENCES}'::text[]
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

/*
 * We need this function to prevent the planner from attempting to directly
 * cast text to variant during function compilation, before get_test_language_id
 * has allowed text as a type for that variant.
 */
CREATE FUNCTION any_to_trunklet_template(
  anyelement
) RETURNS variant.variant(trunklet_template) LANGUAGE plpgsql VOLATILE AS $$BEGIN RETURN $1::variant.variant(trunklet_template); END$$;
CREATE FUNCTION any_to_trunklet_parameter(
  anyelement
) RETURNS variant.variant(trunklet_parameter) LANGUAGE plpgsql VOLATILE AS $$BEGIN RETURN $1::variant.variant(trunklet_parameter); END$$;
CREATE FUNCTION get_test_templates(
) RETURNS int[] LANGUAGE plpgsql AS $body$
DECLARE
  ids int[];
BEGIN
  -- Do this even if the test_templates table already exists
  PERFORM get_test_language_id();

  BEGIN
    SELECT ids INTO ids FROM test_templates;
  EXCEPTION
    WHEN undefined_table THEN
      ids[1] := trunklet.template__add( get_test_language_name(), 'test template', any_to_trunklet_template('test 1'::text) );
      ids[2] := trunklet.template__add( get_test_language_name(), 'test template', 2, any_to_trunklet_template('test 2'::text) );

      -- See also test_template__remove
      CREATE TEMP TABLE test_templates AS VALUES(ids);
  END;

  RETURN ids;
END
$body$;

CREATE FUNCTION test_template__add
() RETURNS SETOF text LANGUAGE plpgsql AS $body$
DECLARE
  ids CONSTANT int[] := get_test_templates();
  v_array_allowed CONSTANT boolean := 
    EXISTS(SELECT 1 FROM variant.allowed_types( 'trunklet_template' ) WHERE allowed_type = 'text[]'::regtype)
  ;
BEGIN
--  RAISE WARNING 'v_array_allowed %', v_array_allowed;
  IF NOT v_array_allowed THEN
    PERFORM variant.add_type( 'trunklet_template', 'text[]' );
  END IF;

  RETURN NEXT throws_ok(
    $$SELECT trunklet.template__add( bogus_language_name(), 'test_template', any_to_trunklet_template('test 1'::text) )$$
    , format( 'language "%s" not found', bogus_language_name() )
    , 'Bogus language throws error'
  );

  RETURN NEXT todo( 'Need to implement template type enforcement' );
  RETURN NEXT throws_ok(
    $$SELECT trunklet.template__add( get_test_language_name(), 'test_template', 9, '{a,b}'::text[]::variant.variant(trunklet_template) )$$
    , '12345'
    , NULL
    , 'template__add: throw error when given bad template type'
  );
  /*
   * Unfortunately, we can't actually support this right now, because variant doesn't allow for it
  IF NOT v_array_allowed THEN
    PERFORM variant.remove_type( 'trunklet_template', 'text[]' );
  END IF;
   */

  RETURN NEXT bag_eq(
    -- Need to cast variant to text because it doesn't have an equality operator family
    $$SELECT language_name
          , template_id
          , template_name
          , template_version
          , template::text
        FROM _trunklet.template t
          JOIN _trunklet.language l USING( language_id )
        WHERE template_id = ANY( $$ || quote_literal(ids) || $$ )
      $$
    , format(
        $$SELECT get_test_language_name() AS language_name
              , (%L::int[])[i] AS template_id
              , 'test template'::text AS template_name
              , i AS template_version
              , ('test ' || i) AS template
            FROM generate_series(1,2) AS i(i)
        $$
        , ids
      )
    , $$Verify template__add results$$
  );
END
$body$;

CREATE FUNCTION test_secdef_privs
() RETURNS SETOF text LANGUAGE plpgsql AS $body$
DECLARE
BEGIN
  RETURN QUERY SELECT is(
        proacl
        , NULL
        , 'Verify acl for ' || p.oid::regprocedure
      )
    FROM pg_proc p
      JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE nspname = 'trunklet'
      AND prosecdef
  ;

  RETURN QUERY SELECT is(
        proconfig
        , '{search_path=pg_catalog}'
        , 'Verify search_path for ' || p.oid::regprocedure
      )
    FROM pg_proc p
      JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE nspname = 'trunklet'
      AND prosecdef
  ;

END
$body$;

/*
 * FUNCTION _trunklet.template__get
 */
CREATE FUNCTION test_template__get
() RETURNS SETOF text LANGUAGE plpgsql AS $body$
DECLARE
BEGIN
  PERFORM get_test_templates();

  RETURN NEXT throws_ok(
    format( $$SELECT _trunklet.template__get( 'bogus' )$$ )
    , 'P0002'
    , format( $$template name "bogus" at version 1 not found$$, get_test_language_name() )
  );

  RETURN NEXT is(
    ( SELECT row(g.*)::_trunklet.template FROM _trunklet.template__get( 'bogus', loose := true ) AS g )
    , NULL::_trunklet.template
    , 'Verify loose := true'
  );

  RETURN NEXT bag_eq(
    $$SELECT * FROM _trunklet.template__get( 'test template' )$$
    , $$SELECT *
          FROM _trunklet.template
          WHERE language_id = get_test_language_id()
            AND template_name = 'test template'
            AND template_version = 1
      $$
    , $$Check _trunklet.template__get( ..., 'test template' )$$
  );
  /*
  RETURN NEXT bag_eq(
    $$SELECT * FROM _trunklet.template__get( get_test_language_name(), 'test template', i ) FROM generate_series(1, 2) i$$
    , $$SELECT * FROM verify_test_template$$
    , $$Check _trunklet.template__get( ..., 'test template', version )$$
  );
  */
  RETURN QUERY SELECT is(
        _trunklet.template__get( template_name, template_version )
        , ROW(t.*)::_trunklet.template
        , format( $$Check _trunklet.template__get( 'test template', %s )$$, template_version )
      )
    FROM _trunklet.template t
      LEFT JOIN _trunklet.language l USING( language_id )
  ;

END
$body$;



/*
 * FUNCTION trunklet.template__remove
 */
CREATE FUNCTION test_template__remove
() RETURNS SETOF text LANGUAGE plpgsql AS $body$
DECLARE
  ids int[];
  test_sql CONSTANT text := 
    $$SELECT * FROM _trunklet.template WHERE template_id = ANY( %L )$$
  ;
BEGIN
  ids := get_test_templates();
  PERFORM trunklet.template__remove( 'test template' );
  PERFORM trunklet.template__remove( 'test template', 2 );
  -- Drop temp table now that templates are gone
  DROP TABLE test_templates;

  RETURN NEXT is_empty(
    format( test_sql, ids )
    , $$Test templates removed by name/version$$
  );

  ids := get_test_templates();
  PERFORM trunklet.template__remove( id ) FROM unnest(ids) AS i(id);
  DROP TABLE test_templates;

  RETURN NEXT is_empty(
    format( test_sql, ids )
    , $$Test templates removed by id$$
  );
END
$body$;


/*
 * FUNCTION trunklet.template__dependency
 */
CREATE FUNCTION pg_temp.exec_as(name,text) RETURNS void LANGUAGE plpgsql AS $body$
DECLARE
  v_current_role name;
BEGIN
  v_current_role := current_role;
  EXECUTE 'SET ROLE ' || $1;
  EXECUTE $2;
  EXECUTE 'SET ROLE ' || v_current_role;
END
$body$;
CREATE FUNCTION test_template__dependency
() RETURNS SETOF text LANGUAGE plpgsql AS $body$
DECLARE
  test_table text;
  test_field name;
BEGIN

  -- Can't use a temp table because you can't add a FK from a temp table to a non-temp table
  test_table := '_trunklet_test.test_dependency';
  test_field := 'test_template_id';
  DROP TABLE IF EXISTS _trunklet_test.test_dependency;
  CREATE TABLE _trunklet_test.test_dependency(
    test_template_id int
  );

  /*
   * This ugliness is to verify we get the proper context. We need to do that
   * to ensure that we're protecting against SQL injection.
   */
  DECLARE
    errcode text := '42P01';
    errmsg text := 'relation "bogus_table" does not exist';
    errcontext text := $$\APL/pgSQL function trunklet.template__dependency__add\(text,name\) line \d+ during statement block local variable initialization$$;

    context text;
    description text := 'threw with proper context ' || errcode || ': ' || errmsg;
  BEGIN
    PERFORM trunklet.template__dependency__add( 'bogus_table', test_field );
    RETURN NEXT ok( FALSE, description ) || E'\n' || diag(
           '      caught: no exception' ||
        E'\n      wanted: ' || COALESCE( errcode, 'an exception' )
    );
  EXCEPTION
    WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS context = PG_EXCEPTION_CONTEXT;
      IF (errcode IS NULL OR SQLSTATE = errcode)
        AND ( errmsg IS NULL OR SQLERRM = errmsg)
        AND context ~ errcontext
      THEN
        RETURN NEXT ok( TRUE, description );
      ELSE
        RETURN NEXT ok( FALSE, description ) || E'\n' || diag(
             '      caught: ' || SQLSTATE || ': ' || SQLERRM ||
          E'\n        context: ' || context ||
          E'\n      wanted: ' || COALESCE( errcode, 'an exception' ) ||
          COALESCE( ': ' || errmsg, '') ||
          E'\n        context: ' || errcontext
        );
      END IF;
  END;

  RETURN NEXT throws_ok(
    $$SELECT trunklet.template__dependency__add( 'test_dependency', 'bogus_field' )$$
    , '42703'
    , NULL
    , 'dependency__add: column does not exist'
  );

  DECLARE
    test_template CONSTANT text :=
        $test$SELECT pg_temp.exec_as( '_trunklet_test_role', $sql$SELECT trunklet.template__dependency__%s( %L, %L )$sql$ )$test$
    ;
  BEGIN
    DROP ROLE IF EXISTS _trunklet_test_role;
    CREATE ROLE _trunklet_test_role;
    GRANT USAGE ON SCHEMA _trunklet_test TO _trunklet_test_role;
    GRANT USAGE ON SCHEMA _trunklet TO _trunklet_test_role;
    ALTER TABLE _trunklet_test.test_dependency OWNER TO _trunklet_test_role;
    RETURN NEXT throws_ok(
      format( test_template, 'add', test_table, test_field )
      , '42501'
      , NULL
      , 'dependency__add: insufficient privilege'
    );

    GRANT trunklet__dependency TO _trunklet_test_role;
    RETURN NEXT lives_ok(
      format( test_template, 'add', test_table, test_field )
      , 'dependency__add: success'
    );

    RETURN NEXT fk_ok(
      '_trunklet_test', 'test_dependency', test_field
      , '_trunklet', 'template', 'template_id'
    );

    RETURN NEXT lives_ok(
      format( test_template, 'remove', test_table, test_field )
      , 'dependency__remove: success'
    );

    RETURN NEXT col_isnt_fk( '_trunklet_test', 'test_dependency', test_field, $$FK does not exist$$ );

    RETURN NEXT throws_ok(
      format( test_template, 'remove', test_table, test_field )
      , '42704'
      , 'no template dependency on ' || test_table || '.' || test_field
      , 'dependency__remove: constraint does not exist'
    );

    RETURN NEXT throws_ok(
      format( test_template, 'remove', test_table || 'XXX', test_field )
      , '42P01'
      , NULL
      , 'dependency__remove: undefined table'
    );

    RETURN NEXT throws_ok(
      format( test_template, 'remove', test_table, test_field || 'XXX' )
      , '42703'
      , 'column "' || test_field || 'XXX" does not exist'
      , 'dependency__remove: column does not exist'
    );

    DROP TABLE _trunklet_test.test_dependency;
    REVOKE USAGE ON SCHEMA _trunklet_test FROM _trunklet_test_role;
    REVOKE USAGE ON SCHEMA _trunklet FROM _trunklet_test_role;
    DROP ROLE IF EXISTS _trunklet_test_role;
  END;
END
$body$;



/*
 * FUNCTION trunklet.process
 */
CREATE FUNCTION test_process
() RETURNS SETOF text LANGUAGE plpgsql AS $body$
DECLARE
  lname CONSTANT text := get_test_language_name();
  test_l CONSTANT text := $$SELECT trunklet.process_language( %L, %L, %L )$$;
  test CONSTANT text := replace( test_l, '_language', '' );
  template_name CONSTANT text := 'test template';
  p CONSTANT text := 'trunklet.process(): ';
  c_test_role CONSTANT name := 'Completely bogus trunklet test role';
  c_original_role CONSTANT name := current_user;
BEGIN
  PERFORM get_test_language_id();
  PERFORM variant.add_type( 'trunklet_template', 'varchar' );
  PERFORM variant.add_type( 'trunklet_parameter', 'text' );

  RETURN NEXT throws_ok(
    format( test_l, bogus_language_name(), any_to_trunklet_template('%s'::text), any_to_trunklet_parameter('{a}'::text[]) )
    , 'P0002'
    , 'language "bogus template language that does not exist" not found'
    , p || 'invalid language'
  );

  RETURN NEXT throws_ok(
    format( test_l, lname, any_to_trunklet_template('%s'::varchar), any_to_trunklet_parameter('{a}'::text[]) )
    , '22000'
    , 'templates for language "Our internal test language" must by of type "text"'
    , p || 'invalid template' -- TEMPLATE
  );

  RETURN NEXT throws_ok(
    format( test_l, lname, any_to_trunklet_template('%s'::text), any_to_trunklet_parameter('{a}'::text) )
    , '22000'
    , 'parameters for language "Our internal test language" must by of type "text[]"'
    , p || 'invalid parameter' -- PARAMETERS
  );

  /*
  RETURN QUERY SELECT row(oid::regprocedure, prorettype::regtype, prosrc)::text
    FROM pg_proc
    WHERE pronamespace = (SELECT oid FROM pg_namespace WHERE nspname='_trunklet_functions')
  ;
  */

  RETURN NEXT lives_ok($lives$
    CREATE TEMP VIEW test AS
    SELECT *
          -- Once we switch roles later we can't run these functions, so do that in the view instead
          , any_to_trunklet_template(template) AS template_v
          , any_to_trunklet_parameter(parameters) AS parameters_v
      FROM (
          SELECT *
            FROM (VALUES
                  ( 1::int, '%s'::text,   '{a}'::text[],  'a'::text )
                , ( 2,      '%s %s',      '{a,b}',        'a b' )
                , ( 3,      '%s %s',      '{a,NULL}',     'a ' )
                , ( 4,      '%s',         '{NULL}',       '' )
                , ( 5,      'moo',        NULL,           'moo' )
              ) a(version, template, parameters, expected)
        ) a
    ;
    GRANT SELECT ON test TO PUBLIC;
    $lives$
    , 'Create test view'
  );

  RETURN NEXT lives_ok(
    format(
        $$SELECT trunklet.template__add( %L, %L, version, template ) FROM test$$
        , lname
        , template_name
      )
    , 'Create predefined templates'
  );

  RETURN NEXT lives_ok(
    format( 'CREATE ROLE %I', c_test_role )
    , 'Create test role'
  );
  RETURN NEXT lives_ok(
    format( 'SET LOCAL ROLE = %I', c_test_role )
    , 'Change to test role'
  );
  RETURN NEXT is(
    current_user
    , c_test_role
    , 'Verify role change' -- Roles in functions are finicky enough this is worth testing for
  );
  RAISE DEBUG 'current_user = %, search_path = %', current_user, current_setting('search_path');

  RETURN QUERY
    SELECT is(
          /*
           * REMEMBER: the test language is actually just format, so first argument
           * here is a format string itself, second is an array of text values.
           */
          trunklet.process_language( lname, template_v, parameters_v )
          , expected
          , format( 'trunklet.process( ..., %L, %L )', template, parameters )
        )
      FROM test
  ;

  -- This stuff will die if we screwed up template creation above
  BEGIN
    RETURN QUERY
      SELECT is(
            trunklet.process( template_name, parameters_v )
            , expected
            , format( 'trunklet.process( %L, %L )', template_name, parameters )
          )
        FROM test
        WHERE version = 1
    ;

    RETURN QUERY
      SELECT is(
            trunklet.process( template_name, version, parameters_v )
            , expected
            , format( 'trunklet.process( %L, %L, %L )', template_name, version, parameters )
          )
        FROM test
    ;
  EXCEPTION
    WHEN others THEN
      RAISE WARNING 'Caught exception %: %', SQLSTATE, SQLERRM;
  END;

  RETURN NEXT lives_ok(
    format( 'SET LOCAL ROLE = %I', c_original_role )
    , 'Change back to original role'
  );
  RETURN NEXT lives_ok(
    format( 'DROP ROLE %I', c_test_role )
    , 'Drop test role'
  );
END
$body$;


/*
 * FUNCTION trunklet.execute
CREATE FUNCTION test_execute
() RETURNS SETOF text LANGUAGE plpgsql AS $body$
DECLARE
  lname CONSTANT text := get_test_language_name();
  test CONSTANT text := $$SELECT trunklet.execute( %L, %L, %L )$$;
  template_name CONSTANT text := 'test template';
BEGIN
  PERFORM get_test_language_id();
  PERFORM variant.add_type( 'trunklet_template', 'varchar' );
  PERFORM variant.add_type( 'trunklet_parameter', 'text' );
 */

-- vi: expandtab sw=2 ts=2
