\set ECHO 0
BEGIN;
\i sql/trunklet.sql
\set ECHO all

-- You should write your tests

SELECT trunklet('foo', 'bar');

SELECT 'foo' #? 'bar' AS arrowop;

CREATE TABLE ab (
    a_field trunklet
);

INSERT INTO ab VALUES('foo' #? 'bar');
SELECT (a_field).a, (a_field).b FROM ab;

SELECT (trunklet('foo', 'bar')).a;
SELECT (trunklet('foo', 'bar')).b;

SELECT ('foo' #? 'bar').a;
SELECT ('foo' #? 'bar').b;

ROLLBACK;
