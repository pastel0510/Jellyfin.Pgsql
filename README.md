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

You can use your existing Jellyfin compose file and change the image accordingly to: `ghcr.io/pastel0510/jellyfin.pgsql:12.1-1`.

You need to add the connection parameters as enviornment variables in your compose file:

```yaml

services:
  jellyfin:
    image: ghcr.io/pastel0510/jellyfin.pgsql:12.1-1
    volumes:
        - /path/to/config:/config
        - /path/to/cache:/cache
        - /path/to/media:/media
    environment:
        - POSTGRES_HOST=
        - POSTGRES_PORT=
        - POSTGRES_DB=jellyfin
        - POSTGRES_USER=jellyfin
        - POSTGRES_PASSWORD=jellyfin
      # Optional settings bellow, uncomment if you want to connect using SSL
      # - POSTGRES_SSLMODE=Require
      # - POSTGRES_TRUSTSERVERCERTIFICATE=true  (ignored by current Npgsql; "Require" does not validate the certificate)
      # Optional: per-command timeout in seconds (default 30, 0 = no limit).
      # Raise it if large libraries hit query timeouts.
      # - POSTGRES_COMMAND_TIMEOUT=120
```

## PostgreSQL version

The image is built on Jellyfin 12.1 and ships the PostgreSQL 18 client tools. Jellyfin takes a `pg_dump` backup before
every database migration, and `pg_dump` refuses to dump a server newer than itself, so use a PostgreSQL server
**version 18 or older** (18 recommended; see [`docker/docker-compose.yaml`](docker/docker-compose.yaml)).

With the official `postgres:18` image, mount the data volume at `/var/lib/postgresql` (not `/var/lib/postgresql/data`
as with older images), or the data will not persist.

Backups contain the `\restrict` lines added by pg_dump 18, so restore them by hand only with psql 18 (or 17.6+).

Configuration comes from the `ConnectionString` in `database.xml`, and any `POSTGRES_*` environment variables override it.

## Automated Jellyfin updates

[`jellyfin-update.yaml`](.github/workflows/jellyfin-update.yaml) runs daily (or by hand from the Actions tab, optionally with
a specific tag). When a newer stable Jellyfin release has its Docker image and NuGet packages published, it:

1. bumps every version in the repo with [`update_jellyfin.py`](.github/scripts/update_jellyfin.py) (Jellyfin packages, base
   image, targetAbi, EF Core / Microsoft.Extensions versions to match the server, .NET SDK, submodule, docs);
2. adds a PostgreSQL migration if the data model changed;
3. runs [`scripts/verify.sh`](scripts/verify.sh): Release build, migration check, Docker build and
   [`scripts/smoke-test.sh`](scripts/smoke-test.sh) against PostgreSQL 18 (startup wizard, login, library scan with a real
   video, upgrade from the newest published image, backup and restore);
4. if anything fails, or upstream added raw SQL migrations that may need a PostgreSQL port, Claude Code fixes or reviews it
   and the verification runs again;
5. opens a pull request `automation/jellyfin-<version>` (a draft if verification still fails).

One-time setup:
- Actions > enable workflows (forks start with them disabled).
- Settings > Actions > General > Workflow permissions > allow GitHub Actions to create and approve pull requests.
- Settings > Secrets and variables > Actions > add `CLAUDE_CODE_OAUTH_TOKEN` (from `claude setup-token`) or
  `ANTHROPIC_API_KEY`. Without it the workflow still bumps and verifies, but cannot fix failures.

To check the Claude step works, run **Claude Check** from the Actions tab: `quick` makes one short Claude call with the same
credential, model and permissions; `drill` breaks the build on purpose in that run, lets Claude find and fix it, and verifies
the fix (uses more of your Claude usage). Neither commits anything.

Pull requests opened by the workflow don't trigger other workflows; they were already verified in the same run.
After merging, publish the image with a release or by running the Docker workflow.

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

# Release flow

To create a new release, first sync all Jellyfin server changes then create a new migration as seen above. After that create a new efbundle:
`dotnet ef migrations bundle -o docker/jellyfin.PgsqlMigrator.dll -r linux-x64 --self-contained --project "/workspaces/Jellyfin.Pgsql/Jellyfin.Plugin.Pgsql" --  --migration-provider Jellyfin-PgSql`
Then build the container.

# Migration Instructions (ADVANCED, UNTESTED)

To migrate your existing Jellyfin instance to a custom database (not using the docker image) follow the steps IN THIS ORDER.

1. Download the Jellyfin PGSQL container and configure it to point to an existing empty database and empty config directory. DO NOT USE YOUR EXISTING DATA OR SQLITE LIBRARY CONFIGURE A FULLY CLEAR INSTANCE.
2. Run Jellyfin once with it configured to your empty database, this will seed the database and its migration history.
3. Stop your Jellyfin instance after it has been started once (no need to fully configure it via the setup wizard). If you did not get the setup wizard then you did something wrong!
4. Install the pgloader tool `apt install pgloader` or see https://pgloader.readthedocs.io/en/latest/install.html.
5. Download the [jellyfindb.load](/docker/jellyfindb.load) file
6. Adapt the `jellyfindb.load` file accordingly to point towards your old jellyfin.db and your postgres instance. See https://pgloader.readthedocs.io/en/latest/ref/sqlite.html
7. Use the load file in `jellyfindb.load` to transfer your sqlite db into the postgres db like `pgloader /jellyfin-pgsql/jellyfindb.load`.
8. Move your old Data back to the Jellyfin directories
9. Start Jellyfin

If you get an error regarding a missing `__EFMigrationsHistory` you did not start Jellyfin with a clear state.
