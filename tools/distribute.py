#!/usr/bin/env python3
"""Build resource-inclusive rootful, rootless, and jailed Debian packages."""
import argparse
import gzip
import hashlib
import io
import os
from pathlib import Path, PurePosixPath
import re
import stat
import subprocess
import tarfile

ROOT = Path(__file__).resolve().parents[1]
PACKAGE = "com.tqmane.ruin"
INSTALL_DIR = "Library/MobileSubstrate/DynamicLibraries"
VARIANTS = {
    "rootful": ("", "iphoneos-arm"),
    "rootless": ("var/jb/", "iphoneos-arm64"),
    "jailed": ("", "iphoneos-arm64"),
}
DYLIB_INSTALL_NAME = "@rpath/RUIN.dylib"
DYLIB_ARCHITECTURES = ("arm64", "arm64e")
OTOOL_ARCHITECTURE_RE = re.compile(r"\(architecture ([^)]+)\):$")
# Direct links reviewed for this build; new SDK dependencies require review.
APPLE_DEPENDENCIES = {
    f"/System/Library/Frameworks/{name}.framework/{name}"
    for name in ("Foundation", "UIKit", "CoreText", "WebKit", "CoreGraphics",
                 "Security", "CoreData", "ImageIO", "UniformTypeIdentifiers",
                 "UserNotifications", "CoreFoundation")
} | {
    "/usr/lib/libsqlite3.dylib", "/usr/lib/libz.1.dylib",
    "/usr/lib/libSystem.B.dylib", "/usr/lib/libobjc.A.dylib",
} | {
    f"{prefix}libswift{name}.dylib"
    for prefix in ("/usr/lib/swift/", "@rpath/")
    for name in ("Core", "CoreFoundation", "Dispatch", "ObjectiveC", "XPC",
                 "_Builtin_float")
}
VERSION_RE = re.compile(
    r"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)"
    r"(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?"
    r"(?:\+([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?$"
)
FILTER_PLIST = b'''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Filter</key>
  <dict>
    <key>Bundles</key>
    <array><string>jp.naver.line</string></array>
  </dict>
</dict>
</plist>
'''


def validate_version(value):
    match = VERSION_RE.fullmatch(value)
    prerelease = match.group(4) if match else None
    if not match or any(
        identifier.isdigit() and len(identifier) > 1 and identifier.startswith("0")
        for identifier in (prerelease or "").split(".")
    ):
        raise ValueError(f"Invalid SemVer version: {value!r}")
    return value


def dependency_blocks_from_otool(output):
    blocks = []
    current = None
    for line in output.splitlines():
        line = line.strip()
        if not line:
            continue
        if line.endswith(":"):
            if current is not None:
                blocks.append(current)
            match = OTOOL_ARCHITECTURE_RE.search(line)
            current = {"architecture": match.group(1) if match else None, "dependencies": []}
            continue
        if current is None:
            current = {"architecture": None, "dependencies": []}
        current["dependencies"].append(re.split(r"\s+\(", line, maxsplit=1)[0])
    if current is not None:
        blocks.append(current)
    return blocks


def dependencies_from_otool(output):
    dependencies = set()
    for block in dependency_blocks_from_otool(output):
        entries = block["dependencies"]
        if entries and entries[0] == DYLIB_INSTALL_NAME:
            entries = entries[1:]
        dependencies.update(entries)
    return sorted(dependencies)


def validate_dependencies(dependencies):
    for name in dependencies:
        if name not in APPLE_DEPENDENCIES:
            raise ValueError(f"Dependency is not an Apple system or Swift runtime library: {name}")


