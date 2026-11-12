#!/bin/sh
# Decides which image tags to delete from Docker Hub. Reads the repository's
# tags, as printed by hub-tags.sh, on stdin and prints a JSON array of
# {name, last_pulled, action, reason}, sorted by name. Keeps every tag built
# from the current versions.json and any tag pulled in the last PULL_DAYS
# days. Only debian<version> and debian<version>-hugo<version> tags are
# considered; other tags are never pruned.
set -eu

PULL_DAYS=${PULL_DAYS:-30}
NOW=${NOW:-$(date -u +%s)}

current=$("$(dirname "$0")/matrix.sh" | jq -c '[.[].tags[]]')

jq -c --argjson days "$PULL_DAYS" --argjson now "$NOW" --argjson current "$current" '
  def timestamp: if . == null then null else sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601 end;
  [ .[] | select(.name | test("^debian[0-9]+\\.[0-9]+(-hugo[0-9]+\\.[0-9]+(\\.[0-9]+)?)?$")) ]
  | map(
      (.tag_last_pulled | timestamp) as $pulled
      | {name, last_pulled: .tag_last_pulled}
      + if (.name as $n | any($current[]; . == $n)) then
          {action: "keep", reason: "built from versions.json"}
        elif $pulled != null and $now - $pulled < $days * 86400 then
          {action: "keep", reason: "pulled in the last \($days) days"}
        else
          {action: "delete", reason: "not pulled in the last \($days) days"}
        end)
  | sort_by(.name)
'
