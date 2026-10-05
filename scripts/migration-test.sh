#!/usr/bin/env bash
# End-to-end test of scripts/migrate-sqlite-to-postgres.sh: sets up a stock Jellyfin on SQLite with a small
# library and user state, migrates it into PostgreSQL, starts the Jellyfin.Pgsql image on the migrated config and
# checks that users, library, watch state and edge-case rows came across and that new rows can be inserted.
#
#   IMAGE=jellyfin-pgsql:test scripts/migration-test.sh
#
# Environment:
#   IMAGE          Jellyfin.Pgsql image under test (required)
#   SQLITE_IMAGE   stock Jellyfin image for the SQLite side (default: the base image in docker/Dockerfile)
#   PG_IMAGE       PostgreSQL server image (default postgres:18)
#   LOG_DIR        where logs are written (default ./migration-logs)
#   PORT, PG_PORT  host ports for Jellyfin and PostgreSQL (default 8097 and 55432)
# Needs docker, sqlite3, psql, jq and pgloader (or PGLOADER_IMAGE) on the host.
set -euo pipefail
cd "$(dirname "$0")/.."

: "${IMAGE:?IMAGE is required}"
SQLITE_IMAGE="${SQLITE_IMAGE:-$(grep -oP '^FROM \Kjellyfin/jellyfin:\S+' docker/Dockerfile)}"
PG_IMAGE="${PG_IMAGE:-postgres:18}"
LOG_DIR="$(mkdir -p "${LOG_DIR:-migration-logs}" && cd "${LOG_DIR:-migration-logs}" && pwd)"
PORT="${PORT:-8097}"
PG_PORT="${PG_PORT:-55432}"
NAME="jfpg-migration-$$"
JF="$NAME-jellyfin"
PG="$NAME-postgres"
WORK="$(mktemp -d -t jfpg-migration.XXXXXX)"
BASE="http://127.0.0.1:$PORT"
AUTH_HEADER='MediaBrowser Client="migration-test", Device="ci", DeviceId="migration-test", Version="1.0"'
USER_NAME="migrated"
USER_PASS="migration-test-password"
MOVIES=("Alpha Test (2001)" "Beta Test (2002)" "Gamma Test (2003)")
LONG_APP_VERSION="$(printf 'v%.0s' {1..40})"
RUN_AS="$(id -u):$(id -g)"
TOKEN=""

step() { echo "::group::$*" 2>/dev/null || true; echo "==> $*"; }
endstep() { echo "::endgroup::" 2>/dev/null || true; }
fail() { echo "MIGRATION TEST FAILED: $*" >&2; exit 1; }

cleanup() {
    local code=$?
    docker logs "$JF" >"$LOG_DIR/jellyfin.log" 2>&1 || true
    docker rm -f "$JF" "$PG" >/dev/null 2>&1 || true
    docker network rm "$NAME" >/dev/null 2>&1 || true
    rm -rf "$WORK"
    if [[ $code -ne 0 ]]; then
        echo "---- last 60 lines of the Jellyfin log ($LOG_DIR/jellyfin.log) ----" >&2
        tail -n 60 "$LOG_DIR/jellyfin.log" >&2 || true
    fi
    exit $code
}
trap cleanup EXIT

psql_q() { PGPASSWORD=jellyfin psql -X -h 127.0.0.1 -p "$PG_PORT" -U jellyfin -d jellyfin -tAc "$1"; }

api() { # api METHOD PATH [JSON] -> prints body, fails on HTTP >= 400
    local method="$1" path="$2" body="${3:-}"
    local args=(-fsS -X "$method" "$BASE$path" -H "Authorization: $AUTH_HEADER${TOKEN:+, Token=\"$TOKEN\"}")
    [[ -n "$body" ]] && args+=(-H 'Content-Type: application/json' -d "$body")
    curl "${args[@]}"
}

start_jellyfin() { # start_jellyfin IMAGE CONFIG_DIR [extra docker args...]
    local image="$1" config="$2"
    shift 2
    docker rm -f "$JF" >/dev/null 2>&1 || true
    docker run -d --name "$JF" --network "$NAME" -p "127.0.0.1:$PORT:8096" --user "$RUN_AS" -e HOME=/config \
        -e JELLYFIN_CACHE_DIR=/config/cache -v "$config:/config" -v "$WORK/media:/media:ro" "$@" "$image" >/dev/null
    for _ in $(seq 1 120); do
        if [[ "$(curl -fsS "$BASE/health" 2>/dev/null)" == "Healthy" ]]; then
            return 0
        fi
        if [[ "$(docker inspect -f '{{.State.Running}}' "$JF")" != "true" ]]; then
            docker logs "$JF" 2>&1 | tail -20 >&2
            fail "Jellyfin container ($image) exited during startup"
        fi
        sleep 2
    done
    fail "Jellyfin ($image) did not report Healthy within 240s"
}

