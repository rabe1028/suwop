# Suwop development

- Use Rust + Crux for core behavior: catalog identity, presence, transfer state,
  deletion eligibility, metadata policy, persistence migration and Immich API.
- Swift owns SwiftUI, presentation and thin Apple/native I/O adapters. It executes
  Rust effects; it must not reproduce domain decisions or assemble Immich routes.
- Generate Swift DTOs with `make generate-types`. Do not edit generated DTOs.
- Run `make check` before committing. Rust changes affecting the Apple boundary
  also require `make apple-build`; Immich contract changes require `make integration`.
- Use `make setup` for pinned lint tools and repository hooks. Preserve the
  user's global hooks. Do not suppress checks to commit or merge.
- Rust unsafe code belongs only in the documented C ABI. Swift unchecked
  Sendable requires a narrow, documented native-API invariant.
- Moves require an explicit Move receipt and fresh source/destination
  verification. Legacy or Copy receipts never authorize deletion. Persist the
  deletion phase before native deletion; uncertain deletion is never retried.
- Report local checks, hosted CI and actual PhotoKit/device acceptance separately.
