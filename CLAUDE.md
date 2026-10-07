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
- `FULL=1 scripts/verify.sh`: also the linuxserver-layout smoke test and `scripts/migration-test.sh` (SQLite to
  PostgreSQL migration end to end; needs sqlite3, psql and pgloader). CI runs this.

## Rules

- Keep `Microsoft.EntityFrameworkCore*` and `Microsoft.Extensions*` versions equal to the server's
  `jellyfin/Directory.Packages.props`.
- Add migrations with `dotnet ef migrations add Jellyfin<version> --project Jellyfin.Plugin.Pgsql -- --migration-provider Jellyfin-PgSql`.
  Never edit migrations that were already released.
- Raw SQL in upstream SQLite migrations is not carried over by EF; port data fixes to PostgreSQL syntax by hand.
- The pg_dump/psql arguments in `scripts/smoke-test.sh` mirror `PgSqlDatabaseProvider`; keep them in sync.
- Keep PostgreSQL behaving like SQLite where Jellyfin depends on it (NULL ordering, `DateTime.MinValue`, no JIT; see
  "Differences from SQLite" in the README). The smoke test checks these.
- Every merge to master that changes the plugin or Docker files is published automatically (Docker workflow after
  Verify): `<version>-<n>` plus the moving `<version>` and `latest` tags, a git tag and a GitHub release whose notes list new
  migrations. Docs use the moving tag for trying it and recommend pinning `<version>-<n>@<digest>` for production.
- No emoji anywhere in the repository (code, docs, workflow names, commit messages, PR texts); keep the tone plain and
  professional. `scripts/verify.sh` fails on emoji.
