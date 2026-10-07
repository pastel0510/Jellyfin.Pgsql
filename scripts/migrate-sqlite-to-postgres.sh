#!/usr/bin/env bash
# Copy a Jellyfin SQLite database (jellyfin.db) into a PostgreSQL database seeded by this plugin.
#
#   POSTGRES_HOST=db POSTGRES_DB=jellyfin POSTGRES_USER=jellyfin POSTGRES_PASSWORD=... \
#       scripts/migrate-sqlite-to-postgres.sh /path/to/jellyfin.db
#
# Prerequisites:
#   - Jellyfin is stopped. The SQLite database and the plugin image are the same Jellyfin version (checked).
#   - The PostgreSQL database was seeded: the Jellyfin.Pgsql image was started once against it with an empty
#     config directory and stopped again (see the README). The script refuses to run otherwise.
#   - sqlite3 and psql on the PATH, and pgloader on the PATH or PGLOADER_IMAGE set to a pgloader Docker image
#     (for example ghcr.io/dimitri/pgloader:latest), which is then run with docker on the host network.
#
# What it does (the original jellyfin.db is only read, never changed):
#   1. takes a consistent copy (WAL checkpointed, integrity_check must be ok) into a scratch directory;
#   2. checks that both databases have the same tables and were migrated by the same Jellyfin version;
#   3. rewrites PostgreSQL array columns from EF's SQLite JSON form ([1,2]) to array literals ({1,2}) and trims
#      strings longer than PostgreSQL's varchar(n) limits (SQLite does not enforce them), in the copy;
#   4. loads the data with pgloader (data only, into the seeded schema);
#   5. resets identity sequences past the loaded ids and runs ANALYZE;
#   6. verifies every table's row count and that every seeded constraint and index exists (missing ones are
#      re-created from the seeded definitions). pgloader's exit code is not trusted.
#
# Environment: POSTGRES_HOST (required), POSTGRES_PORT (5432), POSTGRES_DB (jellyfin), POSTGRES_USER (jellyfin),
# POSTGRES_PASSWORD (required), POSTGRES_SSLMODE, WORK_DIR (default: a new temporary directory), PGLOADER_IMAGE.
set -euo pipefail

SOURCE_DB="${1:?usage: $0 /path/to/jellyfin.db}"
: "${POSTGRES_HOST:?POSTGRES_HOST is required}"
: "${POSTGRES_PASSWORD:?POSTGRES_PASSWORD is required}"
export PGHOST="$POSTGRES_HOST" PGPORT="${POSTGRES_PORT:-5432}" PGDATABASE="${POSTGRES_DB:-jellyfin}"
export PGUSER="${POSTGRES_USER:-jellyfin}" PGPASSWORD="$POSTGRES_PASSWORD"
if [[ -n "${POSTGRES_SSLMODE:-}" ]]; then
    export PGSSLMODE="${POSTGRES_SSLMODE,,}"
fi
WORK_DIR="${WORK_DIR:-$(mktemp -d -t jellyfin-pgsql-migration.XXXXXX)}"
COPY_DB="$WORK_DIR/jellyfin.db"
EXCLUDED_TABLES="'__EFMigrationsHistory', '__EFMigrationsLock'"

step() { echo; echo "==> $*"; }
fail() { echo "MIGRATION FAILED: $*" >&2; exit 1; }
pg() { psql -X -v ON_ERROR_STOP=1 -tA "$@"; }
lite() { sqlite3 -batch -bail "$COPY_DB" "$@"; }

for tool in sqlite3 psql; do
    command -v "$tool" >/dev/null || fail "$tool is not installed"
done
if [[ -z "${PGLOADER_IMAGE:-}" ]] && ! command -v pgloader >/dev/null; then
    fail "pgloader is not installed; install it or set PGLOADER_IMAGE to a pgloader Docker image"
fi
[[ -f "$SOURCE_DB" ]] || fail "$SOURCE_DB does not exist"

