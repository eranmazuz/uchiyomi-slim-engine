#!/bin/sh
# Smoke test for the built engine image: run it the way Uchiyomi runs it, and prove it works.
#
# Phases, because Woodpecker runs steps serially and a step can be allowed to fail:
#   up    - network, volume, flaresolverr, the engine, and the hermetic CBZ fixture
#   hard  - assertions that must hold (engine + our configuration). Any failure is a real regression
#   site  - assertions that depend on a third-party manga site. Run with `failure: ignore`
#   down  - tear everything down
#
# usage: ci-smoke.sh <image:tag> <up|hard|site|down> [keiyoushi-index-url]
#
# Nothing here assumes the workspace path is visible to the docker daemon (the fixture is streamed in
# with `docker cp`), so the same script runs in CI and from a laptop against a remote daemon.
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
    # curl + jq once, reused by every call below (apk on each call is seconds of noise per assertion)
    if ! docker image inspect "$TOOLS" >/dev/null 2>&1; then
        mkdir -p .ci-tools
        printf 'FROM alpine:3.21\nRUN apk add --no-cache curl jq\n' > .ci-tools/Dockerfile
        docker build -q -t "$TOOLS" .ci-tools >/dev/null
    fi
}

gq() {   # gq <graphql-json-body>
    docker run --rm --network "$NET" "$TOOLS" \
        curl -s -X POST "$BASE/api/graphql" -H 'content-type: application/json' -d "$1"
}

# jq runs in the tools container, not in this shell: the CI step image (docker:cli) has no jq, and
# neither does a plain workstation shell. Same code path in both.
jqf() { docker run --rm -i "$TOOLS" jq "$@"; }

