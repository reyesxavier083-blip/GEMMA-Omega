# GEMMA-Omega — SPDX License Library

This repository contains an automated library builder for official SPDX license and exception texts.

- tools/sync_spdx_licenses.py downloads and organizes the current official SPDX text library.
- .github/workflows/sync-spdx-licenses.yml runs the sync in GitHub Actions and commits generated files.
- licenses/SPDX/ will contain full license texts, exception texts, metadata, indexes, and reusable notice templates.

Refresh on GitHub: open Actions, select “Sync SPDX license library”, and choose “Run workflow”.

Local refresh:
python tools/sync_spdx_licenses.py --output licenses/SPDX

Entries whose full text cannot be retrieved are marked; terms are never invented. The catalog does not determine which license applies to a dependency and does not guarantee legal compliance.
