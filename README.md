# uchiyomi-slim-engine

A stripped Suwayomi-Server, built for exactly one job: being the extension engine Uchiyomi calls.

Uchiyomi talks to the engine over one GraphQL endpoint (`POST /api/graphql`), four REST image paths and
optional Basic auth. It never opens the engine's UI, never uses its library, and never lets it download
anything. So this image removes everything upstream ships that serves those other jobs, and tunes the
JVM for a small box.

**Measured, same host, same workload, official `ghcr.io/suwayomi/suwayomi-server:v2.4.2366` vs this image:**

|                        | official          | this image | |
|------------------------|-------------------|------------|---|
| image size             | **2.13 GB**       | **754 MB** | 2.8× smaller |
| ready to answer (HTTP 200) | 10.6 s        | 5.4 s      | starts twice as fast |
| idle RSS               | **1067 MB**       | **383 MB** | 2.8× less |
| RSS during the workload below | 1186 MB    | 436 MB     | 2.7× less |
| peak RSS               | 1191 MB           | 446 MB     | |
| processes              | 12 (java + Xvfb + **10 Chromium/CEF helpers**) | **1 (java)** | |

The idle number is the one that matters if the engine sits behind Uchiyomi doing nothing for most of the
day: the official image runs a full headless Chromium the whole time, this one runs a JVM with a
320 MB heap cap.

## What was removed, and why it is safe

| Removed | Why it is not needed |
|---|---|
| **KCEF / JCEF** (Chromium Embedded Framework): its ~200 MB of natives, Xvfb, and the X11/GTK/audio/CJK-font dependency chain | It is the engine's Android-`WebView` implementation. Uchiyomi never enables it and has no UI. **This is the one real trade-off — see below.** |
| the bundled **WebUI** (`WebUI.zip`) and its update checker | Uchiyomi never opens the engine's interface |
| `tini`, `curl`, `unzip`, `gettext-base`, `jq`, `gawk` | upstream's entrypoint needs them to sed ~70 values into `server-reference.conf`; this one passes config as `-D` system properties instead, which is the mechanism Suwayomi's own systemd unit uses, needs no packages, and outranks a stale `server.conf` in the volume |
| every non-x86_64 native in the jar (Mac/Windows/ARM/PPC/x86 `libwebp`, zstd) | never loaded on a Linux/amd64 host |

**Everything the extension engine needs is kept:** the whole AndroidCompat fake-Android runtime (the
~84 MB that lets Mihon/Tachiyomi extensions run off-Android), the extension store/install machinery,
the image pipeline including the x86_64 `libwebp` real webtoon pages need, H2, the GraphQL schema, and
FlareSolverr support.

## What was configured off

None of this is guesswork: every value below was read back off the running engine after start.

| Setting | upstream default | here | why |
|---|---|---|---|
| `kcefEnabled` | `true` | **`false`** | no WebView in this image |
| `webUIEnabled` / `webUIUpdateCheckInterval` | `true` / `23h` | **`false` / `0`** | Uchiyomi never opens it |
| `systemTrayEnabled` | `true` | **`false`** | headless; the tray needs X11 |
| `initialOpenInBrowserEnabled` | `true` | **`false`** | ditto |
| `globalUpdateInterval` | `12h` | **`0`** | Uchiyomi owns the update schedule |
| `backupInterval` / `backupTTL` | `1` day / `14` | **`0` / `0`** | Uchiyomi takes its own backups |
| `autoDownloadNewChapters` | `false` | `false` | explicit |
| `maxSourcesInParallel` | `6` | **`2`** | smaller thread pool; Uchiyomi drives the parallelism it wants |
| `maxLogFiles` / size / folder | 31 / `10mb` / `100mb` | **3 / `2mb` / `15mb`** | bounded log growth |
| JVM | none (unbounded heap = ¼ of host RAM) | `-Xmx320m -XX:+UseSerialGC -XX:MaxMetaspaceSize=192m -XX:ReservedCodeCacheSize=96m -XX:MaxDirectMemorySize=160m -XX:ActiveProcessorCount=2 -Djava.awt.headless=true` | measured peak RSS under the workload is 446 MB, so a **512 MB container limit** is comfortable |

`JAVA_TOOL_OPTIONS` is only set if you have not set it, so an operator value replaces the defaults
rather than fighting them.

## Verification

`test/uchiyomi-api-check.py` replays every operation Uchiyomi sends (its whole `operations.ts` registry
plus the image paths from `routes/images.ts`) against a running engine:

```
python3 test/uchiyomi-api-check.py http://engine:4567 \
    --repo https://github.com/keiyoushi/extensions/raw/repo/index.pb
```

Result on this image, from a **fresh volume**:

```
ok  aboutServer, addExtensionStore, extensionStores, fetchExtensions,
    extensions (1443 in the catalogue), updateExtension (install),
    sources, fetchSourceManga, fetchMangaAndChapters, fetchChapterPages,
    GET /api/v1/manga/<id>/chapter/<n>/page/<n>, GET thumbnail, GET extension icon
21/24 ok — the 3 failures are "No chapters found" from the MangaDex extension for
particular titles, and happen identically on the official image
```

