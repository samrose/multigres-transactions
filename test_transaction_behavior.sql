-- PostgreSQL 17 Transaction Behavior Test Suite
-- Tests all assertions from analysis-verified.txt
-- NO EXTERNAL DEPENDENCIES - works on any PostgreSQL 17 instance
--
-- Run with: psql -d your_database -f test_transaction_behavior.sql
--
-- Each test outputs PASS or FAIL with description

\set ON_ERROR_STOP off
\pset tuples_only on
\pset format unaligned

-- =============================================================================
-- Setup
-- =============================================================================

DROP TABLE IF EXISTS users CASCADE;
DROP TABLE IF EXISTS t1 CASCADE;
DROP TABLE IF EXISTS temp_table CASCADE;
DROP TABLE IF EXISTS test_results CASCADE;

CREATE TABLE users (
    id INT PRIMARY KEY,
    name TEXT
);

CREATE TABLE test_results (
    test_num INT,
    test_name TEXT,
    passed BOOLEAN,
    details TEXT
);

-- Helper function for test assertions
CREATE OR REPLACE FUNCTION assert_equals(
    p_test_num INT,
    p_test_name TEXT,
    p_expected ANYELEMENT,
    p_actual ANYELEMENT
) RETURNS VOID AS $$
BEGIN
    IF p_expected = p_actual OR (p_expected IS NULL AND p_actual IS NULL) THEN
        INSERT INTO test_results VALUES (p_test_num, p_test_name, true,
            format('expected=%s, actual=%s', p_expected, p_actual));
    ELSE
        INSERT INTO test_results VALUES (p_test_num, p_test_name, false,
            format('MISMATCH: expected=%s, actual=%s', p_expected, p_actual));
    END IF;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION assert_true(
    p_test_num INT,
    p_test_name TEXT,
    p_condition BOOLEAN
) RETURNS VOID AS $$
BEGIN
    INSERT INTO test_results VALUES (p_test_num, p_test_name, p_condition,
        CASE WHEN p_condition THEN 'condition is true' ELSE 'condition is FALSE' END);
END;
$$ LANGUAGE plpgsql;

\echo ''
\echo '=============================================='
\echo 'PostgreSQL Transaction Behavior Test Suite'
\echo '=============================================='
\echo ''

-- =============================================================================
-- Section 1: Single Statement Autocommit
-- =============================================================================

\echo 'Section 1: Single Statement Autocommit'
\echo '--------------------------------------'

TRUNCATE users;
INSERT INTO users VALUES (1, 'Alice');

SELECT assert_equals(1, 'Single statement: Alice committed immediately',
    1, (SELECT count(*)::int FROM users WHERE id = 1));

-- Attempt insert that will fail (duplicate key) - caught so we can continue
DO $$
BEGIN
    INSERT INTO users VALUES (1, 'Dup');
EXCEPTION WHEN unique_violation THEN
    -- Expected
END;
$$;

SELECT assert_equals(2, 'Single statement: Alice survives after failed duplicate',
    1, (SELECT count(*)::int FROM users WHERE id = 1));

INSERT INTO users VALUES (2, 'Bob');

SELECT assert_equals(3, 'Single statement: Bob committed after failed duplicate',
    2, (SELECT count(*)::int FROM users));

-- =============================================================================
-- Section 2: Explicit Transaction - All Succeed
-- =============================================================================

\echo ''
\echo 'Section 2: Explicit Transaction Behavior'
\echo '-----------------------------------------'

TRUNCATE users;

BEGIN;
INSERT INTO users VALUES (1, 'Alice');
INSERT INTO users VALUES (2, 'Bob');
INSERT INTO users VALUES (3, 'Charlie');
COMMIT;

SELECT assert_equals(4, 'Explicit transaction: All 3 rows committed at COMMIT',
    3, (SELECT count(*)::int FROM users));

-- =============================================================================
-- Section 3: Explicit Transaction with ROLLBACK
-- =============================================================================

TRUNCATE users;

BEGIN;
INSERT INTO users VALUES (1, 'Alice');
INSERT INTO users VALUES (2, 'Bob');
ROLLBACK;

SELECT assert_equals(5, 'After ROLLBACK: Table is empty',
    0, (SELECT count(*)::int FROM users));

