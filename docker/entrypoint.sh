#!/bin/bash
set -euo pipefail

# Use Jellyfin's own data and config locations, so the plugin and database.xml land where the server reads them:
# <data dir>/plugins/PostgreSQL and <config dir>/database.xml. The jellyfin/jellyfin image sets
# JELLYFIN_DATA_DIR=/config and JELLYFIN_CONFIG_DIR=/config/config; to keep a linuxserver-style layout, set
# JELLYFIN_DATA_DIR=/config/data and JELLYFIN_CONFIG_DIR=/config instead.
DATA_DIR="${JELLYFIN_DATA_DIR:-/config}"
CONFIG_DIR="${JELLYFIN_CONFIG_DIR:-/config/config}"
PLUGIN_DIR="${DATA_DIR}/plugins/PostgreSQL"
DATABASE_XML="${CONFIG_DIR}/database.xml"

# Install the bundled plugin, replacing any older copy
rm -rf "${PLUGIN_DIR}"
mkdir -p "${PLUGIN_DIR}"
cp -r /jellyfin-pgsql/plugin/. "${PLUGIN_DIR}/"

# Create database.xml if it doesn't exist
if [ ! -f "${DATABASE_XML}" ]; then
    mkdir -p "${CONFIG_DIR}"
    cp /jellyfin-pgsql/database.xml "${DATABASE_XML}"
fi

# Check database.xml correctly configured
ConfiguredDatabaseType="$(xmlstarlet select -t -m '//DatabaseConfigurationOptions/DatabaseType' -v . -n "${DATABASE_XML}" || true)"
ConfiguredPluginName="$(xmlstarlet select -t -m '//DatabaseConfigurationOptions/CustomProviderOptions/PluginName' -v . -n "${DATABASE_XML}" || true)"
if [ "${ConfiguredDatabaseType}" != "PLUGIN_PROVIDER" ]; then
    echo "${DATABASE_XML} configures the '${ConfiguredDatabaseType}' database, not PostgreSQL. If this config comes from a"
    echo "SQLite install, migrate the data first (see the README), then move that file aside and restart:"
    echo "  mv ${DATABASE_XML} ${DATABASE_XML}.sqlite"
    exit 2
fi
if [ "${ConfiguredPluginName}" != "PostgreSQL" ]; then
    echo "Plugin name in ${DATABASE_XML} is not set to PostgreSQL. abort."
    exit 2
fi

# Check env variables set
if [ -z "${POSTGRES_HOST:-}" ] || [ -z "${POSTGRES_PASSWORD:-}" ]; then
    echo "PostgreSQL connection unset. Please set 'POSTGRES_HOST' and 'POSTGRES_PASSWORD' (and optionally 'POSTGRES_PORT', 'POSTGRES_DB', 'POSTGRES_USER') then restart"
    exit 3
fi

# Record the non-secret connection settings in database.xml. The password is not written to disk: the plugin reads
# POSTGRES_PASSWORD, and the other POSTGRES_* variables, from the environment on every start.
ConnectionString="Host=${POSTGRES_HOST};Port=${POSTGRES_PORT:-5432};Database=${POSTGRES_DB:-jellyfin};Username=${POSTGRES_USER:-jellyfin}"
xmlstarlet edit -L -u '//DatabaseConfigurationOptions/CustomProviderOptions/ConnectionString' -v "${ConnectionString}" "${DATABASE_XML}"

# Run original Jellyfin entrypoint
exec /jellyfin/jellyfin "$@"
