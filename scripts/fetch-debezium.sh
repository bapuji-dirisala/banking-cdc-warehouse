#!/usr/bin/env bash
# Fetch the Debezium Postgres connector plugin into compose/connect/plugins/.
#
# Idempotent: skips the download if the plugin directory is already populated.
# Respects curl's CURL_CA_BUNDLE env (Nike corp CA bundle, set in ~/.zprofile)
# so corporate TLS inspection does not break the fetch.

set -euo pipefail

DEBEZIUM_VERSION="${DEBEZIUM_VERSION:-2.6.2.Final}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PLUGIN_DIR="$REPO_ROOT/compose/connect/plugins"
TARGET_DIR="$PLUGIN_DIR/debezium-connector-postgres"

if [ -d "$TARGET_DIR" ] && [ -n "$(ls -A "$TARGET_DIR" 2>/dev/null | grep -v '^\.' || true)" ]; then
    echo "Debezium Postgres plugin already present at $TARGET_DIR — skipping."
    echo "Set DEBEZIUM_FORCE=1 to re-download."
    if [ -z "${DEBEZIUM_FORCE:-}" ]; then
        exit 0
    fi
    echo "DEBEZIUM_FORCE set; wiping $TARGET_DIR and re-downloading..."
    rm -rf "$TARGET_DIR"
fi

TARBALL_URL="https://repo1.maven.org/maven2/io/debezium/debezium-connector-postgres/${DEBEZIUM_VERSION}/debezium-connector-postgres-${DEBEZIUM_VERSION}-plugin.tar.gz"

echo "Fetching Debezium Postgres ${DEBEZIUM_VERSION} from Maven Central..."
mkdir -p "$PLUGIN_DIR"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

curl -fSL --retry 3 --retry-delay 2 "$TARBALL_URL" -o "$TMPDIR/debezium.tar.gz"
tar -xzf "$TMPDIR/debezium.tar.gz" -C "$PLUGIN_DIR"

if [ ! -d "$TARGET_DIR" ]; then
    echo "ERROR: expected $TARGET_DIR after extraction; the tarball layout may have changed." >&2
    exit 1
fi

echo "Installed Debezium Postgres plugin to $TARGET_DIR"
echo "Contents (first 5):"
ls "$TARGET_DIR" | head -5
