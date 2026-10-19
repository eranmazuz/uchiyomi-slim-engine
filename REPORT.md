# Uchiyomi extension engine, slimmed — what was done and why

*Work report. The runnable artifacts are in this same directory: `Dockerfile`, `entrypoint.sh`,
`compose.snippet.yml`, `test/`.*

---

## 1. What this actually is

**Short answer: it is the same Suwayomi-Server, configured to be nothing but the extension engine and
the API Uchiyomi calls — plus the removal of the parts that only exist to serve a user interface.**

Two things worth separating, because they are different kinds of change:

**Removed (files, real size):**
- the KCEF/JCEF WebView — the Chromium Embedded Framework the engine uses to implement Android
  `WebView`. That is its ~200 MB native download, plus Xvfb, plus the X11/GTK/audio libraries and the
  CJK font packages upstream installs to support it;
- the bundled WebUI (`WebUI.zip`) and its update checker;
- the KCEF Java bindings and every non-x86_64 native inside the jar (Mac/Windows/ARM/PPC/x86 `libwebp`
  and zstd) — about 8 MB;
- `tini`, `curl`, `unzip`, `gettext-base`, `jq`, `gawk` — upstream's entrypoint needs them to `sed`
  ~70 values into `server-reference.conf`; this image passes config as `-D` system properties instead,
  which is what Suwayomi's own systemd unit does and needs no packages at all.

**Not removed (deliberately):** the downloader, library, tracker and updater **code is still in the
jar**. It is inert — its schedulers are switched off and Uchiyomi never calls it — but it is present,
because Suwayomi generates its GraphQL schema from all of those services, and Uchiyomi queries that
schema. Deleting features would break the API contract the client depends on. So the honest phrasing
is *"the extension engine and the API, and nothing else running"*, not *"the code was stripped"*.

**Kept because the engine cannot work without it:** the whole AndroidCompat fake-Android runtime — the
~84 MB that lets Mihon/Tachiyomi extensions run off-Android. That is the bulk of the jar and the one
part that is genuinely irreplaceable.

---

## 2. Why the process count went from ~12 to 1

The processes that disappeared were not the engine. They were **a browser**:

| official image, idle | this image, idle |
|---|---|
| 1 JVM | **1 JVM** |
| `tini` (init wrapper) | — (single `exec java`, no wrapper) |
| entrypoint `sh` | — |
| `xvfb-run` + `Xvfb` (a virtual X server) | — |
| **6 Chromium helper processes** (`jcef_helper`: gpu-process, renderer, network service, storage, on-device-model, zygotes) | — |
| **total ~10, growing to ~12** | **1** |