step "Checking the PostgreSQL database $PGDATABASE on $PGHOST:$PGPORT"
pg -c 'SELECT version()'
seeded=0
if [[ "$(pg -c "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public' AND table_name = '__EFMigrationsHistory'")" == "1" ]]; then
    seeded="$(pg -c 'SELECT count(*) FROM "__EFMigrationsHistory"')"
fi
[[ "$seeded" -gt 0 ]] || fail "the database is not seeded; start the Jellyfin.Pgsql image once against it with an empty config directory, stop it, then run this again"
echo "seeded with $seeded migrations"

step "Taking a consistent copy of $SOURCE_DB into $WORK_DIR"
mkdir -p "$WORK_DIR"
cp "$SOURCE_DB" "$COPY_DB"
for suffix in -wal -shm; do
    if [[ -f "$SOURCE_DB$suffix" ]]; then
        cp "$SOURCE_DB$suffix" "$COPY_DB$suffix"
    fi
done
lite 'PRAGMA wal_checkpoint(TRUNCATE);' >/dev/null
lite 'PRAGMA journal_mode=DELETE;' >/dev/null
integrity="$(lite 'PRAGMA integrity_check;')"
[[ "$integrity" == "ok" ]] || fail "SQLite integrity_check failed: $integrity"
echo "integrity_check: ok"

step "Comparing tables"
lite "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name NOT IN ($EXCLUDED_TABLES) ORDER BY name;" >"$WORK_DIR/tables.sqlite"
pg -c "SELECT table_name FROM information_schema.tables WHERE table_schema = 'public' AND table_type = 'BASE TABLE'
       AND table_name NOT IN ($EXCLUDED_TABLES) ORDER BY table_name COLLATE \"C\"" >"$WORK_DIR/tables.postgres"
if ! diff -u "$WORK_DIR/tables.sqlite" "$WORK_DIR/tables.postgres" >"$WORK_DIR/tables.diff"; then
    cat "$WORK_DIR/tables.diff" >&2
    fail "the databases have different tables (- only in SQLite, + only in PostgreSQL); are both the same Jellyfin version?"
fi
echo "$(wc -l <"$WORK_DIR/tables.sqlite") tables"

step "Comparing Jellyfin versions"
# Jellyfin records its own migrations in __EFMigrationsHistory with its four-part version (12.2.0.0); EF schema
# migrations carry the EF Core version. The seed has every Jellyfin migration of the image's version, so one the
# SQLite database lacks means the server is older than the image. Its rows are not loaded either way.
lite "SELECT MigrationId FROM __EFMigrationsHistory WHERE ProductVersion GLOB '[0-9]*.[0-9]*.[0-9]*.[0-9]*' ORDER BY 1;" \
    >"$WORK_DIR/code-migrations.sqlite"
pg -c "SELECT \"MigrationId\" FROM \"__EFMigrationsHistory\" WHERE \"ProductVersion\" ~ '^[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+$' ORDER BY \"MigrationId\" COLLATE \"C\"" \
    >"$WORK_DIR/code-migrations.postgres"
sqlite_version="$(lite "SELECT ProductVersion FROM __EFMigrationsHistory WHERE ProductVersion GLOB '[0-9]*.[0-9]*.[0-9]*.[0-9]*';" | sort -V | tail -1)"
image_version="$(pg -c "SELECT \"ProductVersion\" FROM \"__EFMigrationsHistory\" WHERE \"ProductVersion\" ~ '^[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+$'" | sort -V | tail -1)"
echo "SQLite: Jellyfin ${sqlite_version:-unknown}, PostgreSQL seed: Jellyfin ${image_version:-unknown}"
missing="$(LC_ALL=C comm -13 "$WORK_DIR/code-migrations.sqlite" "$WORK_DIR/code-migrations.postgres")"
if [[ -n "$missing" ]]; then
    echo "$missing" | sed 's/^/  not run on SQLite: /' >&2
    fail "the SQLite database is from an older Jellyfin (${sqlite_version:-unknown}) than the image (${image_version}). Migrate with the image of the server's version (for example ghcr.io/pastel0510/jellyfin.pgsql:12.1-2 for 12.1) and upgrade the image afterwards, or upgrade the SQLite server first; see \"Migrating from SQLite\" in the README"
fi
if [[ -n "$sqlite_version" && -n "$image_version" && "$(printf '%s\n%s\n' "$sqlite_version" "$image_version" | sort -V | tail -1)" != "$image_version" ]]; then
    fail "the SQLite database was last migrated by Jellyfin $sqlite_version, newer than the image's $image_version; use the image of that version"
fi

step "Converting array columns and trimming over-length strings in the copy"
while IFS='|' read -r table column; do
    converted="$(lite "UPDATE \"$table\" SET \"$column\" = '{' || substr(\"$column\", 2, length(\"$column\") - 2) || '}' WHERE \"$column\" LIKE '[%]'; SELECT changes();")"
    echo "array column $table.$column: $converted rows converted"
done < <(pg -c "SELECT table_name, column_name FROM information_schema.columns WHERE table_schema = 'public' AND data_type = 'ARRAY'")
while IFS='|' read -r table column length; do
    trimmed="$(lite "UPDATE \"$table\" SET \"$column\" = substr(\"$column\", 1, $length) WHERE length(\"$column\") > $length; SELECT changes();")"
    [[ "$trimmed" == "0" ]] || echo "trimmed $trimmed values of $table.$column to $length characters"