field() { printf '%s' "$1" | jqf -r "$2"; }

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

    # 1. the engine is what we think it is
    r=$(gq '{"query":"{ aboutServer { name version buildType } }"}')
    [ "$(field "$r" '.data.aboutServer.name')" = "Suwayomi-Server" ] || fail "unexpected engine: $r"
    ok "engine $(field "$r" '.data.aboutServer.version')"

    # 2. our configuration actually applied -- these are the settings Uchiyomi depends the image for.
    #    Tested numerically: globalUpdateInterval is a Double and reads back as 0.0, so comparing the
    #    rendered string is what broke first.
    r=$(gq '{"query":"{ settings { kcefEnabled systemTrayEnabled initialOpenInBrowserEnabled globalUpdateInterval backupInterval flareSolverrEnabled } }"}')
    printf '%s' "$r" | jqf -e '.data.settings
        | (.kcefEnabled == false) and (.systemTrayEnabled == false) and (.initialOpenInBrowserEnabled == false)
          and (.globalUpdateInterval == 0) and (.backupInterval == 0) and (.flareSolverrEnabled == true)' >/dev/null \
        || fail "the settings Uchiyomi depends on are not applied: $r"
    ok "kcef/tray/openInBrowser off, update+backup schedulers off, flaresolverr on"

    # 3. the page path, hermetically: Local source -> chapters -> page URLs -> page bytes
    r=$(gq '{"query":"{ sources { nodes { id name lang } } }"}')
    sid=$(printf '%s' "$r" | jqf -r '.data.sources.nodes[] | select(.lang=="localsourcelang") | .id')
    [ -n "$sid" ] || fail "no local source registered: $r"
    mid=$(gq "{\"query\":\"mutation(\$s:LongString!,\$t:FetchSourceMangaType!,\$q:String,\$p:Int!){ fetchSourceManga(input:{source:\$s,type:\$t,query:\$q,page:\$p}){ mangas { id title } } }\",\"variables\":{\"s\":\"$sid\",\"t\":\"SEARCH\",\"q\":\"\",\"p\":1}}" | jqf -r '.data.fetchSourceManga.mangas[0].id')
    [ -n "$mid" ] && [ "$mid" != "null" ] || fail "the local source listed no manga (fixture missing?)"
    chid=$(gq "{\"query\":\"mutation(\$id:Int!){ fetchMangaAndChapters(input:{id:\$id,fetchManga:true,fetchChapters:true}){ chapters { id } } }\",\"variables\":{\"id\":$mid}}" | jqf -r '.data.fetchMangaAndChapters.chapters[0].id')
    [ -n "$chid" ] && [ "$chid" != "null" ] || fail "no chapters from the local source"
    page=$(gq "{\"query\":\"mutation(\$c:Int!){ fetchChapterPages(input:{chapterId:\$c}){ pages } }\",\"variables\":{\"c\":$chid}}" | jqf -r '.data.fetchChapterPages.pages[0]')
    [ -n "$page" ] && [ "$page" != "null" ] || fail "no page URLs for the local chapter"
    bytes=$(docker run --rm --network "$NET" "$TOOLS" curl -s "$BASE$page" | wc -c)
    [ "$bytes" -gt 100 ] || fail "page bytes came back empty ($bytes bytes)"
    ok "local source served a page: $page ($bytes bytes)"

    # 4. the extension integration: store -> catalogue -> install (APK -> JVM bytecode)
    r=$(gq "{\"query\":\"mutation(\$u:String!){ addExtensionStore(input:{indexUrl:\$u}){ extensionStore { name } } }\",\"variables\":{\"u\":\"$INDEX\"}}")
    printf '%s' "$r" | jqf -e '.data.addExtensionStore.extensionStore' >/dev/null || fail "could not add the store: $r"
    gq '{"query":"mutation{ fetchExtensions(input:{}){ extensions { pkgName } } }"}' >/dev/null
    r=$(gq '{"query":"{ extensions { nodes { pkgName lang contentWarning isInstalled } } }"}')
    total=$(printf '%s' "$r" | jqf '.data.extensions.nodes | length')
    [ "$total" -gt 100 ] || fail "catalogue looks empty ($total extensions)"
    ok "catalogue fetched: $total extensions"

    # pick the extension at test time -- never a hardcoded name, so upstream renames don't fail CI
    pkg=$(printf '%s' "$r" | jqf -r '[.data.extensions.nodes[] | select(.lang=="en" and .contentWarning!="NSFW" and .isInstalled==false)] | sort_by(.pkgName) | .[0].pkgName')
    [ -n "$pkg" ] && [ "$pkg" != "null" ] || fail "no installable extension in the catalogue"
    r=$(gq "{\"query\":\"mutation(\$id:String!,\$p:UpdateExtensionPatchInput!){ updateExtension(input:{id:\$id,patch:\$p}){ extension { pkgName isInstalled } } }\",\"variables\":{\"id\":\"$pkg\",\"p\":{\"install\":true}}}")
    [ "$(field "$r" '.data.updateExtension.extension.isInstalled')" = "true" ] || fail "install failed for $pkg: $r"
    ok "installed $pkg (APK converted to JVM bytecode)"

    r=$(gq '{"query":"{ sources { totalCount } }"}')
    [ "$(field "$r" '.data.sources.totalCount')" -gt 1 ] || fail "the installed extension registered no sources: $r"
    ok "sources registered: $(field "$r" '.data.sources.totalCount')"
    echo "hard assertions: PASSED"
    ;;

site)
    # Third-party and therefore advisory: the site may be down, rate-limit us or Cloudflare-block the
    # CI IP, and the extension itself may be broken or retired. None of that is a regression here.
    echo "site check (advisory - never fails the build)"
    r=$(gq '{"query":"{ sources { nodes { id name } } }"}')
    n=0
    for sid in $(printf '%s' "$r" | jqf -r '.data.sources.nodes[] | select(.name!="Local source") | .id' | head -5); do
        n=$((n + 1))
        out=$(gq "{\"query\":\"mutation(\$s:LongString!,\$t:FetchSourceMangaType!,\$q:String,\$p:Int!){ fetchSourceManga(input:{source:\$s,type:\$t,query:\$q,page:\$p}){ mangas { title } } }\",\"variables\":{\"s\":\"$sid\",\"t\":\"SEARCH\",\"q\":\"one piece\",\"p\":1}}")
        titles=$(printf '%s' "$out" | jqf -r '[.data.fetchSourceManga.mangas[]?.title] | length' 2>/dev/null || echo 0)
        if [ "${titles:-0}" -gt 0 ]; then
            echo "  ok   source $sid returned $titles results"
            exit 0
        fi
        echo "  warn source $sid did not answer: $(printf '%s' "$out" | jqf -r '.errors[0].message' 2>/dev/null | head -c 120)"
    done
    echo "  warn no source answered ($n tried) - advisory only"
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
