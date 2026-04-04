---
name: simplemigrations
description: Use when working with database migrations in Go using simplemigrations, creating migration adapters, integrating migrations with dbx-generated code, or setting up schema versioning. Covers MigrateToLatest, MigrateToLatestWithSchema, and the adapter pattern for dbx integration.
argument-hint: "[migrate|adapter|dbx-integration|schema-version|help]"
---

# simplemigrations - Database Migration Library

`simplemigrations` helps you run ordered database migrations in Go while staying agnostic to the underlying transport. You provide transactional primitives and the package coordinates schema upgrades.

## Installation

```bash
go get github.com/amwolff/simplemigrations
```

## Core Concepts

### Interfaces

```go
// MinimalTx executes migration queries and manages schema versions.
// This is the minimum interface needed for MigrateToLatest.
type MinimalTx interface {
    ExecContext(ctx context.Context, query string, args ...any) error
    LatestSchemaVersion(ctx context.Context) (int, error)
    CreateSchema(ctx context.Context, version int, comment string) error
}

// Tx wraps MinimalTx with commit and rollback semantics.
type Tx interface {
    MinimalTx
    Commit() error
    Rollback() error
}

// DB opens transactional connections and reports the active dialect.
// Required for MigrateToLatestWithSchema.
type DB interface {
    Dialect() Dialect
    Open(ctx context.Context) (Tx, error)
    ExecContext(ctx context.Context, query string, args ...any) error
}

// Logger records diagnostic messages about migration progress.
type Logger interface {
    Debug(ctx context.Context, msg string, args ...any)
    Info(ctx context.Context, msg string, args ...any)
    Warn(ctx context.Context, msg string, args ...any)
}
```

### Migration Structure

```go
type Migration struct {
    Queries        []string  // SQL statements to execute
    Version        int       // Unique version number (must be ordered)
    VersionComment string    // Description of the migration
}
```

## Primary Functions

### MigrateToLatest

General entry point for running migrations within a provided transaction:

```go
func MigrateToLatest(
    ctx context.Context,
    log Logger,
    tx MinimalTx,
    migrations []Migration,
    freshDB bool,  // Skip version check if true (new database)
) error
```

### MigrateToLatestWithSchema

PostgreSQL-specific function that can create isolated schemas:

```go
func MigrateToLatestWithSchema(
    ctx context.Context,
    log Logger,
    db DB,
    schema string,      // Schema name (empty = default schema)
    temporary bool,     // If true, cleanup will drop the schema
    migrations []Migration,
    shouldRetry func(err error) bool,  // Retry predicate for transient errors
) (cleanup func() error, err error)
```

### Helper Functions

```go
// RollbackUnlessCommitted safely rolls back if not already committed
func RollbackUnlessCommitted(ctx context.Context, log Logger, tx Tx) error

// SetSearchPathTo changes PostgreSQL search_path within a transaction
func SetSearchPathTo(ctx context.Context, tx MinimalTx, schema string) error

// NopLogger discards all log messages
var _ Logger = NopLogger{}
```

## Integration with DBX

The optimal pattern for combining simplemigrations with dbx-generated code.

### Step 1: Define schema_version Model in DBX

Add this to your `.dbx` file:

```dbx
model schema_version (
    key number

    field number  int
    field comment text
)

create schema_version ( )

read first (
    select schema_version.number
    orderby desc schema_version.number
)
```

This generates:
- `Create_SchemaVersion(ctx, number, comment) (*SchemaVersion, error)`
- `First_SchemaVersion_Number_OrderBy_Desc_Number(ctx) (*Number_Row, error)`

### Step 2: Generate DBX Code

```bash
dbx golang -p yourpkg -d pgx schema.dbx .
dbx schema -d pgx schema.dbx .
```

Or use go:generate:

```go
//go:generate dbx golang -p yourpkg -d pgx schema.dbx .
//go:generate dbx schema -d pgx schema.dbx .
```

### Step 3: Create Adapter Types

```go
package yourpkg

import (
    "context"

    "github.com/amwolff/simplemigrations"
)

// Ensure interface compliance
var (
    _ simplemigrations.DB = (*DBAdapter)(nil)
    _ simplemigrations.Tx = (*TxAdapter)(nil)
)

// DBAdapter wraps dbx-generated DB to implement simplemigrations.DB
type DBAdapter struct {
    db *DB  // dbx-generated type
}

func NewDBAdapter(db *DB) *DBAdapter {
    return &DBAdapter{db: db}
}

func (a *DBAdapter) Dialect() simplemigrations.Dialect {
    return simplemigrations.DialectPostgres
}

func (a *DBAdapter) Open(ctx context.Context) (simplemigrations.Tx, error) {
    tx, err := a.db.Open(ctx)
    if err != nil {
        return nil, err
    }
    return &TxAdapter{tx: tx}, nil
}

func (a *DBAdapter) ExecContext(ctx context.Context, query string, args ...any) error {
    _, err := a.db.ExecContext(ctx, query, args...)
    return err
}

// TxAdapter wraps dbx-generated Tx to implement simplemigrations.Tx
type TxAdapter struct {
    tx *Tx  // dbx-generated type
}

func (a *TxAdapter) ExecContext(ctx context.Context, query string, args ...any) error {
    _, err := a.tx.ExecContext(ctx, query, args...)
    return err
}

func (a *TxAdapter) LatestSchemaVersion(ctx context.Context) (int, error) {
    row, err := a.tx.First_SchemaVersion_Number_OrderBy_Desc_Number(ctx)
    if err != nil {
        return 0, err
    }
    if row == nil {
        return 0, nil  // No versions yet
    }
    return row.Number, nil
}

func (a *TxAdapter) CreateSchema(ctx context.Context, version int, comment string) error {
    _, err := a.tx.Create_SchemaVersion(ctx,
        SchemaVersion_Number(version),
        SchemaVersion_Comment(comment),
    )
    return err
}

func (a *TxAdapter) Commit() error {
    return a.tx.Commit()
}

func (a *TxAdapter) Rollback() error {
    return a.tx.Rollback()
}
```

