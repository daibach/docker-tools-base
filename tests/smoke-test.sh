#!/bin/sh
# Checks run against each image before it is published.
# Usage: tests/smoke-test.sh <image> [expected Debian version] [expected Hugo version]
# With no expected Hugo version, the image must not contain Hugo.
# MARIADB_SERVERS lists the server versions to test dumps against.
set -eu

IMAGE=$1
EXPECTED_DEBIAN=${2:-}
EXPECTED_HUGO=${3:-}
MARIADB_SERVERS=${MARIADB_SERVERS-10.6 11.8}
PREFIX=tools-parent-smoke-$$
WORK=$(mktemp -d)
FIXTURES=$(cd "$(dirname "$0")/fixtures" && pwd)

cleanup() {
  for id in $(docker ps -aq --filter "name=^${PREFIX}-"); do
    docker rm -f "$id" >/dev/null 2>&1 || true
  done
  docker network rm "$PREFIX" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

pass() {
  echo "  ok: $*"
}

run() {
  docker run --rm "$IMAGE" "$@"
}

echo "== Debian"
DEBIAN=$(run cat /etc/debian_version)
case "$DEBIAN" in
  "$EXPECTED_DEBIAN" | "$EXPECTED_DEBIAN".*) pass "Debian $DEBIAN" ;;
  *) fail "Debian $DEBIAN, expected $EXPECTED_DEBIAN" ;;
esac

echo "== Tools"
for cmd in bash curl git gzip jq less unzip zip aws mariadb mariadb-dump mysql mysqldump; do
  run sh -c "command -v $cmd" >/dev/null || fail "$cmd not installed"
done
pass "commands present"
AWS=$(run aws --version) || fail "aws not working"
pass "$AWS"
[ -z "$(run sh -c 'echo "$AWS_PAGER"')" ] || fail "AWS_PAGER is set"
pass "AWS_PAGER is empty"
run aws sts get-caller-identity --region eu-west-2 >/dev/null 2>&1 \
  && fail "aws succeeded without credentials"
pass "aws runs (no credentials, as expected)"
MARIADB=$(run mariadb --version) || fail "mariadb not working"
pass "$MARIADB"

echo "== Amazon RDS certificate authorities"
# Every CA in the RDS bundle is in the system trust store
run sh -c '
  awk "/BEGIN CERTIFICATE/ { getline; print }" /usr/local/share/rds-global-bundle.pem > /tmp/first-lines
  test -s /tmp/first-lines
  while read -r line; do
    grep -qxF "$line" /etc/ssl/certs/ca-certificates.crt || exit 1
  done < /tmp/first-lines
  echo "$(wc -l < /tmp/first-lines) CAs"
' || fail "RDS CAs not in the system trust store"
pass "RDS CAs in the system trust store"

echo "== Hugo"
if [ -z "$EXPECTED_HUGO" ]; then
  run sh -c 'command -v hugo' >/dev/null && fail "hugo installed in an image without Hugo"
  pass "not installed"