def verify_dylib(path):
    path = Path(path)
    if not path.is_file():
        raise ValueError(f"Dylib not found: {path}")
    result = subprocess.run(["lipo", str(path), "-archs"], check=True,
                            capture_output=True, text=True)
    architectures = result.stdout.split()
    if len(architectures) != len(DYLIB_ARCHITECTURES) or set(architectures) != set(DYLIB_ARCHITECTURES):
        found = " ".join(architectures) or "none"
        raise ValueError(f"Dylib must contain exactly arm64 and arm64e slices; found: {found}")
    subprocess.run(["lipo", str(path), "-verify_arch", *DYLIB_ARCHITECTURES], check=True)
    subprocess.run(["codesign", "--verify", "--strict", str(path)], check=True)
    result = subprocess.run(["otool", "-arch", "all", "-L", str(path)], check=True,
                            capture_output=True, text=True)
    blocks = dependency_blocks_from_otool(result.stdout)
    slice_architectures = [block["architecture"] for block in blocks]
    if (len(slice_architectures) != len(DYLIB_ARCHITECTURES) or
            set(slice_architectures) != set(DYLIB_ARCHITECTURES)):
        found = " ".join(str(architecture) for architecture in slice_architectures) or "none"
        raise ValueError(f"otool must report one dependency list for each arm64/arm64e slice; found: {found}")
    dependencies = dependencies_from_otool(result.stdout)
    validate_dependencies(dependencies)
    return dependencies


def source_date_epoch():
    try:
        value = int(os.environ.get("SOURCE_DATE_EPOCH", "0"))
    except ValueError as exc:
        raise ValueError("SOURCE_DATE_EPOCH must be an integer") from exc
    if not 0 <= value <= 0xFFFFFFFF:
        raise ValueError("SOURCE_DATE_EPOCH must be between 0 and 4294967295")
    return value


def payload_files(dylib, resources, variant):
    dylib, resources = Path(dylib), Path(resources)
    if not dylib.is_file():
        raise ValueError(f"Dylib not found: {dylib}")
    if not resources.is_dir() or not (resources / "Info.plist").is_file():
        raise ValueError(f"Resource bundle is missing or has no Info.plist: {resources}")

    prefix, _ = VARIANTS[variant]
    install_dir = prefix + INSTALL_DIR
    files = {
        f"{install_dir}/RUIN.dylib": (dylib.read_bytes(), 0o755),
        f"{install_dir}/RUIN.plist": (FILTER_PLIST, 0o644),
        f"{prefix}usr/share/doc/{PACKAGE}/RUIN-ThirdPartyNotices.txt": (third_party_notices(), 0o644),
    }
    bundle_prefix = f"{install_dir}/RUINResources.bundle"
    for path in sorted(resources.rglob("*")):
        if path.is_symlink():
            raise ValueError(f"Resource bundle must not contain symlinks: {path}")
        if path.is_file():
            relative = path.relative_to(resources).as_posix()
            files[f"{bundle_prefix}/{relative}"] = (path.read_bytes(), stat.S_IMODE(path.stat().st_mode))
    return files


def third_party_notices():
    fishhook_source = (ROOT / "vendor/fishhook/fishhook.c").read_text(encoding="utf-8")
    marker = '#include "fishhook.h"'
    if marker not in fishhook_source:
        raise ValueError("Could not find the fishhook license header")
    fishhook_notice = fishhook_source.split(marker, 1)[0].rstrip()
    tabler_notice = (ROOT / "vendor/tabler-icons/LICENSE").read_text(encoding="utf-8").rstrip()
    return (
        "fishhook - https://github.com/facebook/fishhook\n\n"
        f"{fishhook_notice}\n\n"
        "Tabler Icons - https://github.com/tabler/tabler-icons\n\n"
        f"{tabler_notice}\n"
    ).encode("utf-8")


def tar_gz(files, directories, epoch):
    raw = io.BytesIO()
    with tarfile.open(fileobj=raw, mode="w", format=tarfile.USTAR_FORMAT) as archive:
        for name in sorted(directories):
            info = tarfile.TarInfo(name.rstrip("/") + "/")
            info.type = tarfile.DIRTYPE
            info.mode = 0o755
            info.mtime = epoch
            info.uid = info.gid = 0
            info.uname = info.gname = "root"
            archive.addfile(info)
        for name in sorted(files):
            data, mode = files[name]
            info = tarfile.TarInfo(name)
            info.mode = mode
            info.size = len(data)
            info.mtime = epoch
            info.uid = info.gid = 0
            info.uname = info.gname = "root"
            archive.addfile(info, io.BytesIO(data))
    compressed = io.BytesIO()
    with gzip.GzipFile(fileobj=compressed, filename="", mode="wb", mtime=epoch, compresslevel=9) as stream:
        stream.write(raw.getvalue())
    return compressed.getvalue()


