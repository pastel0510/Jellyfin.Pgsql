#!/usr/bin/env bash
# Print UPGRADE_FROM=<image:tag> for the newest published <version>-<n> tag of an image, for the
# smoke test's upgrade path. Prints nothing when the image has not been published yet.
#   previous_image.sh ghcr.io/owner/jellyfin.pgsql
# Uses ACTOR and GH_TOKEN for registry credentials when set.
set -euo pipefail
IMAGE="${1:?image name required}"

creds=()
[[ -n "${ACTOR:-}" && -n "${GH_TOKEN:-}" ]] && creds=(--creds "${ACTOR}:${GH_TOKEN}")
if ! tags="$(skopeo list-tags "${creds[@]}" "docker://${IMAGE}" 2>/dev/null | jq -r '.Tags[]')"; then
    echo "No published ${IMAGE} found, skipping the upgrade test" >&2
    exit 0
fi
newest="$(grep -E '^[0-9]+(\.[0-9]+)+-[0-9]+$' <<<"$tags" | sort -V | tail -1 || true)"
if [[ -n "$newest" ]]; then
    echo "Upgrade test starts from ${IMAGE}:${newest}" >&2
    echo "UPGRADE_FROM=${IMAGE}:${newest}"
fi
