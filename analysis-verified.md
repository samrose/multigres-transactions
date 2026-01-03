# PostgreSQL 17 Transactions, Portals, and Multi-Statements Behavior Guide

This document covers the behavior of PostgreSQL transactions, prepared statements, portals, and multi-statements from an end-user perspective, with implementation details for building a sharded PostgreSQL solution.

**Verification Legend:**
- ✅ **DOCUMENTED**: Verified in official PostgreSQL 17 documentation (quote provided)
- 🔧 **SOURCE ONLY**: Verified in source code but NOT in official documentation
- ⚠️ **CORRECTED**: Original assertion was incorrect; corrected based on official documentation

---

## Table of Contents

1. [Multi-Statement Handling](#1-multi-statement-handling)
2. [Portal Behavior and Transactions](#2-portal-behavior-and-transactions)
3. [Prepared Statements](#3-prepared-statements)
4. [Key Scenarios for Sharding](#4-key-scenarios-for-sharding)

---

## 1. Multi-Statement Handling

### 1.1 How Multi-Statements Are Processed

When multiple SQL statements are sent in a single query string, PostgreSQL handles them as follows:

✅ **DOCUMENTED:**
> **Source ([protocol-flow.html](https://www.postgresql.org/docs/17/protocol-flow.html)):** "When a simple Query message contains more than one SQL statement (separated by semicolons), those statements are executed as a single transaction, unless explicit transaction control commands are included to force a different behavior."

> **Source ([protocol-flow.html](https://www.postgresql.org/docs/17/protocol-flow.html)):** "This behavior is implemented by running the statements in a multi-statement Query message in an implicit transaction block unless there is some explicit transaction block for them to run in. The main difference between an implicit transaction block and a regular one is that an implicit block is closed automatically at the end of the Query message, either by an implicit commit if there was no error, or an implicit rollback if there was an error."

🔧 **SOURCE ONLY** - Processing Flow (`src/backend/tcop/postgres.c:1088-1157`):
1. All statements are parsed at once via `pg_parse_query()`
2. System checks if `list_length(parsetree_list) > 1`
3. If multiple statements detected, an **implicit transaction block** is created via `BeginImplicitTransactionBlock()`
4. Each statement is processed sequentially in a loop
5. After the last statement, `EndImplicitTransactionBlock()` is called

### 1.2 Implicit vs Explicit Transactions

🔧 **SOURCE ONLY** - PostgreSQL tracks transaction state via `TBlockState` enum (`src/backend/access/transam/xact.c:155-182`):

```c
typedef enum TBlockState
{
    TBLOCK_DEFAULT,              /* idle */
    TBLOCK_STARTED,              /* running single-query transaction */
    TBLOCK_BEGIN,                /* starting transaction block */
    TBLOCK_INPROGRESS,           /* live transaction */
    TBLOCK_IMPLICIT_INPROGRESS,  /* live transaction after implicit BEGIN */
    TBLOCK_PARALLEL_INPROGRESS,  /* live transaction inside parallel worker */
    TBLOCK_END,                  /* COMMIT received */
    TBLOCK_ABORT,                /* failed xact, awaiting ROLLBACK */
    TBLOCK_ABORT_END,            /* failed xact, ROLLBACK received */
    TBLOCK_ABORT_PENDING,        /* live xact, ROLLBACK received */
    TBLOCK_PREPARE,              /* live xact, PREPARE received */
    /* subtransaction states ... */
} TBlockState;
```

#### Implicit Transaction Block (Auto-created for multi-statements)

🔧 **SOURCE ONLY:**
- **State**: `TBLOCK_IMPLICIT_INPROGRESS`
- **Activation**: Automatically when multiple statements in a single query
- **State Flow**: `TBLOCK_STARTED` → `TBLOCK_IMPLICIT_INPROGRESS` → `TBLOCK_STARTED` → `TBLOCK_DEFAULT`

✅ **DOCUMENTED** - Behavior:
> **Source ([protocol-flow.html](https://www.postgresql.org/docs/17/protocol-flow.html)):** "The main difference between an implicit transaction block and a regular one is that an implicit block is closed automatically at the end of the Query message, either by an implicit commit if there was no error, or an implicit rollback if there was an error."

#### Explicit Transaction Block (User-initiated via BEGIN)

✅ **DOCUMENTED:**
> **Source ([sql-begin.html](https://www.postgresql.org/docs/17/sql-begin.html)):** "BEGIN initiates a transaction block, that is, all statements after a BEGIN command will be executed in a single transaction until an explicit COMMIT or ROLLBACK is given."

🔧 **SOURCE ONLY:**
- **States**: `TBLOCK_BEGIN` → `TBLOCK_INPROGRESS`

### 1.3 Multi-Statement Examples with INSERT (Failure Scenarios)

Let's use a table for these examples:
```sql
CREATE TABLE users (id INT PRIMARY KEY, name TEXT);
```

---

#### Example 1: Successful Multi-Statement (Implicit Transaction)

**Query sent as single string**:
```sql
INSERT INTO users VALUES (1, 'Alice');
INSERT INTO users VALUES (2, 'Bob');
INSERT INTO users VALUES (3, 'Charlie');
```

✅ **DOCUMENTED:**
> **Source ([protocol-flow.html](https://www.postgresql.org/docs/17/protocol-flow.html)):** "When a simple Query message contains more than one SQL statement (separated by semicolons), those statements are executed as a single transaction..."

**What happens**:
1. PostgreSQL detects 3 statements → creates implicit transaction block
2. All three INSERTs execute within the implicit transaction
3. After last statement, implicit transaction commits

**Result**: All 3 rows committed. Table contains: `(1, Alice), (2, Bob), (3, Charlie)`

---

#### Example 2: Failure in Multi-Statement (Implicit Transaction Rollback)

**Query sent as single string**:
```sql
INSERT INTO users VALUES (1, 'Alice');
INSERT INTO users VALUES (2, 'Bob');
INSERT INTO users VALUES (1, 'Duplicate');  -- ERROR: duplicate key
INSERT INTO users VALUES (3, 'Charlie');    -- Never executed
```

✅ **DOCUMENTED:**
> **Source ([protocol-flow.html](https://www.postgresql.org/docs/17/protocol-flow.html)):** "In the event of an error, ErrorResponse is issued followed by ReadyForQuery. All further processing of the query string is aborted by ErrorResponse (even if more queries remained in it)."

> **Source ([protocol-flow.html](https://www.postgresql.org/docs/17/protocol-flow.html)):** "...either by an implicit commit if there was no error, or an implicit rollback if there was an error."

**What happens**:
1. PostgreSQL detects 4 statements → creates implicit transaction block
2. INSERT (1, Alice) succeeds
3. INSERT (2, Bob) succeeds
4. INSERT (1, Duplicate) **FAILS** with duplicate key violation
5. **Entire implicit transaction is rolled back**
6. INSERT (3, Charlie) is **never executed**

**Result**: Table is **EMPTY**. All previously successful INSERTs are rolled back.

**Key Point**: In an implicit transaction, failure of ANY statement rolls back ALL statements, including those that succeeded before the error.

---

#### ⚠️ CORRECTED: Example 3: Multi-Statement with BEGIN (Implicit → Explicit Transition)

**Query sent as single string**:
```sql
INSERT INTO users VALUES (1, 'Alice');
BEGIN;
INSERT INTO users VALUES (2, 'Bob');
INSERT INTO users VALUES (3, 'Charlie');
COMMIT;
```

⚠️ **CORRECTION**: The original document claimed BEGIN commits the preceding implicit transaction. This is **WRONG**.

✅ **DOCUMENTED:**
> **Source ([protocol-flow.html](https://www.postgresql.org/docs/17/protocol-flow.html)):** "Conversely, if a `BEGIN` appears in a multi-statement Query message, then it starts a regular transaction block that will only be terminated by an explicit `COMMIT` or `ROLLBACK`, whether that appears in this Query message or a later one. **If the `BEGIN` follows some statements that were executed as an implicit transaction block, those statements are not immediately committed; in effect, they are retroactively included into the new regular transaction block.**"

**What actually happens**:
1. PostgreSQL detects 5 statements → starts implicit transaction block
2. INSERT (1, Alice) executes in implicit transaction
3. **BEGIN detected**:
   - Alice is **NOT committed**
   - Alice is **retroactively included** into the new explicit transaction block
4. INSERT (2, Bob) executes in explicit transaction
5. INSERT (3, Charlie) executes in explicit transaction
6. COMMIT → **all three rows committed together**

**Result**: All 3 rows committed **together** at COMMIT. Alice was NOT committed separately before BEGIN.

---

#### ⚠️ CORRECTED: Example 4: Failure AFTER BEGIN (Entire Transaction Rolls Back)

**Query sent as single string**:
```sql
INSERT INTO users VALUES (1, 'Alice');
BEGIN;
INSERT INTO users VALUES (2, 'Bob');
INSERT INTO users VALUES (2, 'Duplicate');  -- ERROR: duplicate key
INSERT INTO users VALUES (3, 'Charlie');    -- Never executed
COMMIT;                                      -- Never executed
```

⚠️ **CORRECTION**: The original document claimed Alice survives because she was "committed before BEGIN." This is **WRONG**.

✅ **DOCUMENTED** (same quote as above):
> **Source ([protocol-flow.html](https://www.postgresql.org/docs/17/protocol-flow.html)):** "If the `BEGIN` follows some statements that were executed as an implicit transaction block, those statements are not immediately committed; in effect, they are retroactively included into the new regular transaction block."

**What actually happens**:
1. INSERT (1, Alice) in implicit transaction
2. BEGIN → Alice is **retroactively included** in explicit transaction (**NOT committed!**)
3. INSERT (2, Bob) in explicit transaction - succeeds
4. INSERT (2, Duplicate) **FAILS** with duplicate key
5. Explicit transaction enters aborted state
6. Remaining statements are skipped

**Result**: Table is **EMPTY**. Alice is rolled back because she was retroactively included in the explicit transaction that aborted.

---

#### Example 5: Failure BEFORE BEGIN (Nothing Committed)

**Query sent as single string**:
```sql
INSERT INTO users VALUES (1, 'Alice');
INSERT INTO users VALUES (1, 'Duplicate');  -- ERROR: duplicate key
BEGIN;                                       -- Never executed
INSERT INTO users VALUES (2, 'Bob');         -- Never executed
COMMIT;                                      -- Never executed
```

✅ **DOCUMENTED:**
> **Source ([protocol-flow.html](https://www.postgresql.org/docs/17/protocol-flow.html)):** "Remember that, regardless of any transaction control commands that may be present, execution of the Query message stops at the first error."

**What happens**:
1. INSERT (1, Alice) in implicit transaction - succeeds
2. INSERT (1, Duplicate) **FAILS** with duplicate key
3. **Entire implicit transaction is rolled back** (including Alice)
4. BEGIN, INSERT Bob, COMMIT are **never executed**

**Result**: Table is **EMPTY**. Alice was rolled back because she was in the implicit transaction that failed.

---

#### ⚠️ CORRECTED: Example 6: Multiple BEGIN/COMMIT Blocks in One Multi-Statement

**Query sent as single string**:
```sql
INSERT INTO users VALUES (1, 'Alice');
BEGIN;
INSERT INTO users VALUES (2, 'Bob');
COMMIT;
INSERT INTO users VALUES (3, 'Charlie');
BEGIN;
INSERT INTO users VALUES (4, 'David');
INSERT INTO users VALUES (4, 'Duplicate');  -- ERROR
COMMIT;
```

⚠️ **CORRECTION**: The original document's description was incorrect regarding when commits happen.

**What actually happens**:
1. INSERT Alice → in implicit transaction
2. BEGIN → Alice **retroactively included** in explicit transaction
3. INSERT Bob → in explicit transaction
4. COMMIT → **Alice AND Bob committed together**
5. INSERT Charlie → in new implicit transaction
6. BEGIN → Charlie **retroactively included** in new explicit transaction
7. INSERT David → in explicit transaction
8. INSERT Duplicate → **FAILS**
9. Explicit transaction aborted (Charlie and David rolled back)

**Result**: Table contains `(1, Alice), (2, Bob)`. Charlie and David are **rolled back**.

---

### 1.4 Summary: What Gets Committed on Failure?

⚠️ **CORRECTED TABLE**:

| Scenario | Statements Before Failure | Result |
|----------|---------------------------|--------|
| Pure multi-statement (no BEGIN) | All rolled back | Nothing committed |
| Failure before BEGIN | All rolled back | Nothing committed |
| Failure after BEGIN (no prior COMMIT) | All rolled back (retroactively included) | Nothing committed |
| Failure after COMMIT, then BEGIN, then error | First COMMIT's statements committed | Partial commit |

**Rule of Thumb** (⚠️ CORRECTED):
- **BEGIN does NOT act as a commit point** - statements before BEGIN are retroactively included
- **COMMIT acts as a commit point** for the current transaction
- Everything not yet committed when an error occurs is rolled back

---

### 1.5 Autocommit Behavior

✅ **DOCUMENTED:**
> **Source ([tutorial-transactions.html](https://www.postgresql.org/docs/17/tutorial-transactions.html)):** "PostgreSQL actually treats every SQL statement as being executed within a transaction. If you do not issue a `BEGIN` command, then each individual statement has an implicit `BEGIN` and (if successful) `COMMIT` wrapped around it."

> **Source ([sql-begin.html](https://www.postgresql.org/docs/17/sql-begin.html)):** "By default (without BEGIN), PostgreSQL executes transactions in "autocommit" mode, that is, each statement is executed in its own transaction and a commit is implicitly performed at the end of the statement (if execution was successful, otherwise a rollback is done)."

🔧 **SOURCE ONLY:**
- **State flow**: `TBLOCK_DEFAULT` → `TBLOCK_STARTED` → (execute) → `TBLOCK_DEFAULT`

**Single Statement Example**:
```sql
-- Sent as separate single statements (not multi-statement):
INSERT INTO users VALUES (1, 'Alice');  -- Commits immediately
INSERT INTO users VALUES (1, 'Dup');    -- Fails, but Alice is safe
INSERT INTO users VALUES (2, 'Bob');    -- Commits immediately
```
**Result**: Table contains `(1, Alice), (2, Bob)`. Each statement is its own transaction.

Client libraries (like psql, libpq) may implement autocommit mode at the application level.

### 1.6 Transaction Block State Machine

🔧 **SOURCE ONLY** - This state machine is derived from source code and is not in official documentation:

```
                                TBLOCK_DEFAULT (idle)
                                       │
                     ┌─────────────────┴─────────────────┐
                     │                                   │
            [Single Statement]                    [Multi-Statement]
                     │                                   │
                     ▼                                   ▼
              TBLOCK_STARTED ──────────────► TBLOCK_IMPLICIT_INPROGRESS
                     │                                   │
            [Statement completes]               [All statements done]
                     │                                   │
                     ▼                                   ▼
              TBLOCK_DEFAULT                      TBLOCK_STARTED
                                                        │
                                                        ▼
                                                  TBLOCK_DEFAULT

                          [With BEGIN]
                               │
                               ▼
                        TBLOCK_BEGIN
                               │
                   [CommitTransactionCommand]
                               │
                               ▼
                     TBLOCK_INPROGRESS
                          │         │
                    [COMMIT]     [error]
                          │         │
                          ▼         ▼
                    TBLOCK_END   TBLOCK_ABORT
                          │         │
                          ▼         ▼
                   TBLOCK_DEFAULT  [ROLLBACK] → TBLOCK_DEFAULT
```

### 1.7 DDL Statements and Transaction Behavior

#### Are DDL Statements Transactional?

**YES** - Unlike MySQL, PostgreSQL DDL is fully transactional. You can:
- Run `CREATE TABLE`, `ALTER TABLE`, `DROP TABLE` inside a transaction
- Roll back DDL changes with `ROLLBACK`
- Mix DDL and DML in the same transaction

🔧 **SOURCE ONLY** - No explicit documentation states "DDL is transactional," but it's demonstrated by DDL working in transaction blocks.

**Example: Transactional DDL**
```sql
BEGIN;
CREATE TABLE temp_users (id INT, name TEXT);
INSERT INTO temp_users VALUES (1, 'Alice');
ALTER TABLE temp_users ADD COLUMN email TEXT;
-- Changed my mind...
ROLLBACK;  -- Table creation, insert, and alter are ALL rolled back
```

**Result**: No `temp_users` table exists. Everything rolled back.

#### Do Any Statements Cause Implicit COMMIT?

**NO** - PostgreSQL does NOT have implicit commits like MySQL. Regular DDL does not auto-commit.

🔧 **SOURCE ONLY** - However, certain statements use `XACT_FLAGS_NEEDIMMEDIATECOMMIT` flag to **force immediate commit after execution** (`src/include/access/xact.h:114`).

#### Statements That CANNOT Run Inside a Transaction Block

✅ **DOCUMENTED** - These statements will **ERROR** if you try to run them inside BEGIN...COMMIT:

| Statement | Documentation Quote | Source |
|-----------|---------------------|--------|
| `CREATE DATABASE` | "CREATE DATABASE cannot be executed inside a transaction block." | [sql-createdatabase.html](https://www.postgresql.org/docs/17/sql-createdatabase.html) |
| `DROP DATABASE` | "DROP DATABASE cannot be executed inside a transaction block." | [sql-dropdatabase.html](https://www.postgresql.org/docs/17/sql-dropdatabase.html) |
| `CREATE TABLESPACE` | "CREATE TABLESPACE cannot be executed inside a transaction block." | [sql-createtablespace.html](https://www.postgresql.org/docs/17/sql-createtablespace.html) |
| `DROP TABLESPACE` | "DROP TABLESPACE cannot be executed inside a transaction block." | [sql-droptablespace.html](https://www.postgresql.org/docs/17/sql-droptablespace.html) |
| `ALTER SYSTEM` | "Also, since this command acts directly on the file system and cannot be rolled back, it is not allowed inside a transaction block or function." | [sql-altersystem.html](https://www.postgresql.org/docs/17/sql-altersystem.html) |
| `CREATE INDEX CONCURRENTLY` | "Another difference is that a regular CREATE INDEX command can be performed within a transaction block, but CREATE INDEX CONCURRENTLY cannot." | [sql-createindex.html](https://www.postgresql.org/docs/17/sql-createindex.html) |
| `REINDEX CONCURRENTLY` | "Another difference is that a regular REINDEX TABLE or REINDEX INDEX command can be performed within a transaction block, but REINDEX CONCURRENTLY cannot." | [sql-reindex.html](https://www.postgresql.org/docs/17/sql-reindex.html) |
| `DROP INDEX CONCURRENTLY` | "Also, regular DROP INDEX commands can be performed within a transaction block, but DROP INDEX CONCURRENTLY cannot." | [sql-dropindex.html](https://www.postgresql.org/docs/17/sql-dropindex.html) |
| `VACUUM` | "VACUUM cannot be executed inside a transaction block." | [sql-vacuum.html](https://www.postgresql.org/docs/17/sql-vacuum.html) |
| `CLUSTER` (all tables) | "This form of CLUSTER cannot be executed inside a transaction block." | [sql-cluster.html](https://www.postgresql.org/docs/17/sql-cluster.html) |
| `CLUSTER` (partitioned) | "CLUSTER on a partitioned table cannot be executed inside a transaction block." | [sql-cluster.html](https://www.postgresql.org/docs/17/sql-cluster.html) |
| `COMMIT PREPARED` | "This command cannot be executed inside a transaction block." | [sql-commit-prepared.html](https://www.postgresql.org/docs/17/sql-commit-prepared.html) |
| `ROLLBACK PREPARED` | "This command cannot be executed inside a transaction block." | [sql-rollback-prepared.html](https://www.postgresql.org/docs/17/sql-rollback-prepared.html) |
| `CREATE SUBSCRIPTION` (with slot) | "When creating a replication slot (the default behavior), CREATE SUBSCRIPTION cannot be executed inside a transaction block." | [sql-createsubscription.html](https://www.postgresql.org/docs/17/sql-createsubscription.html) |
| `DROP SUBSCRIPTION` (with slot) | "If a subscription is associated with a replication slot, then DROP SUBSCRIPTION cannot be executed inside a transaction block." | [sql-dropsubscription.html](https://www.postgresql.org/docs/17/sql-dropsubscription.html) |

🔧 **SOURCE ONLY** - These statements call `PreventInTransactionBlock()` internally.

**Example: Error when DDL inside transaction**
```sql
BEGIN;
CREATE DATABASE mydb;  -- ERROR: CREATE DATABASE cannot run inside a transaction block
```

#### Statements That REQUIRE a Transaction Block

✅ **DOCUMENTED** - These statements will **ERROR** if run outside BEGIN...COMMIT:

| Statement | Documentation Quote | Source |
|-----------|---------------------|--------|
| `LOCK TABLE` | "LOCK TABLE is useless outside a transaction block: the lock would remain held only to the completion of the statement. Therefore PostgreSQL reports an error if LOCK is used outside a transaction block." | [sql-lock.html](https://www.postgresql.org/docs/17/sql-lock.html) |
| `DECLARE CURSOR` (non-holdable) | "Unless WITH HOLD is specified, the cursor created by this command can only be used within the current transaction... Therefore PostgreSQL reports an error if such a command is used outside a transaction block." | [sql-declare.html](https://www.postgresql.org/docs/17/sql-declare.html) |
| `SAVEPOINT` | "Savepoints can only be established when inside a transaction block." | [sql-savepoint.html](https://www.postgresql.org/docs/17/sql-savepoint.html) |

🔧 **SOURCE ONLY** - `RELEASE SAVEPOINT` and `ROLLBACK TO SAVEPOINT` also require transaction blocks (via `RequireTransactionBlock()` in source).

**Example: Error when outside transaction**
```sql
LOCK TABLE users IN EXCLUSIVE MODE;
-- ERROR: LOCK TABLE can only be used in transaction blocks
```

#### DDL Failure Scenarios

**Scenario 1: DDL + DML in implicit transaction**
```sql
CREATE TABLE t1 (id INT PRIMARY KEY);
INSERT INTO t1 VALUES (1);
INSERT INTO t1 VALUES (1);  -- ERROR: duplicate key
```
**Result**: Table `t1` does NOT exist. CREATE TABLE rolled back with the failed INSERT.

**Scenario 2: DDL + DML with explicit transaction**
```sql
BEGIN;
CREATE TABLE t1 (id INT PRIMARY KEY);
INSERT INTO t1 VALUES (1);
COMMIT;

BEGIN;
DROP TABLE t1;
INSERT INTO nonexistent VALUES (1);  -- ERROR
-- Transaction now in ABORT state
COMMIT;  -- Actually does ROLLBACK
```
**Result**: Table `t1` EXISTS. The DROP was rolled back because the transaction aborted.

**Scenario 3: Non-transactional DDL attempt**
```sql
BEGIN;
INSERT INTO users VALUES (1, 'Alice');
CREATE DATABASE newdb;  -- ERROR: cannot run inside transaction
-- Transaction continues, but errored
ROLLBACK;
```
**Result**: Alice is rolled back. Database `newdb` was never created (statement errored before execution).

#### Summary: DDL Transaction Categories

| Category | Behavior | Examples |
|----------|----------|----------|
| **Fully Transactional** | Can run in transaction, can be rolled back | CREATE/ALTER/DROP TABLE, CREATE/DROP INDEX, CREATE/DROP VIEW |
| **Cannot Be In Transaction** | Must run outside BEGIN...COMMIT, auto-commits | CREATE/DROP DATABASE, CREATE/DROP TABLESPACE, VACUUM |
| **Requires Transaction** | Must run inside BEGIN...COMMIT | LOCK TABLE, SAVEPOINT, non-holdable CURSOR |

#### Implications for Sharding

For a sharding proxy:
1. **Most DDL is safe** - can participate in distributed transactions
2. **Watch for forbidden statements** - CREATE DATABASE, VACUUM, etc. cannot be part of multi-shard transactions
3. **CONCURRENTLY variants** - CREATE INDEX CONCURRENTLY cannot run in transaction, handle specially
4. **No implicit commits** - unlike MySQL, you don't need to track auto-commit behavior for DDL

---

## 2. Portal Behavior and Transactions

### 2.1 What is a Portal?

🔧 **SOURCE ONLY** - A **portal** is an abstraction representing the execution state of a running or runnable query (`src/include/utils/portal.h:115-206`).

✅ **DOCUMENTED:**
> **Source ([sql-declare.html](https://www.postgresql.org/docs/17/sql-declare.html)):** The internal server structure is called a "portal."

Portals support:
- SQL-level CURSORs (created with `DECLARE CURSOR`)
- Protocol-level portals (internal unnamed portals for extended query protocol)

🔧 **SOURCE ONLY** - Key Portal Fields:

| Field | Description |
|-------|-------------|
| `name` | Portal identifier |
| `status` | Current state (NEW, DEFINED, READY, ACTIVE, DONE, FAILED) |
| `queryDesc` | Query descriptor if executor is active |
| `holdStore` | Tuplestore for holdable cursors |
| `createSubid` | Creating subtransaction ID |
| `portalPos` | Current cursor position |
| `atStart`, `atEnd` | Position tracking flags |

### 2.2 Portal Execution Strategies

🔧 **SOURCE ONLY** - Determined by `ChoosePortalStrategy()` (`src/backend/tcop/pquery.c:208-316`):

| Strategy | Query Type | Partial Execution | Holdable |
|----------|-----------|-------------------|----------|
| `PORTAL_ONE_SELECT` | Single SELECT | **Yes** - Incremental | Yes |
| `PORTAL_ONE_RETURNING` | INSERT/UPDATE/DELETE with RETURNING | No - Materialized | No |
| `PORTAL_UTIL_SELECT` | EXPLAIN, SHOW | No - Materialized | No |
| `PORTAL_MULTI_QUERY` | Multiple queries | No - Run to completion | No |

### 2.3 Partial Execution with FETCH/maxrows

🔧 **SOURCE ONLY** - Only `PORTAL_ONE_SELECT` supports true partial execution.

**FETCH Flow** (`src/backend/tcop/pquery.c:847-988` - `PortalRunSelect`):
```
PortalRunSelect(Portal, forward, count, DestReceiver)
  - forward=true: Fetches count rows forward
  - forward=false: Fetches count rows backward (if SCROLL)
  - count=0: Fetch ALL remaining rows
  - Returns: nprocessed (rows actually fetched)
  - Updates: portal->portalPos, portal->atStart, portal->atEnd
```

🔧 **SOURCE ONLY** - Position Tracking:
```c
bool atStart;        // true at beginning
bool atEnd;          // true when no more rows available
uint64 portalPos;    // row number after fetching
```

### 2.4 Portals and Transaction Commit

🔧 **SOURCE ONLY** - On transaction commit (`src/backend/utils/mmgr/portalmem.c:676-772` - `PreCommit_Portals`):

| Portal Type | Behavior on COMMIT |
|-------------|-------------------|
| **WITH HOLD cursor** | Materialized to tuplestore, survives transaction |
| **Regular cursor** | **Dropped immediately** |
| **Portal from prior transaction** | Ignored (already held over) |

✅ **DOCUMENTED:**
> **Source ([sql-declare.html](https://www.postgresql.org/docs/17/sql-declare.html)):** "Unless WITH HOLD is specified, the cursor created by this command can only be used within the current transaction."

🔧 **SOURCE ONLY** - Holdable Cursor Materialization (`HoldPortal()` at line 636-662):
1. Results dumped into tuplestore
2. `createSubid` set to `InvalidSubTransactionId`
3. Executor closed, queryDesc freed
4. Cursor now accessed via tuplestore only

### 2.5 Portals and Transaction Abort

🔧 **SOURCE ONLY** - Two-phase cleanup:

**Phase 1: `AtAbort_Portals()`** (`src/backend/utils/mmgr/portalmem.c:780-851`):
- Mark READY portals as FAILED
- Run cleanup hooks
- Release cached plan references
- Portal structure kept (not deleted yet)
- Holdable portals from prior transactions preserved

**Phase 2: `AtCleanup_Portals()`** (`src/backend/utils/mmgr/portalmem.c:857-908`):
- Delete all portals created in aborted transaction
- Holdable portals (`InvalidSubTransactionId`) preserved

### 2.6 Opening Transaction While Portal is Partially Executed

**Yes, but with restrictions:**

✅ **DOCUMENTED:**
> **Source ([sql-declare.html](https://www.postgresql.org/docs/17/sql-declare.html)):** "Unless WITH HOLD is specified, the cursor created by this command can only be used within the current transaction... Therefore PostgreSQL reports an error if such a command is used outside a transaction block."

🔧 **SOURCE ONLY** - Constraint (`src/backend/commands/portalcmds.c:63-68`):
- Non-holdable cursors **MUST** be declared within an explicit transaction block
- `RequireTransactionBlock(isTopLevel, "DECLARE CURSOR")` enforces this

**Subtransaction Scenario (in procedures)**:
```sql
BEGIN
  DECLARE c CURSOR FOR SELECT ...;
  FETCH 1 FROM c;  -- Portal partially executed

  SAVEPOINT sp;
    -- Subtransaction started
    FETCH 1 FROM c;  -- Still works
  ROLLBACK TO sp;
    -- AtSubAbort_Portals() called
    -- Portal remains READY (not forced to FAILED)
END
```

### 2.7 Holdable vs Regular Cursors

✅ **DOCUMENTED:**

> **Source ([sql-declare.html](https://www.postgresql.org/docs/17/sql-declare.html)):** "WITH HOLD specifies that the cursor can continue to be used after the transaction that created it successfully commits."

> **Source ([sql-declare.html](https://www.postgresql.org/docs/17/sql-declare.html)):** "If WITH HOLD is specified and the transaction that created the cursor successfully commits, the cursor can continue to be accessed by subsequent transactions in the same session. (But if the creating transaction is aborted, the cursor is removed.)"

> **Source ([sql-declare.html](https://www.postgresql.org/docs/17/sql-declare.html)):** "In the current implementation, the rows represented by a held cursor are copied into a temporary file or memory area so that they remain available for subsequent transactions."

> **Source ([sql-declare.html](https://www.postgresql.org/docs/17/sql-declare.html)):** "WITH HOLD may not be specified when the query includes FOR UPDATE or FOR SHARE."

| Aspect | Regular Cursor | WITH HOLD Cursor |
|--------|----------------|------------------|
| Creation | In transaction | In transaction |
| At COMMIT | ✅ **DROPPED** | ✅ Materialized to tuplestore |
| createSubid | 🔧 Valid subxid | 🔧 `InvalidSubTransactionId` |
| Executor State | 🔧 Active | 🔧 Closed (tuplestore-based) |
| Post-Commit Access | ✅ **ERROR** | ✅ **ALLOWED** |
| FOR UPDATE/SHARE | ✅ Allowed | ✅ **Not allowed** |

### 2.8 Cursors and Savepoints

✅ **DOCUMENTED:**
> **Source ([sql-rollback-to.html](https://www.postgresql.org/docs/17/sql-rollback-to.html)):** "Cursors have somewhat non-transactional behavior with respect to savepoints. Any cursor that is opened inside a savepoint will be closed when the savepoint is rolled back. If a previously opened cursor is affected by a FETCH or MOVE command inside a savepoint that is later rolled back, the cursor remains at the position that FETCH left it pointing to (that is, the cursor motion caused by FETCH is not rolled back)."

---

## 3. Prepared Statements

### 3.1 Lifecycle of a Prepared Statement

🔧 **SOURCE ONLY** - Preparation (`src/backend/commands/prepare.c:56-136`):
1. `PrepareQuery()` entry point
2. Creates `CachedPlanSource` wrapping parse tree
3. Analyzes query with `pg_analyze_and_rewrite_varparams()`
4. Calls `StorePreparedStatement()` to save in hash table

🔧 **SOURCE ONLY** - Storage (`src/backend/commands/prepare.c:389-421`):
- Stored in `prepared_queries` hash table (per-backend, not shared)
- Hash key: statement name
- Value: `PreparedStatement` struct

🔧 **SOURCE ONLY** - Execution (`src/backend/commands/prepare.c:146-263`):
1. Fetch prepared statement from hash table
2. Create Portal via `CreateNewPortal()`
3. Get cached plan via `GetCachedPlan()`
4. Define portal with `PortalDefineQuery()`
5. Run via `PortalStart()` and `PortalRun()`
6. Drop portal after execution

🔧 **SOURCE ONLY** - Deallocation (`src/backend/commands/prepare.c:502-531`):
- `DEALLOCATE` removes from hash table
- `DropAllPreparedStatements()` on disconnect

### 3.2 Prepared Statements and Transactions

✅ **DOCUMENTED:**
> **Source ([sql-prepare.html](https://www.postgresql.org/docs/17/sql-prepare.html)):** "Prepared statements only last for the duration of the current database session. When the session ends, the prepared statement is forgotten, so it must be recreated before being used again."

**Key distinction**:
- **Prepared statements** (in hash table): **Survive transactions** (implied by "session duration")
- **Portals** (execution instances): **Transaction-bound**

For Extended Query Protocol:
- Parse/Bind/Execute all share a transaction
- Transaction doesn't commit until `Sync` message

### 3.3 Prepared Statements on Commit/Abort

| Event | Prepared Statement | Portal |
|-------|-------------------|--------|
| COMMIT | ✅ **Survives** | ✅ Dropped (unless holdable) |
| ABORT | ✅ **Survives** | ✅ Marked FAILED, then deleted |
| Disconnect | ✅ Dropped | Dropped |

### 3.4 Simple Query vs Extended Query Protocol

✅ **DOCUMENTED:**

> **Source ([protocol-flow.html](https://www.postgresql.org/docs/17/protocol-flow.html)):** "In the extended protocol, the frontend first sends a Parse message, which contains a textual query string, optionally some information about data types of parameter placeholders, and the name of a destination prepared-statement object..."

> **Source ([protocol-flow.html](https://www.postgresql.org/docs/17/protocol-flow.html)):** "Once a prepared statement exists, it can be readied for execution using a Bind message..."

> **Source ([protocol-flow.html](https://www.postgresql.org/docs/17/protocol-flow.html)):** "Once a portal exists, it can be executed using an Execute message..."

**Simple Query Protocol**:
```
Client: Query("SELECT * FROM users WHERE id = 1")
Server: [Parse] → [Plan] → [Execute] → RowDescription → DataRow* → CommandComplete → ReadyForQuery
```
- Single message for entire query
- Parse every time
- Implicit autocommit per statement

**Extended Query Protocol**:
```
Client: Parse("stmt1", "SELECT * FROM users WHERE id = $1", [INT4])
Server: ParseComplete

Client: Bind("portal1", "stmt1", [1])
Server: BindComplete

Client: Execute("portal1", max_rows=10)
Server: DataRow* → CommandComplete (or PortalSuspended if more rows)

Client: Sync
Server: ReadyForQuery
```
- Separate phases
- Parse once, execute many times
- Transaction spans until Sync

✅ **DOCUMENTED:**
> **Source ([protocol-flow.html](https://www.postgresql.org/docs/17/protocol-flow.html)):** "At completion of each series of extended-query messages, the frontend should issue a Sync message. This parameterless message causes the backend to close the current transaction if it's not inside a BEGIN/COMMIT transaction block ("close" meaning to commit if no error, or roll back if error)."

**Key Differences**:

| Aspect | Simple Protocol | Extended Protocol |
|--------|----------------|-------------------|
| Phases | Single Query | Parse → Bind → Execute → Sync |
| Reuse | Parse every time | Parse once, execute many |
| Parameters | Text substitution | Type-checked at Bind |
| Transaction | Per-statement | Spans until Sync |
| Portal | Implicit | Explicit management |

### 3.5 Prepared Statement to Portal Relationship

```
PREPARE stmt AS SELECT ...
       │
       ▼
┌──────────────────────────┐
│  prepared_queries hash   │
│  ├─ CachedPlanSource     │
│  └─ Per-backend          │
└──────────────────────────┘
       │
       │ Bind (creates portal)
       ▼
┌──────────────────────────┐
│      Portal              │
│  ├─ prepStmtName         │──► points back to prepared statement
│  ├─ cplan                │──► CachedPlan reference
│  ├─ portalParams         │──► bound parameters
│  └─ status               │──► READY/ACTIVE/DONE
└──────────────────────────┘
       │
       │ Execute (runs query)
       ▼
   Returns rows
```

### 3.6 Mixing Simple and Extended Query Protocols

What happens when a client switches between protocols mid-stream? This is important for sharding proxies that may need to inject queries.

#### Key Distinction: Named vs Unnamed Resources

✅ **DOCUMENTED:**
> **Source ([protocol-flow.html](https://www.postgresql.org/docs/17/protocol-flow.html)):** "If successfully created, a named portal object lasts till the end of the current transaction, unless explicitly destroyed. An unnamed portal is destroyed at the end of the transaction, or as soon as the next Bind statement specifying the unnamed portal as destination is issued."

🔧 **SOURCE ONLY** - Behavior on simple Query arrival:

| Resource | On Simple Query Arrival | Behavior |
|----------|------------------------|----------|
| **Unnamed Portal** | **DROPPED** silently | Replaced by new unnamed portal |
| **Unnamed Prepared Stmt** | **DROPPED** | `drop_unnamed_stmt()` called |
| **Named Portals** | **PRESERVED** | Continue to exist, can resume |
| **Named Prepared Stmts** | **PRESERVED** | Continue to exist, can reuse |

🔧 **SOURCE ONLY** - CreatePortal with allowDup/dupSilent (`src/backend/tcop/postgres.c`):
```c
if (portal_name[0] == '\0')
    portal = CreatePortal(portal_name, true, true);   /* allowDup=true, dupSilent=true */
else
    portal = CreatePortal(portal_name, false, false);
```

---

#### Scenario 1: Unnamed Portal Partially Executed, Then Simple Query

**Extended Protocol**:
```
Parse("", "SELECT * FROM large_table", [])      -- Unnamed statement
Bind("", "", [])                                 -- Unnamed portal
Execute("", 10)                                  -- Fetch 10 rows, SUSPENDED
```

**Then Simple Protocol**:
```
Query("INSERT INTO users VALUES (1, 'Alice')")
```

🔧 **SOURCE ONLY** - What happens (`src/backend/tcop/postgres.c:1059, 1220`):
1. `exec_simple_query()` is called
2. `drop_unnamed_stmt()` drops the unnamed prepared statement
3. New unnamed portal is created with `CreatePortal("", true, true)` - the `allowDup=true, dupSilent=true` parameters cause **silent replacement** of existing unnamed portal
4. The partially executed SELECT portal is **DESTROYED** without completing
5. INSERT executes and commits
6. Original SELECT results are **LOST**

**Result**: Unnamed portal is gone. Remaining rows from SELECT are never retrieved.

---

#### Scenario 2: Named Portal Partially Executed, Then Simple Query

**Extended Protocol**:
```
Parse("stmt1", "SELECT * FROM large_table", [])
Bind("portal1", "stmt1", [])                     -- Named portal
Execute("portal1", 10)                           -- Fetch 10 rows, SUSPENDED
```

**Then Simple Protocol**:
```
Query("INSERT INTO users VALUES (1, 'Alice')")
```

🔧 **SOURCE ONLY** - What happens:
1. `exec_simple_query()` is called
2. `drop_unnamed_stmt()` only affects **unnamed** statement - "stmt1" is safe
3. New unnamed portal created for INSERT (doesn't affect "portal1")
4. INSERT executes and commits
5. Named portal "portal1" **STILL EXISTS** in PORTAL_READY state

**Then Extended Protocol again**:
```
Execute("portal1", 10)                           -- Fetch next 10 rows - WORKS!
```

**Result**: Named portals survive simple query interruptions.

---

#### Scenario 3: Simple Query BEGIN During Extended Protocol Transaction

**Extended Protocol** (transaction started implicitly):
```
Parse("s1", "INSERT INTO users VALUES ($1, $2)", [])
Bind("p1", "s1", [1, "Alice"])
Execute("p1", 0)                                 -- INSERT executed, no Sync yet
```

**Then Simple Protocol**:
```
Query("BEGIN")                                   -- What happens?
```

🔧 **SOURCE ONLY** - What happens (`src/backend/tcop/postgres.c:1045-1051`):
1. Extended protocol has started a transaction (via `start_xact_command()`)
2. Simple query also calls `start_xact_command()`
3. BEGIN processes and... **WARNING or unexpected behavior**

**The issue**: Extended protocol expects transaction to commit at Sync. Simple query's BEGIN:
- If in `TBLOCK_STARTED`: Converts to explicit transaction block
- If in `TBLOCK_IMPLICIT_INPROGRESS`: Converts implicit to explicit

**After this**:
```
Query("COMMIT")                                  -- Commits the transaction
```

Now the extended protocol's work (Alice INSERT) is committed, but:
- Client never received Sync/ReadyForQuery for extended protocol
- Protocol state may be inconsistent

**Result**: Transaction control via simple query affects extended protocol's pending work.

---

#### Scenario 4: Simple Query INSERT During Suspended Portal

**Extended Protocol**:
```
Parse("", "SELECT * FROM users FOR UPDATE", [])
Bind("", "", [])
Execute("", 5)                                   -- Lock 5 rows, SUSPENDED
```

**Then Simple Protocol**:
```
Query("INSERT INTO users VALUES (100, 'New')")
```

🔧 **SOURCE ONLY** - What happens:
1. Unnamed portal is **DESTROYED** (silent replacement)
2. The `FOR UPDATE` locks on the 5 rows are **STILL HELD** (transaction still open)
3. INSERT executes in the **SAME TRANSACTION**
4. Simple query commits → all locks released, INSERT committed

**Critical**: The SELECT FOR UPDATE's locks persist even though the portal was destroyed!

---

#### Scenario 5: Error Recovery and Protocol Mixing

**Extended Protocol with Error**:
```
Parse("s1", "INSERT INTO users VALUES ($1)", [])
Bind("p1", "s1", ["not_an_int"])                 -- Type error
```

**Server Response**:
```
ErrorResponse
```

✅ **DOCUMENTED:**
> **Source ([protocol-flow.html](https://www.postgresql.org/docs/17/protocol-flow.html)):** "The purpose of Sync is to provide a resynchronization point for error recovery. When an error is detected while processing any extended-query message, the backend issues ErrorResponse, then reads and discards messages until a Sync is reached, then issues ReadyForQuery and returns to normal message processing."

🔧 **SOURCE ONLY** - What happens (`src/backend/tcop/postgres.c:4516-4517`):
1. `ignore_till_sync = true` is set
2. Server ignores ALL subsequent extended protocol messages until Sync
3. But simple query messages are **STILL PROCESSED** (🔧 SOURCE ONLY - needs verification)

**Simple Protocol**:
```
Query("SELECT 1")                                -- This WORKS!
```

**Result**: Simple query can "escape" the error state that blocks extended protocol.

---

#### Summary: Protocol Mixing Rules

| Situation | Unnamed Portal | Named Portal | Transaction |
|-----------|---------------|--------------|-------------|
| Simple query arrives | 🔧 Destroyed | ✅ Preserved | Continues |
| Simple BEGIN | 🔧 Destroyed | ✅ Preserved | Converts to explicit |
| Simple COMMIT | 🔧 Destroyed | Destroyed (txn ends) | Committed |
| Simple ROLLBACK | 🔧 Destroyed | Destroyed (txn ends) | Aborted |
| Error + ignore_till_sync | 🔧 Destroyed on next use | ✅ Preserved until Sync | Depends on error |

---

#### Implications for Sharding Proxy

1. **Injecting queries**: If proxy needs to inject a query (e.g., `SET search_path`), use simple protocol - but be aware it destroys unnamed portals

2. **Named portals are safer**: Named portals survive protocol mixing - prefer them for long-running cursors

3. **Transaction state**: Simple query BEGIN/COMMIT affects the entire connection's transaction state, including pending extended protocol work

4. **Error recovery**: A simple query can execute even when extended protocol is in `ignore_till_sync` state (🔧 SOURCE ONLY)

5. **Lock preservation**: Destroying a portal does NOT release locks - they're held until transaction ends

**Recommendation for proxy**: Track whether unnamed portals are suspended before injecting simple queries. If so, either:
- Use extended protocol for injected queries
- Accept that the unnamed portal will be destroyed
- Force client to use named portals for resumable cursors

---

## 4. Key Scenarios for Sharding

### 4.1 Multi-Statement Sharding Implications

⚠️ **CORRECTED** based on documentation findings:

**Scenario 1: Pure multi-statement across shards**
```sql
INSERT INTO users VALUES (1, 'Alice');   -- Routes to shard A (user_id % 2 = 1)
INSERT INTO users VALUES (2, 'Bob');     -- Routes to shard B (user_id % 2 = 0)
INSERT INTO users VALUES (3, 'Charlie'); -- Routes to shard A
```
- All INSERTs run in implicit transaction
- **Sharding concern**: Must coordinate implicit transaction across multiple shards
- **On success**: All shards must commit atomically (2PC or similar)
- **On failure**: All shards must rollback (even those that succeeded locally)

**Scenario 2: Multi-statement with BEGIN across shards** (⚠️ CORRECTED)
```sql
INSERT INTO users VALUES (1, 'Alice');   -- Implicit txn, shard A
BEGIN;
INSERT INTO users VALUES (2, 'Bob');     -- Explicit txn, shard B
INSERT INTO users VALUES (3, 'Charlie'); -- Explicit txn, shard A
COMMIT;
```
- ⚠️ **CORRECTED**: Alice is **retroactively included** in explicit transaction, NOT committed at BEGIN
- All three committed together at COMMIT
- **Sharding concern**:
  - Track that BEGIN includes prior statements in new transaction
  - All shards participating before and after BEGIN are in same transaction
  - On COMMIT → coordinate 2PC across all shards

**Scenario 3: Failure in multi-statement (all shards rollback)**
```sql
INSERT INTO users VALUES (1, 'Alice');   -- Shard A - succeeds locally
INSERT INTO users VALUES (2, 'Bob');     -- Shard B - succeeds locally
INSERT INTO users VALUES (1, 'Dup');     -- Shard A - FAILS (duplicate)
INSERT INTO users VALUES (3, 'Charlie'); -- Never executed
```
- Error on shard A after Alice and Bob succeeded locally
- **Result**: Alice AND Bob must be rolled back (implicit transaction)
- **Sharding concern**: Must propagate abort to ALL shards, not just the failing one

**Scenario 4: Failure after BEGIN** (⚠️ CORRECTED)
```sql
INSERT INTO users VALUES (1, 'Alice');   -- Implicit txn, shard A
BEGIN;                                    -- Alice retroactively included
INSERT INTO users VALUES (2, 'Bob');     -- Explicit txn, shard B
INSERT INTO users VALUES (2, 'Dup');     -- Shard B - FAILS (duplicate)
COMMIT;                                   -- Never executed
```
- ⚠️ **CORRECTED**: Alice is NOT committed at BEGIN
- Alice AND Bob rolled back (all in same explicit transaction)
- **Result**: Both shards empty
- **Sharding concern**: BEGIN does NOT act as commit point - proxy must NOT commit shards at BEGIN

**Scenario 5: Cross-shard transaction atomicity challenge**
```sql
BEGIN;
INSERT INTO users VALUES (1, 'Alice');   -- Shard A
INSERT INTO orders VALUES (100, 1);      -- Shard C (orders table)
INSERT INTO users VALUES (1, 'Dup');     -- Shard A - FAILS
COMMIT;
```
- Alice and Order both need to rollback
- **Sharding concern**: Explicit transaction touched shards A and C before failure
- Must ensure Order on shard C is also rolled back

### 4.2 Portal Sharding Implications

**Scenario 1: FETCH with row limit across shards**
```sql
BEGIN;
DECLARE c CURSOR FOR SELECT * FROM distributed_table;
FETCH 100 FROM c;  -- Get first 100
FETCH 100 FROM c;  -- Get next 100
COMMIT;
```
- **Challenge**: Must maintain portal state (position) across shards
- **Solution**: Could materialize results or track per-shard positions

**Scenario 2: Holdable cursor**
```sql
BEGIN;
DECLARE c CURSOR WITH HOLD FOR SELECT * FROM users;
FETCH 10 FROM c;
COMMIT;  -- Cursor survives
FETCH 10 FROM c;  -- Still works
```
- **Challenge**: Holdable cursors must materialize results at commit time
- **Solution**: Proxy must implement tuplestore-like behavior for held results

**Scenario 3: Transaction abort with open cursor**
```sql
BEGIN;
DECLARE c CURSOR FOR SELECT * FROM users;
FETCH 5 FROM c;
ROLLBACK;  -- Cursor destroyed
```
- **Behavior**: Portal marked FAILED, then cleaned up
- **Sharding concern**: Must clean up portal state on all shards

### 4.3 Prepared Statement Sharding Implications

**Scenario 1: Prepared statement spanning shards**
```sql
PREPARE get_user(int) AS SELECT * FROM users WHERE id = $1;
EXECUTE get_user(1);  -- Routes to shard A
EXECUTE get_user(2);  -- Routes to shard B
```
- **Challenge**: Same prepared statement, different target shards
- **Solution**: Store statement at proxy level, determine shard at Bind/Execute time

**Scenario 2: Extended protocol transaction**
```
Parse("s1", "INSERT INTO users VALUES ($1, $2)", ...)
Bind("p1", "s1", [1, "Alice"])
Execute("p1", 0)
Bind("p2", "s1", [2, "Bob"])  -- Reuse statement, new portal
Execute("p2", 0)
Sync  -- Transaction commits here
```
- **Behavior**: Both inserts in same transaction, commit at Sync
- **Sharding concern**: Must hold transaction open across all shards until Sync

**Scenario 3: Portal suspension**
```
Parse("s1", "SELECT * FROM large_table", ...)
Bind("p1", "s1", [])
Execute("p1", 100)  -- Get 100 rows, portal suspended
Execute("p1", 100)  -- Get next 100 rows
Execute("p1", 0)    -- Get remaining rows
Sync
```
- **Behavior**: Portal stays open between Execute calls
- **Sharding concern**: Must track portal suspension state, ensure same shard routing

### 4.4 State Tracking Requirements for Sharding Proxy

| State | Scope | Survives Transaction | Notes |
|-------|-------|---------------------|-------|
| Implicit transaction | Connection | No | Created for multi-statements |
| Explicit transaction | Connection | No | Created by BEGIN |
| Portal | Transaction | No (unless WITH HOLD) | Execution state |
| Holdable cursor | Connection | **Yes** | Materialized at commit |
| Prepared statement | Connection | **Yes** | Stored in hash table |
| Subtransaction | Transaction | Nested | SAVEPOINTs |

### 4.5 Transaction State Machine for Proxy

⚠️ **CORRECTED** - BEGIN does NOT cause implicit commit:

```
IDLE
 │
 ├─[Single statement]─────► IMPLICIT_SINGLE ──► IDLE (auto-commit)
 │
 ├─[Multi-statement start]─► IMPLICIT_MULTI ───┬──► IDLE (auto-commit at end)
 │                               │             │
 │                               │ [BEGIN]     │ [error]
 │                               ▼             ▼
 │                    (retroactively include)  ABORTED
 │                               │
 │                               ▼
 │                          EXPLICIT ──────────► ABORTED
 │
 └─[BEGIN]────────────────► EXPLICIT
                               │
                    ┌──────────┼──────────┐
                    │          │          │
               [COMMIT]   [ROLLBACK]   [error]
                    │          │          │
                    ▼          ▼          ▼
                  IDLE       IDLE      ABORTED
                                          │
                                     [ROLLBACK]
                                          │
                                          ▼
                                        IDLE
```

---

## 5. Code References Summary

🔧 **SOURCE ONLY** - These are implementation details not guaranteed by documentation:

| Component | File:Line | Purpose |
|-----------|-----------|---------|
| Multi-statement processing | `postgres.c:1088-1157` | `exec_simple_query()` loop |
| Transaction block states | `xact.c:155-182` | `TBlockState` enum |
| Implicit transaction | `xact.c:4275-4290` | `BeginImplicitTransactionBlock()` |
| Portal structure | `portal.h:115-206` | `PortalData` struct |
| Portal strategies | `pquery.c:208-316` | `ChoosePortalStrategy()` |
| Partial fetch | `pquery.c:847-988` | `PortalRunSelect()` |
| Portal commit handling | `portalmem.c:676-772` | `PreCommit_Portals()` |
| Portal abort handling | `portalmem.c:780-851` | `AtAbort_Portals()` |
| Holdable cursor | `portalcmds.c:315-496` | `PersistHoldablePortal()` |
| Prepared statement storage | `prepare.c:389-421` | `StorePreparedStatement()` |
| Extended protocol Parse | `postgres.c:1395-1622` | `exec_parse_message()` |
| Extended protocol Bind | `postgres.c:1630-2093` | `exec_bind_message()` |
| Extended protocol Execute | `postgres.c:2101-2358` | `exec_execute_message()` |

---

## Appendix: Documentation References

**Official PostgreSQL 17 Documentation URLs:**

- **Transactions**: https://www.postgresql.org/docs/17/tutorial-transactions.html
- **BEGIN**: https://www.postgresql.org/docs/17/sql-begin.html
- **Protocol Flow**: https://www.postgresql.org/docs/17/protocol-flow.html
- **DECLARE CURSOR**: https://www.postgresql.org/docs/17/sql-declare.html
- **FETCH**: https://www.postgresql.org/docs/17/sql-fetch.html
- **PREPARE**: https://www.postgresql.org/docs/17/sql-prepare.html
- **LOCK**: https://www.postgresql.org/docs/17/sql-lock.html
- **SAVEPOINT**: https://www.postgresql.org/docs/17/sql-savepoint.html
- **ROLLBACK TO**: https://www.postgresql.org/docs/17/sql-rollback-to.html
- **CREATE DATABASE**: https://www.postgresql.org/docs/17/sql-createdatabase.html
- **DROP DATABASE**: https://www.postgresql.org/docs/17/sql-dropdatabase.html
- **CREATE TABLESPACE**: https://www.postgresql.org/docs/17/sql-createtablespace.html
- **DROP TABLESPACE**: https://www.postgresql.org/docs/17/sql-droptablespace.html
- **ALTER SYSTEM**: https://www.postgresql.org/docs/17/sql-altersystem.html
- **VACUUM**: https://www.postgresql.org/docs/17/sql-vacuum.html
- **CLUSTER**: https://www.postgresql.org/docs/17/sql-cluster.html
- **CREATE INDEX**: https://www.postgresql.org/docs/17/sql-createindex.html
- **DROP INDEX**: https://www.postgresql.org/docs/17/sql-dropindex.html
- **REINDEX**: https://www.postgresql.org/docs/17/sql-reindex.html
- **CREATE SUBSCRIPTION**: https://www.postgresql.org/docs/17/sql-createsubscription.html
- **DROP SUBSCRIPTION**: https://www.postgresql.org/docs/17/sql-dropsubscription.html
- **COMMIT PREPARED**: https://www.postgresql.org/docs/17/sql-commit-prepared.html
- **ROLLBACK PREPARED**: https://www.postgresql.org/docs/17/sql-rollback-prepared.html
