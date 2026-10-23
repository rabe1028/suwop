"""Keep domain and Immich policy in Rust, with native I/O and presentation in Swift."""

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FORBIDDEN = {
    "domain orchestration": r"\b(?:Catalog|TransferCoordinator|ImmichClient|SHA1Value)\b",
    "hash algorithms": r"\b(?:CryptoKit|Insecure\.SHA1|SHA256\.hash)\b",
    "Immich routes": (
        r'["\'](?:/assets|assets/|/albums|albums/'
        r"|search/metadata|server/version|users/me|stacks/|asset-files(?:/|\?))"
    ),
}
errors = []
for directory in ("App", "Sources/SuwopShell"):
    for path in (ROOT / directory).rglob("*.swift"):
        if "Generated" in path.parts:
            continue
        source = path.read_text()
        for label, pattern in FORBIDDEN.items():
            if re.search(pattern, source):
                errors.append(f"{path.relative_to(ROOT)}: {label} must live in suwop-core")
# Offline Rust integration tests share one binary; an undeclared module never runs.
for suite in (ROOT / "crates").glob("*/tests/suite"):
    declared = set(re.findall(r"^mod (\w+);", (suite / "main.rs").read_text(), re.MULTILINE))
    for path in suite.glob("*.rs"):
        if path.name != "main.rs" and path.stem not in declared:
            errors.append(f"{path.relative_to(ROOT)}: declare it in {suite.name}/main.rs")
if errors:
    raise SystemExit("\n".join(errors))
