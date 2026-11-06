#!/usr/bin/env python3
"""Build reproducible RUIN dylib, jailed Debian package, and manual payload ZIP."""
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
import zipfile

ROOT = Path(__file__).resolve().parents[1]
PACKAGE = "com.tqmane.ruin"
INSTALL_DIR = "Library/MobileSubstrate/DynamicLibraries"
DYLIB_INSTALL_NAME = "@rpath/RUIN.dylib"
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


def dependencies_from_otool(output):
    dependencies = []
    for line in output.splitlines():
        line = line.strip()
        if not line or line.endswith(":"):
            continue
        dependencies.append(re.split(r"\s+\(", line, maxsplit=1)[0])
    if dependencies and dependencies[0] == DYLIB_INSTALL_NAME:
        dependencies.pop(0)
    return dependencies


def validate_dependencies(dependencies):
    for name in dependencies:
        if name not in APPLE_DEPENDENCIES:
            raise ValueError(f"Dependency is not an Apple system or Swift runtime library: {name}")


def verify_dylib(path):
    path = Path(path)
    if not path.is_file():
        raise ValueError(f"Dylib not found: {path}")
    subprocess.run(["lipo", str(path), "-verify_arch", "arm64"], check=True)
    result = subprocess.run(["otool", "-L", str(path)], check=True,
                            capture_output=True, text=True)
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


def payload_files(dylib, resources):
    dylib, resources = Path(dylib), Path(resources)
    if not dylib.is_file():
        raise ValueError(f"Dylib not found: {dylib}")
    if not resources.is_dir() or not (resources / "Info.plist").is_file():
        raise ValueError(f"Resource bundle is missing or has no Info.plist: {resources}")

    files = {
        f"{INSTALL_DIR}/RUIN.dylib": (dylib.read_bytes(), 0o755),
        f"{INSTALL_DIR}/RUIN.plist": (FILTER_PLIST, 0o644),
        "usr/share/doc/com.tqmane.ruin/RUIN-ThirdPartyNotices.txt": (third_party_notices(), 0o644),
    }
    bundle_prefix = f"{INSTALL_DIR}/RUINResources.bundle"
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


def control_archive(version, epoch):
    control = (
        f"Package: {PACKAGE}\n"
        f"Version: {version}\n"
        "Architecture: iphoneos-arm64\n"
        "Maintainer: RUIN contributors\n"
        "Description: RUIN runtime tweak for LINE\n"
    ).encode("utf-8")
    return tar_gz({"./control": (control, 0o644)}, {"."}, epoch)


def ar_member(name, data, epoch):
    if len(name) > 16:
        raise ValueError(f"ar member name is too long: {name}")
    header = (
        f"{name:<16}{epoch:<12d}{0:<6d}{0:<6d}{0o100644:<8o}{len(data):<10d}`\n"
    ).encode("ascii")
    return header + data + (b"\n" if len(data) % 2 else b"")


def deb_archive(files, version, epoch):
    members = (
        ("debian-binary", b"2.0\n"),
        ("control.tar.gz", control_archive(version, epoch)),
        ("data.tar.gz", data_archive(files, epoch)),
    )
    return b"!<arch>\n" + b"".join(ar_member(name, data, epoch) for name, data in members)


def payload_zip(files):
    output = io.BytesIO()
    with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_STORED) as archive:
        for name in sorted(files):
            data, mode = files[name]
            info = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
            info.create_system = 3
            info.compress_type = zipfile.ZIP_STORED
            info.external_attr = (stat.S_IFREG | mode) << 16
            archive.writestr(info, data)
    return output.getvalue()


def build_distribution(dylib, resources, output, version, epoch=None):
    version = validate_version(version)
    epoch = source_date_epoch() if epoch is None else epoch
    if not 0 <= epoch <= 0xFFFFFFFF:
        raise ValueError("epoch must be between 0 and 4294967295")
    files = payload_files(dylib, resources)
    output = Path(output)
    output.mkdir(parents=True, exist_ok=True)

    standalone = output / f"RUIN-{version}-ios-arm64.dylib"
    package = output / f"{PACKAGE}_{version}_iphoneos-arm64.deb"
    manual = output / f"RUIN-{version}-manual-injection.zip"
    notices = output / "RUIN-ThirdPartyNotices.txt"
    standalone.write_bytes(files[f"{INSTALL_DIR}/RUIN.dylib"][0])
    standalone.chmod(0o755)
    package.write_bytes(deb_archive(files, version, epoch))
    manual.write_bytes(payload_zip(files))
    notices.write_bytes(third_party_notices())

    artifacts = (standalone, package, manual, notices)
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
