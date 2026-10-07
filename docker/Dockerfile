# syntax=docker/dockerfile:1
# Build stage
# Context hint: project root ../
# sudo docker build -t ghcr.io/pastel0510/jellyfin.pgsql:12.2 -f ./Dockerfile ../
# The plugin is a framework-dependent, RID-neutral net10.0 library, so it is built once on the
# native build platform and reused for every target architecture (no QEMU for the compile).
FROM --platform=$BUILDPLATFORM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /src

# Copy project files
COPY jellyfin.ruleset .
COPY Jellyfin.Plugin.Pgsql.sln .
COPY build.yaml .
COPY Jellyfin.Plugin.Pgsql/ ./Jellyfin.Plugin.Pgsql/

# Restore and publish (no --runtime: output is identical for amd64/arm64). The Docker workflow passes the plugin
# version of the build (<major>.<minor>.<k>.0, as listed in manifest.json).
ARG PLUGIN_VERSION=1.0.0.0
RUN dotnet restore Jellyfin.Plugin.Pgsql.sln
RUN dotnet publish Jellyfin.Plugin.Pgsql.sln -c Release --no-restore -p:Version=${PLUGIN_VERSION} -o /app/publish

# Final stage - Jellyfin with plugin
FROM jellyfin/jellyfin:12.2

# Install the PostgreSQL 18 client tools (pg_dump/psql) used for the pre-migration backup/restore.
# pg_dump refuses to dump a server newer than itself, so this major version is the newest
# PostgreSQL server the image can back up. Uses the PGDG repo for the base image's Debian release
# in deb822 format; apt reads the ASCII-armored key directly, so gnupg is not needed.
RUN set -eux; \
    . /etc/os-release; \
    apt-get update; \
    apt-get install -y --no-install-recommends ca-certificates curl; \
    install -d /usr/share/postgresql-common/pgdg; \
    curl -fsSL -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc https://www.postgresql.org/media/keys/ACCC4CF8.asc; \
    printf 'Types: deb\nURIs: https://apt.postgresql.org/pub/repos/apt\nSuites: %s-pgdg\nComponents: main\nSigned-By: /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc\n' "${VERSION_CODENAME}" \
        > /etc/apt/sources.list.d/pgdg.sources; \
    apt-get update; \
    apt-get install -y --no-install-recommends postgresql-client-18 xmlstarlet; \
    pg_dump --version; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/*

# Copy the published plugin and config files
COPY --from=build /app/publish/ /jellyfin-pgsql/plugin/
COPY docker/entrypoint.sh /entrypoint.sh
COPY docker/database.xml /jellyfin-pgsql/database.xml
# COPY docker/jellyfindb.load /jellyfin-pgsql/jellyfindb.load
# COPY docker/jellyfin.PgsqlMigrator.dll /jellyfin-pgsql/jellyfin.PgsqlMigrator.dll

# Make entrypoint executable
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
