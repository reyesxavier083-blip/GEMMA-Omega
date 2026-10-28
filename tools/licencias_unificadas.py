#!/usr/bin/env python3
"""GEMMA Omega: gestor de licencias SPDX en un solo archivo.

Uso:
  python tools/licencias_unificadas.py sync
  python tools/licencias_unificadas.py status
  python tools/licencias_unificadas.py show Apache-2.0
  python tools/licencias_unificadas.py audit

'sync' descarga el catálogo oficial SPDX y los textos, y los incrusta
en ESTE MISMO ARCHIVO para consultas posteriores sin conexión.
No concede licencias de terceros ni sustituye la revisión legal.
"""
import json
import pathlib
import sys
import urllib.request

# == SPDX DATA START ==
DATA = {"source": "pending", "licenses": {}, "texts": {}}
# == SPDX DATA END ==
START = "# == SPDX DATA START =="
END = "# == SPDX DATA END =="

def fetch(url):
    req = urllib.request.Request(url, headers={"User-Agent": "GEMMA-Omega-license-manager/1.0"})
    with urllib.request.urlopen(req, timeout=30) as response:
        return response.read().decode("utf-8")

def sync():
    base = "https://raw.githubusercontent.com/spdx/license-list-data/main/"
    catalog = json.loads(fetch(base + "json/licenses.json"))
    licenses = {}
    texts = {}
    entries = catalog.get("licenses", [])
    for index, item in enumerate(entries, 1):
        identifier = item["licenseId"]
        licenses[identifier] = {
            "name": item.get("name", ""),
            "osiApproved": item.get("isOsiApproved", False),
            "deprecated": item.get("isDeprecatedLicenseId", False),
            "reference": item.get("reference", ""),
        }
        try:
            texts[identifier] = fetch(base + "text/" + identifier + ".txt")
        except Exception as error:
            print("Aviso: texto no disponible:", identifier, error, file=sys.stderr)
        if index % 100 == 0:
            print("Procesadas:", index, "/", len(entries))
    payload = {"source": base, "version": catalog.get("licenseListVersion"), "licenses": licenses, "texts": texts}
    path = pathlib.Path(__file__)
    original = path.read_text(encoding="utf-8")
    beginning = original.index(START) + len(START)
    ending = original.index(END, beginning)
    updated = original[:beginning] + "\nDATA = " + repr(payload) + "\n" + original[ending:]
    temporary = path.with_suffix(".tmp")
    temporary.write_text(updated, encoding="utf-8")
    temporary.replace(path)
    print("Catálogo integrado:", len(licenses), "licencias;", len(texts), "textos.")

def main():
    args = sys.argv[1:]
    command = args[0] if args else "status"
    if command == "sync":
        sync()
    elif command == "status":
        print("Fuente:", DATA["source"])
        print("Licencias:", len(DATA["licenses"]))
        print("Textos completos:", len(DATA["texts"]))
    elif command == "show" and len(args) == 2:
        print(DATA["texts"].get(args[1], "No disponible: ejecuta sync o revisa el identificador."))
    elif command == "audit":
        print("Este catálogo no acredita licencias de dependencias instaladas.")
        print("Verifica versiones, avisos de copyright, modelos y condiciones de distribución.")
        print("Para licencias oficiales consulta https://spdx.org/licenses/")
    else:
        print("Uso: sync | status | show SPDX-ID | audit")
        raise SystemExit(2)

if __name__ == "__main__":
    main()
