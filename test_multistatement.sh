#!/bin/bash
# PostgreSQL 17 Multi-Statement Behavior Test Suite
# Tests behaviors that require sending multiple statements as a single Query message
#
# Usage: ./test_multistatement.sh [database_name]
# Default database: postgres

set -e

DB="${1:-postgres}"
PASS=0
FAIL=0

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo "=============================================="
echo "PostgreSQL Multi-Statement Behavior Test Suite"
echo "Database: $DB"
echo "=============================================="
echo ""

# Helper function to run test
run_test() {
    local test_name="$1"
    local setup_sql="$2"
    local test_sql="$3"
    local expected_count="$4"
    local description="$5"

    echo -n "Test: $test_name... "

    # Setup
    psql -d "$DB" -q -c "$setup_sql" 2>/dev/null || true

    # Run test (may fail, that's expected)
    psql -d "$DB" -q -c "$test_sql" 2>/dev/null || true

    # Check result
    actual_count=$(psql -d "$DB" -t -A -c "SELECT count(*)::int FROM users;" 2>/dev/null)

    if [ "$actual_count" -eq "$expected_count" ]; then
        echo -e "${GREEN}PASS${NC} (count=$actual_count)"
        ((PASS++))
    else
        echo -e "${RED}FAIL${NC} (expected=$expected_count, actual=$actual_count)"
        echo "  Description: $description"
        ((FAIL++))
    fi
}

# =============================================================================
# Setup
# =============================================================================

psql -d "$DB" -q -c "DROP TABLE IF EXISTS users CASCADE;"
psql -d "$DB" -q -c "CREATE TABLE users (id INT PRIMARY KEY, name TEXT);"

# =============================================================================
# Test 1: Multi-statement success (all in implicit transaction)
# =============================================================================

run_test "1-multistatement-success" \
    "TRUNCATE users;" \
    "INSERT INTO users VALUES (1, 'Alice'); INSERT INTO users VALUES (2, 'Bob'); INSERT INTO users VALUES (3, 'Charlie');" \
    3 \
    "All 3 INSERTs should commit atomically in implicit transaction"

# =============================================================================
# Test 2: Multi-statement failure (all rolled back)
# =============================================================================

run_test "2-multistatement-failure-rollback" \
    "TRUNCATE users;" \
    "INSERT INTO users VALUES (1, 'Alice'); INSERT INTO users VALUES (2, 'Bob'); INSERT INTO users VALUES (1, 'Duplicate'); INSERT INTO users VALUES (3, 'Charlie');" \
    0 \
    "All INSERTs should be rolled back when one fails (implicit transaction)"

# =============================================================================
# Test 3: ⚠️ CRITICAL - BEGIN retroactively includes prior statements
# According to docs: statements before BEGIN are NOT committed at BEGIN,
# they are retroactively included in the explicit transaction
# =============================================================================

run_test "3-begin-retroactive-inclusion" \
    "TRUNCATE users;" \
    "INSERT INTO users VALUES (1, 'Alice'); BEGIN; INSERT INTO users VALUES (2, 'Bob'); INSERT INTO users VALUES (3, 'Charlie'); COMMIT;" \
    3 \
    "All 3 should commit TOGETHER at COMMIT (Alice retroactively included)"

# =============================================================================
# Test 4: ⚠️ CRITICAL - Failure after BEGIN rolls back EVERYTHING
# This is the corrected behavior - Alice should NOT survive
# =============================================================================

run_test "4-failure-after-begin-rollback-all" \
    "TRUNCATE users;" \
    "INSERT INTO users VALUES (1, 'Alice'); BEGIN; INSERT INTO users VALUES (2, 'Bob'); INSERT INTO users VALUES (2, 'Duplicate'); COMMIT;" \
    0 \
    "Alice should be ROLLED BACK (retroactively included in failed explicit txn)"

# =============================================================================
# Test 5: Failure BEFORE BEGIN (all rolled back)
# =============================================================================

run_test "5-failure-before-begin" \
    "TRUNCATE users;" \
    "INSERT INTO users VALUES (1, 'Alice'); INSERT INTO users VALUES (1, 'Duplicate'); BEGIN; INSERT INTO users VALUES (2, 'Bob'); COMMIT;" \
    0 \
    "All should be rolled back (error before BEGIN, implicit txn fails)"