def data_archive(files, epoch):
    tar_files = {f"./{name}": value for name, value in files.items()}
    directories = {"."}
    for name in tar_files:
        parent = PurePosixPath(name[2:]).parent
        while str(parent) not in (".", ""):
            directories.add(f"./{parent.as_posix()}")
            parent = parent.parent
    return tar_gz(tar_files, directories, epoch)


def control_archive(version, variant, epoch):
    _, architecture = VARIANTS[variant]
    control = (
        f"Package: {PACKAGE}\n"
        f"Name: RUIN ({variant})\n"
        f"Version: {version}\n"
        f"Architecture: {architecture}\n"
        "Maintainer: RUIN contributors\n"
        "Section: Tweaks\n"
        f"X-RUIN-Variant: {variant}\n"
        f"Description: RUIN runtime tweak for LINE ({variant})\n"
    ).encode("utf-8")
    if variant != "jailed":
        # The platform supplies the injector; RUIN links no hook runtime.
        control += b"Depends: firmware (>= 18.0), mobilesubstrate\n"
    return tar_gz({"./control": (control, 0o644)}, {"."}, epoch)


def ar_member(name, data, epoch):
    if len(name) > 16:
        raise ValueError(f"ar member name is too long: {name}")
    header = (
        f"{name:<16}{epoch:<12d}{0:<6d}{0:<6d}{0o100644:<8o}{len(data):<10d}`\n"
    ).encode("ascii")
    return header + data + (b"\n" if len(data) % 2 else b"")


def deb_archive(files, version, variant, epoch):
    members = (
        ("debian-binary", b"2.0\n"),
        ("control.tar.gz", control_archive(version, variant, epoch)),
        ("data.tar.gz", data_archive(files, epoch)),
    )
    return b"!<arch>\n" + b"".join(ar_member(name, data, epoch) for name, data in members)


def build_distribution(dylib, resources, output, version, epoch=None):
    version = validate_version(version)
    epoch = source_date_epoch() if epoch is None else epoch
    if not 0 <= epoch <= 0xFFFFFFFF:
        raise ValueError("epoch must be between 0 and 4294967295")
    output = Path(output)
    output.mkdir(parents=True, exist_ok=True)
    # Remove the obsolete distribution formats, preserving signed IPA output.
    for pattern in ("RUIN-*-ios-arm64.dylib", "RUIN-*-manual-injection.zip",
                    "RUIN-ThirdPartyNotices.txt", f"{PACKAGE}_*_iphoneos-arm64.deb"):
        for old in output.glob(pattern):
            old.unlink()
    artifacts = []
    for variant in VARIANTS:
        files = payload_files(dylib, resources, variant)
        package = output / f"RUIN-{version}-{variant}.deb"
        package.write_bytes(deb_archive(files, version, variant, epoch))
        artifacts.append(package)
    sums = "".join(
        f"{hashlib.sha256(path.read_bytes()).hexdigest()}  {path.name}\n"
        for path in artifacts
    )
    (output / "SHA256SUMS").write_text(sums, encoding="ascii", newline="\n")
    return (*artifacts, output / "SHA256SUMS")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dylib", type=Path, default=ROOT / "build/RUIN.dylib")
    parser.add_argument("--resources", type=Path, default=ROOT / "resources/RUINResources.bundle")
    parser.add_argument("--output", type=Path, default=ROOT / "dist")
    parser.add_argument("--version", default=(ROOT / "VERSION").read_text(encoding="ascii").strip())
    args = parser.parse_args()

    version = validate_version(args.version)
    dependencies = verify_dylib(args.dylib)
    artifacts = build_distribution(args.dylib, args.resources, args.output, version)
    print("Verified dylib dependencies:")
    for dependency in dependencies:
        print(f"  {dependency}")
    for artifact in artifacts:
        print(artifact)


if __name__ == "__main__":
    main()
