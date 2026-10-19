#!/bin/sh
# Entrypoint for the slim Suwayomi engine.
#
# Upstream's entrypoint unzips server-reference.conf out of the jar and seds ~70 values into it (which
# is why its image carries unzip, gettext-base, jq and gawk). Suwayomi reads `-D` system properties as
# config overrides -- the mechanism its own systemd unit uses -- so this one passes them on the command
# line instead: no unzip, no sed, and the overrides still win over a server.conf left in the volume by
# an earlier (official) run.
#
# Two traps worth knowing, both hit while writing this:
#   * the -D flags must come BEFORE -jar. After it they are program arguments and the app silently
#     starts with every default (WebUI downloading itself, WebView on, X11 wanted).
#   * `set --` inside a shell FUNCTION sets that function's own positional parameters, not the
#     caller's. A helper that appends a flag therefore appends nothing. Hence the straight-line
#     `set -- "$@" ...` below: verbose, but it is the only form that works in POSIX sh.
#
# Values are HOCON (that is how Suwayomi parses the property), so strings are quoted and
# numbers/booleans are not. Keep that distinction when adding one.
set -eu

ENGINE_HOME="${ENGINE_HOME:-/home/suwayomi/.local/share/Tachidesk}"
JAR="${JAR:-/home/suwayomi/startup/engine.jar}"

read_secret() {
    # $1 names an env var holding a path to a file with the secret (upstream parity)
    eval "_file=\${$1:-}"
    if [ -n "$_file" ] && [ -f "$_file" ]; then cat "$_file"; fi
}
if [ -n "$(read_secret AUTH_PASSWORD_FILE)" ]; then AUTH_PASSWORD="$(read_secret AUTH_PASSWORD_FILE)"; fi
if [ -n "$(read_secret BASIC_AUTH_PASSWORD_FILE)" ]; then BASIC_AUTH_PASSWORD="$(read_secret BASIC_AUTH_PASSWORD_FILE)"; fi
if [ -n "$(read_secret DATABASE_PASSWORD_FILE)" ]; then DATABASE_PASSWORD="$(read_secret DATABASE_PASSWORD_FILE)"; fi

# AUTH_MODE wins; BASIC_AUTH_ENABLED=true is the shorthand. SUWAYOMI_USERNAME/PASSWORD are accepted
# too, so a Uchiyomi .env written for its bundled engine works verbatim.
if [ -z "${AUTH_MODE:-}" ] && [ "${BASIC_AUTH_ENABLED:-false}" = "true" ]; then AUTH_MODE=BASIC_AUTH; fi

# ---- the argument list ---------------------------------------------------------------------------
set -- -Duser.home=/home/suwayomi

# server binding
set -- "$@" "-Dsuwayomi.tachidesk.config.server.ip=${BIND_IP:-0.0.0.0}"
set -- "$@" "-Dsuwayomi.tachidesk.config.server.port=${BIND_PORT:-4567}"

# this image is a headless extension engine: the UI, the WebView and the tray are all gone. Forced,
# not defaulted, so a server.conf left in the volume cannot turn them back on.
set -- "$@" "-Dsuwayomi.tachidesk.config.server.initialOpenInBrowserEnabled=false"
set -- "$@" "-Dsuwayomi.tachidesk.config.server.systemTrayEnabled=false"
set -- "$@" "-Dsuwayomi.tachidesk.config.server.kcefEnabled=false"
set -- "$@" "-Dsuwayomi.tachidesk.config.server.webUIEnabled=${WEB_UI_ENABLED:-false}"
set -- "$@" "-Dsuwayomi.tachidesk.config.server.webUIUpdateCheckInterval=${WEB_UI_UPDATE_INTERVAL:-0}"
set -- "$@" "-Dsuwayomi.tachidesk.config.server.webUIInterface=\"${WEB_UI_INTERFACE:-BROWSER}\""

