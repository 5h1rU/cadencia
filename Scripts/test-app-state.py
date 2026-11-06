#!/usr/bin/env python3
"""Run the Foundation-only app-state tests without an iOS test host.

Usage: python3 Scripts/test-app-state.py
"""
import json
from pathlib import Path
import subprocess
import tempfile


root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="cadencia-state-tests-") as directory:
    package = Path(directory)
    tests = package / "Tests" / "StateTests"
    tests.mkdir(parents=True)
    # The brands' test literals and ids are CadenciaCore's.
    for source in [root / "Cadencia/App/AppState.swift", root / "Cadencia/App/AppConfig.swift", root / "Tests/AppStateTests.swift",
                   root / "CadenciaCore/Tests/CadenciaCoreTests/BrandLiterals.swift"]:
        (tests / source.name).symlink_to(source)
    core = json.dumps(str(root / "CadenciaCore"), ensure_ascii=False)
    (package / "Package.swift").write_text(f'''// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "CadenciaStateTests", platforms: [.macOS(.v14)],
    dependencies: [.package(path: {core})],
    targets: [.testTarget(name: "StateTests", dependencies: [.product(name: "CadenciaCore", package: "CadenciaCore")])],
    swiftLanguageModes: [.v5])
''')
    result = subprocess.run(["swift", "test", "--package-path", str(package)])
raise SystemExit(result.returncode)
