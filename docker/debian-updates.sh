#!/bin/sh
# Apply or count pending updates from the base image's Debian sources (the release, its updates and its security
# archive) only. The other sources stay out: the base image's Jellyfin repository is Jellyfin's development
# channel, whose newer ffmpeg builds the image must not pick up, and the PostgreSQL client comes from PGDG at build.
#
#   debian-updates.sh upgrade   install the updates (used by the Dockerfile)
#   debian-updates.sh check     print how many packages have an update (used by the weekly rebuild check)
set -eu

mode="${1:?usage: $0 upgrade|check}"
parts="$(mktemp -d)"
trap 'rm -rf "$parts"' EXIT
if [ -f /etc/apt/sources.list.d/debian.sources ]; then
    cp /etc/apt/sources.list.d/debian.sources "$parts/"
fi
list=/dev/null
if [ -s /etc/apt/sources.list ]; then
    list=/etc/apt/sources.list
fi

apt_debian() {
    apt-get -o "Dir::Etc::SourceParts=$parts" -o "Dir::Etc::SourceList=$list" "$@"
}

apt_debian update -qq
case "$mode" in
    upgrade)
        DEBIAN_FRONTEND=noninteractive apt_debian upgrade -y --no-install-recommends
        ;;
    check)
        apt_debian upgrade --simulate | grep -c '^Inst ' || true
        ;;
    *)
        echo "unknown mode $mode (use upgrade or check)" >&2
        exit 2
        ;;
esac
