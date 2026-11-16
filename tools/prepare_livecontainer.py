#!/usr/bin/env python3
"""Prepare a separate RUIN dylib for one LiveContainer import (requires macOS)."""
import argparse
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile

from distribute import (DYLIB_ARCHITECTURES, DYLIB_INSTALL_NAME, LIVECONTAINER_RPATHS,
                        dylib_rpaths, validate_rpaths, verify_dylib)


def remove_livecontainer_rpaths(data):
    """Remove only LC's paths from one thin RUIN slice, retaining all file offsets."""
    if len(data) < 32:
        raise ValueError("Truncated Mach-O header")
    magic, cpu, subtype, kind, count, size, flags, reserved = struct.unpack_from('<8I', data)
    if (magic, cpu, kind) != (0xFEEDFACF, 0x0100000C, 6):
        raise ValueError("Expected a thin arm64/arm64e Mach-O dylib")
    end = 32 + size
    if end > len(data) or count > size // 8:
        raise ValueError("Invalid Mach-O load-command bounds")
    cursor = 32
    kept = []
    install_names = []
    for _ in range(count):
        if cursor + 8 > end:
            raise ValueError("Truncated Mach-O load command")
        command, length = struct.unpack_from('<II', data, cursor)
        # LC appends 44/28-byte commands. install_name_tool rejects their
        # four-byte alignment, so compact only this metadata ourselves.
        if length < 8 or length % 4 or cursor + length > end:
            raise ValueError("Invalid Mach-O load-command size")
        raw = data[cursor:cursor + length]
        remove = False
        if command in (0x8000001C, 0xD):  # LC_RPATH / LC_ID_DYLIB
            minimum = 12 if command == 0x8000001C else 24
            if length < minimum:
                raise ValueError("Truncated Mach-O path command")
            offset = struct.unpack_from('<I', raw, 8)[0]
            if not minimum <= offset < length or b'\0' not in raw[offset:]:
                raise ValueError("Invalid Mach-O path string")
            path = raw[offset:].split(b'\0', 1)[0].decode('utf-8')
            if command == 0xD:
                install_names.append(path)
            else:
                remove = path in LIVECONTAINER_RPATHS
        if not remove:
            kept.append(raw)
        cursor += length
    if cursor != end or install_names != [DYLIB_INSTALL_NAME]:
        raise ValueError("Expected an intact RUIN dylib load-command table")
    if len(kept) == count:
        return data
    commands = b''.join(kept)
    result = bytearray(data)
    struct.pack_into('<II', result, 16, len(kept), len(commands))
    result[32:end] = commands.ljust(size, b'\0')
    return bytes(result)


def prepare_livecontainer(source, output):
    source, output = Path(source), Path(output)
    if source.resolve() == output.resolve():
        raise ValueError("Use a separate output file; the source dylib must remain unchanged")
    if output.exists():
        raise FileExistsError(f"Output already exists: {output}")

    result = subprocess.run(["lipo", str(source), "-archs"], check=True,
                            capture_output=True, text=True)
    architectures = result.stdout.split()
    if len(architectures) != 2 or set(architectures) != set(DYLIB_ARCHITECTURES):
        raise ValueError("Expected a RUIN universal dylib with exactly arm64 and arm64e slices")
    paths_by_arch = {arch: dylib_rpaths(source, arch) for arch in DYLIB_ARCHITECTURES}
    for arch, paths in paths_by_arch.items():
        # Only repair paths owned by LC. Unrelated duplicate metadata is an error.
        validate_rpaths([path for path in paths if path not in LIVECONTAINER_RPATHS], arch)

    # Work on copies and publish only after strict signing/dependency checks.
    # In particular, never modify build/RUIN.dylib or a DEB's shared payload.
    with tempfile.TemporaryDirectory(prefix="ruin-lc-", dir=output.parent) as temporary:
        directory = Path(temporary)
        prepared = directory / "RUIN.dylib"
        changed = any(path in LIVECONTAINER_RPATHS
                      for paths in paths_by_arch.values() for path in paths)
        if changed:
            slices = []
            for arch in DYLIB_ARCHITECTURES:
                thin = directory / f"RUIN-{arch}.dylib"
                subprocess.run(["lipo", str(source), "-thin", arch, "-output", str(thin)], check=True)
                thin.write_bytes(remove_livecontainer_rpaths(thin.read_bytes()))
                slices.append(str(thin))
            subprocess.run(["lipo", "-create", *slices, "-output", str(prepared)], check=True)
            subprocess.run(["codesign", "--force", "--sign", "-", "--timestamp=none", str(prepared)],
                           check=True)
        else:
            shutil.copyfile(source, prepared)
        verify_dylib(prepared, for_livecontainer=True)
        prepared.replace(output)
    return output


def main():
    parser = argparse.ArgumentParser(description=__doc__, epilog=(
        "Import the output directly into the target LiveContainer tweak folder once. "
        "Re-importing a file already processed by LiveContainer adds the paths again. "
        "The output is ad-hoc signed; LiveContainer must apply its own signing as usual."))
    parser.add_argument("source", type=Path, help="RUIN dylib, including an already LC-imported copy")
    parser.add_argument("output", type=Path, help="New output file; the source is never overwritten")
    args = parser.parse_args()
    path = prepare_livecontainer(args.source, args.output)
    print(f"Prepared {path}; import this copy into the target LiveContainer folder once.")


if __name__ == "__main__":
    main()
