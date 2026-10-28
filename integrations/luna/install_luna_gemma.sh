#!/data/data/com.termux/files/usr/bin/bash
# Instalador integrado L.U.N.A. v5 + catálogo SPDX de GEMMA-Omega.
# Ejecutar desde cualquier directorio después de clonar/actualizar el repositorio.
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
INSTALLER="$ROOT/integrations/luna/install_luna_v5.sh"
BRIDGE="$ROOT/integrations/luna/connect_gemma_spdx.py"
SPDX="$ROOT/licenses/SPDX"

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[[ -f "$INSTALLER" ]] || fail "No encuentro el instalador de Luna: $INSTALLER"
[[ -f "$BRIDGE" ]] || fail "No encuentro el puente SPDX: $BRIDGE"

if [[ ! -d "$SPDX/metadata" || ! -d "$SPDX/licenses" ]]; then
  [[ -f "$ROOT/tools/sync_spdx_licenses.py" ]] || fail "Falta el sincronizador SPDX."
  printf '\n[1/3] Preparando el catálogo oficial SPDX de GEMMA...\n'
  python "$ROOT/tools/sync_spdx_licenses.py" --output "$SPDX"
else
  printf '\n[1/3] Catálogo SPDX de GEMMA encontrado.\n'
fi

printf '\n[2/3] Instalando L.U.N.A. v5...\n'
bash "$INSTALLER"

printf '\n[3/3] Conectando el catálogo y los textos SPDX a L.U.N.A....\n'
python "$BRIDGE" --gemma-root "$ROOT" --luna-home "$HOME/.termux/tasker"

CACHE="$HOME/.termux/tasker/data/licenses/licenses.json"
[[ -s "$CACHE" ]] || fail "No se generó el catálogo local de Luna."
python - "$CACHE" <<'PY'
import json, sys
from pathlib import Path
p = Path(sys.argv[1])
data = json.loads(p.read_text(encoding="utf-8"))
items = data.get("licenses", [])
if not items:
    raise SystemExit("ERROR: el catálogo local no contiene licencias.")
print(f"VERIFICADO: catálogo local válido con {len(items)} licencias.")
print(f"Origen: {data.get('source', 'no indicado')}")
print(f"Modo sin conexión tras copiar: {data.get('offline', False)}")
PY

printf '\nIntegración completada. Para arrancar Luna: luna start\n'
printf 'Para ejecutar las pruebas de Luna: luna test\n'