The official image starts a headless Chromium at boot, because upstream's default is `kcefEnabled =
true` and Uchiyomi's compose file does not override it. That Chromium exists so extensions that ask for
an Android `WebView` can have one. This image sets `kcefEnabled=false`, so `CEFManager` logs
`CEF is disabled` and returns before it ever touches X11 — no X server, no browser, no helper
processes.

That is also where most of the idle memory went: those Chromium processes plus their share of the JVM
are why the official image sits at ~1067 MB doing nothing, and this one at ~383 MB.

*(Note on the exact number: Chromium spawns its helpers on demand, so the official count moves between
9 and 12 depending on when you look — I saw 9, then 10, then 12 across measurements. The slim image is
1, always. My first "12" figure also included the `docker exec` shell used to take the measurement;
the table above is from `docker top`, which lists only the container's own processes.)*

---

## 3. What Uchiyomi actually needs from the engine

Everything below was read out of Uchiyomi's source (`bff/src/lib/sources/suwayomi/*`,
`bff/src/routes/images.ts`), not from Suwayomi's documentation.

**One API endpoint:** `POST /api/graphql` — *not* `/graphql`; the published Suwayomi docs say otherwise
and the server 404s on it. Auth is HTTP **Basic** (`SUWAYOMI_USERNAME` / `SUWAYOMI_PASSWORD`); there is
no login or token endpoint.

Queries: `aboutServer`, `sources`, `extensions`, `extensionFacts`, `sourcesOfExtension`,
`extensionStores`, `solverSettings`, `sourcePreferences`.

Mutations: `fetchSourceManga`, `fetchMangaAndChapters` (replaced `fetchManga`/`fetchChapters`),
`fetchChapterPages`, `fetchExtensions`, `updateExtension` (install/uninstall/update),
`addExtensionStore`, `removeExtensionStore`, `setSettings`, `clearCachedImages`,
`updateSourcePreference`.

**Four REST paths, images only:**
- `GET /api/v1/manga/{mangaId}/thumbnail`
- `GET /api/v1/manga/{mangaId}/chapter/{sourceOrder}/page/{n}` (keyed on `sourceOrder`, not chapter id)
- `GET /api/v1/extension/icon/{pkgName}`
- `GET /api/v1/settings/about` (used only by the compose healthcheck)

That is the entire surface. The engine's UI, library, downloads and OPDS are never touched — which is
what made the stripping possible.

---

## 4. How the image is built

**Stage 1 — fetch and strip.** Downloads the pinned release jar
(`Suwayomi-Server-v2.4.2366.jar`) and **verifies its sha256** against the value from upstream's
`Checksums.sha256`, then removes the WebUI bundle, the KCEF Java bindings, the foreign-arch natives and
any signature files, using `zip -d` so everything kept stays byte-identical.

**Stage 2 — runtime.** `eclipse-temurin:25.0.4_7-jre-noble`, a uid/gid 1000 `suwayomi` user (same as
upstream, so an existing engine volume keeps working), the jar, the entrypoint, and **no packages
installed at all** — the Ubuntu base already has everything needed.

**Configuration is passed as `-D` system properties, not sed'ed into a file.** Suwayomi reads
`-Dsuwayomi.tachidesk.config.server.<key>` as an override (that is what its systemd unit uses). This
means: no `unzip`/`gettext`/`sed` in the image, and the overrides **outrank** a `server.conf` left in
the volume by an earlier official-image run — a stale file cannot quietly turn the WebUI or the
WebView back on.

Two traps found the hard way, both fixed and commented in `entrypoint.sh`:
- the `-D` flags must come **before** `-jar`; after it they are program arguments, and the app starts
  with every default (WebUI downloading itself, WebView on, X11 wanted) with nothing in the log to say why;
- `set --` inside a shell **function** sets that function's own positional parameters, not the
  caller's — so a helper that appends a flag appends nothing. The entrypoint is straight-line
  `set -- "$@" ...` for that reason.

---

## 5. Configuration, and why each value

| Setting | upstream | here | reason |
|---|---|---|---|
| `kcefEnabled` | `true` | **`false`** | no WebView in this image — the main saving |
| `webUIEnabled` / `webUIUpdateCheckInterval` | `true` / `23h` | **`false` / `0`** | Uchiyomi never opens the UI |
| `systemTrayEnabled` | `true` | **`false`** | headless; the tray needs X11 |
| `initialOpenInBrowserEnabled` | `true` | **`false`** | ditto |
| `globalUpdateInterval` | `12h` | **`0`** | Uchiyomi owns the update schedule |
| `backupInterval` / `backupTTL` | `1` day / `14` | **`0` / `0`** | Uchiyomi takes its own backups |
| `maxSourcesInParallel` | `6` | **`2`** | smaller thread pool |
| `maxLogFiles` / size / folder | 31 / `10mb` / `100mb` | **3 / `2mb` / `15mb`** | bounded log growth |
| `flareSolverrEnabled` | `false` | **`true`** (via env) | the engine has no browser; this is the replacement |
| JVM | none — unbounded heap, sized from host RAM (a quarter of it) | `-Xmx320m -XX:+UseSerialGC -XX:MaxMetaspaceSize=192m -XX:ReservedCodeCacheSize=96m -XX:MaxDirectMemorySize=160m -XX:ActiveProcessorCount=2 -Djava.awt.headless=true` | measured peak under the workload is 446 MB, so a 512 MB limit is comfortable |

Every one of these was read back off the running engine after start, not assumed. `JAVA_TOOL_OPTIONS`
is only set when the operator has not set it, so a custom value replaces the defaults rather than
fighting them.

---

## 6. Measured results

Same host, same workload, official `ghcr.io/suwayomi/suwayomi-server:v2.4.2366` versus this image:

| | official | this image |
|---|---|---|
| image size | 2.13 GB | **754 MB** |
| ready to answer (HTTP 200) | 10.6 s | **5.4 s** |
| idle RSS | 1067 MB | **383 MB** |
| RSS during the workload | 1186 MB | **436 MB** |
| peak RSS | 1191 MB | **446 MB** |
| processes at idle | ~10 (grows to 12) | **1** |
| suggested container limit | 2048 MB | **512 MB** |

Caveat on method: the sandbox daemon cannot apply `--memory` (its cgroup v2 delegation is broken), so
these are RSS figures summed from `/proc/*/VmRSS` on unlimited containers. Comparable between the two
images; not cgroup numbers.

---

## 7. Verification

`test/uchiyomi-api-check.py` replays **every operation Uchiyomi sends** — its whole `operations.ts`
registry plus the image paths from `routes/images.ts` — against a running engine. On this image, from a
fresh volume:

- 1443 extensions in the catalogue from the keiyoushi store, 6 installed during testing;
- full chain exercised: search → series → chapters → page paths → **`GET
  /api/v1/manga/109/chapter/1/page/0` → HTTP 200 `image/jpeg`, 921 KB**;
- cover and extension-icon paths return real bytes;
- 21/24 operations ok — the 3 failures are the MangaDex extension answering `No chapters found` for
  particular titles, and they are **identical on the official image**, which I ran side by side;
- Uchiyomi's own healthcheck command passes inside the image and Docker reports `healthy`.

**FlareSolverr** was raised and checked separately (details in `README.md`): container up and ready,
engine resolves it by the compose service name, settings applied, and the exact `POST /v1` call the
engine makes — issued from *inside* the engine container — returned a full solved response for a
Cloudflare-protected site. What that test could **not** show on this host: none of ~12 probed sources
actually triggered a solver call, because they did not challenge this IP. The wiring is proven; the
rescue is not reproducible here.

---

## 8. Trade-offs and open gaps

1. **No WebView.** Extensions that ask for an Android `WebView` fail with `CEF is disabled` (Manga UP!
   is one). This is the bulk of the saving and the one real functional loss. On the official image, in
   this environment, that same extension failed the other way — `Timed out waiting for WebView after
   10s` — so how well upstream's Chromium works on real hardware is not something these measurements
   can answer. A `WITH_WEBVIEW=1` build variant is the obvious follow-up if a source you care about
   needs it.
2. **Unexplained latency.** Searches ran consistently ~1.1–1.4 s slower with `flareSolverrEnabled=true`
   even though the solver received no requests. Recorded, not explained; no cause invented.
3. **Alpine was tried and rejected.** Suwayomi loads glibc-only natives out of the jar
   (`libwebp-imageio.so`, `libjnidispatch.so`, `libzstd-kmp.so`) and ships no musl builds — real webp
   pages would break. The base is Debian/Ubuntu.
4. **The jar cannot be slimmed much further.** Of its 175 MB, ~84 MB is the AndroidCompat runtime that
   actually runs extensions. What remains (GraalJS/Truffle/ICU, ~49 MB) is dead weight for this path in
   principle, but deleting classes from a fat jar fails at the first class-init that touches them —
   not worth 49 MB without a reason.
5. **Version pinning.** The image no longer pins an engine: it resolves the newest Suwayomi release and
   verifies the jar against that release's published `Checksums.sha256`, so a wrong hash fails the build
   rather than shipping silently. Pin deliberately with `--build-arg ENGINE_VERSION=... ENGINE_SHA256=...`
   or by filling in `engine.env`. Uchiyomi supports `v2.3.2243` and up; this pipeline has been exercised
   on `v2.4.2366`.

---

## 9. Continuous integration

`.woodpecker.yml` builds on the `plugins/docker` template the other repos in this homelab use and adds what
this image needs. Every run — a push to `main`, or the weekly cron — goes:

| # | step | what it proves |
|---|---|---|
| 1 | `resolve-engine` | the newest Suwayomi release, its commit, and the jar's hash from upstream's own `Checksums.sha256`; written to `engine.env` |
| 2 | `fetch-engine` | the jar downloads and its sha256 matches that file |
| 3 | `test-engine` | the engine **runs and answers**: started as a process from the same jar and `entrypoint.sh`, then the hard assertions over localhost — settings, a real page served from a local source, a real extension installed from the keiyoushi store |
| 4 | `build-and-push` | the Dockerfile builds and the image lands in the registry as `latest` |
| 5 | `tag-engine-identity` | the manifest just pushed is re-tagged with the engine's release date and its commit |
| 6 | `test-live-sources` | advisory, `failure: ignore`, deliberately last: a real extension against a real site |

Three tags per release, over one digest: `latest`, `<engine-release-date>` (the upstream release's own date,
UTC — not the day the cron fired, so a week with no new release adds no tag), and `<engine-sha>` (Suwayomi's
commit). The CI repo's own commit is deliberately not tagged: it says nothing about the engine inside.

Verified end to end: the assertions above pass and both extra tags answered `HTTP 201`. Also verified that a
push to any other branch runs nothing at all, so nothing but `main` can publish.

**What the test step cannot see:** the image's own packaging — base image, `COPY` paths, user, healthcheck —
because it runs the jar as a process rather than the image as a container. A Dockerfile that builds but
produces a broken image would still pass. `test/ci-smoke.sh` covers exactly that gap, and is how the
packaging was verified while it was written.

## 10. Files

| file | what it is |
|---|---|
| `Dockerfile` | two stages: fetch+verify+strip the release jar, then the runtime image |
| `entrypoint.sh` | translates env vars into `-D` config overrides and `exec`s the JVM; carries the lean JVM defaults |
| `compose.snippet.yml` | drop-in replacement for the `uchiyomi-suwayomi` service (and the FlareSolverr service), same volume path and uid as upstream |
| `.woodpecker.yml` | the pipeline: resolve → fetch → test → build+push → tag → advisory site check |
| `engine.env` | build input read from the build context; committed empty, overwritten by the pipeline's resolve step so the image always carries exactly the engine the tests ran against |
| `test/check-engine.sh` | the hard assertions the pipeline runs against a live engine |
| `test/ci-smoke.sh` | runs a *built image* in containers and checks it — for the packaging the pipeline cannot see |
| `test/make-fixture.py` | generates the CBZ fixture that the hermetic page test serves |
| `test/uchiyomi-api-check.py` | replays Uchiyomi's whole API surface against an engine; the acceptance test |
| `test/flaresolverr-ab.py` | searches the same sources with the solver off and on, flipping it through the same mutation Uchiyomi uses |
| `README.md` | the image's own documentation: what was removed, measurements, trade-offs |
