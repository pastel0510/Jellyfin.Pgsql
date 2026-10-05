#!/usr/bin/env bash
# End-to-end smoke test of a Jellyfin.Pgsql Docker image against a real PostgreSQL server.
#
#   IMAGE=jellyfin-pgsql:test scripts/smoke-test.sh
#
# Environment:
#   IMAGE           image under test (required)
#   UPGRADE_FROM    optional older image: it sets up a server and library first, then IMAGE is started
#                   on the same config and database to exercise the upgrade migrations on existing data
#   PG_IMAGE        PostgreSQL server image (default postgres:18)
#   EXPECT_VERSION  optional Jellyfin version IMAGE must report (e.g. 12.1.0)
#   LOG_DIR         where container logs are written (default ./smoke-logs)
#   PORT            host port for Jellyfin (default 8096)
#   KEEP            if set, leave the containers running afterwards for debugging
set -euo pipefail

: "${IMAGE:?IMAGE is required}"
PG_IMAGE="${PG_IMAGE:-postgres:18}"
LOG_DIR="${LOG_DIR:-smoke-logs}"
PORT="${PORT:-8096}"
NAME="jfpg-smoke-$$"
NET="$NAME"
JF="$NAME-jellyfin"
PG="$NAME-postgres"
BASE="http://127.0.0.1:$PORT"
AUTH_HEADER='MediaBrowser Client="smoke-test", Device="ci", DeviceId="smoke-test", Version="1.0"'
USER_NAME="smoke"
USER_PASS="smoke-test-password"
MOVIE="Smoke Test (2020)"

mkdir -p "$LOG_DIR"
step() { echo "::group::$*" 2>/dev/null || true; echo "==> $*"; }
endstep() { echo "::endgroup::" 2>/dev/null || true; }
fail() { echo "SMOKE TEST FAILED: $*" >&2; exit 1; }

cleanup() {
    local code=$?
    docker logs "$JF" >"$LOG_DIR/jellyfin.log" 2>&1 || true
    docker logs "$PG" >"$LOG_DIR/postgres.log" 2>&1 || true
    if [[ -n "${KEEP:-}" ]]; then
        echo "KEEP set: leaving $JF, $PG and their volumes running" >&2
        exit $code
    fi
    docker rm -f "$JF" "$PG" >/dev/null 2>&1 || true
    docker volume rm "$NAME-config" "$NAME-media" >/dev/null 2>&1 || true
    docker network rm "$NET" >/dev/null 2>&1 || true
    if [[ $code -ne 0 ]]; then
        echo "---- last 80 lines of the Jellyfin log ($LOG_DIR/jellyfin.log) ----" >&2
        tail -n 80 "$LOG_DIR/jellyfin.log" >&2 || true
    fi
    exit $code
}
trap cleanup EXIT

psql_q() { docker exec -e PGPASSWORD=jellyfin "$PG" psql -U jellyfin -d jellyfin -tAc "$1"; }

start_jellyfin() {
    local image="$1"
    docker rm -f "$JF" >/dev/null 2>&1 || true
    docker run -d --name "$JF" --network "$NET" -p "127.0.0.1:$PORT:8096" \
        -e POSTGRES_HOST="$PG" -e POSTGRES_PORT=5432 -e POSTGRES_DB=jellyfin \
        -e POSTGRES_USER=jellyfin -e POSTGRES_PASSWORD=jellyfin \
        -v "$NAME-config:/config" -v "$NAME-media:/media:ro" "$image" >/dev/null
    for _ in $(seq 1 120); do
        if [[ "$(curl -fsS "$BASE/health" 2>/dev/null)" == "Healthy" ]]; then
            return 0
        fi
        if [[ "$(docker inspect -f '{{.State.Running}}' "$JF")" != "true" ]]; then
            fail "Jellyfin container ($image) exited during startup"
        fi
        sleep 2
    done
    fail "Jellyfin ($image) did not report Healthy on /health within 240s"
}

api() { # api METHOD PATH [JSON] -> prints body, fails on HTTP >= 400
    local method="$1" path="$2" body="${3:-}"
    local args=(-fsS -X "$method" "$BASE$path" -H "Authorization: $AUTH_HEADER${TOKEN:+, Token=\"$TOKEN\"}")
    [[ -n "$body" ]] && args+=(-H 'Content-Type: application/json' -d "$body")
    curl "${args[@]}"
}

run_wizard() {
    api POST /Startup/Configuration '{"UICulture":"en-US","MetadataCountryCode":"US","PreferredMetadataLanguage":"en"}' >/dev/null
    api GET /Startup/User >/dev/null
    api POST /Startup/User "{\"Name\":\"$USER_NAME\",\"Password\":\"$USER_PASS\"}" >/dev/null
    api POST /Startup/Complete >/dev/null
}

login() {
    TOKEN=""
    TOKEN="$(api POST /Users/AuthenticateByName "{\"Username\":\"$USER_NAME\",\"Pw\":\"$USER_PASS\"}" | jq -er .AccessToken)" \
        || fail "login as $USER_NAME failed"
}

add_library_and_scan() {
    api POST "/Library/VirtualFolders?name=Movies&collectionType=movies&paths=/media/movies&refreshLibrary=false" '{"LibraryOptions":{}}' >/dev/null
    # Adding a library does not reliably scan its contents, so run a full library scan explicitly.
    api POST /Library/Refresh >/dev/null
    wait_for_movie
}

wait_for_movie() {
    for _ in $(seq 1 90); do
        if [[ "$(api GET '/Items?Recursive=true&IncludeItemTypes=Movie' | jq '.TotalRecordCount')" -ge 1 ]]; then
            return 0
        fi
        sleep 2
    done
    echo "libraries: $(api GET /Library/VirtualFolders | jq -c '[.[] | {Name, Locations}]')" >&2
    docker exec "$JF" ls -laR /media >&2 || true
    fail "library scan did not produce the test movie within 180s"
}

