#!/bin/sh
# Assertions against a running engine, given its base URL.
#
# Deliberately knows nothing about how the engine was started -- containers, a bare JVM in a CI step,
# or a real install all look the same from here. Only needs sh, curl and jq on PATH.
#
#   check-engine.sh <base-url> hard [index-url]   # must pass: engine + our configuration
#   check-engine.sh <base-url> site [index-url]   # advisory: a real extension against a real site
#
# hard covers, in order: the engine identifies itself; the settings Uchiyomi depends on are applied;
# the page path works end to end through the built-in Local source (no site, no extension); the
# extension store resolves; the catalogue is fetched; one extension installs (APK -> JVM bytecode) and
# registers its sources.
set -eu

BASE="${1:?usage: check-engine.sh <base-url> <hard|site> [index-url]}"
MODE="${2:?usage: check-engine.sh <base-url> <hard|site> [index-url]}"
INDEX="${3:-https://github.com/keiyoushi/extensions/raw/repo/index.pb}"

command -v curl >/dev/null || { echo "curl is required" >&2; exit 2; }
command -v jq >/dev/null || { echo "jq is required" >&2; exit 2; }

fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "  ok   $*"; }
warn() { echo "  warn $*"; }

gq() { curl -s -X POST "$BASE/api/graphql" -H 'content-type: application/json' -d "$1"; }
field() { printf '%s' "$1" | jq -r "$2"; }

# wait for the engine (a CI step starts it as a process, so this matters more here than with containers)
wait_ready() {
    i=0
    printf 'waiting for %s' "$BASE"
    while [ "$i" -lt 120 ]; do
        code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "$BASE/api/v1/settings/about" || true)
        [ "$code" = "200" ] && { echo " - up after ${i}s"; return 0; }
        i=$((i + 1)); printf .; sleep 1
    done
    echo; return 1
}