# databases
set -- "$@" "-Dsuwayomi.tachidesk.config.server.databaseType=\"${DATABASE_TYPE:-H2}\""
set -- "$@" "-Dsuwayomi.tachidesk.config.server.databaseUrl=\"${DATABASE_URL:-postgresql://localhost:5432/suwayomi}\""
set -- "$@" "-Dsuwayomi.tachidesk.config.server.databaseUsername=\"${DATABASE_USERNAME:-}\""
set -- "$@" "-Dsuwayomi.tachidesk.config.server.databasePassword=\"${DATABASE_PASSWORD:-}\""
set -- "$@" "-Dsuwayomi.tachidesk.config.server.useHikariConnectionPool=${USE_HIKARI_CONNECTION_POOL:-true}"

# auth
set -- "$@" "-Dsuwayomi.tachidesk.config.server.authMode=\"${AUTH_MODE:-NONE}\""
set -- "$@" "-Dsuwayomi.tachidesk.config.server.authUsername=\"${AUTH_USERNAME:-${BASIC_AUTH_USERNAME:-${SUWAYOMI_USERNAME:-}}}\""
set -- "$@" "-Dsuwayomi.tachidesk.config.server.authPassword=\"${AUTH_PASSWORD:-${BASIC_AUTH_PASSWORD:-${SUWAYOMI_PASSWORD:-}}}\""
set -- "$@" "-Dsuwayomi.tachidesk.config.server.jwtAudience=\"${JWT_AUDIENCE:-suwayomi-server-api}\""
set -- "$@" "-Dsuwayomi.tachidesk.config.server.jwtTokenExpiry=\"${JWT_TOKEN_EXPIRY:-5m}\""
set -- "$@" "-Dsuwayomi.tachidesk.config.server.jwtRefreshExpiry=\"${JWT_REFRESH_EXPIRY:-60d}\""

# extension stores (Uchiyomi normally adds these itself over GraphQL; this is for pre-seeding)
if [ -n "${EXTENSION_STORES:-}" ]; then
    set -- "$@" "-Dsuwayomi.tachidesk.config.server.extensionStores=${EXTENSION_STORES}"
fi

# Cloudflare: the engine has no browser of its own, it uses the FlareSolverr Uchiyomi ships
set -- "$@" "-Dsuwayomi.tachidesk.config.server.flareSolverrEnabled=${FLARESOLVERR_ENABLED:-false}"
set -- "$@" "-Dsuwayomi.tachidesk.config.server.flareSolverrUrl=\"${FLARESOLVERR_URL:-http://localhost:8191}\""
set -- "$@" "-Dsuwayomi.tachidesk.config.server.flareSolverrTimeout=${FLARESOLVERR_TIMEOUT:-60}"
set -- "$@" "-Dsuwayomi.tachidesk.config.server.flareSolverrSessionName=\"${FLARESOLVERR_SESSION_NAME:-suwayomi}\""
set -- "$@" "-Dsuwayomi.tachidesk.config.server.flareSolverrSessionTtl=${FLARESOLVERR_SESSION_TTL:-15}"
set -- "$@" "-Dsuwayomi.tachidesk.config.server.flareSolverrAsResponseFallback=${FLARESOLVERR_RESPONSE_AS_FALLBACK:-false}"

# fetching: Uchiyomi owns the library and the downloads
set -- "$@" "-Dsuwayomi.tachidesk.config.server.maxSourcesInParallel=${MAX_SOURCES_IN_PARALLEL:-2}"
set -- "$@" "-Dsuwayomi.tachidesk.config.server.downloadAsCbz=${DOWNLOAD_AS_CBZ:-true}"
set -- "$@" "-Dsuwayomi.tachidesk.config.server.autoDownloadNewChapters=${AUTO_DOWNLOAD_CHAPTERS:-false}"
set -- "$@" "-Dsuwayomi.tachidesk.config.server.autoDownloadNewChaptersLimit=${AUTO_DOWNLOAD_NEW_CHAPTERS_LIMIT:-0}"