A real end-to-end run: search → 5 chapters → 14 page paths → **`GET /api/v1/manga/109/chapter/1/page/0`
→ HTTP 200 `image/jpeg`, 921 KB**. Six extensions installed from the keiyoushi store in the process.

Uchiyomi's own healthcheck passes inside the image (`bash` is kept for exactly that), and Docker
reports it `healthy`.

## The one trade-off: no WebView

The official image runs headless Chromium so extensions that ask for an Android `WebView` can use one.
This image does not, and such extensions fail with:

```
Exception while fetching data (/fetchSourceManga) : CEF is disabled
```

Manga UP! is the example found here. On the official image, in this test environment, the same
extension failed the other way — `Timed out waiting for WebView after 10s` — so how well the WebView
works on a real host is not something these measurements can tell you either way.

What to do about it:

- Most extensions use plain HTTP and are unaffected; Uchiyomi routes Cloudflare challenges through the
  FlareSolverr container it ships (`FLARESOLVERR_ENABLED`), which still works here.
- If a source you care about needs the WebView, ask and it can be built as a second variant
  (`--build-arg WITH_WEBVIEW=1`): Chromium, Xvfb and the KCEF download come back, and with them most of
  the image size and the ~700 MB of Chromium processes at idle.

## FlareSolverr (Cloudflare)

Unchanged from Uchiyomi's stack: the solver is its own container, and the engine is pointed at it by
name. This image needs nothing extra for it — removing the engine's own Chromium is precisely why the
solver matters, and `flareSolverrEnabled` is on by default here.

Brought up exactly as Uchiyomi's compose does, on the same user-defined network with the same service
name, and verified:

- `ghcr.io/flaresolverr/flaresolverr` (3.5.2, Chromium 152) answers `{"msg": "FlareSolverr is ready!"}`;
- the engine resolves and connects to `uchiyomi-flaresolverr:8191` on that network;
- the settings read back as `flareSolverrEnabled: true`, `flareSolverrUrl: http://uchiyomi-flaresolverr:8191`;
- **the exact call the engine makes, issued from inside the engine container** — `POST /v1`
  `{"cmd":"request.get","url":"https://weebcentral.com"}` — came back with a full solution (cookies and
  all) in ~8 s.

`test/flaresolverr-ab.py` searches the same sources with the setting off and on, flipping it through
the same GraphQL mutation Uchiyomi uses (`setSolverSettings`).

⚠️ **What that A/B did *not* show, on this host:** none of the ~12 sources probed actually triggered a
call to the solver — no `Incoming request` ever reached it during a search (calibrated: a direct `/v1`
call *does* get logged, so silence is real information). These sites did not challenge this IP, so the
run cannot demonstrate the solver rescuing a Cloudflare-blocked source; it demonstrates the wiring is
live and correct. Worth knowing: the searches ran consistently ~1.1–1.4 s slower with the setting on
even though the solver received nothing — unexplained, and reportedly there is no reason for it.

Suwayomi only calls the solver from `CloudflareInterceptor` (`server/src/main/kotlin/eu/kanade/tachiyomi/network/interceptor/CloudflareInterceptor.kt`),
i.e. when a response actually looks like a challenge — so a quiet solver log during searches that work
is the expected shape, not a fault. If a source is challenged, `flareSolverrAsResponseFallback` decides
whether the solved response is used in place of the site's own.

## Build and run

```sh
cd uchiyomi-slim-engine
docker build -t uchiyomi-engine-slim:v2.4.2366 .
```

Then in Uchiyomi's `deploy/docker-compose.yml`, replace the `uchiyomi-suwayomi` service with
`compose.snippet.yml`. The volume path is unchanged (`uchiyomi_suwayomi:/home/suwayomi/.local/share/Tachidesk`)
and ownership is still uid/gid 1000, so an existing engine volume — installed extensions, sources, the
H2 database — carries over untouched.

```
SUWAYOMI_MEM_LIMIT=512m        # was 2048m
SUWAYOMI_JAVA_OPTS=...         # optional, replaces the lean defaults
```

## Notes and known limits

- **Base image:** `eclipse-temurin:25.0.4_7-jre-noble`. Alpine was tried and rejected: Suwayomi loads
  glibc-only natives from the jar (`libwebp-imageio.so`, `libjnidispatch.so`, `libzstd-kmp.so`), and
  `linux-musl` builds are not among them — real webp pages would break.
- **The jar cannot be slimmed much further.** Of its 175 MB, the AndroidCompat fake-Android runtime is
  ~84 MB and is the thing that actually runs extensions. `WebUI.zip`, the KCEF Java bindings and the
  foreign-arch natives were ~15 MB of it. What is left (GraalJS/Truffle/ICU, ~49 MB) is dead weight for
  our path in principle, but removing classes from a fat jar is the kind of change that fails at the
  first class-init that touches them; not worth 49 MB without a reason.
- The engine still has its own updater, downloader and library code; they are inert (their schedulers
  are off) but present. Stripping them would break the GraphQL schema Uchiyomi queries.
- The engine pins `v2.4.2366`. Uchiyomi supports `v2.3.2243` and up, and validates its documents against
  every engine schema from there — if you move this image to another engine version, move
  `ENGINE_VERSION`/`ENGINE_SHA256` in the Dockerfile with it (the sha256 is checked at build time).
- H2 is the database (upstream's default). That is right here: one writer, no library.
