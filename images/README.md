# images folder

This folder stores visual references used by documentation.

## Why these files exist

- `resources.png`: Example Azure portal resource view after deployment.
- `variables.png`: Example variable values used in post-deployment checks.
- `volume.png`: Workspace billable-table size snapshot (30-minute window) used in the root README to illustrate which `DefApi*` datasets dominate ingestion volume.
- `volume2.png`: Per-table record counts from a single collection cycle, paired with `volume.png` to motivate the recommended defaults in the dataset coverage table.
- `.gitkeep`: Keeps the folder in source control even if images are removed in future cleanups.

## Notes

- Images are documentation assets only; runtime code and deployment scripts do not depend on them.
- Keep image names stable so README references do not break.