done < <(pg -c "SELECT table_name, column_name, character_maximum_length FROM information_schema.columns
                WHERE table_schema = 'public' AND character_maximum_length IS NOT NULL")

step "Recording the seeded constraints and indexes"
pg -c "SELECT format('ALTER TABLE %s ADD CONSTRAINT %I %s', conrelid::regclass, conname, pg_get_constraintdef(oid))
       FROM pg_constraint WHERE connamespace = 'public'::regnamespace AND contype IN ('p', 'u', 'f', 'c')
       ORDER BY contype = 'f', conname" >"$WORK_DIR/constraints.sql"
pg -c "SELECT indexdef FROM pg_indexes WHERE schemaname = 'public' ORDER BY indexname" >"$WORK_DIR/indexes.sql"
echo "$(wc -l <"$WORK_DIR/constraints.sql") constraints, $(wc -l <"$WORK_DIR/indexes.sql") indexes"

step "Loading the data with pgloader"
cat >"$WORK_DIR/jellyfin.load" <<EOF
load database
    from sqlite://$COPY_DB
    into postgresql://$PGUSER@$PGHOST:$PGPORT/$PGDATABASE

with quote identifiers, data only, truncate, drop indexes, reset no sequences

excluding table names like $EXCLUDED_TABLES;
EOF
if [[ -n "${PGLOADER_IMAGE:-}" ]]; then
    docker run --rm --network host -e PGPASSWORD -e PGSSLMODE -v "$WORK_DIR:$WORK_DIR" "$PGLOADER_IMAGE" \
        pgloader "$WORK_DIR/jellyfin.load" | tee "$WORK_DIR/pgloader.log" || true
else
    pgloader "$WORK_DIR/jellyfin.load" | tee "$WORK_DIR/pgloader.log" || true
fi

step "Resetting identity sequences and analyzing"
pg <<'SQL'
DO $$
DECLARE
    r record;
    seq text;
    next_value bigint;
BEGIN
    FOR r IN
        SELECT table_name, column_name FROM information_schema.columns
        WHERE table_schema = 'public' AND (is_identity = 'YES' OR column_default LIKE 'nextval%')
    LOOP
        seq := pg_get_serial_sequence(format('public.%I', r.table_name), r.column_name);
        IF seq IS NOT NULL THEN
            EXECUTE format('SELECT coalesce(max(%I), 0) + 1 FROM public.%I', r.column_name, r.table_name) INTO next_value;
            PERFORM setval(seq, next_value, false);
        END IF;
    END LOOP;
END $$;
SQL
PGOPTIONS="-c client_min_messages=error" pg -c 'ANALYZE'

step "Verifying"
mismatches=0
while read -r table; do
    sqlite_rows="$(lite "SELECT count(*) FROM \"$table\";")"
    postgres_rows="$(pg -c "SELECT count(*) FROM \"$table\"")"
    if [[ "$sqlite_rows" != "$postgres_rows" ]]; then
        echo "row count mismatch in $table: SQLite $sqlite_rows, PostgreSQL $postgres_rows" >&2
        mismatches=$((mismatches + 1))
    fi
done <"$WORK_DIR/tables.sqlite"
total_rows="$(pg -c "SELECT sum((xpath('/row/n/text()', query_to_xml(format('SELECT count(*) AS n FROM %I', table_name), false, true, '')))[1]::text::bigint)
                     FROM information_schema.tables WHERE table_schema = 'public' AND table_type = 'BASE TABLE' AND table_name NOT IN ($EXCLUDED_TABLES)")"
[[ "$mismatches" == "0" ]] || fail "$mismatches tables have different row counts; see $WORK_DIR/pgloader.log"
echo "row counts match: $(wc -l <"$WORK_DIR/tables.sqlite") tables, $total_rows rows"

recreated=0
while read -r definition; do
    name="$(sed -E 's/^ALTER TABLE .* ADD CONSTRAINT ("[^"]+"|[^ ]+) .*/\1/' <<<"$definition" | tr -d '"')"
    if [[ "$(pg -c "SELECT count(*) FROM pg_constraint WHERE connamespace = 'public'::regnamespace AND conname = '$name'")" == "0" ]]; then
        echo "re-creating missing constraint $name"
        pg -c "$definition" >/dev/null
        recreated=$((recreated + 1))
    fi
done <"$WORK_DIR/constraints.sql"
while read -r definition; do
    name="$(sed -E 's/^CREATE (UNIQUE )?INDEX ("[^"]+"|[^ ]+) .*/\2/' <<<"$definition" | tr -d '"')"
    if [[ "$(pg -c "SELECT count(*) FROM pg_indexes WHERE schemaname = 'public' AND indexname = '$name'")" == "0" ]]; then
        echo "re-creating missing index $name"
        pg -c "$definition" >/dev/null
        recreated=$((recreated + 1))
    fi
done <"$WORK_DIR/indexes.sql"
echo "constraints and indexes: all present ($recreated re-created)"

cat <<EOF

MIGRATION COMPLETE. Next steps:
  1. Rename the old database so a misconfigured start cannot silently use SQLite again:
       mv "$SOURCE_DB" "$SOURCE_DB.migrated"
  2. Start the Jellyfin.Pgsql image with your existing config and data directories and check its log for
     "PgSqlDatabaseProvider: PostgreSQL connection string".
The scratch copy and logs are in $WORK_DIR (delete it when you no longer need it).
EOF