# scheduled work Uchiyomi does not want the engine doing
set -- "$@" "-Dsuwayomi.tachidesk.config.server.globalUpdateInterval=${UPDATE_INTERVAL:-0}"
set -- "$@" "-Dsuwayomi.tachidesk.config.server.updateMangas=${UPDATE_MANGAS:-false}"
set -- "$@" "-Dsuwayomi.tachidesk.config.server.backupInterval=${BACKUP_INTERVAL:-0}"
set -- "$@" "-Dsuwayomi.tachidesk.config.server.backupTTL=${BACKUP_TTL:-0}"

# local source: a directory of CBZ/CBR/EPUB/PDF or image folders the engine serves pages from. Uchiyomi
# keeps its own library on its own disk, so this is normally unset -- CI sets it so the page path
# (chapter -> page URLs -> page bytes) is exercised with no external site and no extension involved.
if [ -n "${LOCAL_SOURCE_PATH:-}" ]; then
    set -- "$@" "-Dsuwayomi.tachidesk.config.server.localSourcePath=\"${LOCAL_SOURCE_PATH}\""
fi

# logs: bounded, off by default
set -- "$@" "-Dsuwayomi.tachidesk.config.server.debugLogsEnabled=${DEBUG:-false}"
set -- "$@" "-Dsuwayomi.tachidesk.config.server.maxLogFiles=${MAX_LOG_FILES:-3}"
set -- "$@" "-Dsuwayomi.tachidesk.config.server.maxLogFileSize=\"${MAX_LOG_FILE_SIZE:-2mb}\""
set -- "$@" "-Dsuwayomi.tachidesk.config.server.maxLogFolderSize=\"${MAX_LOG_FOLDER_SIZE:-15mb}\""

# optional SOCKS5 proxy (upstream parity)
set -- "$@" "-Dsuwayomi.tachidesk.config.server.socksProxyEnabled=${SOCKS_PROXY_ENABLED:-false}"
set -- "$@" "-Dsuwayomi.tachidesk.config.server.socksProxyVersion=${SOCKS_PROXY_VERSION:-5}"
set -- "$@" "-Dsuwayomi.tachidesk.config.server.socksProxyHost=\"${SOCKS_PROXY_HOST:-}\""
set -- "$@" "-Dsuwayomi.tachidesk.config.server.socksProxyPort=\"${SOCKS_PROXY_PORT:-}\""
set -- "$@" "-Dsuwayomi.tachidesk.config.server.socksProxyUsername=\"${SOCKS_PROXY_USERNAME:-}\""
set -- "$@" "-Dsuwayomi.tachidesk.config.server.socksProxyPassword=\"${SOCKS_PROXY_PASSWORD:-}\""

# escape hatch: any extra -D flags, verbatim
if [ -n "${SUWAYOMI_SERVER_OPTS:-}" ]; then
    # shellcheck disable=SC2086
    set -- "$@" $SUWAYOMI_SERVER_OPTS
fi

mkdir -p "$ENGINE_HOME" 2>/dev/null || true

# JAVA_TOOL_OPTIONS is read by every JVM; set here only if the operator has not, so an operator value
# replaces (not accumulates with) ours.
if [ -z "${JAVA_TOOL_OPTIONS:-}" ]; then
    export JAVA_TOOL_OPTIONS="-Xms48m -Xmx320m -XX:+UseSerialGC -XX:MaxMetaspaceSize=192m -XX:ReservedCodeCacheSize=96m -XX:MaxDirectMemorySize=160m -XX:ActiveProcessorCount=2 -XX:+ExitOnOutOfMemoryError -XX:-UsePerfData -Djava.awt.headless=true -Dfile.encoding=UTF-8 -Dsun.jnu.encoding=UTF-8"
fi
export MALLOC_ARENA_MAX="${MALLOC_ARENA_MAX:-2}"

exec java "$@" -jar "$JAR"
