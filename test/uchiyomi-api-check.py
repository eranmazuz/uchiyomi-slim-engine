#!/usr/bin/env python3
"""Replay the exact Suwayomi API surface Uchiyomi uses, and report what worked.

Every operation below is one Uchiyomi actually sends (see bff/src/lib/sources/suwayomi/operations.ts
and routes/images.ts). It is the acceptance test for a slimmer engine image: if this passes, Uchiyomi's
extension engine works.

usage: uchiyomi-api-check.py http://host:port [--repo URL] [--install PKG] [--search TERM]
                             [--user U --password P] [--json OUT]
"""
import argparse
import base64
import json
import sys
import time
import urllib.error
import urllib.request

MANGA_FIELDS = "id title thumbnailUrl realUrl url description author artist genre status sourceId"
CHAPTER_FIELDS = "id chapterNumber name scanlator uploadDate pageCount sourceOrder url"
EXT_FIELDS = "pkgName name lang versionName iconUrl isInstalled hasUpdate isObsolete contentWarning storeIndexUrl"

OPS = {
    "aboutServer": "{ aboutServer { name version buildType } }",
    "sources": "{ sources { totalCount nodes { id name displayName lang iconUrl contentWarning supportsLatest extension { pkgName name } } } }",
    "extensions": "{ extensions { nodes { %s } } }" % EXT_FIELDS,
    "extensionFacts": "{ extensions { nodes { pkgName versionCodeLong apkUrl jarUrl apkName storeIndexUrl } } }",
    "extensionStores": "{ extensionStores { nodes { indexUrl name } } }",
    "solverSettings": "{ settings { flareSolverrEnabled flareSolverrUrl } }",
    "sourcesOfExtension": "{ extensions { nodes { pkgName source { nodes { id name lang contentWarning } } } } }",
    "addStore": "mutation($indexUrl:String!){ addExtensionStore(input:{indexUrl:$indexUrl}){ extensionStore { indexUrl name } } }",
    "fetchExtensions": "mutation{ fetchExtensions(input:{}){ extensions { pkgName } } }",
    "updateExtension": "mutation($id:String!,$patch:UpdateExtensionPatchInput!){ updateExtension(input:{id:$id,patch:$patch}){ extension { pkgName isInstalled } } }",
    "fetchSourceManga": "mutation($source:LongString!,$type:FetchSourceMangaType!,$query:String,$page:Int!){"
                        " fetchSourceManga(input:{source:$source,type:$type,query:$query,page:$page}){ mangas { %s } } }" % MANGA_FIELDS,
    "fetchManga": "mutation($id:Int!){ fetchMangaAndChapters(input:{id:$id,fetchManga:true,fetchChapters:false}){ manga { %s } } }" % MANGA_FIELDS,
    "fetchChapters": "mutation($id:Int!){ fetchMangaAndChapters(input:{id:$id,fetchManga:false,fetchChapters:true}){ manga { sourceId } chapters { %s } } }" % CHAPTER_FIELDS,
    "fetchChapterPages": "mutation($chapterId:Int!){ fetchChapterPages(input:{chapterId:$chapterId}){ pages } }",
    "clearCachedImages": "mutation { clearCachedImages(input: { cachedPages: true }) { cachedPages } }",
}


class Client:
    def __init__(self, base, user=None, password=None, timeout=120):
        self.base = base.rstrip("/")
        self.timeout = timeout
        self.auth = None
        if user:
            self.auth = "Basic " + base64.b64encode(f"{user}:{password}".encode()).decode()

    def gql(self, op, variables=None, label=None, optional=False, timeout=None):
        body = json.dumps({"query": OPS[op], "variables": variables or {}}).encode()
        req = urllib.request.Request(self.base + "/api/graphql", data=body, method="POST")
        req.add_header("content-type", "application/json")
        req.add_header("accept", "application/json")
        if self.auth:
            req.add_header("authorization", self.auth)
        t0 = time.time()
        try:
            with urllib.request.urlopen(req, timeout=timeout or self.timeout) as r:
                payload = json.loads(r.read())
        except urllib.error.HTTPError as e:
            return {"ok": False, "op": label or op, "ms": round((time.time() - t0) * 1000),
                    "error": f"HTTP {e.code}"}
        except Exception as e:  # transport
            return {"ok": False, "op": label or op, "ms": round((time.time() - t0) * 1000), "error": str(e)}
        ms = round((time.time() - t0) * 1000)
        errs = payload.get("errors")
        if errs:
            return {"ok": False, "op": label or op, "ms": ms,
                    "error": (errs[0].get("message") or "graphql error")[:300],
                    "data": payload.get("data")}
        if payload.get("data") is None:
            return {"ok": False, "op": label or op, "ms": ms, "error": "no data"}
        return {"ok": True, "op": label or op, "ms": ms, "data": payload["data"]}

    def get(self, path, timeout=60):
        req = urllib.request.Request(self.base + path)
        if self.auth:
            req.add_header("authorization", self.auth)
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, r.headers.get("content-type", ""), r.read()