stop_jellyfin() {
    docker stop -t 30 "$JF" >/dev/null
    docker logs "$JF" >"$LOG_DIR/$1.log" 2>&1 || true
    docker rm -f "$JF" >/dev/null
}

login() {
    TOKEN=""
    TOKEN="$(api POST /Users/AuthenticateByName "{\"Username\":\"$USER_NAME\",\"Pw\":\"$USER_PASS\"}" | jq -er .AccessToken)" \
        || fail "login as $USER_NAME failed"
}

movie_id() { api GET "/Items?Recursive=true&IncludeItemTypes=Movie&SortBy=SortName" | jq -er ".Items[$1].Id"; }

step "Preparing PostgreSQL ($PG_IMAGE) and test media"
mkdir -p "$WORK/media/movies" "$WORK/sqlite-config" "$WORK/seed-config"
docker network create "$NAME" >/dev/null
docker run -d --name "$PG" --network "$NAME" -p "127.0.0.1:$PG_PORT:5432" -e POSTGRES_USER=jellyfin -e POSTGRES_PASSWORD=jellyfin \
    -e POSTGRES_DB=jellyfin "$PG_IMAGE" >/dev/null
for movie in "${MOVIES[@]}"; do
    mkdir -p "$WORK/media/movies/$movie"
    docker run --rm --user "$RUN_AS" --entrypoint /usr/lib/jellyfin-ffmpeg/ffmpeg -v "$WORK/media:/media" "$SQLITE_IMAGE" \
        -hide_banner -loglevel error -f lavfi -i testsrc=duration=3:size=320x240:rate=10 \
        -f lavfi -i sine=duration=3 -c:v libx264 -c:a aac -shortest "/media/movies/$movie/$movie.mkv"
done
for _ in $(seq 1 60); do
    docker exec "$PG" pg_isready -h 127.0.0.1 -U jellyfin -d jellyfin >/dev/null 2>&1 && break
    sleep 1
done
psql_q 'SELECT version()'
endstep

step "Setting up Jellyfin on SQLite ($SQLITE_IMAGE)"
start_jellyfin "$SQLITE_IMAGE" "$WORK/sqlite-config"
api POST /Startup/Configuration '{"UICulture":"en-US","MetadataCountryCode":"US","PreferredMetadataLanguage":"en"}' >/dev/null
api GET /Startup/User >/dev/null
api POST /Startup/User "{\"Name\":\"$USER_NAME\",\"Password\":\"$USER_PASS\"}" >/dev/null
api POST /Startup/Complete >/dev/null
login
api POST "/Library/VirtualFolders?name=Movies&collectionType=movies&paths=/media/movies&refreshLibrary=false" '{"LibraryOptions":{}}' >/dev/null
api POST /Library/Refresh >/dev/null
for _ in $(seq 1 90); do
    [[ "$(api GET '/Items?Recursive=true&IncludeItemTypes=Movie' | jq .TotalRecordCount)" -ge "${#MOVIES[@]}" ]] && break
    sleep 2
done
[[ "$(api GET '/Items?Recursive=true&IncludeItemTypes=Movie' | jq .TotalRecordCount)" -ge "${#MOVIES[@]}" ]] || fail "SQLite library scan incomplete"
api POST "/UserFavoriteItems/$(movie_id 0)" >/dev/null
api POST "/UserPlayedItems/$(movie_id 1)" >/dev/null
stop_jellyfin jellyfin-sqlite
SQLITE_DB="$WORK/sqlite-config/data/jellyfin.db"
[[ -f "$SQLITE_DB" ]] || fail "no SQLite database at $SQLITE_DB"
endstep

step "Planting rows that need conversion (array column, over-length string)"
sqlite3 -bail "$SQLITE_DB" <<SQL
INSERT INTO "KeyframeData" ("ItemId", "TotalDuration", "KeyframeTicks")
    SELECT "Id", 30000000, '[0,8340000,16680000]' FROM "BaseItems" WHERE "Type" LIKE '%.Movie' LIMIT 1;
UPDATE "Devices" SET "AppVersion" = '$LONG_APP_VERSION';
SQL
echo "KeyframeData rows: $(sqlite3 "$SQLITE_DB" 'SELECT count(*) FROM KeyframeData'), devices: $(sqlite3 "$SQLITE_DB" 'SELECT count(*) FROM Devices')"
endstep

