#!/usr/bin/env python3
"""Build a reusable local library from the official SPDX license list."""
import concurrent.futures
import csv
import json
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
import argparse

BASE = "https://raw.githubusercontent.com/spdx/license-list-data/main"
HEADERS = {"User-Agent": "SKILL-X-SPDX-Library/1.0"}
WORKERS = 12

def fetch(url):
    try:
        req = urllib.request.Request(url, headers=HEADERS)
        with urllib.request.urlopen(req, timeout=25) as r:
            return r.read()
    except Exception:
        return None

def load_json(url):
    data = fetch(url)
    if not data:
        raise RuntimeError("Could not download official SPDX index: " + url)
    return json.loads(data.decode("utf-8"))

def get_text(item, kind):
    ident = item.get("licenseId") if kind == "license" else item.get("licenseExceptionId")
    if not ident or any(c not in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.+-_" for c in ident):
        return item, kind, ident or "UNKNOWN", None, None
    paths = [f"{BASE}/text/{ident}.txt"]
    if kind == "exception":
        paths.append(f"{BASE}/exceptions/{ident}.txt")
    for url in paths:
        raw = fetch(url)
        if raw and raw.strip():
            return item, kind, ident, raw.decode("utf-8", "replace"), url
    raw = fetch(f"{BASE}/json/details/{ident}.json")
    if raw:
        try:
            detail = json.loads(raw.decode("utf-8"))
            text = detail.get("licenseText") or detail.get("licenseExceptionText")
            if text:
                return item, kind, ident, text, f"{BASE}/json/details/{ident}.json"
        except Exception:
            pass
    return item, kind, ident, None, None

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", default="licenses/SPDX")
    args = parser.parse_args()
    out = Path(args.output)
    ldir, edir, mdir = out / "licenses", out / "exceptions", out / "metadata"
    for d in (ldir, edir, mdir):
        d.mkdir(parents=True, exist_ok=True)

    print("Downloading official SPDX indexes...")
    license_data = load_json(f"{BASE}/json/licenses.json")
    exception_data = load_json(f"{BASE}/json/exceptions.json")
    licenses = license_data.get("licenses", [])
    exceptions = exception_data.get("exceptions", [])
    jobs = [(x, "license") for x in licenses] + [(x, "exception") for x in exceptions]
    rows, missing = [], []
    print(f"Catalog entries: {len(licenses)} licenses, {len(exceptions)} exceptions")

    with concurrent.futures.ThreadPoolExecutor(max_workers=WORKERS) as pool:
        futures = [pool.submit(get_text, item, kind) for item, kind in jobs]
        for n, future in enumerate(concurrent.futures.as_completed(futures), 1):
            item, kind, ident, text, source = future.result()
            dest = ldir if kind == "license" else edir
            status = "downloaded" if text else "MISSING_TEXT"
            if text:
                (dest / f"{ident}.txt").write_text(text.rstrip() + "\n", encoding="utf-8")
            else:
                missing.append({"id": ident, "type": kind, "name": item.get("name", "")})
            meta = dict(item)
            meta.update({"spdx_kind": kind, "text_status": status, "text_source": source})
            (mdir / f"{ident}.json").write_text(json.dumps(meta, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
            rows.append({"id": ident, "type": kind, "name": item.get("name", ""), "status": status, "source": source or ""})
            if n % 50 == 0 or n == len(jobs):
                print(f"Progress: {n}/{len(jobs)}")

    rows.sort(key=lambda x: (x["type"], x["id"].lower()))
    with (out / "INDEX.csv").open("w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=["id", "type", "name", "status", "source"])
        w.writeheader()
        w.writerows(rows)
    (out / "INDEX.json").write_text(json.dumps({
        "generated_utc": datetime.now(timezone.utc).isoformat(),
        "source": BASE,
        "license_count_in_index": len(licenses),
        "exception_count_in_index": len(exceptions),
        "texts_downloaded": sum(r["status"] == "downloaded" for r in rows),
        "missing_texts": missing
    }, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    (out / "MISSING-TEXTS.md").write_text(
        "# SPDX entries with unavailable text\n\n"
        "These entries remain in the official index, but a text file could not be retrieved. "
        "Do not invent or substitute license terms.\n\n" +
        ("\n".join(f"- {x['id']} ({x['type']}): {x['name']}" for x in missing) if missing else "None.") + "\n",
        encoding="utf-8")
    (out / "README.md").write_text(
        "# SPDX License Library\n\n"
        "Official license and exception texts from the SPDX License List Data project.\n\n"
        "Folders: licenses/ (license texts), exceptions/ (exception texts), metadata/ (source metadata).\n\n"
        "INDEX.csv and INDEX.json list entries and download status. MISSING-TEXTS.md records unavailable texts.\n\n"
        "Before reusing a license, verify which license actually applies to your project or dependency. "
        "Preserve required notices and attribution. This library is not legal advice and does not guarantee compliance.\n\n"
        "Refresh: python tools/sync_spdx_licenses.py --output licenses/SPDX\n",
        encoding="utf-8")
    (out / "templates").mkdir(exist_ok=True)
    (out / "templates" / "THIRD_PARTY_NOTICES.template.txt").write_text(
        "THIRD-PARTY NOTICES\n====================\n\n"
        "Project: <PROJECT NAME>\nVersion: <VERSION>\n\n"
        "For every distributed dependency, record package/version, verified license ID, copyright notice, "
        "required NOTICE text, source URL, modifications, and any separate model/native-binary terms.\n"
        "Do not ship this template with placeholders unfilled.\n",
        encoding="utf-8")
    (out / "templates" / "SPDX-HEADER.template.txt").write_text(
        "SPDX-License-Identifier: <LICENSE-ID>\n", encoding="utf-8")

    downloaded_licenses = sum(r["status"] == "downloaded" and r["type"] == "license" for r in rows)
    downloaded_exceptions = sum(r["status"] == "downloaded" and r["type"] == "exception" for r in rows)
    print("\nDONE")
    print(f"Output: {out.resolve()}")
    print(f"License texts downloaded: {downloaded_licenses}")
    print(f"Exception texts downloaded: {downloaded_exceptions}")
    print(f"Missing texts: {len(missing)}")
    print("No project dependency licenses were guessed or changed.")

if __name__ == "__main__":
    main()
