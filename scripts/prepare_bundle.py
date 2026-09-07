"""Remove AppleDouble metadata from the generated app, never from source files.

On ExFAT, macOS stores extended attributes as ._* files. codesign interprets
those inside Contents/MacOS as unsigned code. They are not app resources.
Run after compilation and before Xcode signs the enclosing app bundle.
"""
from pathlib import Path
import sys

bundle = Path(sys.argv[1])
if bundle.suffix != ".app" or not (bundle / "Contents").is_dir():
    raise SystemExit("Expected a generated .app bundle with Contents")

for sidecar in bundle.rglob("._*"):
    if sidecar.is_file() and not sidecar.is_symlink():
        sidecar.unlink()
