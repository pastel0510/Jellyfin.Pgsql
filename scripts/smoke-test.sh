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
#   LAYOUT          "jellyfin" (default): the image's own paths, running as root. "linuxserver": the
#                   linuxserver.io paths (data /config/data, config /config) as a non-root user (uid 3000)
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
LAYOUT="${LAYOUT:-jellyfin}"
# The PremiereDate sort exercises two SQLite compatibility fixes: the undated movie must come first (NULLs first
# when ascending) and the year-only movies must be ordered by year (DateTime.MinValue + years, not -infinity).
MOVIES=("Undated Test" "Older Test (2010)" "Smoke Test (2020)")
EXPECTED_PREMIERE_ORDER="Undated Test,Older Test (2010),Smoke Test (2020)"

case "$LAYOUT" in
    jellyfin)
        LAYOUT_ARGS=()
        DATABASE_XML=/config/config/database.xml
        ;;
    linuxserver)
        LAYOUT_ARGS=(--user 3000:3000 -e HOME=/config -e JELLYFIN_DATA_DIR=/config/data -e JELLYFIN_CONFIG_DIR=/config
            -e JELLYFIN_CACHE_DIR=/config/cache -e JELLYFIN_LOG_DIR=/config/log)
        DATABASE_XML=/config/database.xml
        ;;
    *)
        echo "Unknown LAYOUT '$LAYOUT' (use jellyfin or linuxserver)" >&2
        exit 2
        ;;
esac
if [[ "$LAYOUT" != "jellyfin" && -n "${UPGRADE_FROM:-}" ]]; then
    echo "LAYOUT=$LAYOUT cannot be combined with UPGRADE_FROM (older images only support the jellyfin layout)" >&2
    exit 2
fi

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
    docker run -d --name "$JF" --network "$NET" -p "127.0.0.1:$PORT:8096" "${LAYOUT_ARGS[@]}" \
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
        if [[ "$(api GET '/Items?Recursive=true&IncludeItemTypes=Movie' | jq '.TotalRecordCount')" -ge "${#MOVIES[@]}" ]]; then
            return 0
        fi
        sleep 2
    done
    echo "libraries: $(api GET /Library/VirtualFolders | jq -c '[.[] | {Name, Locations}]')" >&2
    docker exec "$JF" ls -laR /media >&2 || true
    fail "library scan did not produce the ${#MOVIES[@]} test movies within 180s"
}

check_data() {
    local movies streams
    movies="$(api GET '/Items?Recursive=true&IncludeItemTypes=Movie' | jq -r '.Items[].Name')"
    [[ "$movies" == *"Smoke Test"* ]] || fail "test movie missing from /Items (got: $movies)"
    streams="$(psql_q 'SELECT count(*) FROM "MediaStreamInfos"')"
    [[ "$streams" -ge 1 ]] || fail "no media streams stored in PostgreSQL (ffprobe data was not saved)"
    echo "movies: $movies | media streams in PostgreSQL: $streams"
}

check_sqlite_compatibility() {
    local order infinite found
    order="$(api GET '/Items?Recursive=true&IncludeItemTypes=Movie&SortBy=PremiereDate&SortOrder=Ascending' | jq -r '[.Items[].Name] | join(",")')"
    [[ "$order" == "$EXPECTED_PREMIERE_ORDER" ]] \
        || fail "movies by PremiereDate: expected $EXPECTED_PREMIERE_ORDER (SQLite order), got $order"
    infinite="$(psql_q "SELECT coalesce(sum((xpath('/row/n/text()', query_to_xml(format(
        'SELECT count(*) AS n FROM %I WHERE %I IN (''infinity'', ''-infinity'')', table_name, column_name), false, true, '')))[1]::text::int), 0)
        FROM information_schema.columns WHERE table_schema = 'public'
        AND data_type IN ('timestamp with time zone', 'timestamp without time zone', 'date')")"
    [[ "$infinite" == "0" ]] || fail "$infinite infinite timestamp values stored in PostgreSQL"
    # Jellyfin matches the mixed-case OriginalTitle with EF.Functions.Like, which ignores case on SQLite.
    psql_q "UPDATE \"BaseItems\" SET \"OriginalTitle\" = 'Zebra Crossing' WHERE \"Name\" = 'Smoke Test (2020)'" >/dev/null
    found="$(api GET '/Items?Recursive=true&IncludeItemTypes=Movie&searchTerm=zebra' | jq -r '[.Items[].Name] | join(",")')"
    [[ "$found" == "Smoke Test (2020)" ]] || fail "searching 'zebra' did not find the movie with OriginalTitle 'Zebra Crossing' (got: $found)"
    grep -q 'PostgreSQL connection string: .*jit=off' "$LOG_DIR/jellyfin.log" || fail "connection does not set jit=off"
    if docker exec "$JF" grep -qi 'password' "$DATABASE_XML"; then
        fail "$DATABASE_XML contains the database password"
    fi
    echo "PremiereDate order: $order | case-insensitive LIKE | infinite timestamps: $infinite | jit=off | no password in $DATABASE_XML"
}

