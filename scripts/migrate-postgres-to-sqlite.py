#!/usr/bin/env python3
"""Copy the Jellyfin database from PostgreSQL back into a stock Jellyfin SQLite database (jellyfin.db).

    POSTGRES_HOST=db POSTGRES_DB=jellyfin POSTGRES_USER=jellyfin POSTGRES_PASSWORD=... \\
        scripts/migrate-postgres-to-sqlite.py /path/to/seed/jellyfin.db /path/to/output/jellyfin.db

Prerequisites:
  - Jellyfin is stopped; nothing else is connected to the database as this role (the script refuses otherwise).
  - SEED is the jellyfin.db of a stock Jellyfin of the same version, started once with an empty config directory
    and stopped again (see "Switching back to SQLite" in the README). It supplies the SQLite schema and the
    migration history of that version; its data is replaced.
  - python3 with psycopg 3 (pip install "psycopg[binary]").

What it does (PostgreSQL is only read, the seed is only read; OUTPUT is written):
  1. checks that the PostgreSQL database and the seed are the same Jellyfin version (Jellyfin records its own
     migrations in __EFMigrationsHistory with its four-part version) and have the same tables and columns;
  2. reads every table in one REPEATABLE READ snapshot and writes the rows into a copy of the seed, in the format
     EF Core's SQLite provider uses: upper-case GUID text, UTC timestamps as "yyyy-MM-dd HH:mm:ss.FFFFFFF",
     booleans as 0/1, real values as their float32 value, arrays as JSON, bytea as BLOB;
  3. keeps the seed's migration history (complete for its version) and raises sqlite_sequence to the PostgreSQL
     sequences, so new rows get the ids PostgreSQL would have given them;
  4. verifies row counts, foreign_key_check and integrity_check, reads every row back and compares it with what
     PostgreSQL holds, and checks every value's storage format.

PostgreSQL stores microseconds and SQLite 100 ns ticks, so the 7th fractional digit of timestamps written before the
move to PostgreSQL stays lost; everything else round-trips.

Environment: POSTGRES_HOST (required), POSTGRES_PORT (5432), POSTGRES_DB (jellyfin), POSTGRES_USER (jellyfin),
POSTGRES_PASSWORD (required), POSTGRES_SSLMODE.
"""
import argparse
import datetime
import hashlib
import json
import os
import re
import shutil
import sqlite3
import struct
import sys
from collections import Counter
from pathlib import Path

try:
    import psycopg
except ImportError:
    sys.exit('psycopg 3 is required: pip install "psycopg[binary]"')

# Not copied: EF's history (the seed's is kept), its SQLite-only lock table and SQLite's own bookkeeping.
SKIPPED_TABLES = {"__EFMigrationsHistory", "__EFMigrationsLock", "sqlite_sequence"}
CODE_MIGRATION_VERSION = re.compile(r"^\d+\.\d+\.\d+\.\d+$")
UUID_FORMAT = re.compile(r"^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$")
TIMESTAMP_FORMAT = re.compile(r"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}(\.\d{1,7})?$")


def fail(message: str) -> None:
    sys.exit(f"MIGRATION FAILED: {message}")


def step(message: str) -> None:
    print(f"\n==> {message}", flush=True)


def version_key(version: str) -> tuple[int, ...]:
    return tuple(int(p) for p in version.split("."))


def float32(value: float) -> float:
    # EF reads a float column back as the double of the stored float32, which is what Jellyfin's SQLite file holds.
    return struct.unpack("<f", struct.pack("<f", value))[0]


def timestamp(value: datetime.datetime) -> str:
    value = value.astimezone(datetime.timezone.utc) if value.tzinfo else value
    ticks = f"{value.microsecond * 10:07d}".rstrip("0")
    # Not strftime: its %Y does not zero-pad year 1, which is how DateTime.MinValue is stored.
    return (f"{value.year:04d}-{value.month:02d}-{value.day:02d} {value.hour:02d}:{value.minute:02d}:{value.second:02d}"
            + (f".{ticks}" if ticks else ""))


def converter(udt_name: str):
    """How to write a PostgreSQL value of this type the way EF Core's SQLite provider stores it."""
    return {
        "uuid": lambda v: str(v).upper(),
        "timestamptz": timestamp,
        "timestamp": timestamp,
        "bool": int,
        "float4": float32,
        "float8": float,
        "_int8": lambda v: json.dumps(v, separators=(",", ":")),
        "_int4": lambda v: json.dumps(v, separators=(",", ":")),
        "bytea": bytes,
    }.get(udt_name, lambda v: v)


def format_ok(udt_name: str, value) -> bool:
    """Whether a value read back from SQLite has the storage format of its PostgreSQL type."""
    if value is None:
        return True
    if udt_name == "uuid":
        return isinstance(value, str) and UUID_FORMAT.match(value) is not None
    if udt_name in ("timestamptz", "timestamp"):
        return isinstance(value, str) and TIMESTAMP_FORMAT.match(value) is not None
    if udt_name == "bool":
        return isinstance(value, int) and value in (0, 1)
    if udt_name in ("float4", "float8"):
        return isinstance(value, float)
    if udt_name in ("int2", "int4", "int8"):
        return isinstance(value, int)
    if udt_name.startswith("_"):
        return isinstance(value, str) and isinstance(json.loads(value), list)
    if udt_name == "bytea":
        return isinstance(value, bytes)
    return isinstance(value, str)


