#!/usr/bin/env python3
"""Verify every shipped static resource in each slice of the finished dylib."""
import argparse
from pathlib import Path
import subprocess
import tempfile

from embed_resources import bundle_digest, bundle_files

ARCHITECTURES = ("arm64", "arm64e")


def verify_slice_resources(data, files):
    digest = bundle_digest(files)
    if digest.encode("ascii") + b"\0" not in data:
        raise ValueError("Embedded resource digest is missing or stale")
    for name, contents in files:
        if name.encode("utf-8") + b"\0" not in data:
            raise ValueError(f"Embedded resource path is missing: {name}")
        if contents and contents not in data:
            raise ValueError(f"Embedded resource contents differ: {name}")
    return digest


def verify_embedded_resources(dylib, resources):
    files = bundle_files(resources)
    results = {}
    with tempfile.TemporaryDirectory(prefix="ruin-embedded-check-") as temporary:
        for architecture in ARCHITECTURES:
            thin = Path(temporary) / (architecture + ".dylib")
            subprocess.run(["lipo", str(dylib), "-thin", architecture, "-output", str(thin)],
                           check=True, capture_output=True)
            try:
                digest = verify_slice_resources(thin.read_bytes(), files)
            except ValueError as error:
                raise ValueError(f"{architecture}: {error}") from error
            results[architecture] = {"files": len(files), "digest": digest}
    return results


def main():
    root = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("dylib", type=Path)
    parser.add_argument("--resources", type=Path, default=root / "resources/RUINResources.bundle")
    args = parser.parse_args()
    for architecture, result in verify_embedded_resources(args.dylib, args.resources).items():
        print(f"PASS {architecture}: {result['files']} embedded resource files, digest {result['digest']}")


if __name__ == "__main__":
    main()
