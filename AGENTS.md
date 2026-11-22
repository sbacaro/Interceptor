# Workspace Rules

## Post-Build & Release Cleanup

- Always delete all `.zip` archives and `.app` bundles created inside the local repository (including under `dist/` or `build/`) immediately after any local build, packaging step, or GitHub release upload.
- Keep the working repository clean of binary or release artifacts at all times. Use `/tmp` (e.g., `/tmp/InterceptorDerivedData` and `/tmp/InterceptorRelease`) for temporary Xcode `DerivedData`, build products, and staging `.zip` packages before uploading to GitHub Releases.

## Licensing

- **Interceptor** is licensed under the **PolyForm Noncommercial License 1.0.0** (`PolyForm-Noncommercial-1.0.0`).
- Preserve [LICENSE](./LICENSE) verbatim and maintain the `Required Notice: Copyright © 2026 Samuel Bacaro` attribution in documentation and distributions.
