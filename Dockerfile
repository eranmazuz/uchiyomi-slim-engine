# Suwayomi-Server, stripped down to what Uchiyomi actually calls.
#
# Uchiyomi drives the engine over exactly one GraphQL endpoint (/api/graphql) plus four REST image
# paths, all Basic-auth. It never opens the engine's UI, never uses its library, and never lets it
# download anything. So this image drops everything upstream ships that serves those other jobs:
#
#   * the KCEF/JCEF WebView (Chromium Embedded Framework) and its ~200 MB of natives, plus Xvfb and
#     the whole X11/GTK/audio dependency chain and the CJK font packages upstream installs for it;
#   * the bundled WebUI (WebUI.zip) and its update checker;
#   * every non-x86_64 native in the jar (Mac/Windows/ARM/PPC/x86 libwebp + zstd);
#   * tini, curl, unzip, gettext-base, jq, gawk -- none of which the runtime needs. Upstream uses
#     them in the entrypoint to sed the config; this image overrides config with -D system
#     properties instead, which is the mechanism upstream's own systemd unit uses.
#
# Result: ~2.13 GB -> ~0.3 GB, and a leaner JVM at runtime (see README.md for measured numbers).
#
# Everything the extension engine itself needs is kept: the whole AndroidCompat fake-Android runtime
# (the ~84 MB that makes Mihon/Tachiyomi extensions run off-Android), the extension store/install
# machinery, the image pipeline (incl. the x86_64 libwebp you need for real webtoon pages), H2, the
# GraphQL schema and FlareSolverr support.

ARG BASE_IMAGE=eclipse-temurin:25.0.4_7-jre-noble

# ---------------------------------------------------------------- stage 1: fetch + strip the jar
FROM ${BASE_IMAGE} AS fetch

ARG ENGINE_VERSION=v2.4.2366
ARG ENGINE_SHA256=af9feb20af9d7ebe9e30769e6c6ebc7fc7ab1c447388d42e0280b1da5fe07bfd

RUN apt-get update && apt-get -y install --no-install-recommends curl unzip zip ca-certificates \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /engine
RUN curl -fsSL -o engine.jar \
      "https://github.com/Suwayomi/Suwayomi-Server/releases/download/${ENGINE_VERSION}/Suwayomi-Server-${ENGINE_VERSION}.jar" \
 && echo "${ENGINE_SHA256}  engine.jar" | sha256sum -c -

# `zip -d` rewrites only the central directory, so everything we keep stays byte-identical.
# No signature files exist in the release jar; this removes them if upstream ever starts signing.
RUN set -eux; \
    zip -q -d engine.jar \
        'WebUI.zip' \
        'com/jetbrains/cef/*' \
        'native/Mac/*' 'native/Windows/*' \
        'native/Linux/aarch64/*' 'native/Linux/arm/*' 'native/Linux/armv6/*' 'native/Linux/armv7/*' \
        'native/Linux/ppc64/*' 'native/Linux/x86/*' \
        'jni/aarch64/*' 'jni/x86_64/*' 'jni/x86/*' \
        'META-INF/*.SF' 'META-INF/*.RSA' 'META-INF/*.DSA' 'META-INF/*.EC' \
    ; \
    ls -l engine.jar

# ---------------------------------------------------------------- stage 2: the runtime
FROM ${BASE_IMAGE}

# v2.4.2366 is what Uchiyomi v0.78.x pins and tests against (bff/src/lib/sources/suwayomi/enginePin.ts).
ARG ENGINE_VERSION=v2.4.2366

ENV HOME=/home/suwayomi \
    LANG=C.UTF-8 \
    TZ=UTC \
    MALLOC_ARENA_MAX=2 \
    ENGINE_HOME=/home/suwayomi/.local/share/Tachidesk

# uid/gid 1000, same as upstream, so an existing uchiyomi_suwayomi volume keeps working untouched.
RUN set -eux; \
    if getent passwd 1000 >/dev/null; then userdel -r "$(getent passwd 1000 | cut -d: -f1)"; fi; \
    groupadd --gid 1000 suwayomi; \
    useradd --uid 1000 --gid 1000 --no-log-init --create-home --home-dir /home/suwayomi suwayomi; \
    mkdir -p /home/suwayomi/startup "${ENGINE_HOME}"; \
    chown -R 1000:1000 /home/suwayomi

# The jar is only ever read, so plain COPY (root-owned, mode 644) is enough and costs no chown layer;
# the writable paths are the volume and the user's home, both owned by 1000.
COPY --from=fetch /engine/engine.jar /home/suwayomi/startup/engine.jar
COPY entrypoint.sh /home/suwayomi/entrypoint.sh
RUN chmod 0644 /home/suwayomi/startup/engine.jar && chmod 0755 /home/suwayomi/entrypoint.sh

USER suwayomi
WORKDIR /home/suwayomi
EXPOSE 4567

# Same check Uchiyomi's compose file uses, so either healthcheck works. 401 counts as alive: the
# engine is up, it just has authentication switched on.
HEALTHCHECK --interval=60s --timeout=10s --retries=3 --start-period=60s \
  CMD bash -c "exec 3<>/dev/tcp/127.0.0.1/4567; printf 'GET /api/v1/settings/about HTTP/1.0\r\n\r\n' >&3; head -1 <&3 | grep -qE ' (200|401) '"

ENTRYPOINT ["/home/suwayomi/entrypoint.sh"]