# =============================================================================
# Test 6: Multiple BEGIN/COMMIT blocks - first commits, second fails
# =============================================================================

run_test "6-multiple-blocks-partial-commit" \
    "TRUNCATE users;" \
    "INSERT INTO users VALUES (1, 'Alice'); BEGIN; INSERT INTO users VALUES (2, 'Bob'); COMMIT; INSERT INTO users VALUES (3, 'Charlie'); BEGIN; INSERT INTO users VALUES (4, 'David'); INSERT INTO users VALUES (4, 'Duplicate'); COMMIT;" \
    2 \
    "First COMMIT saves Alice+Bob, second block (Charlie+David) rolled back"

# =============================================================================
# Test 7: Single statement autocommit (baseline)
# =============================================================================

echo ""
echo "Testing single-statement autocommit behavior..."

psql -d "$DB" -q -c "TRUNCATE users;"
psql -d "$DB" -q -c "INSERT INTO users VALUES (1, 'Alice');"
psql -d "$DB" -q -c "INSERT INTO users VALUES (1, 'Duplicate');" 2>/dev/null || true
psql -d "$DB" -q -c "INSERT INTO users VALUES (2, 'Bob');"

actual_count=$(psql -d "$DB" -t -A -c "SELECT count(*)::int FROM users;")

echo -n "Test: 7-single-statement-autocommit... "
if [ "$actual_count" -eq 2 ]; then
    echo -e "${GREEN}PASS${NC} (count=$actual_count)"
    ((PASS++))
else
    echo -e "${RED}FAIL${NC} (expected=2, actual=$actual_count)"
    echo "  Description: Alice and Bob survive, duplicate fails independently"
    ((FAIL++))
fi

# =============================================================================
# Test 8: DDL in implicit transaction (rolled back with DML failure)
# =============================================================================

psql -d "$DB" -q -c "DROP TABLE IF EXISTS t1;"

run_test "8-ddl-implicit-transaction-rollback" \
    "" \
    "CREATE TABLE t1 (id INT PRIMARY KEY); INSERT INTO t1 VALUES (1); INSERT INTO t1 VALUES (1);" \
    0 \
    "CREATE TABLE should be rolled back when INSERT fails (implicit txn)"

# Check if table exists
table_exists=$(psql -d "$DB" -t -A -c "SELECT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 't1');" 2>/dev/null)

echo -n "Test: 8b-ddl-table-rolled-back... "
if [ "$table_exists" = "f" ]; then
    echo -e "${GREEN}PASS${NC} (table does not exist)"
    ((PASS++))
else
    echo -e "${RED}FAIL${NC} (table exists but should have been rolled back)"
    ((FAIL++))
fi

# =============================================================================
# Test 9: Explicit transaction with DDL rollback
# =============================================================================

psql -d "$DB" -q -c "DROP TABLE IF EXISTS t1;"

echo -n "Test: 9-explicit-ddl-rollback... "
psql -d "$DB" -q -c "BEGIN; CREATE TABLE t1 (id INT PRIMARY KEY); INSERT INTO t1 VALUES (1); ROLLBACK;"

table_exists=$(psql -d "$DB" -t -A -c "SELECT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 't1');" 2>/dev/null)

if [ "$table_exists" = "f" ]; then
    echo -e "${GREEN}PASS${NC} (CREATE TABLE rolled back)"
    ((PASS++))
else
    echo -e "${RED}FAIL${NC} (table exists but should have been rolled back)"
    ((FAIL++))
fi

# =============================================================================
# Summary
# =============================================================================

echo ""
echo "=============================================="
echo "Test Summary"
echo "=============================================="
echo -e "Passed: ${GREEN}$PASS${NC}"
echo -e "Failed: ${RED}$FAIL${NC}"
echo ""

if [ $FAIL -eq 0 ]; then
    echo -e "${GREEN}All tests passed!${NC}"
    exit 0
else
    echo -e "${RED}Some tests failed!${NC}"
    echo ""
    echo -e "${YELLOW}NOTE: If Test 4 failed (Alice survived), your PostgreSQL version"
    echo -e "may behave differently than documented in PostgreSQL 17 protocol-flow.html.${NC}"
    exit 1
fi