else
  HUGO=$(run hugo version) || fail "hugo not working"
  echo "  $HUGO"
  case "$HUGO" in
    "hugo v$EXPECTED_HUGO-"*) pass "version $EXPECTED_HUGO" ;;
    *) fail "expected Hugo $EXPECTED_HUGO" ;;
  esac
  case "$HUGO" in
    *+extended*) pass "extended" ;;
    *) fail "not the extended edition" ;;
  esac
  # Builds a site with SCSS, which needs the extended edition
  OUT=$(docker run --rm -v "$FIXTURES/hugo-site:/fixture:ro" "$IMAGE" sh -c '
    cp -r /fixture /tmp/site
    hugo --source /tmp/site --destination /tmp/public --quiet
    cat /tmp/public/index.html
  ') || fail "site build failed"
  echo "$OUT" | grep -q 'body{color:#369}' || fail "SCSS not compiled: $OUT"
  echo "$OUT" | grep -q '<strong>tools-parent</strong>' || fail "content not rendered: $OUT"
  pass "builds a site with SCSS"
fi

echo "== Build info"
INFO=$(run cat /etc/tools-parent/build.json) || fail "build info missing"
echo "$INFO"
echo "$INFO" | jq -e --arg debian "$DEBIAN" --arg hugo "$EXPECTED_HUGO" '
  .image == "cedyrn/tools-parent"
  and .debian_version == $debian
  and .hugo_version == (if $hugo == "" then null else $hugo end)
  and (.aws_cli_version | test("^2\\."))
  and (.mariadb_client_version | test("^[0-9]+\\."))
  and (.built_at | fromdateiso8601 > 0)
' >/dev/null || fail "build info invalid"
pass "valid"

echo "== MariaDB dump and restore over verified TLS"
# A test CA and a server certificate for the server container's name. The
# client must reject the server until the test CA is trusted, showing that
# certificates are verified by default. The TLS checks connect as a user
# with no password: for users with a password, the client also accepts a
# certificate the server proves with the password (MariaDB's fallback for
# self-signed certificates), so they would pass without the trust store.
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=tools-parent smoke test CA" \
  -keyout "$WORK/ca.key" -out "$WORK/ca.pem" 2>/dev/null
openssl req -newkey rsa:2048 -nodes -subj "/CN=$PREFIX-db" \
  -keyout "$WORK/server.key" -out "$WORK/server.csr" 2>/dev/null
printf 'subjectAltName=DNS:%s\n' "$PREFIX-db" > "$WORK/ext"
openssl x509 -req -days 1 -in "$WORK/server.csr" -CA "$WORK/ca.pem" -CAkey "$WORK/ca.key" \
  -CAcreateserial -extfile "$WORK/ext" -out "$WORK/server.pem" 2>/dev/null
# Readable by the server's mysql user: mktemp -d creates the directory 0700
chmod 755 "$WORK"
chmod 644 "$WORK"/*
docker network create "$PREFIX" >/dev/null

for server in $MARIADB_SERVERS; do
  echo "-- mariadb:$server"
  db=$PREFIX-db
  docker run -d --name "$db" --network "$PREFIX" -v "$WORK:/certs:ro" \
    -e MARIADB_ROOT_PASSWORD=smoke "mariadb:$server" \
    --ssl-cert=/certs/server.pem --ssl-key=/certs/server.key >/dev/null
  i=0
  until docker exec "$db" healthcheck.sh --connect --innodb_initialized >/dev/null 2>&1; do
    i=$((i + 1))
    [ "$i" -ge 90 ] && { docker logs "$db"; fail "mariadb:$server did not start"; }
    sleep 1
  done
  docker exec "$db" mariadb -uroot -psmoke -e "CREATE USER nopw@'%'"

  docker run --rm --network "$PREFIX" "$IMAGE" \
    mariadb -h "$db" -unopw -e 'SELECT 1' >/dev/null 2>&1 \
    && fail "connected to a server with an untrusted certificate"
  pass "rejects an untrusted server certificate"

  docker run --rm --network "$PREFIX" -v "$WORK/ca.pem:/usr/local/share/ca-certificates/smoke.crt:ro" \
    -e MYSQL_PWD=smoke -e DB="$db" "$IMAGE" bash -euo pipefail -c '
      update-ca-certificates >/dev/null 2>&1
      tls=$(MYSQL_PWD= mariadb -h "$DB" -unopw -N -e "SHOW STATUS LIKE \"Ssl_version\"" | cut -f2)
      [ -n "$tls" ] || { echo "not using TLS" >&2; exit 1; }
      echo "  verified the server certificate, connected with $tls"
      mariadb -h "$DB" -uroot -e "
        CREATE DATABASE smoke CHARACTER SET utf8mb4;
        CREATE TABLE smoke.t (id INT PRIMARY KEY AUTO_INCREMENT, s VARCHAR(50), d DATETIME);
        INSERT INTO smoke.t (s, d) VALUES (\"Helô\", NOW()), (\"🐉\", NOW()), (NULL, NULL);
        CREATE PROCEDURE smoke.p() SELECT COUNT(*) FROM smoke.t;
        CREATE DATABASE smoke_restore CHARACTER SET utf8mb4;"
      for dump in mariadb-dump mysqldump; do
        "$dump" -h "$DB" -uroot --single-transaction --routines --triggers smoke | gzip > /tmp/dump.sql.gz
        gunzip -c /tmp/dump.sql.gz | mariadb -h "$DB" -uroot smoke_restore
        a=$(mariadb -h "$DB" -uroot -N -e "CHECKSUM TABLE smoke.t" | cut -f2)
        b=$(mariadb -h "$DB" -uroot -N -e "CHECKSUM TABLE smoke_restore.t" | cut -f2)
        [ "$a" = "$b" ] || { echo "$dump: restored table differs" >&2; exit 1; }
        mariadb -h "$DB" -uroot -N -e "CALL smoke_restore.p()" | grep -qx 3
        echo "  $dump: dump and restore match"
      done
    ' || fail "dump and restore against mariadb:$server"
  pass "mariadb:$server"
  docker rm -f "$db" >/dev/null
done

echo "PASS: $IMAGE"
