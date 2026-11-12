#!/bin/sh
# Writes /etc/tools-parent/build.json, describing the build of the image.
# Run by the Dockerfile as the last step of each target, with the BUILD_* and
# TARGETARCH build arguments in the environment.
set -eu

hugo_version=null
if command -v hugo >/dev/null 2>&1; then
  hugo_version=$(hugo version | sed -n 's/^hugo v\([0-9][0-9.]*\).*/"\1"/p')
fi

mkdir -p /etc/tools-parent
jq -n \
  --arg tags "${BUILD_TAGS:-}" \
  --arg debian "$(cat /etc/debian_version)" \
  --argjson hugo "$hugo_version" \
  --arg aws "$(aws --version | sed -n 's/^aws-cli\/\([^ ]*\).*/\1/p')" \
  --arg mariadb "$(mariadb --version | sed -n 's/.* from \([0-9.]*\)-MariaDB.*/\1/p')" \
  --arg arch "${TARGETARCH:-}" \
  --arg built_at "${BUILD_DATE:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}" \
  --arg revision "${BUILD_REVISION:-}" \
  --arg url "${BUILD_URL:-}" \
  '{
    image: "cedyrn/tools-parent",
    tags: ($tags | split(",") | map(select(. != ""))),
    debian_version: $debian,
    hugo_version: $hugo,
    aws_cli_version: $aws,
    mariadb_client_version: $mariadb,
    architecture: $arch,
    built_at: $built_at,
    source_revision: (if $revision == "" then null else $revision end),
    build_url: (if $url == "" then null else $url end)
  }' > /etc/tools-parent/build.json

cat /etc/tools-parent/build.json
