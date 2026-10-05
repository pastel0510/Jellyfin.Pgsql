# Jellyfin.Pgsql

PostgreSQL database provider plugin for the Jellyfin media server (EF Core + Npgsql), shipped as a Docker image
built on `jellyfin/jellyfin`.

- `Jellyfin.Plugin.Pgsql/Database/PgSqlDatabaseProvider.cs`: the provider (connection, backup/restore via pg_dump/psql).
- `Jellyfin.Plugin.Pgsql/Migrations/`: PostgreSQL EF Core migrations, one per Jellyfin version with model changes.
- `jellyfin/`: upstream Jellyfin source as a submodule, for reference only (the plugin builds against NuGet packages).
- `.github/scripts/update_jellyfin.py`: bumps all versions to a Jellyfin release.

## Verify

- `scripts/verify.sh`: Release build (warnings are errors), migration/model check, Docker build, smoke test.
- `SKIP_DOCKER=1 scripts/verify.sh`: build and migration check only.

## Rules

- Keep `Microsoft.EntityFrameworkCore*` and `Microsoft.Extensions*` versions equal to the server's
  `jellyfin/Directory.Packages.props`.
- Add migrations with `dotnet ef migrations add Jellyfin<version> --project Jellyfin.Plugin.Pgsql -- --migration-provider Jellyfin-PgSql`.
  Never edit migrations that were already released.
- Raw SQL in upstream SQLite migrations is not carried over by EF; port data fixes to PostgreSQL syntax by hand.
- The pg_dump/psql arguments in `scripts/smoke-test.sh` mirror `PgSqlDatabaseProvider`; keep them in sync.
