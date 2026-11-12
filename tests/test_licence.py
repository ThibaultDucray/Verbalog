# SPDX-FileCopyrightText: 2026 Thibault Ducray
# SPDX-License-Identifier: GPL-3.0-or-later

"""Every source file says who wrote it and under which licence, even when copied alone."""

import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
HEADER = ("SPDX-FileCopyrightText: 2026 Thibault Ducray", "SPDX-License-Identifier: GPL-3.0-or-later")


def source_files() -> list[Path]:
    try:
        listed = subprocess.run(
            ["git", "ls-files", "*.swift", "*.py", "*.sh"], cwd=ROOT, capture_output=True, text=True, check=True
        ).stdout.split()
    except (OSError, subprocess.CalledProcessError):
        pytest.skip("not a git checkout")
    return [ROOT / name for name in listed]


def test_every_source_file_has_the_licence_header():
    missing = []
    for path in source_files():
        top = "".join(path.read_text(encoding="utf-8").splitlines(keepends=True)[:4])
        if not all(line in top for line in HEADER):
            missing.append(str(path.relative_to(ROOT)))
    assert not missing, "Add the two SPDX lines at the top (see CONTRIBUTING.md): " + ", ".join(missing)