### Step 4: Define Migrations

```go
var Migrations = []simplemigrations.Migration{
    {
        // Version 1: Create schema_versions table (matches dbx model)
        Queries: []string{`
            CREATE TABLE schema_versions (
                number integer NOT NULL,
                comment text NOT NULL,
                PRIMARY KEY ( number )
            )`},
        Version:        1,
        VersionComment: "initial version (schema_versions table)",
    },
    {
        // Version 2: Create your application tables
        Queries: []string{`
            CREATE TABLE users (
                id serial PRIMARY KEY,
                email varchar(255) NOT NULL UNIQUE,
                created_at timestamp NOT NULL DEFAULT NOW()
            )`},
        Version:        2,
        VersionComment: "create users table",
    },
    {
        // Version 3: Add columns, modify schema, etc.
        Queries: []string{
            "ALTER TABLE users ADD COLUMN name varchar(100)",
            "CREATE INDEX idx_users_email ON users(email)",
        },
        Version:        3,
        VersionComment: "add name column and email index",
    },
}
```

### Step 5: Run Migrations

```go
func SetupDatabase(ctx context.Context, source string) (*DB, func() error, error) {
    db, err := Open("pgx", source)
    if err != nil {
        return nil, nil, err
    }

    adapter := NewDBAdapter(db)
    log := simplemigrations.NopLogger{}  // Or your logger

    // For production: use default schema
    cleanup, err := simplemigrations.MigrateToLatestWithSchema(
        ctx, log, adapter,
        "",     // empty = default schema
        false,  // not temporary
        Migrations,
        func(err error) bool { return false },  // no retries
    )
    if err != nil {
        db.Close()
        return nil, nil, err
    }

    return db, cleanup, nil
}

// For tests: use isolated temporary schema
func SetupTestDatabase(ctx context.Context, t *testing.T, source, schemaName string) (*DB, func() error, error) {
    db, err := Open("pgx", source)
    if err != nil {
        return nil, nil, err
    }

    adapter := NewDBAdapter(db)
    log := simplemigrations.NopLogger{}

    retryCount := 0
    shouldRetry := func(err error) bool {
        // Retry on "undefined table" errors (fresh schema)
        if retryCount > 3 {
            return false
        }
        retryCount++
        return true
    }

    cleanup, err := simplemigrations.MigrateToLatestWithSchema(
        ctx, log, adapter,
        schemaName,  // isolated schema
        true,        // temporary = cleanup drops schema
        Migrations,
        shouldRetry,
    )
    if err != nil {
        db.Close()
        return nil, nil, err
    }

    return db, cleanup, nil
}
```

## Migration Best Practices

1. **First migration creates schema_versions table** - Must match your dbx model definition
2. **Migrations are ordered by version** - The library validates this automatically
3. **Each migration has unique version** - Duplicates cause errors
4. **Migrations are idempotent when re-run** - Already-applied versions are skipped
5. **Use multiple queries per migration** - For complex changes that must succeed together
6. **Keep migrations immutable** - Never modify a migration after it's been applied
7. **Test with temporary schemas** - Use `MigrateToLatestWithSchema` with `temporary=true`

## Retry Logic for Fresh Databases

When using `MigrateToLatestWithSchema`, provide a retry function for handling fresh database scenarios:

```go
func shouldRetry(err error) bool {
    // PostgreSQL error code 42P01 = undefined_table
    // This indicates the schema_versions table doesn't exist yet
    var pgErr *pgconn.PgError
    if errors.As(err, &pgErr) && pgErr.Code == "42P01" {
        return true
    }
    return false
}
```

## Logger Implementation

```go
type SlogLogger struct {
    logger *slog.Logger
}

func (l *SlogLogger) Debug(ctx context.Context, msg string, args ...any) {
    l.logger.DebugContext(ctx, msg, args...)
}

func (l *SlogLogger) Info(ctx context.Context, msg string, args ...any) {
    l.logger.InfoContext(ctx, msg, args...)
}

func (l *SlogLogger) Warn(ctx context.Context, msg string, args ...any) {
    l.logger.WarnContext(ctx, msg, args...)
}
```

## Complete Example

See the `simplemigrations` repository's `internal/fruitsdbx/` directory for a complete working example that demonstrates:

- DBX schema definition with `schema_version` model
- Generated Go code and SQL schema
- Adapter implementation in test file
- Migration definitions
- Usage with `MigrateToLatestWithSchema`