check_data() {
    local movies streams
    movies="$(api GET '/Items?Recursive=true&IncludeItemTypes=Movie' | jq -r '.Items[].Name')"
    [[ "$movies" == *"Smoke Test"* ]] || fail "test movie missing from /Items (got: $movies)"
    streams="$(psql_q 'SELECT count(*) FROM "MediaStreamInfos"')"
    [[ "$streams" -ge 1 ]] || fail "no media streams stored in PostgreSQL (ffprobe data was not saved)"
    echo "movies: $movies | media streams in PostgreSQL: $streams"
}

check_logs() {
    docker logs "$JF" >"$LOG_DIR/jellyfin.log" 2>&1
    if grep -E '\[FTL\]|\[ERR\].*(Pgsql|EntityFrameworkCore|Jellyfin\.Database)|PostgresException|NpgsqlException|DbUpdateException|InvalidCastException' "$LOG_DIR/jellyfin.log" >"$LOG_DIR/db-errors.log"; then
        cat "$LOG_DIR/db-errors.log" >&2
        fail "database errors in the Jellyfin log"
    fi
}

step "Starting $PG_IMAGE"
docker network create "$NET" >/dev/null
docker volume create "$NAME-config" >/dev/null
docker volume create "$NAME-media" >/dev/null
docker run -d --name "$PG" --network "$NET" -e POSTGRES_USER=jellyfin -e POSTGRES_PASSWORD=jellyfin \
    -e POSTGRES_DB=jellyfin "$PG_IMAGE" >/dev/null
for _ in $(seq 1 60); do
    docker exec "$PG" pg_isready -h 127.0.0.1 -U jellyfin -d jellyfin >/dev/null 2>&1 && break
    sleep 1
done
docker exec "$PG" pg_isready -h 127.0.0.1 -U jellyfin -d jellyfin >/dev/null || fail "PostgreSQL did not become ready"
psql_q 'SELECT version()'
endstep

step "Creating a test video with jellyfin-ffmpeg"
docker run --rm --entrypoint /usr/lib/jellyfin-ffmpeg/ffmpeg -v "$NAME-media:/media" "$IMAGE" \
    -hide_banner -loglevel error -f lavfi -i testsrc=duration=3:size=320x240:rate=10 \
    -f lavfi -i sine=duration=3 -c:v libx264 -c:a aac -shortest \
    -metadata title="$MOVIE" "/media/$MOVIE.mkv"
docker run --rm --entrypoint sh -v "$NAME-media:/media" "$IMAGE" -c \
    "mkdir -p '/media/movies/$MOVIE' && mv '/media/$MOVIE.mkv' '/media/movies/$MOVIE/'"
endstep

TOKEN=""
if [[ -n "${UPGRADE_FROM:-}" ]]; then
    step "Setting up a server on the previous image $UPGRADE_FROM"
    start_jellyfin "$UPGRADE_FROM"
    run_wizard
    login
    add_library_and_scan
    check_data
    docker stop -t 30 "$JF" >/dev/null
    docker logs "$JF" >"$LOG_DIR/jellyfin-previous.log" 2>&1 || true
    endstep

    step "Upgrading to $IMAGE"
    start_jellyfin "$IMAGE"
    login
    wait_for_movie
    endstep
else
    step "Starting $IMAGE on an empty database"
    start_jellyfin "$IMAGE"
    run_wizard
    login
    add_library_and_scan
    endstep
fi

step "Checking server and data"
version="$(api GET /System/Info/Public | jq -r .Version)"
echo "Jellyfin version: $version"
if [[ -n "${EXPECT_VERSION:-}" && "$version" != "$EXPECT_VERSION" ]]; then
    fail "expected Jellyfin $EXPECT_VERSION, got $version"
fi
docker exec "$JF" sh -c 'pg_dump --version && psql --version'
check_data
check_logs
endstep

# Mirrors PgSqlDatabaseProvider.MigrationBackupFast / RestoreBackupFast; keep the arguments in sync.
step "Backup and restore with the bundled pg_dump/psql"
docker exec -e PGPASSWORD=jellyfin "$JF" pg_dump --host="$PG" --port=5432 --username=jellyfin --dbname=jellyfin \
    --file=/config/smoke-backup.sql --no-password --clean --if-exists
psql_q 'CREATE TABLE smoke_marker (id int)'
docker exec -e PGPASSWORD=jellyfin -e PGOPTIONS="-c client_min_messages=warning" "$JF" psql --host="$PG" --port=5432 --username=jellyfin --dbname=jellyfin \
    --no-password --quiet --set=ON_ERROR_STOP=1 --single-transaction \
    --command="DROP SCHEMA public CASCADE; CREATE SCHEMA public AUTHORIZATION pg_database_owner; GRANT USAGE ON SCHEMA public TO PUBLIC;" \
    --file=/config/smoke-backup.sql >/dev/null
[[ "$(psql_q "SELECT count(*) FROM pg_tables WHERE tablename = 'smoke_marker'")" == "0" ]] \
    || fail "restore did not replace the schema"
endstep

step "Restarting on the restored database"
docker restart -t 30 "$JF" >/dev/null
for _ in $(seq 1 120); do [[ "$(curl -fsS "$BASE/health" 2>/dev/null)" == "Healthy" ]] && break; sleep 2; done
login
check_data
check_logs
endstep

echo "SMOKE TEST PASSED ($IMAGE${UPGRADE_FROM:+, upgraded from $UPGRADE_FROM}, $PG_IMAGE)"