step "Seeding PostgreSQL with $IMAGE"
PG_ENV=(-e POSTGRES_HOST="$PG" -e POSTGRES_DB=jellyfin -e POSTGRES_USER=jellyfin -e POSTGRES_PASSWORD=jellyfin)
start_jellyfin "$IMAGE" "$WORK/seed-config" "${PG_ENV[@]}"
stop_jellyfin jellyfin-seed
echo "migrations recorded: $(psql_q 'SELECT count(*) FROM "__EFMigrationsHistory"')"
endstep

step "Migrating SQLite to PostgreSQL"
POSTGRES_HOST=127.0.0.1 POSTGRES_PORT="$PG_PORT" POSTGRES_DB=jellyfin POSTGRES_USER=jellyfin POSTGRES_PASSWORD=jellyfin \
    WORK_DIR="$WORK/migration" scripts/migrate-sqlite-to-postgres.sh "$SQLITE_DB" 2>&1 | tee "$LOG_DIR/migrate.log"
grep -q 'MIGRATION COMPLETE' "$LOG_DIR/migrate.log" || fail "migration script did not complete"
endstep

step "Starting $IMAGE on the migrated config"
docker rm -f "$JF" >/dev/null 2>&1 || true
set +e
docker run --name "$JF" --network "$NAME" --user "$RUN_AS" -e HOME=/config -v "$WORK/sqlite-config:/config" \
    "${PG_ENV[@]}" "$IMAGE" >"$LOG_DIR/jellyfin-unmigrated-config.log" 2>&1
code=$?
set -e
docker rm -f "$JF" >/dev/null
if [[ $code -ne 2 ]] || ! grep -q 'not PostgreSQL' "$LOG_DIR/jellyfin-unmigrated-config.log"; then
    fail "the image did not refuse the SQLite database.xml (exit $code)"
fi
echo "the SQLite database.xml is refused with a clear message, as expected"
mv "$WORK/sqlite-config/config/database.xml" "$WORK/sqlite-config/config/database.xml.sqlite"
mv "$SQLITE_DB" "$SQLITE_DB.migrated"
start_jellyfin "$IMAGE" "$WORK/sqlite-config" "${PG_ENV[@]}"
endstep

step "Checking the migrated server"
login
movies="$(api GET '/Items?Recursive=true&IncludeItemTypes=Movie' | jq .TotalRecordCount)"
favourites="$(api GET '/Items?Recursive=true&IncludeItemTypes=Movie&Filters=IsFavorite' | jq .TotalRecordCount)"
played="$(api GET '/Items?Recursive=true&IncludeItemTypes=Movie&Filters=IsPlayed' | jq .TotalRecordCount)"
echo "movies: $movies, favourites: $favourites, played: $played"
[[ "$movies" == "${#MOVIES[@]}" && "$favourites" == "1" && "$played" == "1" ]] || fail "library or user state was not migrated"
[[ "$(psql_q 'SELECT array_to_string("KeyframeTicks", $$,$$) FROM "KeyframeData"')" == "0,8340000,16680000" ]] \
    || fail "KeyframeData.KeyframeTicks was not migrated as an array"
[[ "$(psql_q 'SELECT max(length("AppVersion")) FROM "Devices"')" -le 32 ]] || fail "Devices.AppVersion was not trimmed"
# Writes after the migration: new rows need identity sequences past the migrated ids.
api POST "/UserFavoriteItems/$(movie_id 2)" >/dev/null
api POST /Auth/Keys?app=migration-test >/dev/null
docker restart -t 30 "$JF" >/dev/null
for _ in $(seq 1 120); do [[ "$(curl -fsS "$BASE/health" 2>/dev/null)" == "Healthy" ]] && break; sleep 2; done
login
[[ "$(api GET '/Items?Recursive=true&IncludeItemTypes=Movie&Filters=IsFavorite' | jq .TotalRecordCount)" == "2" ]] \
    || fail "a favourite set after the migration was not stored"
[[ "$(psql_q 'SELECT count(*) FROM "ApiKeys"')" -ge 1 ]] || fail "an API key created after the migration was not stored"
docker logs "$JF" >"$LOG_DIR/jellyfin.log" 2>&1
if grep -E '\[FTL\]|\[ERR\].*(Pgsql|EntityFrameworkCore|Jellyfin\.Database)|PostgresException|NpgsqlException|DbUpdateException|23505' \
    "$LOG_DIR/jellyfin.log" >"$LOG_DIR/db-errors.log"; then
    cat "$LOG_DIR/db-errors.log" >&2
    fail "database errors in the Jellyfin log"
fi
grep -q 'PgSqlDatabaseProvider: PostgreSQL connection string' "$LOG_DIR/jellyfin.log" || fail "the server is not running on PostgreSQL"
endstep

echo "MIGRATION TEST PASSED ($SQLITE_IMAGE on SQLite -> $IMAGE on $PG_IMAGE)"