def row_digest(row) -> bytes:
    return hashlib.sha256(repr(tuple(row)).encode()).digest()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("seed", type=Path, help="jellyfin.db of a fresh stock Jellyfin of the same version")
    parser.add_argument("output", type=Path, help="where to write the new jellyfin.db (must not exist)")
    args = parser.parse_args()

    for name in ("POSTGRES_HOST", "POSTGRES_PASSWORD"):
        if not os.environ.get(name):
            fail(f"{name} is required")
    os.environ.update({
        "PGHOST": os.environ["POSTGRES_HOST"],
        "PGPORT": os.environ.get("POSTGRES_PORT") or "5432",
        "PGDATABASE": os.environ.get("POSTGRES_DB") or "jellyfin",
        "PGUSER": os.environ.get("POSTGRES_USER") or "jellyfin",
        "PGPASSWORD": os.environ["POSTGRES_PASSWORD"],
    })
    if os.environ.get("POSTGRES_SSLMODE"):
        os.environ["PGSSLMODE"] = os.environ["POSTGRES_SSLMODE"].lower()
    if not args.seed.is_file():
        fail(f"{args.seed} does not exist")
    if args.output.exists():
        fail(f"{args.output} already exists; remove it or choose another path")

    step(f"Checking the PostgreSQL database {os.environ['PGDATABASE']} on {os.environ['PGHOST']}:{os.environ['PGPORT']}")
    pg = psycopg.connect(autocommit=False)
    pg.isolation_level = psycopg.IsolationLevel.REPEATABLE_READ
    pg.read_only = True
    cur = pg.cursor()
    cur.execute("SELECT version()")
    print(cur.fetchone()[0])
    cur.execute(
        "SELECT count(*) FROM pg_stat_activity WHERE datname = current_database() AND usename = current_user"
        " AND pid <> pg_backend_pid()")
    others = cur.fetchone()[0]
    if others:
        fail(f"{others} other session(s) of this role are connected to the database; stop Jellyfin first")

    seed = sqlite3.connect(f"file:{args.seed}?mode=ro", uri=True)
    if seed.execute("PRAGMA integrity_check").fetchone()[0] != "ok":
        fail(f"integrity_check failed on the seed {args.seed}")

    step("Comparing Jellyfin versions")
    # Jellyfin's own migrations carry its four-part version; EF schema migrations carry the EF Core version.
    seed_code = {r[0]: r[1] for r in seed.execute('SELECT MigrationId, ProductVersion FROM "__EFMigrationsHistory"')
                 if CODE_MIGRATION_VERSION.match(r[1])}
    cur.execute('SELECT "MigrationId", "ProductVersion" FROM "__EFMigrationsHistory"')
    pg_code = {r[0]: r[1] for r in cur.fetchall() if CODE_MIGRATION_VERSION.match(r[1])}
    if not seed_code:
        fail(f"{args.seed} has no Jellyfin migration history; seed it with a stock Jellyfin (see the README)")
    seed_version = max(seed_code.values(), key=version_key)
    pg_version = max(pg_code.values(), key=version_key) if pg_code else "none"
    print(f"seed: Jellyfin {seed_version}, PostgreSQL: Jellyfin {pg_version}")
    missing = sorted(set(seed_code) - set(pg_code))
    if missing:
        fail(f"the PostgreSQL database has not run {len(missing)} Jellyfin migration(s) the seed's version has "
             f"({', '.join(missing[:5])}{', ...' if len(missing) > 5 else ''}): it is an older Jellyfin than the seed. "
             "Seed with the stock Jellyfin of the version PostgreSQL runs.")
    if pg_code and version_key(pg_version) > version_key(seed_version):
        fail(f"the PostgreSQL database was last migrated by Jellyfin {pg_version}, newer than the seed's {seed_version}. "
             "Seed with the stock Jellyfin of that version.")

    step("Comparing tables and columns")
    seed_tables = {r[0] for r in seed.execute("SELECT name FROM sqlite_master WHERE type = 'table'")} - SKIPPED_TABLES
    cur.execute("SELECT table_name, column_name, udt_name FROM information_schema.columns"
                " WHERE table_schema = 'public' ORDER BY table_name, ordinal_position")
    pg_columns: dict[str, dict[str, str]] = {}
    for table, column, udt in cur.fetchall():
        if table not in SKIPPED_TABLES:
            pg_columns.setdefault(table, {})[column] = udt
    if set(pg_columns) != seed_tables:
        fail(f"the table sets differ: only in PostgreSQL {sorted(set(pg_columns) - seed_tables)}, "
             f"only in the seed {sorted(seed_tables - set(pg_columns))}")
    for table in sorted(seed_tables):
        seed_cols = {r[1] for r in seed.execute(f'PRAGMA table_info("{table}")')}
        if seed_cols != set(pg_columns[table]):
            fail(f"the columns of {table} differ: only in PostgreSQL {sorted(set(pg_columns[table]) - seed_cols)}, "
                 f"only in the seed {sorted(seed_cols - set(pg_columns[table]))}")
    print(f"{len(seed_tables)} tables with the same columns")
    seed.close()

    step(f"Copying the data into {args.output}")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(args.seed, args.output)
    out = sqlite3.connect(args.output, isolation_level=None)
    out.execute("PRAGMA foreign_keys = OFF")
    out.execute("BEGIN")
    expected: dict[str, Counter] = {}
    counts: dict[str, int] = {}
    for table in sorted(seed_tables):
        columns = list(pg_columns[table])
        convert = [converter(pg_columns[table][c]) for c in columns]
        out.execute(f'DELETE FROM "{table}"')
        column_list = ", ".join(f'"{c}"' for c in columns)
        insert = f'INSERT INTO "{table}" ({column_list}) VALUES ({", ".join("?" for _ in columns)})'
        digests: Counter = Counter()
        rows = 0
        with pg.cursor(name=f"copy_{table}") as source:
            source.itersize = 5000
            source.execute(f'SELECT {column_list} FROM "{table}"')
            batch = []
            for row in source:
                values = tuple(None if v is None else f(v) for f, v in zip(convert, row))
                digests[row_digest(values)] += 1
                batch.append(values)
                if len(batch) >= 5000:
                    out.executemany(insert, batch)
                    batch.clear()
                rows += 1
            out.executemany(insert, batch)
        expected[table] = digests
        counts[table] = rows
        print(f"{table}: {rows}")

    # Explicit ids already raise sqlite_sequence to the highest copied id; PostgreSQL's sequences can be further on
    # (deleted rows), and new rows should not reuse those ids.
    autoincrement = {r[0] for r in out.execute(
        "SELECT name FROM sqlite_master WHERE type = 'table' AND sql LIKE '%AUTOINCREMENT%'")}
    for table in sorted(autoincrement & seed_tables):
        for column in pg_columns[table]:
            cur.execute("SELECT pg_get_serial_sequence(%s, %s)", (f'public."{table}"', column))
            sequence = cur.fetchone()[0]
            if sequence is None:
                continue
            cur.execute(f"SELECT last_value, is_called FROM {sequence}")
            last_value, is_called = cur.fetchone()
            used = last_value if is_called else last_value - 1
            if out.execute("SELECT count(*) FROM sqlite_sequence WHERE name = ?", (table,)).fetchone()[0]:
                out.execute("UPDATE sqlite_sequence SET seq = max(seq, ?) WHERE name = ?", (used, table))
            elif used > 0:
                out.execute("INSERT INTO sqlite_sequence (name, seq) VALUES (?, ?)", (table, used))
    out.execute("COMMIT")
    pg.rollback()
    pg.close()

    step("Verifying")
    problems = []
    for table in sorted(seed_tables):
        n = out.execute(f'SELECT count(*) FROM "{table}"').fetchone()[0]
        if n != counts[table]:
            problems.append(f"{table}: {n} rows in SQLite, {counts[table]} in PostgreSQL")
    fk = out.execute("PRAGMA foreign_key_check").fetchall()
    if fk:
        problems.append(f"foreign_key_check: {len(fk)} violations, first {fk[0]}")
    integrity = out.execute("PRAGMA integrity_check").fetchone()[0]
    if integrity != "ok":
        problems.append(f"integrity_check: {integrity}")
    # Every row read back must be exactly what was written (SQLite's column affinity can silently convert values),
    # and every value must have the storage format of its PostgreSQL type.
    for table in sorted(seed_tables):
        columns = list(pg_columns[table])
        udts = [pg_columns[table][c] for c in columns]
        digests: Counter = Counter()
        bad_format: dict[str, tuple[int, object]] = {}
        column_list = ", ".join(f'"{c}"' for c in columns)
        for row in out.execute(f'SELECT {column_list} FROM "{table}"'):
            digests[row_digest(row)] += 1
            for column, udt, value in zip(columns, udts, row):
                if not format_ok(udt, value):
                    count, example = bad_format.get(column, (0, value))
                    bad_format[column] = (count + 1, example)
        if digests != expected[table]:
            problems.append(f"{table}: {sum((expected[table] - digests).values())} row(s) differ from PostgreSQL")
        for column, (count, example) in bad_format.items():
            problems.append(f"{table}.{column}: {count} value(s) not in the format of {pg_columns[table][column]},"
                            f" for example {example!r}")
    out.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    out.close()
    if problems:
        for problem in problems:
            print(f"  {problem}", file=sys.stderr)
        fail(f"verification failed; {args.output} must not be used")

    print(f"{sum(counts.values())} rows in {len(seed_tables)} tables: counts, foreign keys, integrity, "
          "every row and every value format verified")
    print(f"\nMIGRATION COMPLETE: {args.output}")
    print("Put it in place of <data dir>/jellyfin.db, replace <config dir>/database.xml with the stock one "
          "(DatabaseType Jellyfin-SQLite), and start a stock Jellyfin of the same version.")


if __name__ == "__main__":
    main()
