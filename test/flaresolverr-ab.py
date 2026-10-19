#!/usr/bin/env python3
"""A/B a source with the engine's FlareSolverr support OFF and then ON.

Uchiyomi ships the solver as its own container and points the engine at it
(FLARESOLVERR_ENABLED / FLARESOLVERR_URL). This flips the engine's setting through the same GraphQL
mutation Uchiyomi uses (setSolverSettings) and searches the same source both ways, so "does the solver
actually do anything for us" has an answer other than a promise.

usage: flaresolverr-ab.py http://host:port --pkg PKG [--pkg PKG ...] [--solver-url URL] [--search TERM]
"""
import argparse
import sys

sys.path.insert(0, __file__.rsplit("/", 1)[0])
from importlib.machinery import SourceFileLoader

api = SourceFileLoader("api", __file__.rsplit("/", 1)[0] + "/uchiyomi-api-check.py").load_module()


def main():
    p = argparse.ArgumentParser()
    p.add_argument("base")
    p.add_argument("--pkg", action="append", default=[], required=True)
    p.add_argument("--solver-url", default="http://uchiyomi-flaresolverr:8191")
    p.add_argument("--search", default="one piece")
    a = p.parse_args()

    c = api.Client(a.base)

    # install the candidates (Uchiyomi's admin "install" path)
    for pkg in a.pkg:
        r = c.gql("updateExtension", {"id": pkg, "patch": {"install": True}}, label=f"install {pkg}", timeout=600)
        if not r["ok"] and "already installed" not in str(r.get("error", "")).lower():
            print(f"install {pkg}: {r.get('error')}")

    r = c.gql("sources")
    sources = (r.get("data") or {}).get("sources", {}).get("nodes", []) if r["ok"] else []
    by_pkg = [s for s in sources if s.get("extension") and s["extension"]["pkgName"] in a.pkg]
    print(f"{len(by_pkg)} sources from the {len(a.pkg)} packages\n")

    def set_solver(enabled):
        q = ("mutation($on:Boolean!,$u:String!){ setSettings(input:{settings:{flareSolverrEnabled:$on,"
             "flareSolverrUrl:$u}}){ settings { flareSolverrEnabled flareSolverrUrl } } }")
        import json
        import urllib.request
        body = json.dumps({"query": q, "variables": {"on": enabled, "u": a.solver_url}}).encode()
        req = urllib.request.Request(a.base.rstrip("/") + "/api/graphql", data=body, method="POST")
        req.add_header("content-type", "application/json")
        with urllib.request.urlopen(req, timeout=30) as resp:
            return json.loads(resp.read())["data"]["setSettings"]["settings"]

    def probe(s):
        r = c.gql("fetchSourceManga", {"source": s["id"], "type": "SEARCH", "query": a.search, "page": 1},
                  label=f"search {s['name']}", timeout=120)
        n = len((r.get("data") or {}).get("fetchSourceManga", {}).get("mangas", [])) if r["ok"] else 0
        err = (r.get("error") or "").split("\n")[0][:110]
        return r["ok"] and n > 0, n, r["ms"], err

    print(f"{'source':26s} {'solver OFF':>26s} {'solver ON':>26s}")
    for s in sorted(by_pkg, key=lambda s: s["name"]):
        st = set_solver(False)
        off_ok, off_n, off_ms, off_err = probe(s)
        st = set_solver(True)
        on_ok, on_n, on_ms, on_err = probe(s)
        cell = lambda ok, n, ms, err: (f"ok {n} results {ms}ms" if ok else f"FAIL {err[:18]}")
        print(f"{s['name'][:25]:26s} {cell(off_ok,off_n,off_ms,off_err):>26s} {cell(on_ok,on_n,on_ms,on_err):>26s}")
        if not off_ok and not on_ok:
            print(f"{'':26s}   off: {off_err}\n{'':26s}   on : {on_err}")
    print("\nsolver setting now:", set_solver(True))


if __name__ == "__main__":
    main()
