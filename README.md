# The Unofficial Postgre SQL adapter for Jellyfin Server

> [!WARNING]
> **This is an LLM-made and LLM-maintained fork** of [JPVenson/Jellyfin.Pgsql](https://github.com/JPVenson/Jellyfin.Pgsql).
> The changes in this fork, including the updates to new Jellyfin versions, are written by an AI model (Claude) and updated
> automatically by the [Jellyfin Update workflow](#automated-jellyfin-updates). They are checked by automated builds and
> smoke tests, not necessarily reviewed line by line by a human. It is not affiliated with or endorsed by the original
> author or the Jellyfin project. Report problems with this fork here, not upstream.

This plugin adds postgres SQL support to [Jellyfin Server](https://github.com/jellyfin/jellyfin).


> [!IMPORTANT]
> Pleae note that there are several additional steps required to make this work and it is to be considered __HIGHLY__ experimental.
> 
> This plugin is __NOT__ meant for a production jellyfin server. This is just for advanced users to experiment and evaluate potential issues we will face once we will include pgsql support in the jellyfin server by default.
> 
> Issues __MAY__ not be fixed by me and if i dont have the time to work on it stuff will not nessesarily be done.
> 
> # !!!Use at your own risk!!!
> Full explaination here: https://github.com/JPVenson/Jellyfin.Pgsql/issues/27

# How to use it

You can use your existing Jellyfin compose file and change the image accordingly to: `ghcr.io/pastel0510/jellyfin.pgsql:12.2`.

Images are published automatically whenever a change to the plugin or the image is merged. Each build gets a fixed tag
`<version>-<n>` (for example `12.1-2`) and a [release](https://github.com/pastel0510/Jellyfin.Pgsql/releases) whose notes
list its changes and any new database migration. The tag named after the Jellyfin version (for example `12.1`) and
`latest` always point to the newest build.

You need to add the connection parameters as environment variables in your compose file:

```yaml
services:
  jellyfin:
    image: ghcr.io/pastel0510/jellyfin.pgsql:12.2
    volumes:
      - /path/to/config:/config
      - /path/to/cache:/cache
      - /path/to/media:/media
    environment:
      - POSTGRES_HOST=postgres
      - POSTGRES_PASSWORD=change-me
      # Optional, with their defaults:
      # - POSTGRES_PORT=5432
      # - POSTGRES_DB=jellyfin
      # - POSTGRES_USER=jellyfin
      # - POSTGRES_SSLMODE=Require              # Disable, Allow, Prefer, Require, VerifyCA or VerifyFull
      # - POSTGRES_COMMAND_TIMEOUT=30           # seconds per command, 0 = no limit; raise for very large libraries
      # - POSTGRES_JIT=off                      # see "Differences from SQLite"
      # - POSTGRES_REVERSE_NULL_ORDERING=true   # see "Differences from SQLite"
      # - POSTGRES_CASE_INSENSITIVE_LIKE=true   # see "Differences from SQLite"
      # - POSTGRES_KEEP_BACKUP=true             # keep the newest pre-migration pg_dump, see "Upgrading and pinning"
```

The password is only read from the environment. On every start the entrypoint records the other connection settings in
`database.xml`; the password is never written to disk.

### Upgrading and pinning

`ghcr.io/pastel0510/jellyfin.pgsql:12.2` is fine for trying the image. For a server you rely on, pin the exact build
and its digest as given in the release notes (`ghcr.io/pastel0510/jellyfin.pgsql:<version>-<n>@sha256:...`): with a
moving tag, a restart can silently pull a build that adds a database migration. Migrations run on the first start of
the new image and cannot be undone by going back to an older image, so before moving to a new build read its release
notes and take a `pg_dump` of the database.

Before running migrations the plugin also writes a `pg_dump` to `<data dir>/PgsqlBackups/` (`/config/data/PgsqlBackups`
by default) and restores it if a migration fails. Jellyfin deletes that dump once the migrations succeed, so on its own
it does not help with a migration that succeeds but changes data you did not want changed. Since 12.2-2 the plugin
keeps the newest dump and removes the older ones; `POSTGRES_KEEP_BACKUP=false` deletes it as before. The dump holds
the whole database, including password hashes, and needs about as much space as the database.

Known issues of a Jellyfin version are listed in the release notes of its builds. Upgrading to Jellyfin 12.2: its
`HarmonizeConflictingUserData` migration can mark a watched item as unwatched (a Jellyfin bug that affects SQLite too).
From 12.2-3 on the plugin's own migration resolves those rows first, preferring played and favourite; a server already
upgraded with 12.2-1 or 12.2-2 may need one or two items marked as watched again.

Renovate's default Docker versioning reads the `-<n>` of these tags as a compatibility suffix and never offers a newer
build. Add a package rule:

```json
{
  "packageRules": [
    {
      "matchDatasources": ["docker"],
      "matchPackageNames": ["ghcr.io/pastel0510/jellyfin.pgsql"],
      "versioning": "regex:^(?<major>\\d+)\\.(?<minor>\\d+)-(?<patch>\\d+)$"
    }
  ]
}
```

### Configuration paths and running as a non-root user

The entrypoint installs the plugin into `$JELLYFIN_DATA_DIR/plugins/PostgreSQL` and writes `$JELLYFIN_CONFIG_DIR/database.xml`,
the places Jellyfin reads them from. The image's defaults are `JELLYFIN_DATA_DIR=/config` and
`JELLYFIN_CONFIG_DIR=/config/config`. To keep the layout of the linuxserver.io image (for example when moving an existing
linuxserver install over), set:

```yaml
    user: "1000:1000"   # the owner of your config volume (linuxserver's PUID:PGID)
    environment:
      - HOME=/config
      - JELLYFIN_DATA_DIR=/config/data
      - JELLYFIN_CONFIG_DIR=/config
      - JELLYFIN_CACHE_DIR=/config/cache
      - JELLYFIN_LOG_DIR=/config/log
```

The image runs as root by default and then leaves root-owned files in `/config`; running it as the volume's owner with
`user:` works without further changes, including hardware transcoding through `/dev/dri` when that user may access it.

## PostgreSQL version

The image is built on Jellyfin 12.2 and ships the PostgreSQL 18 client tools. Jellyfin takes a `pg_dump` backup before
every database migration, and `pg_dump` refuses to dump a server newer than itself, so use a PostgreSQL server
**version 18 or older** (18 recommended; see [`docker/docker-compose.yaml`](docker/docker-compose.yaml)). PostgreSQL 16 is
confirmed working, including with a non-superuser role that owns the database, and on a 3-instance CloudNativePG cluster
that survived a switchover without restarting Jellyfin.

With the official `postgres:18` image, mount the data volume at `/var/lib/postgresql` (not `/var/lib/postgresql/data`
as with older images), or the data will not persist.

Backups contain the `\restrict` lines added by pg_dump 18, so restore them by hand only with psql 18 (or 17.6+).

Configuration comes from the `ConnectionString` in `database.xml`, and any `POSTGRES_*` environment variables override it.

## Differences from SQLite

Jellyfin's queries were written for SQLite. The plugin adjusts PostgreSQL so results match:

- **JIT is turned off** for Jellyfin's connections (`-c jit=off`). PostgreSQL's JIT compiler spent over 20 seconds on
  every execution of the "continue watching" query (`/UserItems/Resume`: 0.2 s without JIT, about 60 s with it) and
  never pays off for Jellyfin's short, index-driven lookups. `POSTGRES_JIT=on`, or a `jit` setting in the
  connection string, keeps the server's default. If a connection pooler such as PgBouncer rejects the `options` startup
  parameter, set `POSTGRES_JIT=on` and run `ALTER DATABASE jellyfin SET jit = off;` instead.
- **NULLs sort like in SQLite**: first in ascending and last in descending order (PostgreSQL's default is the
  opposite), so lists such as "continue watching", next up and sorting by rating or date come back in the same order.
  `POSTGRES_REVERSE_NULL_ORDERING=false` turns this off.
- **`LIKE` ignores case, as in SQLite.** Jellyfin's search matches the original title and sort name with
  `EF.Functions.Like`, which is case-insensitive on SQLite and case-sensitive on PostgreSQL, so searching "amelie" did
  not find an item whose original title is "Amelie". The plugin translates it to `ILIKE`; with the `C` collation it
  uses, `ILIKE` folds only ASCII letters, like SQLite. `POSTGRES_CASE_INSENSITIVE_LIKE=false` turns this off.
- **Query results are read completely before they are used.** SQLite lets Jellyfin run a command while it is still
  reading a query on the same connection; PostgreSQL does not (Npgsql reports "A command is already in progress"), and
  Jellyfin 12.2's rating migration depends on it. The plugin uses an EF Core execution strategy that buffers results
  (as EF does for retrying strategies) but never retries.
- **Planner statistics are refreshed after every library scan** (`ANALYZE`, from Jellyfin 12.2), and the scheduled
  database optimisation runs `VACUUM ANALYZE`, as the SQLite provider does. Both skip `ANALYZE` while the library holds
  no items yet: statistics of empty tables would make the planner choose full scans once the library fills up.
- **`DateTime.MinValue` is stored as `0001-01-01`**, not `-infinity`, so Jellyfin's date arithmetic in queries works
  (sorting by premiere date for items with only a production year). Values stored as infinity by earlier versions are
  converted by a database migration on the first start.

Expected differences that are not bugs:

- Some list queries remain slower than on SQLite. On a library of 84,000 items, "continue watching"
  (`/UserItems/Resume`) and next up take 0.2-0.8 s on PostgreSQL against 0.07-0.11 s on SQLite. This is the cost of
  Jellyfin's query shapes on PostgreSQL, not the JIT problem above (which made them take about a minute).

- PostgreSQL stores timestamps with microsecond precision, .NET and SQLite with 100 ns ticks, so values lose their
  last digit. Image tags are derived from such timestamps, so after migrating from SQLite every image tag changes once
  and clients download each image again a single time.
- Items with an equal sort key (two movies with the same rating) can come back in a different order; neither database
  defines the order of ties.

## Automated Jellyfin updates

[`jellyfin-update.yaml`](.github/workflows/jellyfin-update.yaml) runs daily (or by hand from the Actions tab, optionally with
a specific tag). When a newer stable Jellyfin release has its Docker image and NuGet packages published, it:

1. bumps every version in the repo with [`update_jellyfin.py`](.github/scripts/update_jellyfin.py) (Jellyfin packages, base
   image, targetAbi, EF Core / Microsoft.Extensions versions to match the server, .NET SDK, submodule, docs);
2. adds a PostgreSQL migration if the data model changed;
3. runs [`scripts/verify.sh`](scripts/verify.sh): Release build, migration check, Docker build and
   [`scripts/smoke-test.sh`](scripts/smoke-test.sh) against PostgreSQL 18 (startup wizard, login, library scan with a real
   video, upgrade from the newest published image, backup and restore);
4. collects the upstream changes to Jellyfin's database layer since the previous release (the provider interface, the
   SQLite provider, migrations, backup and maintenance code) and any SQLite-specific code added elsewhere;
5. has Claude Code fix any failure and review those upstream changes, including the ones that break nothing, such as
   a new provider feature the PostgreSQL provider should implement; then the verification runs again;
6. opens a pull request `automation/jellyfin-<version>` (a draft if verification still fails) with Claude's summary
   and a checklist of the upstream changes it reviewed.

One-time setup:
- Actions > enable workflows (forks start with them disabled).
- Settings > Actions > General > Workflow permissions > allow GitHub Actions to create and approve pull requests.
- Settings > Secrets and variables > Actions > add `CLAUDE_CODE_OAUTH_TOKEN` (from `claude setup-token`) or
  `ANTHROPIC_API_KEY`. Without it the workflow still bumps and verifies, but cannot fix failures.

To check the Claude step works, run **Claude Check** from the Actions tab: `quick` makes one short Claude call with the same
credential, model and permissions; `drill` breaks the build on purpose in that run, lets Claude find and fix it, and verifies
the fix (uses more of your Claude usage). Neither commits anything.

Pull requests opened by the workflow don't trigger other workflows; they were already verified in the same run.
After the merge the image is published automatically (see [Releases](#releases)).

The upstream review means Claude runs for every Jellyfin release, not only when something fails.

Every push and pull request is also scanned for committed secrets (API keys, tokens, passwords) by the
[Secret Scan](.github/workflows/secret-scan.yaml) workflow, which runs Gitleaks over the full git history.

Run the same checks locally with `scripts/verify.sh` (`SKIP_DOCKER=1` for build and migration checks only).

# Build

Checkout the Jellyfin submodule.
Use dotnet build to build the plugin.
Place the plugin in the `plugins` folder of the Jellyfin app.
Update the `database.xml` file to switch to the plugin as its database provider:

```xml
<?xml version="1.0" encoding="utf-8"?>
<DatabaseConfigurationOptions xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:xsd="http://www.w3.org/2001/XMLSchema">
  <DatabaseType>PLUGIN_PROVIDER</DatabaseType>
  <CustomProviderOptions>
    <PluginAssembly>../../../Jellyfin.Plugin.Pgsql/bin/debug/net10.0/Jellyfin.Plugin.Pgsql.dll</PluginAssembly>
    <PluginName>PostgreSQL</PluginName>
    <ConnectionString>CONNECTION_STRING_TO_LOCAL_PGSQL_SERVER</ConnectionString>
  </CustomProviderOptions>
  <LockingBehavior>NoLock</LockingBehavior>
</DatabaseConfigurationOptions>

```

Launch your Jellyfin server.

# Add migration
Run `dotnet ef migrations add {MIGRATION_NAME} --project "/workspaces/Jellyfin.Pgsql/Jellyfin.Plugin.Pgsql" -- --migration-provider Jellyfin-PgSql`

# Releases

Images are built and published by the [Build & Publish Docker Image](.github/workflows/docker.yaml) workflow:

1. Changes go through a pull request; the Verify workflow (build, migration check, smoke and migration tests) must pass.
2. After the merge, Verify runs again on `master`. If it passes and the merge changed the plugin or the Docker files,
   the image is built for linux/amd64 and linux/arm64 and pushed as `<version>-<n>`, `<version>` and `latest`.
3. The build is tagged in git and gets a GitHub release with the image digest, the changes since the previous build
   and any new database migration.

New Jellyfin versions arrive through the [automated update](#automated-jellyfin-updates) pull request. A database
migration is added when the Jellyfin data model changes (see [Add migration](#add-migration)).
[Release Notes](.github/workflows/release-notes.yaml) can (re)create the release of an already published build.

# Migrating from SQLite

[`scripts/migrate-sqlite-to-postgres.sh`](scripts/migrate-sqlite-to-postgres.sh) copies an existing Jellyfin SQLite
database into PostgreSQL and checks the result. It is tested end to end in CI by
[`scripts/migration-test.sh`](scripts/migration-test.sh), and was used to migrate a real library (84,000 items, 716,000
rows) with identical counts, watch state and sort orders. It needs `sqlite3`, `psql` and `pgloader` (or Docker with
`PGLOADER_IMAGE=ghcr.io/dimitri/pgloader:latest`). Use the same Jellyfin version on both sides, and keep a backup of your
config directory.

1. **Stop Jellyfin.** Work on a copy of your config directory if you can.
2. **Seed the PostgreSQL database.** Start this image once against the empty database with an **empty** config
   directory, wait for `Startup complete` in the log (or the setup wizard), then stop it. This creates the schema and
   its migration history. Do not run the setup wizard.
3. **Migrate:**

   ```sh
   POSTGRES_HOST=postgres POSTGRES_DB=jellyfin POSTGRES_USER=jellyfin POSTGRES_PASSWORD=... \
       scripts/migrate-sqlite-to-postgres.sh /path/to/config/data/jellyfin.db
   ```

   The database is `data/jellyfin.db` with the jellyfin/jellyfin image and `data/data/jellyfin.db` with the linuxserver
   image. The script only reads it: it works on a consistent copy (WAL checkpointed, `integrity_check` must pass),
   checks both databases have the same tables, converts array columns from SQLite's JSON form, trims strings that
   exceed PostgreSQL's length limits, loads the data with pgloader, resets the identity sequences, runs `ANALYZE`,
   and verifies every table's row count and every constraint and index. It stops with an error if anything does
   not match; pgloader's own exit code is not relied on.
4. **Switch the config to PostgreSQL:** move the SQLite settings aside with
   `mv config/database.xml config/database.xml.sqlite` (`/config/database.xml` with the linuxserver layout), and rename
   the old database so a misconfigured start fails instead of quietly using SQLite:
   `mv data/jellyfin.db data/jellyfin.db.migrated`.
5. **Start this image** with your existing config, data and media paths (see
   [Configuration paths](#configuration-paths-and-running-as-a-non-root-user) for linuxserver layouts) and check the log
   for `PgSqlDatabaseProvider: PostgreSQL connection string`.

[`docker/jellyfindb.load`](docker/jellyfindb.load) is the pgloader load file for doing step 3 by hand; the script
generates the same file and does the steps around it.
