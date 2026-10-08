#!/usr/bin/env python3
import re
import argparse
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("--root", default=str(Path(__file__).resolve().parent.parent))
args = parser.parse_args()
root = Path(args.root).resolve()
for document in [root / "README.md", *(root / "docs").rglob("*.md")]:
    for target in re.findall(r"\[[^\]]*\]\(([^)]+)\)", document.read_text()):
        if "://" in target or target.startswith("mailto:"):
            continue
        path = target.split("#", 1)[0]
        if path and not (document.parent / path).exists():
            raise SystemExit(f"{document.relative_to(root)}: missing link {target}")
print("Fleet documentation links checked")
