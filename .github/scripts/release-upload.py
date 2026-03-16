#!/usr/bin/env python3
"""
GitHub Release upload with controlled concurrency and progress monitoring.

Environment variables
─────────────────────
  GITHUB_TOKEN            GitHub token (required)
  GITHUB_REPOSITORY       owner/repo   (required)
  RELEASE_TAG_NAME        Tag name     (required)
  RELEASE_TARGET_COMMITISH  Target commit SHA (optional)
  RELEASE_NAME            Display name (defaults to tag)
  RELEASE_PRERELEASE      "true" / "false" (default "true")
  RELEASE_DRAFT           "true" / "false" (default "false")
  UPLOAD_CONCURRENCY      Max parallel uploads (default 3)
  RELEASE_FILES           Newline-separated glob patterns (required)
"""

import glob
import os
import sys
import threading
import time
import urllib.parse
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

import requests

# ───────────────────────────── Configuration ─────────────────────────────

GITHUB_TOKEN = os.environ["GITHUB_TOKEN"]
GITHUB_REPOSITORY = os.environ["GITHUB_REPOSITORY"]
GITHUB_API = os.environ.get("GITHUB_API_URL", "https://api.github.com")

TAG_NAME = os.environ["RELEASE_TAG_NAME"]
TARGET_COMMITISH = os.environ.get("RELEASE_TARGET_COMMITISH", "")
RELEASE_NAME = os.environ.get("RELEASE_NAME", TAG_NAME)
DRAFT = os.environ.get("RELEASE_DRAFT", "false").lower() == "true"
PRERELEASE = os.environ.get("RELEASE_PRERELEASE", "true").lower() == "true"

UPLOAD_CONCURRENCY = int(os.environ.get("UPLOAD_CONCURRENCY", "") or "3")
FILE_PATTERNS = [
    p for p in os.environ.get("RELEASE_FILES", "").splitlines() if p.strip()
]

MILESTONE_PCT = 20
SUMMARY_INTERVAL_S = 30
MAX_RETRIES = 3
SMALL_FILE_THRESHOLD = 1 * 1024 * 1024  # 1 MiB

API_HEADERS = {
    "Authorization": f"token {GITHUB_TOKEN}",
    "Accept": "application/vnd.github+json",
    "X-GitHub-Api-Version": "2022-11-28",
}

# ───────────────────────────── Helpers ───────────────────────────────────


def fmt_size(n: float) -> str:
    for u in ("B", "KiB", "MiB", "GiB"):
        if n < 1024:
            return f"{n:.1f} {u}"
        n /= 1024
    return f"{n:.1f} TiB"


def fmt_speed(bps: float) -> str:
    return f"{bps / 1048576:.1f} MiB/s"


def fmt_time(s: float) -> str:
    if s < 60:
        return f"{s:.0f}s"
    return f"{int(s // 60)}m {int(s % 60)}s"


def log(msg: str) -> None:
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)


# ───────────────────────────── Upload tracker ────────────────────────────


class UploadTracker:
    """Thread-safe aggregate progress tracker for all uploads."""

    def __init__(self, files: list[Path]):
        self._lock = threading.Lock()
        self.total_files = len(files)
        self.total_bytes = sum(f.stat().st_size for f in files)
        self.done_count = 0
        self.done_bytes = 0
        self.active: dict[str, int] = {}
        self.start_time = time.time()

    def on_start(self, name: str) -> None:
        with self._lock:
            self.active[name] = 0

    def on_progress(self, name: str, uploaded: int) -> None:
        # GIL-safe single dict-value assignment; skip locking for throughput.
        self.active[name] = uploaded

    def on_done(self, name: str, size: int, ok: bool) -> None:
        with self._lock:
            self.active.pop(name, None)
            if ok:
                self.done_count += 1
                self.done_bytes += size

    def summary_line(self) -> str:
        with self._lock:
            active_bytes = sum(self.active.values())
            uploaded = self.done_bytes + active_bytes
            elapsed = time.time() - self.start_time
            speed = uploaded / elapsed if elapsed > 0 else 0
            pct = uploaded / self.total_bytes * 100 if self.total_bytes else 0
            return (
                f"── 📊 SUMMARY: {self.done_count}/{self.total_files} done │ "
                f"{len(self.active)} active │ "
                f"{fmt_size(uploaded)}/{fmt_size(self.total_bytes)} ({pct:.0f}%) │ "
                f"{fmt_speed(speed)} │ {fmt_time(elapsed)} ──"
            )