check_statistics() {
    # Jellyfin runs RefreshStatistics after every library scan; the plugin answers it with ANALYZE.
    for _ in $(seq 1 60); do
        if [[ "$(psql_q "SELECT last_analyze IS NOT NULL FROM pg_stat_user_tables WHERE relname = 'BaseItems'")" == "t" ]]; then
            echo "BaseItems analyzed after the library scan"
            return 0
        fi
        sleep 2
    done
    fail "BaseItems was not analyzed within 120s of the library scan (RefreshStatistics)"
}

check_kept_backup() {
    # Jellyfin deletes the pre-migration backup once the migrations succeed; the plugin keeps the newest one.
    local backup
    backup="$(sed -n 's/.*Starting PostgreSQL backup: \(.*\.sql\).*/\1/p' "$LOG_DIR/jellyfin.log" | tail -1)"
    if [[ -z "$backup" ]]; then
        echo "no migration ran, so no pre-migration backup was taken"
        return 0
    fi
    docker exec "$JF" test -s "$backup" || fail "the pre-migration backup $backup was not kept"
    echo "pre-migration backup kept: $backup"
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

step "Creating test videos with jellyfin-ffmpeg"
for movie in "${MOVIES[@]}"; do
    docker run --rm --entrypoint /usr/lib/jellyfin-ffmpeg/ffmpeg -v "$NAME-media:/media" "$IMAGE" \
        -hide_banner -loglevel error -f lavfi -i testsrc=duration=3:size=320x240:rate=10 \
        -f lavfi -i sine=duration=3 -c:v libx264 -c:a aac -shortest "/media/$movie.mkv"
    docker run --rm --entrypoint sh -v "$NAME-media:/media" "$IMAGE" -c \
        "mkdir -p '/media/movies/$movie' && mv '/media/$movie.mkv' '/media/movies/$movie/'"
done
if [[ "$LAYOUT" == "linuxserver" ]]; then
    docker run --rm --entrypoint chown -v "$NAME-config:/config" -v "$NAME-media:/media" "$IMAGE" -R 3000:3000 /config /media
fi
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
    # Older images stored DateTime.MinValue as -infinity, which the current plugin can no longer read until the
    # Jellyfin12.1_DateTimeInfinity migration converts it. Plant one where the next login reads it.
    if [[ "$(psql_q "SELECT count(*) FROM \"__EFMigrationsHistory\" WHERE \"MigrationId\" LIKE '%DateTimeInfinity'")" == "0" ]]; then
        psql_q "UPDATE \"Users\" SET \"LastActivityDate\" = '-infinity'" >/dev/null
        echo "planted -infinity in Users.LastActivityDate"
    fi
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
    check_statistics
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
check_sqlite_compatibility
check_kept_backup
endstep

# Mirrors PgSqlDatabaseProvider.MigrationBackupFast / RestoreBackupFast; keep the arguments in sync.
step "Backup and restore with the bundled pg_dump/psql"
docker exec -e PGPASSWORD=jellyfin "$JF" pg_dump --host="$PG" --port=5432 --username=jellyfin --dbname=jellyfin \
    --file=/tmp/smoke-backup.sql --no-password --clean --if-exists
psql_q 'CREATE TABLE smoke_marker (id int)'
docker exec -e PGPASSWORD=jellyfin -e PGOPTIONS="-c client_min_messages=warning" "$JF" psql --host="$PG" --port=5432 --username=jellyfin --dbname=jellyfin \
    --no-password --quiet --set=ON_ERROR_STOP=1 --single-transaction \
    --command="DROP SCHEMA public CASCADE; CREATE SCHEMA public AUTHORIZATION pg_database_owner; GRANT USAGE ON SCHEMA public TO PUBLIC;" \
    --file=/tmp/smoke-backup.sql >/dev/null
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

echo "SMOKE TEST PASSED ($IMAGE${UPGRADE_FROM:+, upgraded from $UPGRADE_FROM}, $PG_IMAGE, $LAYOUT layout)"
