# Integración L.U.N.A. ↔ GEMMA-Omega

Esta carpeta incorpora el instalador de L.U.N.A. al repositorio GEMMA-Omega y añade un puente para reutilizar la biblioteca SPDX de GEMMA dentro de L.U.N.A.

## Instalar L.U.N.A. en Termux

Desde la raíz de este repositorio, en Termux:

```bash
bash integrations/luna/install_luna_v5.sh
```

El instalador original se conserva; no elimina ni sustituye el código de GEMMA.

## Conectar el catálogo SPDX de GEMMA con L.U.N.A.

Primero genera/actualiza la biblioteca oficial (requiere internet para sincronizarla):

```bash
python tools/sync_spdx_licenses.py --output licenses/SPDX
```

Después importa la biblioteca a la carpeta privada de datos de L.U.N.A.:

```bash
python integrations/luna/connect_gemma_spdx.py
```

Si L.U.N.A. está instalada en otra ruta:

```bash
python integrations/luna/connect_gemma_spdx.py --luna-home "$HOME/.termux/tasker"
```

El puente convierte los metadatos SPDX de GEMMA al formato que consume el endpoint `/api/licenses` de L.U.N.A. y copia los textos disponibles a `~/.termux/tasker/data/licenses/texts/`. Después de importar, L.U.N.A. conserva una copia local y no depende del repositorio GEMMA durante la ejecución. Vuelve a ejecutar el puente cuando actualices la biblioteca.

## Importante

- La importación es local y no cambia la licencia declarada por dependencias de L.U.N.A.
- Una licencia SPDX disponible no demuestra que sea la licencia aplicable a un paquete concreto.
- Revisa `text_status`, las dependencias reales, avisos y licencias de modelos/binarios por separado.
- El instalador puede instalar paquetes en Termux; ejecútalo solo si revisaste su contenido.