# ───────────────────────────── Streaming reader ──────────────────────────


class ProgressReader:
    """File-like wrapper that logs upload milestones."""

    def __init__(self, path: str, index_str: str, tracker: UploadTracker):
        self.name = os.path.basename(path)
        self.size = os.path.getsize(path)
        self._fh = open(path, "rb")
        self._uploaded = 0
        self._index = index_str
        self._tracker = tracker
        self._t0 = time.time()
        self._last_milestone = 0
        self._small = self.size < SMALL_FILE_THRESHOLD

    def read(self, n: int = -1) -> bytes:
        chunk = self._fh.read(n)
        if chunk:
            self._uploaded += len(chunk)
            self._tracker.on_progress(self.name, self._uploaded)
            if not self._small and self.size > 0:
                pct = self._uploaded * 100 // self.size
                m = pct // MILESTONE_PCT * MILESTONE_PCT
                if m > self._last_milestone and m < 100:
                    self._last_milestone = m
                    elapsed = time.time() - self._t0
                    spd = self._uploaded / elapsed if elapsed > 0 else 0
                    log(
                        f"📶 [{self._index}] {m:>3}%  "
                        f"{self.name}  {fmt_speed(spd)}"
                    )
        return chunk

    def __len__(self) -> int:
        return self.size

    def close(self) -> None:
        self._fh.close()

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.close()


# ───────────────────────────── Release API ───────────────────────────────


def _repo_api(path: str = "") -> str:
    return f"{GITHUB_API}/repos/{GITHUB_REPOSITORY}{path}"


def get_or_create_release() -> dict:
    url = _repo_api(f"/releases/tags/{TAG_NAME}")
    r = requests.get(url, headers=API_HEADERS, timeout=30)
    if r.status_code == 200:
        rel = r.json()
        log(f"📦 Found existing release: {rel['name']} (id: {rel['id']})")
        return rel

    log(f"📦 Creating release: {RELEASE_NAME}")
    body: dict = {
        "tag_name": TAG_NAME,
        "name": RELEASE_NAME,
        "draft": DRAFT,
        "prerelease": PRERELEASE,
    }
    if TARGET_COMMITISH:
        body["target_commitish"] = TARGET_COMMITISH
    r = requests.post(
        _repo_api("/releases"), headers=API_HEADERS, json=body, timeout=30
    )
    r.raise_for_status()
    rel = r.json()
    log(f"✅ Release created: {rel['name']} (id: {rel['id']})")
    return rel


def refresh_release(release: dict) -> dict:
    r = requests.get(release["url"], headers=API_HEADERS, timeout=30)
    r.raise_for_status()
    return r.json()


def delete_dup_asset(release: dict, filename: str) -> None:
    for asset in release.get("assets", []):
        if asset["name"] == filename:
            r = requests.delete(asset["url"], headers=API_HEADERS, timeout=30)
            if r.status_code == 204:
                log(f"🗑️  Deleted existing asset: {filename}")
            return


# ───────────────────────────── Upload one file ───────────────────────────


