#!/usr/bin/env bash
# Print the Markdown release notes for a published image build.
#
#   release_notes.sh TAG SHA IMAGE DIGEST [PREVIOUS]
#
#   TAG       the build's tag, e.g. 12.1-2
#   SHA       the commit the image was built from
#   IMAGE     the image name, e.g. ghcr.io/owner/jellyfin.pgsql
#   DIGEST    the multi-arch image digest (sha256:...)
#   PREVIOUS  optional git ref to compare with; default: the newest earlier build tag (<version>-<n>) that is an
#             ancestor of SHA. Without one, the notes only describe the build itself.
#
# Needs the full git history and tags. Lists every EF Core migration added since PREVIOUS: migrations run on the
# first start of the new image and cannot be undone by going back to an older image.
set -euo pipefail

TAG="${1:?tag required}"
SHA="${2:?commit required}"
IMAGE="${3:?image required}"
DIGEST="${4:?digest required}"
PREVIOUS="${5:-}"
REPO_URL="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-pastel0510/Jellyfin.Pgsql}"
MIGRATIONS_DIR=Jellyfin.Plugin.Pgsql/Migrations

if [[ -z "$PREVIOUS" ]]; then
    PREVIOUS="$(git tag --merged "$SHA" | grep -E '^[0-9]+(\.[0-9]+)+-[0-9]+$' | grep -vxF "$TAG" | sort -V | tail -1 || true)"
fi
JELLYFIN_VERSION="$(git show "$SHA:docker/Dockerfile" | grep -oP '^FROM jellyfin/jellyfin:\K\S+')"

echo "## Image"
echo
echo "Jellyfin ${JELLYFIN_VERSION} with the PostgreSQL provider, for linux/amd64 and linux/arm64, built from ${SHA:0:7}."
echo
echo '```'
echo "${IMAGE}:${TAG}@${DIGEST}"
echo '```'
echo
# Set by the Docker workflow for builds that also publish the plugin package.
if [[ -n "${PLUGIN_VERSION:-}" && -n "${PLUGIN_URL:-}" ]]; then
    echo "Plugin package for servers without Docker: [${PLUGIN_URL##*/}](${PLUGIN_URL}) (plugin version ${PLUGIN_VERSION},"
    echo "also offered by the plugin repository; see [Installing without Docker](${REPO_URL}#installing-without-docker))."
    echo
fi

echo "## Database migrations"
echo
if [[ -z "$PREVIOUS" ]]; then
    echo "First build in this repository; see the migrations in \`${MIGRATIONS_DIR}\`."
else
    mapfile -t migrations < <(git diff --name-only --diff-filter=A "$PREVIOUS" "$SHA" -- "$MIGRATIONS_DIR" \
        | grep -vE '\.Designer\.cs$|ModelSnapshot\.cs$' | xargs -r -n1 basename | sed 's/\.cs$//')
    if [[ ${#migrations[@]} -eq 0 ]]; then
        echo "None since ${PREVIOUS}. Switching back to ${PREVIOUS} is safe."
    else
        echo "**This build adds database migrations.** They run on the first start of this image. The plugin takes a"
        echo "\`pg_dump\` first and restores it if a migration fails; builds from 12.2-2 on also keep the newest such dump"
        echo "in \`<data dir>/PgsqlBackups\` after a successful upgrade. Going back to an older image afterwards is not"
        echo "supported: restore a backup taken before the upgrade instead. Take your own \`pg_dump\` before upgrading."
        echo
        for migration in "${migrations[@]}"; do
            echo "- \`${migration}\`"
        done
    fi
fi
echo

# Known issues of a Jellyfin version, kept in .github/release-notes/<version>.md of the checked-out tree, so that
# issues found after a build was released can be added to its notes by re-running the Release Notes workflow.
KNOWN_ISSUES="$(dirname "$0")/../release-notes/${JELLYFIN_VERSION}.md"
if [[ -s "$KNOWN_ISSUES" ]]; then
    echo "## Known issues in Jellyfin ${JELLYFIN_VERSION}"
    echo
    cat "$KNOWN_ISSUES"
    echo
fi

if [[ -n "$PREVIOUS" ]]; then
    echo "## Changes since ${PREVIOUS}"
    echo
    while read -r commit; do
        subject="$(git log -1 --format=%s "$commit")"
        if [[ "$subject" =~ ^Merge\ pull\ request\ \#([0-9]+) ]]; then
            title="$(git log -1 --format=%b "$commit" | sed -n '/./{p;q}')"
            echo "- ${title:-$subject} (#${BASH_REMATCH[1]})"
        else
            echo "- ${subject}"
        fi
    done < <(git rev-list --first-parent "$PREVIOUS..$SHA")
    echo
    echo "Full diff: ${REPO_URL}/compare/${PREVIOUS}...${SHA:0:12}"
fi