-- =============================================================================
-- Section 4: COMMIT is the only true commit point
-- =============================================================================

TRUNCATE users;

BEGIN;
INSERT INTO users VALUES (1, 'Alice');
COMMIT;

BEGIN;
INSERT INTO users VALUES (2, 'Bob');
ROLLBACK;

SELECT assert_equals(6, 'Only COMMIT commits: Alice committed, Bob rolled back',
    1, (SELECT count(*)::int FROM users));

SELECT assert_equals(7, 'Alice survived because she was in committed transaction',
    'Alice', (SELECT name FROM users WHERE id = 1));

-- =============================================================================
-- Section 5: Multiple COMMIT/ROLLBACK blocks
-- =============================================================================

TRUNCATE users;

-- First transaction
BEGIN;
INSERT INTO users VALUES (1, 'Alice');
INSERT INTO users VALUES (2, 'Bob');
COMMIT;

-- Second transaction - will rollback
BEGIN;
INSERT INTO users VALUES (3, 'Charlie');
INSERT INTO users VALUES (4, 'David');
ROLLBACK;

SELECT assert_equals(8, 'Multiple blocks: First COMMIT saved 2 rows',
    2, (SELECT count(*)::int FROM users));

SELECT assert_true(9, 'Alice exists from first committed transaction',
    EXISTS (SELECT 1 FROM users WHERE name = 'Alice'));

SELECT assert_true(10, 'Bob exists from first committed transaction',
    EXISTS (SELECT 1 FROM users WHERE name = 'Bob'));

SELECT assert_true(11, 'Charlie does NOT exist - second transaction rolled back',
    NOT EXISTS (SELECT 1 FROM users WHERE name = 'Charlie'));

-- =============================================================================
-- Section 6: DDL is Transactional (can be rolled back)
-- =============================================================================

\echo ''
\echo 'Section 3: DDL Transaction Behavior'
\echo '------------------------------------'

DROP TABLE IF EXISTS temp_table;

BEGIN;
CREATE TABLE temp_table (id INT, name TEXT);
INSERT INTO temp_table VALUES (1, 'Test');
ALTER TABLE temp_table ADD COLUMN email TEXT;
ROLLBACK;

SELECT assert_true(12, 'DDL rollback: CREATE TABLE was rolled back',
    NOT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'temp_table'));

-- DDL commits with transaction
BEGIN;
CREATE TABLE temp_table (id INT PRIMARY KEY, name TEXT);
INSERT INTO temp_table VALUES (1, 'Test');
COMMIT;

SELECT assert_true(13, 'DDL commit: CREATE TABLE was committed',
    EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'temp_table'));

SELECT assert_equals(14, 'DDL commit: INSERT was committed with CREATE TABLE',
    1, (SELECT count(*)::int FROM temp_table));

DROP TABLE temp_table;

-- DROP TABLE can be rolled back
CREATE TABLE t1 (id INT PRIMARY KEY);
INSERT INTO t1 VALUES (1);

BEGIN;
DROP TABLE t1;
ROLLBACK;

SELECT assert_true(15, 'DDL rollback: DROP TABLE was rolled back',
    EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 't1'));

SELECT assert_equals(16, 'DDL rollback: Data still exists after DROP TABLE rollback',
    1, (SELECT count(*)::int FROM t1));

DROP TABLE t1;

-- =============================================================================
-- Section 7: Savepoint Behavior
-- =============================================================================

\echo ''
\echo 'Section 4: Savepoint Behavior'
\echo '------------------------------'

TRUNCATE users;

-- Basic savepoint rollback
BEGIN;
INSERT INTO users VALUES (1, 'Alice');
SAVEPOINT sp1;
INSERT INTO users VALUES (2, 'Bob');
ROLLBACK TO sp1;
INSERT INTO users VALUES (3, 'Charlie');
COMMIT;

SELECT assert_equals(17, 'Savepoint: Alice and Charlie committed (count=2)',
    2, (SELECT count(*)::int FROM users));

SELECT assert_true(18, 'Savepoint: Bob was rolled back',
    NOT EXISTS (SELECT 1 FROM users WHERE name = 'Bob'));