def upload_one(
    filepath: str,
    release: dict,
    upload_base: str,
    idx: int,
    total: int,
    tracker: UploadTracker,
) -> dict:
    name = os.path.basename(filepath)
    size = os.path.getsize(filepath)
    tag = f"{idx}/{total}"

    log(f"🚀 [{tag}] START  {name} ({fmt_size(size)})")
    tracker.on_start(name)
    delete_dup_asset(release, name)

    url = f"{upload_base}?name={urllib.parse.quote(name)}"
    hdrs = {
        **API_HEADERS,
        "Content-Type": "application/octet-stream",
        "Content-Length": str(size),
    }

    last_err: Exception | None = None
    for attempt in range(1, MAX_RETRIES + 1):
        try:
            t0 = time.time()
            with ProgressReader(filepath, tag, tracker) as reader:
                resp = requests.post(url, headers=hdrs, data=reader, timeout=7200)
                resp.raise_for_status()
            elapsed = time.time() - t0
            spd = size / elapsed if elapsed > 0 else 0
            log(
                f"✅ [{tag}] DONE   {name}  "
                f"{fmt_size(size)} in {fmt_time(elapsed)} ({fmt_speed(spd)})"
            )
            tracker.on_done(name, size, True)
            return {"name": name, "size": size, "time": elapsed, "speed": spd, "ok": True}
        except Exception as e:
            last_err = e
            if attempt < MAX_RETRIES:
                wait = 5 * 2 ** (attempt - 1)
                log(
                    f"⚠️  [{tag}] RETRY  {name} "
                    f"(attempt {attempt}/{MAX_RETRIES}, wait {wait}s): {e}"
                )
                time.sleep(wait)

    log(f"❌ [{tag}] FAIL   {name}: {last_err}")
    tracker.on_done(name, size, False)
    return {"name": name, "size": size, "time": 0, "speed": 0, "ok": False, "err": str(last_err)}


# ───────────────────────────── Summary thread ────────────────────────────


def summary_loop(tracker: UploadTracker, stop: threading.Event) -> None:
    while not stop.wait(SUMMARY_INTERVAL_S):
        log(tracker.summary_line())


# ───────────────────────────── File collection ───────────────────────────


def collect_files() -> list[Path]:
    files: list[Path] = []
    seen: set[str] = set()
    for pattern in FILE_PATTERNS:
        for p in sorted(glob.glob(pattern.strip())):
            rp = os.path.realpath(p)
            if rp not in seen and os.path.isfile(rp):
                seen.add(rp)
                files.append(Path(rp))
    return files


# ───────────────────────────── Main ──────────────────────────────────────


def main() -> None:
    files = collect_files()
    if not files:
        log("❌ No files matched the patterns!")
        sys.exit(1)

    total_size = sum(f.stat().st_size for f in files)
    log(f"📋 Files to upload: {len(files)} ({fmt_size(total_size)})")
    for f in files:
        log(f"   • {f.name} ({fmt_size(f.stat().st_size)})")
    log(f"⚡ Concurrency: {UPLOAD_CONCURRENCY}")

    release = get_or_create_release()
    upload_base = release["upload_url"].replace("{?name,label}", "")
    release = refresh_release(release)

    tracker = UploadTracker(files)
    stop = threading.Event()
    threading.Thread(
        target=summary_loop, args=(tracker, stop), daemon=True
    ).start()

    results: list[dict] = []
    with ThreadPoolExecutor(max_workers=UPLOAD_CONCURRENCY) as pool:
        futs = {
            pool.submit(
                upload_one, str(f), release, upload_base, i, len(files), tracker
            ): f
            for i, f in enumerate(files, 1)
        }
        for fut in as_completed(futs):
            results.append(fut.result())

    stop.set()

    ok = [r for r in results if r["ok"]]
    fail = [r for r in results if not r["ok"]]
    wall = time.time() - tracker.start_time
    uploaded = sum(r["size"] for r in ok)
    avg = uploaded / wall if wall > 0 else 0

    log("")
    log("═" * 70)
    log(
        f"🏁 COMPLETE  {len(ok)}/{len(results)} files │ "
        f"{fmt_size(uploaded)} │ {fmt_time(wall)} │ avg {fmt_speed(avg)}"
    )
    if fail:
        log("")
        for r in fail:
            log(f"   ❌ {r['name']}: {r.get('err', 'unknown')}")
    log("═" * 70)

    if fail:
        sys.exit(1)


if __name__ == "__main__":
    main()
