# syntax=docker/dockerfile:1
# check=skip=InvalidDefaultArgInFrom
# cedyrn/tools-parent: Debian with the AWS CLI and a MariaDB client, for
# CodeBuild jobs and one-off ECS tasks. Two targets:
#   base  cedyrn/tools-parent:debian<debian>
#   hugo  cedyrn/tools-parent:debian<debian>-hugo<hugo>, adding Hugo extended

# No defaults: versions come only from versions.json, so a build without them
# fails rather than using a version set here.
ARG DEBIAN_VERSION

FROM debian:${DEBIAN_VERSION}-slim AS tools

ARG TARGETARCH

# renovate: datasource=github-tags depName=aws/aws-cli
ARG AWS_CLI_VERSION=2.40.1
# Fingerprint of the AWS CLI Team key in keys/aws-cli.asc, which signs every
# AWS CLI release. From the AWS CLI installation guide.
ARG AWS_CLI_KEY_FINGERPRINT=FB5DB77FD5C118B80511ADA8A6310ACC4672475C

ENV LANG=C.UTF-8 \
    AWS_PAGER=""

# Debian security updates (without waiting for the upstream image to be
# rebuilt) and tools. mariadb-client provides mariadb, mariadb-dump and the
# mysql and mysqldump aliases.
RUN set -eux; \
    apt-get update; \
    DEBIAN_FRONTEND=noninteractive apt-get upgrade -y; \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      bash ca-certificates curl git gzip jq less mariadb-client unzip zip; \
    rm -rf /var/lib/apt/lists/*

# Amazon RDS certificate authorities, added to the system trust store so
# clients verify RDS servers' certificates without extra options. The MariaDB
# client requires TLS and verifies the server's certificate by default. The
# bundle is also kept whole for tools that take a CA file.
RUN set -eux; \
    curl -fsSLo /usr/local/share/rds-global-bundle.pem \
      https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem; \
    count=$(grep -c 'BEGIN CERTIFICATE' /usr/local/share/rds-global-bundle.pem); \
    test "$count" -gt 10; \
    mkdir -p /usr/local/share/ca-certificates/rds; \
    awk 'BEGIN { n = 0 } /BEGIN CERTIFICATE/ { n++ } { print > sprintf("/usr/local/share/ca-certificates/rds/rds-%02d.crt", n) }' \
      /usr/local/share/rds-global-bundle.pem; \
    update-ca-certificates

# AWS CLI v2, verified against the AWS CLI Team's signature
RUN --mount=type=bind,source=keys/aws-cli.asc,target=/tmp/aws-cli.asc \
    set -eux; \
    case "$TARGETARCH" in \
      amd64) aws_arch=x86_64 ;; \
      arm64) aws_arch=aarch64 ;; \
      *) echo "Unsupported architecture: $TARGETARCH" >&2; exit 1 ;; \
    esac; \
    apt-get update; \
    apt-get install -y --no-install-recommends gnupg gpgv; \
    work=$(mktemp -d); \
    cd "$work"; \
    url="https://awscli.amazonaws.com/awscli-exe-linux-${aws_arch}-${AWS_CLI_VERSION}.zip"; \
    curl -fsSLo awscliv2.zip "$url"; \
    curl -fsSLo awscliv2.zip.sig "$url.sig"; \
    gpg --batch --dearmor < /tmp/aws-cli.asc > keyring.gpg; \
    # Exits 0 for a good signature, even once the key has expired, so check
    # the signing key's fingerprint too
    gpgv --status-fd 1 --keyring ./keyring.gpg awscliv2.zip.sig awscliv2.zip > status; \
    grep -q "^\[GNUPG:\] VALIDSIG ${AWS_CLI_KEY_FINGERPRINT} " status; \
    unzip -q awscliv2.zip; \
    ./aws/install; \
    cd /; \
    rm -rf "$work"; \
    apt-get purge -y --auto-remove gnupg gpgv; \
    rm -rf /var/lib/apt/lists/*; \
    aws --version

# Hugo extended, verified against the checksums published with the release
FROM tools AS hugo-tools

ARG TARGETARCH
ARG HUGO_VERSION

RUN set -eux; \
    test -n "$HUGO_VERSION"; \
    case "$TARGETARCH" in \
      amd64|arm64) ;; \
      *) echo "Unsupported architecture: $TARGETARCH" >&2; exit 1 ;; \
    esac; \
    work=$(mktemp -d); \
    cd "$work"; \
    file="hugo_extended_${HUGO_VERSION}_linux-${TARGETARCH}.tar.gz"; \
    url="https://github.com/gohugoio/hugo/releases/download/v${HUGO_VERSION}"; \
    curl -fsSLo "$file" "$url/$file"; \
    curl -fsSLo checksums.txt "$url/hugo_${HUGO_VERSION}_checksums.txt"; \
    grep " ${file}\$" checksums.txt | sha256sum -c -; \
    tar -xzf "$file" -C /usr/local/bin hugo; \
    cd /; \
    rm -rf "$work"; \
    hugo version

# Build info: last in each target, so a new build date doesn't invalidate the
# cache of earlier layers
FROM hugo-tools AS hugo

ARG TARGETARCH
ARG BUILD_DATE
ARG BUILD_REVISION
ARG BUILD_URL
ARG BUILD_TAGS
RUN --mount=type=bind,source=scripts/build-info.sh,target=/tmp/build-info.sh \
    sh /tmp/build-info.sh

CMD ["bash"]

# Last, so a build without --target gives the image without Hugo
FROM tools AS base

ARG TARGETARCH
ARG BUILD_DATE
ARG BUILD_REVISION
ARG BUILD_URL
ARG BUILD_TAGS
RUN --mount=type=bind,source=scripts/build-info.sh,target=/tmp/build-info.sh \
    sh /tmp/build-info.sh

CMD ["bash"]
