#!/usr/bin/env python3
"""Import the checked-out GEMMA-Omega SPDX library into L.U.N.A. offline.

Usage from the GEMMA-Omega repository:
  python integrations/luna/connect_gemma_spdx.py
  python integrations/luna/connect_gemma_spdx.py --luna-home "$HOME/.termux/tasker"

No network access and no runtime dependency on the GEMMA repository are required
after the files have been copied into L.U.N.A.'s own data directory.
"""
import argparse
import json
import os
import re
import shutil
import tempfile
from pathlib import Path

ID_RE = re.compile(r"^[A-Za-z0-9.+_-]+$")


def atomic_json(path: Path, payload) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_name = tempfile.mkstemp(prefix=path.name + ".", dir=str(path.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(payload, f, ensure_ascii=False, indent=2)
            f.write("\n")
        os.replace(tmp_name, path)
    finally:
        try:
            os.unlink(tmp_name)
        except FileNotFoundError:
            pass


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--gemma-root", type=Path, default=Path(__file__).resolve().parents[2],
                        help="GEMMA-Omega repository root")
    parser.add_argument("--luna-home", type=Path,
                        default=Path.home() / ".termux" / "tasker",
                        help="L.U.N.A. home directory")
    args = parser.parse_args()

    gemma = args.gemma_root.expanduser().resolve()
    luna = args.luna_home.expanduser().resolve()
    spdx = gemma / "licenses" / "SPDX"
    metadata_dir = spdx / "metadata"
    license_dir = spdx / "licenses"
    if not metadata_dir.is_dir() or not license_dir.is_dir():
        parser.error(f"No encuentro la biblioteca SPDX de GEMMA en {spdx}. "
                     "Primero ejecuta: python tools/sync_spdx_licenses.py --output licenses/SPDX")

    entries = []
    text_dir = luna / "data" / "licenses" / "texts"
    text_dir.mkdir(parents=True, exist_ok=True)
    copied_texts = 0
    missing_texts = []

    for meta_path in sorted(metadata_dir.glob("*.json")):
        try:
            meta = json.loads(meta_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            continue
        if meta.get("spdx_kind", "license") != "license":
            continue
        ident = str(meta.get("licenseId") or meta_path.stem)
        if not ID_RE.fullmatch(ident):
            continue
        text_path = license_dir / f"{ident}.txt"
        local_text = text_dir / f"{ident}.txt"
        text_status = "downloaded" if text_path.is_file() else "MISSING_TEXT"
        if text_path.is_file():
            shutil.copyfile(text_path, local_text)
            copied_texts += 1
        else:
            missing_texts.append(ident)
        entries.append({
            "licenseId": ident,
            "name": str(meta.get("name") or ident),
            "isOsiApproved": bool(meta.get("isOsiApproved", False)),
            "isFsfLibre": bool(meta.get("isFsfLibre", False)),
            "seeAlso": meta.get("seeAlso") or [],
            "reference": meta.get("reference"),
            "text_status": text_status,
            "text_path": f"texts/{ident}.txt" if text_status == "downloaded" else None,
        })

    if not entries:
        parser.error("La biblioteca no contiene metadatos de licencias válidos; no se modificó el catálogo de Luna.")

    cache_path = luna / "data" / "licenses" / "licenses.json"
    atomic_json(cache_path, {"licenses": entries, "source": "GEMMA-Omega/licenses/SPDX",
                             "license_count": len(entries), "offline": True})
    print(f"Catálogo GEMMA → L.U.N.A.: {len(entries)} licencias")
    print(f"Textos completos copiados: {copied_texts}")
    print(f"Textos no disponibles: {len(missing_texts)}")
    print(f"Catálogo local: {cache_path}")
    print("L.U.N.A. conserva una copia local; no necesita importar código de GEMMA al ejecutarse.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
