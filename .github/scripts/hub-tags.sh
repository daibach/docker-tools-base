#!/bin/sh
# Prints every tag of a Docker Hub repository (e.g. cedyrn/php-parent), as a
# JSON array of the tag objects returned by the Docker Hub API.
set -eu

IMAGE=$1
url="https://hub.docker.com/v2/namespaces/${IMAGE%/*}/repositories/${IMAGE#*/}/tags?page_size=100"

pages=$(mktemp)
trap 'rm -f "$pages"' EXIT

while [ -n "$url" ]; do
  page=$(curl -fsSL "$url")
  echo "$page" | jq -c '.results' >> "$pages"
  url=$(echo "$page" | jq -r '.next // empty')
done

jq -cs 'add // []' "$pages"
