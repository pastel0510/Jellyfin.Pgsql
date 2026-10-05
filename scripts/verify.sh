#!/usr/bin/env bash
# Full verification of the plugin: build, EF Core migration check, Docker image build and smoke test.
# Used by CI and by the automated Jellyfin update workflow; run it locally the same way:
#
#   scripts/verify.sh                 everything
#   SKIP_DOCKER=1 scripts/verify.sh   build + migration check only
#
# Environment: IMAGE (default jellyfin-pgsql:verify), DOCKERFILE (default docker/Dockerfile), plus the
# variables of scripts/smoke-test.sh (UPGRADE_FROM, PG_IMAGE, EXPECT_VERSION, LOG_DIR).
set -euo pipefail
cd "$(dirname "$0")/.."

export IMAGE="${IMAGE:-jellyfin-pgsql:verify}"
DOCKERFILE="${DOCKERFILE:-docker/Dockerfile}"
PROJECT=Jellyfin.Plugin.Pgsql

echo "==> Checking for emoji (not used in this repository)"
if git ls-files -z -- . ':!:jellyfin' | LC_ALL=C.UTF-8 xargs -0 grep -nIP '[\x{1F000}-\x{1FAFF}\x{2600}-\x{27BF}\x{2B00}-\x{2BFF}\x{FE0F}]'; then
    echo "Emoji found in the files above; use plain text instead." >&2
    exit 1
fi

echo "==> Building the plugin (Release, warnings as errors)"
dotnet tool restore
dotnet build Jellyfin.Plugin.Pgsql.sln -c Release

echo "==> Checking the PostgreSQL migrations match the Jellyfin data model"
dotnet build "$PROJECT" -c Debug
if ! dotnet ef migrations has-pending-model-changes --project "$PROJECT" --no-build -- --migration-provider Jellyfin-PgSql; then
    echo "The Jellyfin data model has changes without a PostgreSQL migration. Add one with:" >&2
    echo "  dotnet ef migrations add Jellyfin<version> --project $PROJECT -- --migration-provider Jellyfin-PgSql" >&2
    exit 1
fi

if [[ -n "${SKIP_DOCKER:-}" ]]; then
    echo "VERIFY PASSED (Docker skipped)"
    exit 0
fi

echo "==> Building the Docker image $IMAGE"
docker build -f "$DOCKERFILE" -t "$IMAGE" .

echo "==> Smoke testing $IMAGE"
scripts/smoke-test.sh

echo "VERIFY PASSED"
