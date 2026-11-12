# docker-tools-base

Base images for build jobs and admin tasks, published to Docker Hub as
`cedyrn/tools-parent`. Replaces `cedyrn/ubuntu-parent`.

Each image is Debian (`debian:<version>-slim`) with:

- [AWS CLI v2](https://docs.aws.amazon.com/cli/latest/userguide/), with `AWS_PAGER` unset so output is never paged
- the MariaDB client (`mariadb`, `mariadb-dump`, and the `mysql` and `mysqldump` aliases)
- the [Amazon RDS certificate authorities](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/UsingWithRDS.SSL.html) in the system trust store
- `bash`, `curl`, `git`, `gzip`, `jq`, `less`, `zip` and `unzip`
- time zone data (`tzdata`): the time zone is UTC unless `TZ` is set, e.g. `TZ=Europe/London`
- optionally, [Hugo](https://gohugo.io) (extended edition)

amd64 and arm64. The default command is `bash`; there is no entrypoint and
nothing runs in the background.

## Tags

| Tag | Example | Contains | Updates |
|---|---|---|---|
| `debian<debian>` | `debian13.7` | No Hugo | Debian package updates, AWS CLI releases |
| `debian<debian>-hugo<hugo>` | `debian13.7-hugo0.169.0` | Exactly that Hugo version | As above |
| `debian<debian>-hugo<hugo minor>` | `debian13.7-hugo0.169` | That Hugo minor version | Also Hugo patch releases |

Current builds:

| Image | Tags |
|---|---|
| No Hugo | `debian13.7` |
| Hugo 0.151 | `debian13.7-hugo0.151.2`, `debian13.7-hugo0.151` |
| Hugo 0.169 | `debian13.7-hugo0.169.0`, `debian13.7-hugo0.169` |

Every tag is rebuilt weekly, so Debian security fixes and new AWS CLI releases
arrive without the tag changing. Always name a tag: there is no `latest`.

## Using the image

### Hugo sites in CodeBuild

Set the CodeBuild project's environment image to a Hugo tag, e.g.
`cedyrn/tools-parent:debian13.7-hugo0.169`, with Docker Hub registry
credentials (see [Pulling from CodeBuild and ECS](#pulling-from-codebuild-and-ecs)).
The buildspec then has `hugo` and `aws` available:

```yaml
version: 0.2
phases:
  build:
    commands:
      - hugo --minify
      - aws s3 sync public/ "s3://${BUCKET}/" --delete
```

Pick the Hugo minor version the site was built and tested with. The minor
version tag picks up Hugo patch releases; use the exact tag to avoid that.

### Child images

```dockerfile
FROM cedyrn/tools-parent:debian13.7
COPY runtasks.sh /runtasks.sh
CMD ["/runtasks.sh"]
```

Containers run as `root` unless the child image sets `USER`.

To keep a child image up to date with [Renovate](https://docs.renovatebot.com/),
add this rule to its `renovate.json`, so Renovate understands the tags. The
`compatibility` group keeps the child on its Hugo line (or on the image without
Hugo) while moving it to newer Debian versions:

```json
{
  "packageRules": [
    {
      "matchDatasources": ["docker"],
      "matchDepNames": ["cedyrn/tools-parent"],
      "versioning": "regex:^debian(?<major>\\d+)\\.(?<minor>\\d+)(?<compatibility>-hugo\\d+\\.\\d+(\\.\\d+)?)?$"
    }
  ]
}
```

### Databases

The MariaDB client connects with TLS and verifies the server's certificate by
default. The RDS certificate authorities are in the system trust store, so this
works with RDS without any options, connecting with the instance's endpoint
name:

```sh
mariadb-dump -h mydb.abc123.eu-west-2.rds.amazonaws.com -u backup \
  --single-transaction --routines --triggers mydb | gzip > mydb.sql.gz
```

Leave out `--skip-ssl` and `--ssl-verify-server-cert=0` (or their older
spellings): they turn off protection the image provides. The CA bundle is also
at `/usr/local/share/rds-global-bundle.pem`, for tools that take a CA file.

The client is MariaDB 11.8. Dumps start with a `/*M!999999\- enable the sandbox
mode */` line, which clients older than MariaDB 10.5.25 / 10.6.18 can't restore;
restore them with this image or a recent client.

Tests dump and restore against MariaDB 10.6 and 11.8 servers.

## Build info

`/etc/tools-parent/build.json` describes the build of the image, and is
inherited by child images:

```json
{
  "image": "cedyrn/tools-parent",
  "tags": ["debian13.7-hugo0.169.0", "debian13.7-hugo0.169"],
  "debian_version": "13.7",
  "hugo_version": "0.169.0",
  "aws_cli_version": "2.40.1",
  "mariadb_client_version": "11.8.6",
  "architecture": "arm64",
  "built_at": "2026-11-12T07:39:00Z",
  "source_revision": "d04c230f...",
  "build_url": "https://github.com/daibach/docker-tools-base/actions/runs/..."
}
```

`hugo_version` is `null` in the image without Hugo. `tags` lists the tags the
image was published under, not the tag a child's `FROM` used. `tags` is empty,
and `source_revision` and `build_url` are null, for local builds.

## Versions

`versions.json` lists the Debian version, and each Hugo minor version with the
exact patch version it is built from:

```json
{
  "debian": "13.7",
  "hugo": {
    "0.151": "0.151.2",
    "0.169": "0.169.0"
  }
}
```

The image without Hugo is always built. Images are built from the exact
upstream tag (`debian:13.7-slim`), never the moving `debian:trixie-slim`.

- **Add a Hugo version:** add a line with its latest patch version. Its image is built automatically.
- **Drop a Hugo version:** remove its line. Its tags stay on Docker Hub, without updates, until they are pruned.
- **Move to a new Debian major version:** change `debian` (e.g. to `14.1`). Every tag name changes, so children move when they next update their `FROM`.

The AWS CLI version is the `AWS_CLI_VERSION` build argument in the `Dockerfile`.

### Updates

[Renovate](https://docs.renovatebot.com/) watches for updates and opens PRs:

| Update | Wait after release | Merge |
|---|---|---|
| Debian point releases (`13.7` to `13.8`) | 1 day | Automatic once the build passes. Every tag name changes. |
| Debian major versions | | Ignored; change `versions.json` by hand |
| Hugo patch versions | 1 day | Automatic once the build passes. Patches released together are grouped. |
| New Hugo minor versions | | Ignored; add them to `versions.json` by hand |
| AWS CLI (non-major) | 3 days | Automatic once the build passes |
| Trivy | 3 days | Manual: update the `*_SHA256` checksums in `.github/actions/setup-trivy/action.yml` in the same PR |
| GitHub Actions (non-major) | | Automatic once the build passes |

**Urgent updates:** open the Dependency Dashboard issue and tick the box to
make Renovate check immediately, or edit `versions.json` by hand.

### Verifying downloads

- **AWS CLI:** checked against the AWS CLI Team's PGP signature. The public key is in `keys/aws-cli.asc`, from the [AWS CLI installation guide](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html), and the build checks the signing key's fingerprint. AWS extends the key's expiry date from time to time (currently 2027-07-01); builds keep working after it expires, but replace the file with the guide's current copy when it does.
- **Hugo:** checked against the SHA-256 checksums published with each release.
- **RDS certificate authorities:** downloaded over HTTPS from `truststore.pki.rds.amazonaws.com` on each build.

## Builds

Images are built by GitHub Actions (`.github/workflows/build.yml`):

| Trigger | Result |
|---|---|
| Pull request | Builds and tests every image. Nothing is pushed. |
| Push to `main` | Builds, tests and publishes every image. |
| Weekly (Monday 04:00 UTC) | Same as a push to `main`, to pick up Debian updates. |
| Manual (Actions → Build images → Run workflow) | Same as a push to `main`. |

Each image is built natively on amd64 and arm64 runners. Each architecture is
pushed by digest, without a tag, and that exact image is pulled and tested. An
image's tags are only updated when every architecture has passed. Published
images include build provenance and an SBOM.

The `Build result` check passes only when every image passes, and is the
required status check for `main`.

### Vulnerability scanning

Images are scanned with [Trivy](https://trivy.dev/). Only vulnerabilities with
a fix available are reported; findings never fail a build.

| When | What | Results |
|---|---|---|
| Every build | The image just built, for each architecture | HIGH and CRITICAL findings in the job summary |
| After each build that publishes, and daily at 05:00 UTC (`.github/workflows/scan.yml`) | Each published image (amd64) | All findings in the repository's Security tab, plus HIGH and CRITICAL in the job summary |

Most findings are fixed by a rebuild (the weekly build, or Actions → Build
images → Run workflow) or by an AWS CLI update.

### Pruning old tags

A Debian point release or Hugo patch release leaves the previous tags behind.
`.github/workflows/prune.yml` runs weekly (Monday 06:00 UTC) and lists, in the
run's summary, which tags would be deleted. It keeps:

- every tag built from the current `versions.json`
- any tag pulled in the last 30 days, so children pinned to an older tag can still be rebuilt

Scheduled runs never delete anything. To delete the listed tags, run Actions →
Prune tags → Run workflow from `main` with **apply** ticked. Only `debian…`
tags are considered.

Check the plan locally with `.github/scripts/hub-tags.sh cedyrn/tools-parent | .github/scripts/prune-plan.sh`
(`PULL_DAYS` changes the limit).

Deleting a tag leaves its image untagged, as does every rebuild of an existing
tag. Remove untagged images from time to time in the repository's **Image
Management** page on Docker Hub.

### Tests

`tests/smoke-test.sh` checks the tools, time zones, the trust store, Hugo (building a site
with SCSS), the build info, and dump and restore over verified TLS against
MariaDB servers. It needs Docker, `jq` and `openssl`, and can be run locally:

```sh
docker build -t tools-parent-test:base --target base --build-arg DEBIAN_VERSION=13.7 .
tests/smoke-test.sh tools-parent-test:base 13.7

docker build -t tools-parent-test:hugo --target hugo --build-arg DEBIAN_VERSION=13.7 --build-arg HUGO_VERSION=0.169.0 .
tests/smoke-test.sh tools-parent-test:hugo 13.7 0.169.0
```

`MARIADB_SERVERS` sets the MariaDB server versions to test against (default
`10.6 11.8`; empty skips the database tests).

### Configuration

The workflow pushes using a Docker Hub personal access token with Read & Write
permission:

- `DOCKERHUB_USERNAME`: repository variable
- `DOCKERHUB_TOKEN`: repository secret

Deleting tags uses a separate token, so the build token cannot delete anything.
In a GitHub environment named `docker-hub-prune`, limited to the `main` branch:

- `DOCKERHUB_PRUNE_TOKEN`: environment secret, a Docker Hub personal access token with Read, Write & Delete permission

## Pulling from CodeBuild and ECS

Pull with Docker Hub credentials, since anonymous pulls from AWS's shared IP
addresses are rate limited. Store a Docker Hub personal access token with
Public Repo Read-only permission in Secrets Manager:

```json
{"username": "<docker hub user>", "password": "<token>"}
```

- **CodeBuild:** set the project's environment image with registry credential type `SECRETS_MANAGER` and the secret's ARN. The project's service role needs `secretsmanager:GetSecretValue` on it.
- **ECS:** set `repositoryCredentials.credentialsParameter` to the secret's ARN in the container definition. The task execution role needs `secretsmanager:GetSecretValue` on it.