case "$MODE" in
hard)
    wait_ready || fail "the engine never answered /api/v1/settings/about"

    # 1. it is the engine we think it is
    r=$(gq '{"query":"{ aboutServer { name version buildType } }"}')
    [ "$(field "$r" '.data.aboutServer.name')" = "Suwayomi-Server" ] || fail "unexpected engine: $r"
    ok "engine $(field "$r" '.data.aboutServer.version')"

    # 2. our configuration applied. Tested numerically: globalUpdateInterval is a Double and reads
    #    back as 0.0, so comparing rendered strings is wrong.
    r=$(gq '{"query":"{ settings { kcefEnabled systemTrayEnabled initialOpenInBrowserEnabled globalUpdateInterval backupInterval flareSolverrEnabled } }"}')
    printf '%s' "$r" | jq -e '.data.settings
        | (.kcefEnabled == false) and (.systemTrayEnabled == false) and (.initialOpenInBrowserEnabled == false)
          and (.globalUpdateInterval == 0) and (.backupInterval == 0) and (.flareSolverrEnabled == true)' >/dev/null \
        || fail "the settings Uchiyomi depends on are not applied: $r"
    ok "kcef/tray/openInBrowser off, update+backup schedulers off, flaresolverr on"

    # 3. the page path, hermetically: Local source -> chapters -> page URLs -> page bytes
    r=$(gq '{"query":"{ sources { nodes { id name lang } } }"}')
    sid=$(printf '%s' "$r" | jq -r '.data.sources.nodes[] | select(.lang=="localsourcelang") | .id')
    [ -n "$sid" ] || fail "no local source registered: $r"
    mid=$(gq '{"query":"mutation($s:LongString!,$t:FetchSourceMangaType!,$q:String,$p:Int!){ fetchSourceManga(input:{source:$s,type:$t,query:$q,page:$p}){ mangas { id title } } }","variables":{"s":"'"$sid"'","t":"SEARCH","q":"","p":1}}' | jq -r '.data.fetchSourceManga.mangas[0].id')
    [ -n "$mid" ] && [ "$mid" != "null" ] || fail "the local source listed no manga (is the CBZ fixture in place?)"
    chid=$(gq '{"query":"mutation($id:Int!){ fetchMangaAndChapters(input:{id:$id,fetchManga:true,fetchChapters:true}){ chapters { id } } }","variables":{"id":'"$mid"'}}' | jq -r '.data.fetchMangaAndChapters.chapters[0].id')
    [ -n "$chid" ] && [ "$chid" != "null" ] || fail "no chapters from the local source"
    page=$(gq '{"query":"mutation($c:Int!){ fetchChapterPages(input:{chapterId:$c}){ pages } }","variables":{"c":'"$chid"'}}' | jq -r '.data.fetchChapterPages.pages[0]')
    [ -n "$page" ] && [ "$page" != "null" ] || fail "no page URLs for the local chapter"
    bytes=$(curl -s "$BASE$page" | wc -c)
    [ "$bytes" -gt 100 ] || fail "page bytes came back empty ($bytes bytes)"
    ok "local source served a page: $page ($bytes bytes)"

    # 4. the extension integration: store -> catalogue -> install (APK -> JVM bytecode) -> sources
    r=$(gq '{"query":"mutation($u:String!){ addExtensionStore(input:{indexUrl:$u}){ extensionStore { name } } }","variables":{"u":"'"$INDEX"'"}}')
    printf '%s' "$r" | jq -e '.data.addExtensionStore.extensionStore' >/dev/null || fail "could not add the store: $r"
    gq '{"query":"mutation{ fetchExtensions(input:{}){ extensions { pkgName } } }"}' >/dev/null
    r=$(gq '{"query":"{ extensions { nodes { pkgName lang contentWarning isInstalled } } }"}')
    total=$(printf '%s' "$r" | jq '.data.extensions.nodes | length')
    [ "$total" -gt 100 ] || fail "catalogue looks empty ($total extensions)"
    ok "catalogue fetched: $total extensions"

    # chosen at test time, never hardcoded, so an upstream rename or retirement is not a CI failure
    pkg=$(printf '%s' "$r" | jq -r '[.data.extensions.nodes[] | select(.lang=="en" and .contentWarning!="NSFW" and .isInstalled==false)] | sort_by(.pkgName) | .[0].pkgName')
    [ -n "$pkg" ] && [ "$pkg" != "null" ] || fail "no installable extension in the catalogue"
    r=$(gq '{"query":"mutation($id:String!,$p:UpdateExtensionPatchInput!){ updateExtension(input:{id:$id,patch:$p}){ extension { pkgName isInstalled } } }","variables":{"id":"'"$pkg"'","p":{"install":true}}}')
    [ "$(field "$r" '.data.updateExtension.extension.isInstalled')" = "true" ] || fail "install failed for $pkg: $r"
    ok "installed $pkg (APK converted to JVM bytecode)"

    r=$(gq '{"query":"{ sources { totalCount } }"}')
    [ "$(field "$r" '.data.sources.totalCount')" -gt 1 ] || fail "the installed extension registered no sources: $r"
    ok "sources registered: $(field "$r" '.data.sources.totalCount')"
    echo "hard assertions: PASSED"
    ;;

site)
    # Third-party, therefore advisory: the site may be down, rate-limit or Cloudflare-block the CI IP,
    # and the extension itself may be broken or retired. None of that is a regression in this image.
    r=$(gq '{"query":"{ sources { nodes { id name } } }"}')
    n=0
    for sid in $(printf '%s' "$r" | jq -r '.data.sources.nodes[] | select(.name!="Local source") | .id' | head -5); do
        n=$((n + 1))
        out=$(gq '{"query":"mutation($s:LongString!,$t:FetchSourceMangaType!,$q:String,$p:Int!){ fetchSourceManga(input:{source:$s,type:$t,query:$q,page:$p}){ mangas { title } } }","variables":{"s":"'"$sid"'","t":"SEARCH","q":"one piece","p":1}}')
        titles=$(printf '%s' "$out" | jq -r '[.data.fetchSourceManga.mangas[]?.title] | length' 2>/dev/null || echo 0)
        if [ "${titles:-0}" -gt 0 ]; then
            ok "source $sid returned $titles results"
            exit 0
        fi
        warn "source $sid did not answer: $(printf '%s' "$out" | jq -r '.errors[0].message' 2>/dev/null | head -c 120)"
    done
    warn "no source answered ($n tried) - advisory only"
    ;;

*)
    fail "unknown mode: $MODE (expected hard or site)"
    ;;
esac