def main():
    p = argparse.ArgumentParser()
    p.add_argument("base")
    p.add_argument("--repo", action="append", default=[])
    p.add_argument("--install", action="append", default=[])
    p.add_argument("--search", default="solo")
    p.add_argument("--user")
    p.add_argument("--password")
    p.add_argument("--json")
    a = p.parse_args()

    c = Client(a.base, a.user, a.password)
    steps = []

    def step(**kw):
        steps.append(kw)
        print(("  ok  " if kw["ok"] else " FAIL ") + f"{kw['op']:22s} {kw['ms']:>7} ms  " + kw.get("error", ""))

    # 1. the engine itself
    r = c.gql("aboutServer"); step(**r)
    if r["ok"]:
        print("      engine:", r["data"]["aboutServer"])

    # 2. extension stores + repos
    for url in a.repo:
        r = c.gql("addStore", {"indexUrl": url}, label="addExtensionStore")
        if not r["ok"] and "already" in str(r.get("error", "")).lower():
            r["ok"] = True
        step(**r)
    r = c.gql("extensionStores"); step(**r)
    r = c.gql("fetchExtensions", timeout=300); step(**r)

    # 3. the catalogue
    r = c.gql("extensions")
    step(**r)
    exts = (r.get("data") or {}).get("extensions", {}).get("nodes", []) if r["ok"] else []
    print(f"      catalogue: {len(exts)} extensions, {sum(1 for e in exts if e['isInstalled'])} installed")

    c.gql("extensionFacts", label="extensionFacts")

    # 4. install: what Uchiyomi does from Admin -> Extensions
    targets = list(a.install)
    if not targets:
        # first English, non-nsfw, not yet installed one
        for e in sorted(exts, key=lambda e: e["pkgName"]):
            if e.get("lang") == "en" and e.get("contentWarning") == "SAFE" and not e["isInstalled"]:
                targets = [e["pkgName"]]
                break
    installed = []
    for pkg in targets:
        r = c.gql("updateExtension", {"id": pkg, "patch": {"install": True}}, label=f"install {pkg}", timeout=600)
        step(**r)
        if r["ok"]:
            installed.append(pkg)
    if installed:
        c.gql("sourcesOfExtension", label="sourcesOfExtension")

    # 5. sources
    r = c.gql("sources"); step(**r)
    src = (r.get("data") or {}).get("sources", {}).get("nodes", []) if r["ok"] else []
    print(f"      sources: {len(src)}")

    # 6. walk source after source until one gives a real chapter with real pages.
    # Which sites answer is not our business -- an extension that lists no chapters, or whose site is
    # down, says nothing about the image. What has to work is the chain: search -> series -> chapters ->
    # page paths -> page bytes.
    tried = 0
    for s in sorted(src, key=lambda s: s["id"]):
        # MIXED is what a keiyoushi index reports for most entries; only an explicit NSFW is skipped here
        if s.get("contentWarning") == "NSFW":
            continue
        if tried >= 12:
            print("      gave up after 12 sources")
            break
        tried += 1
        r = c.gql("fetchSourceManga", {"source": s["id"], "type": "SEARCH", "query": a.search, "page": 1},
                  label=f"search {s['name']} ({s['id']})", timeout=90)
        step(**r)
        mangas = (r.get("data") or {}).get("fetchSourceManga", {}).get("mangas", []) if r["ok"] else []
        if not mangas:
            continue
        m = mangas[0]
        print(f"      {s['name']}: {m['title']} (id={m['id']})")

        r = c.gql("fetchManga", {"id": m["id"]}, label="fetchMangaAndChapters(manga)", timeout=120)
        step(**r)
        r = c.gql("fetchChapters", {"id": m["id"]}, label="fetchMangaAndChapters(chapters)", timeout=180)
        step(**r)
        chs = (r.get("data") or {}).get("fetchMangaAndChapters", {}).get("chapters", []) if r["ok"] else []
        # the engine answers a failed update with the stored rows AND an error; only rows count here
        if not chs:
            print("      ...no chapters from this source")
            continue
        print(f"      chapters: {len(chs)}")
        ch = sorted(chs, key=lambda c: c["sourceOrder"])[0]
        r = c.gql("fetchChapterPages", {"chapterId": ch["id"]}, label="fetchChapterPages", timeout=300)
        step(**r)
        pages = (r.get("data") or {}).get("fetchChapterPages", {}).get("pages", []) if r["ok"] else []
        if not pages:
            print("      ...no pages from this source")
            continue
        print(f"      pages: {len(pages)}  first={pages[0]}")

        # 7. the image path Uchiyomi proxies (its reader and its downloader)
        try:
            st, ct, body = c.get(pages[0], timeout=120)
            print(f"      page fetch: HTTP {st} {ct} {len(body)} bytes")
            step(op="GET page image", ok=st == 200 and len(body) > 0, ms=0)
        except Exception as e:
            step(op="GET page image", ok=False, ms=0, error=str(e))
        # 8. cover path
        try:
            st, ct, body = c.get(f"/api/v1/manga/{m['id']}/thumbnail", timeout=60)
            step(op="GET thumbnail", ok=st == 200 and len(body) > 0, ms=0)
        except Exception as e:
            step(op="GET thumbnail", ok=False, ms=0, error=str(e))
        print(f"      E2E OK via {s['name']}")
        break

    c.gql("clearCachedImages", label="clearCachedImages")

    # 9. source icons (admin panel)
    if exts:
        try:
            st, ct, body = c.get(f"/api/v1/extension/icon/{exts[0]['pkgName']}", timeout=60)
            step(op="GET extension icon", ok=st == 200 and len(body) > 0, ms=0)
        except Exception as e:
            step(op="GET extension icon", ok=False, ms=0, error=str(e))

    ok = sum(1 for s in steps if s["ok"])
    bad = [s for s in steps if not s["ok"]]
    print(f"\n{ok}/{len(steps)} operations ok")
    for s in bad:
        print(f"  FAILED {s['op']}: {s.get('error')}")
    if a.json:
        with open(a.json, "w") as f:
            json.dump({"base": a.base, "steps": steps, "ok": ok, "total": len(steps)}, f, indent=2)
    return 0 if ok == len(steps) else 1


if __name__ == "__main__":
    sys.exit(main())