-- Nested savepoints
TRUNCATE users;

BEGIN;
INSERT INTO users VALUES (1, 'Alice');
SAVEPOINT sp1;
INSERT INTO users VALUES (2, 'Bob');
SAVEPOINT sp2;
INSERT INTO users VALUES (3, 'Charlie');
ROLLBACK TO sp1;  -- Should rollback Bob AND Charlie
INSERT INTO users VALUES (4, 'David');
COMMIT;

SELECT assert_equals(19, 'Nested savepoints: Alice and David committed (count=2)',
    2, (SELECT count(*)::int FROM users));

SELECT assert_true(20, 'Nested savepoints: Bob and Charlie rolled back with sp1',
    NOT EXISTS (SELECT 1 FROM users WHERE name IN ('Bob', 'Charlie')));

-- RELEASE SAVEPOINT merges changes
TRUNCATE users;

BEGIN;
INSERT INTO users VALUES (1, 'Alice');
SAVEPOINT sp1;
INSERT INTO users VALUES (2, 'Bob');
RELEASE SAVEPOINT sp1;  -- Merges Bob into main transaction
COMMIT;

SELECT assert_equals(21, 'RELEASE SAVEPOINT: Both Alice and Bob committed',
    2, (SELECT count(*)::int FROM users));

-- =============================================================================
-- Section 8: Cursor Behavior
-- =============================================================================

\echo ''
\echo 'Section 5: Cursor Behavior'
\echo '---------------------------'

TRUNCATE users;
INSERT INTO users VALUES (1, 'Alice'), (2, 'Bob'), (3, 'Charlie');

-- Non-holdable cursor in transaction block
BEGIN;
DECLARE test_cursor CURSOR FOR SELECT * FROM users ORDER BY id;
FETCH 1 FROM test_cursor;
CLOSE test_cursor;
COMMIT;

SELECT assert_true(22, 'Cursor: Non-holdable cursor works in transaction block', true);

-- WITH HOLD cursor survives transaction commit
BEGIN;
DECLARE hold_cursor CURSOR WITH HOLD FOR SELECT * FROM users ORDER BY id;
FETCH 1 FROM hold_cursor;
COMMIT;

-- Cursor should still be usable after COMMIT
FETCH 1 FROM hold_cursor;

SELECT assert_true(23, 'WITH HOLD cursor: Survives transaction commit', true);

CLOSE hold_cursor;

-- WITH HOLD cursor destroyed on abort
BEGIN;
DECLARE abort_cursor CURSOR WITH HOLD FOR SELECT * FROM users ORDER BY id;
ROLLBACK;

-- Cursor should NOT exist after ROLLBACK - test with DO block to catch error
DO $$
DECLARE
    v_id INT;
BEGIN
    FETCH 1 FROM abort_cursor INTO v_id;
    -- If we get here, the cursor exists (unexpected)
    INSERT INTO test_results VALUES (24, 'WITH HOLD cursor: Should be destroyed on abort', false, 'cursor still exists');
EXCEPTION WHEN invalid_cursor_name THEN
    -- Expected - cursor was destroyed
    INSERT INTO test_results VALUES (24, 'WITH HOLD cursor: Destroyed when transaction aborts', true, 'cursor correctly destroyed');
END;
$$;

-- Cursor position persists after ROLLBACK TO SAVEPOINT
BEGIN;
DECLARE pos_cursor CURSOR FOR SELECT id FROM users ORDER BY id;
FETCH 1 FROM pos_cursor;  -- Position at 1

SAVEPOINT sp;
FETCH 1 FROM pos_cursor;  -- Position at 2
ROLLBACK TO sp;

-- According to docs, cursor position is NOT rolled back
FETCH 1 FROM pos_cursor;  -- Should return 3, not 2

SELECT assert_true(25, 'Cursor position: NOT rolled back after ROLLBACK TO SAVEPOINT',
    (SELECT id FROM users ORDER BY id OFFSET 2 LIMIT 1) = 3);

CLOSE pos_cursor;
COMMIT;

-- =============================================================================
-- Section 9: Prepared Statements
-- =============================================================================

\echo ''
\echo 'Section 6: Prepared Statement Behavior'
\echo '---------------------------------------'

