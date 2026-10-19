#!/bin/sh
# Run the engine IMAGE in containers and check it -- for a laptop or a manual run.
#
# CI does NOT use this path any more: the pipeline runs the engine as a process inside the step and
# checks it there, so no Docker socket and no `volumes` trust are needed. This stays as the way to
# verify the *image itself* -- its packaging, base image and healthcheck -- which a JVM inside a step
# cannot see.
#
# Phases, because they map onto separate commands and a step can be allowed to fail:
#   up    - network, volume, flaresolverr, the engine, and the hermetic CBZ fixture
#   hard  - assertions that must hold (delegated to test/check-engine.sh)
#   site  - advisory, third-party dependent (delegated too)
#   down  - tear everything down
#
# usage: ci-smoke.sh <image:tag> <up|hard|site|down> [index-url]
#
# Nothing here assumes the workspace path is visible to the docker daemon -- the fixture is streamed in
# with `docker cp` and the checker arrives on stdin -- so it works from a laptop against a remote
# daemon as well as on a CI agent.
set -eu

IMAGE="${1:?usage: ci-smoke.sh <image:tag> <up|hard|site|down> [index-url]}"
PHASE="${2:?usage: ci-smoke.sh <image:tag> <up|hard|site|down> [index-url]}"
INDEX="${3:-https://github.com/keiyoushi/extensions/raw/repo/index.pb}"

NET=ci-smoke-net
ENGINE=ci-smoke-engine
SOLVER=ci-smoke-solver
VOL=ci-smoke-local
TOOLS=ci-tools
BASE="http://${ENGINE}:4567"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "  ok   $*"; }

tools_image() {
    # curl + jq once, reused by every call below
    if ! docker image inspect "$TOOLS" >/dev/null 2>&1; then
        mkdir -p .ci-tools
        printf 'FROM alpine:3.21\nRUN apk add --no-cache curl jq\n' > .ci-tools/Dockerfile
        docker build -q -t "$TOOLS" .ci-tools >/dev/null
    fi
}

# The assertions live in exactly one place (test/check-engine.sh) so this path and the CI path cannot
# drift apart. Run it in a container on the engine's network: the script on stdin, curl+jq from the
# tools image, no mounts.
check() {
    tools_image
    docker run --rm --network "$NET" -i "$TOOLS" sh -s "$BASE" "$1" "$INDEX" < test/check-engine.sh
}

case "$PHASE" in
up)
    docker rm -f "$ENGINE" "$SOLVER" >/dev/null 2>&1 || true
    docker network rm "$NET" >/dev/null 2>&1 || true
    docker network create "$NET" >/dev/null
    tools_image

    docker run -d --name "$SOLVER" --network "$NET" --shm-size 1gb \
        -e LOG_LEVEL=warning ghcr.io/flaresolverr/flaresolverr:latest >/dev/null
    ok "flaresolverr started"

    # create -> copy the fixture in -> start, so the Local source sees the CBZ from its first scan
    docker create --name "$ENGINE" --network "$NET" -v "$VOL:/local" \
        -e TZ=UTC \
        -e LOCAL_SOURCE_PATH=/local \
        -e FLARESOLVERR_ENABLED=true -e FLARESOLVERR_URL="http://${SOLVER}:8191" \
        "$IMAGE" >/dev/null
    docker cp test/fixtures/local-library/. "$ENGINE:/local/"
    ok "fixture copied into the engine's /local"
    docker start "$ENGINE" >/dev/null
    ok "engine started from $IMAGE"

    echo -n "waiting for the engine to answer"
    i=0
    while [ "$i" -lt 90 ]; do
        code=$(docker run --rm --network "$NET" "$TOOLS" \
            curl -s -o /dev/null -w '%{http_code}' --max-time 3 "$BASE/api/v1/settings/about" || true)
        [ "$code" = "200" ] && { echo " - up after ${i}s"; break; }
        i=$((i + 1)); echo -n .
        sleep 1
    done
    [ "$code" = "200" ] || { docker logs "$ENGINE" 2>&1 | tail -30; fail "engine never answered /api/v1/settings/about"; }
    ;;

hard)
    echo "hard assertions (engine + our configuration, no third-party sites)"
    check hard
    ;;

site)
    echo "site check (advisory - never fails the build)"
    check site
    ;;

down)
    docker rm -f "$ENGINE" "$SOLVER" >/dev/null 2>&1 || true
    docker network rm "$NET" >/dev/null 2>&1 || true
    docker volume rm "$VOL" >/dev/null 2>&1 || true
    ok "torn down"
    ;;

*)
    fail "unknown phase: $PHASE"
    ;;
esac
