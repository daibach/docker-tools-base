#!/bin/sh
# Prints the images to build as a JSON array, from versions.json: one image
# without Hugo, and one per Hugo version. Used by build.yml, scan.yml and
# prune-plan.sh.
#
#   name    debian13.7-hugo0.151     the image's main tag, used to name jobs
#   target  base | hugo              Dockerfile target
#   debian  13.7                     upstream debian:<debian>-slim
#   hugo    0.151.2 (or "")          exact Hugo version
#   tags    [debian13.7-hugo0.151.2, debian13.7-hugo0.151]
set -eu

cd "$(dirname "$0")/../.."
jq -c '
  .debian as $debian
  | "debian\($debian)" as $base
  | [ {name: $base, target: "base", debian: $debian, hugo: "", tags: [$base]} ]
    + [ .hugo | to_entries[]
        | "\($base)-hugo\(.key)" as $name
        | {name: $name, target: "hugo", debian: $debian, hugo: .value,
           tags: ["\($base)-hugo\(.value)", $name]} ]
' versions.json