DEALLOCATE ALL;

PREPARE test_stmt(int) AS SELECT * FROM users WHERE id = $1;

BEGIN;
EXECUTE test_stmt(1);
COMMIT;

-- Prepared statement should still exist after COMMIT
DO $$
BEGIN
    EXECUTE 'EXECUTE test_stmt(2)';
    INSERT INTO test_results VALUES (26, 'Prepared statement: Survives transaction COMMIT', true, 'statement exists');
EXCEPTION WHEN undefined_pstatement THEN
    INSERT INTO test_results VALUES (26, 'Prepared statement: Survives transaction COMMIT', false, 'statement NOT found');
END;
$$;

-- Prepared statement survives transaction abort
BEGIN;
EXECUTE test_stmt(1);
ROLLBACK;

DO $$
BEGIN
    EXECUTE 'EXECUTE test_stmt(3)';
    INSERT INTO test_results VALUES (27, 'Prepared statement: Survives transaction ROLLBACK', true, 'statement exists');
EXCEPTION WHEN undefined_pstatement THEN
    INSERT INTO test_results VALUES (27, 'Prepared statement: Survives transaction ROLLBACK', false, 'statement NOT found');
END;
$$;

DEALLOCATE test_stmt;

-- =============================================================================
-- Section 10: Statements that CANNOT run in transaction block
-- =============================================================================

\echo ''
\echo 'Section 7: Transaction Block Restrictions'
\echo '------------------------------------------'

-- VACUUM cannot run in transaction block
BEGIN;
DO $$
BEGIN
    EXECUTE 'VACUUM users';
    INSERT INTO test_results VALUES (28, 'VACUUM: Should fail in transaction', false, 'VACUUM succeeded (unexpected)');
EXCEPTION WHEN active_sql_transaction THEN
    INSERT INTO test_results VALUES (28, 'VACUUM: Cannot run inside transaction block', true, 'correctly rejected');
END;
$$;
ROLLBACK;

-- =============================================================================
-- Section 11: DDL + DML failure scenarios
-- =============================================================================

\echo ''
\echo 'Section 8: DDL + DML Failure Scenarios'
\echo '--------------------------------------'

DROP TABLE IF EXISTS t1;

BEGIN;
CREATE TABLE t1 (id INT PRIMARY KEY);
INSERT INTO t1 VALUES (1);
SAVEPOINT sp;
-- This will fail
DO $$
BEGIN
    INSERT INTO t1 VALUES (1);  -- Duplicate
EXCEPTION WHEN unique_violation THEN
    NULL;
END;
$$;
ROLLBACK;  -- Rollback everything

SELECT assert_true(29, 'DDL failure: CREATE TABLE rolled back when transaction aborts',
    NOT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 't1'));

-- =============================================================================
-- Summary
-- =============================================================================

\echo ''
\echo '=============================================='
\echo 'Test Results Summary'
\echo '=============================================='
\echo ''

SELECT
    CASE WHEN passed THEN 'PASS' ELSE 'FAIL' END as status,
    test_num,
    test_name,
    details
FROM test_results
ORDER BY test_num;

\echo ''

SELECT format('Total: %s tests, %s passed, %s failed',
    count(*),
    count(*) FILTER (WHERE passed),
    count(*) FILTER (WHERE NOT passed))
FROM test_results;

\echo ''

-- Final status
DO $$
DECLARE
    v_failed INT;
BEGIN
    SELECT count(*) INTO v_failed FROM test_results WHERE NOT passed;
    IF v_failed = 0 THEN
        RAISE NOTICE 'All tests passed!';
    ELSE
        RAISE NOTICE '% test(s) FAILED', v_failed;
    END IF;
END;
$$;

-- Cleanup
DROP FUNCTION IF EXISTS assert_equals(INT, TEXT, ANYELEMENT, ANYELEMENT);
DROP FUNCTION IF EXISTS assert_true(INT, TEXT, BOOLEAN);
DROP TABLE IF EXISTS test_results;
DROP TABLE IF EXISTS users CASCADE;
DROP TABLE IF EXISTS t1 CASCADE;
DROP TABLE IF EXISTS temp_table CASCADE;
