"""Apply the two Windows build fixes required by pinned comfy-kitchen 0.2.31."""

from __future__ import annotations

import argparse
from pathlib import Path


def replace_once(path: Path, old: str, new: str) -> None:
    text = path.read_text(encoding="utf-8")
    if new in text:
        print(f"Already patched: {path}")
        return
    count = text.count(old)
    if count != 1:
        raise RuntimeError(f"Expected one patch target in {path}, found {count}")
    path.write_text(text.replace(old, new), encoding="utf-8")
    print(f"Patched: {path}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--site-packages", type=Path, required=True)
    args = parser.parse_args()

    replace_once(
        args.source / "setup.py",
        'if has_extensions and sys.version_info >= (3, 12):',
        'if has_extensions and sys.version_info >= (3, 12) and os.name != "nt":',
    )
    replace_once(
        args.source / "comfy_kitchen" / "backends" / "hip" / "CMakeLists.txt",
        'if(Python_VERSION VERSION_GREATER_EQUAL "3.12")',
        'if(Python_VERSION VERSION_GREATER_EQUAL "3.12" AND NOT WIN32)',
    )
    replace_once(
        args.site_packages / "nanobind" / "include" / "nanobind" / "nb_backend.h",
        "    inline constexpr ret (*name) args = &target;",
        "    inline ret (*const name) args = &target;",
    )


if __name__ == "__main__":
    main()
