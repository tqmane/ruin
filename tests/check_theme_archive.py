#!/usr/bin/env python3
"""Build small hostile ZIP fixtures and run the Foundation host checker."""

import io
import json
import pathlib
import stat
import struct
import subprocess
import sys
import tempfile
import warnings
import zipfile


ROOT = pathlib.Path(__file__).resolve().parents[1]
MAX_ENTRY = 64 * 1024 * 1024
MANIFEST = json.dumps({"manifest": {"schemaVersion": 1, "revision": 7}}, separators=(",", ":")).encode()


class NonSeekableBuffer:
    def __init__(self):
        self.buffer = io.BytesIO()

    def write(self, data):
        return self.buffer.write(data)

    def tell(self):
        return self.buffer.tell()

    def seekable(self):
        return False

    def flush(self):
        self.buffer.flush()

    def getvalue(self):
        return self.buffer.getvalue()


def make_zip(entries, *, compression=zipfile.ZIP_DEFLATED, nonseekable=False):
    sink = NonSeekableBuffer() if nonseekable else io.BytesIO()
    with zipfile.ZipFile(sink, "w", compression=compression) as archive:
        for item in entries:
            if isinstance(item, zipfile.ZipInfo):
                archive.writestr(item, b"link target")
            else:
                name, data = item[:2]
                method = item[2] if len(item) > 2 else compression
                archive.writestr(name, data, compress_type=method)
    return sink.getvalue()


def entry_payload_offset(data, info):
    fields = struct.unpack_from("<IHHHHHIIIHH", data, info.header_offset)
    name_length, extra_length = fields[-2:]
    return info.header_offset + 30 + name_length + extra_length


def make_bomb():
    output = io.BytesIO()
    with zipfile.ZipFile(output, "w", zipfile.ZIP_DEFLATED) as archive:
        archive.writestr("theme.json", MANIFEST)
        with archive.open("images/oversized.bin", "w") as entry:
            remaining = MAX_ENTRY + 1
            chunk = b"B" * 65536
            while remaining:
                count = min(remaining, len(chunk))
                entry.write(chunk[:count])
                remaining -= count
    return output.getvalue()


def fixtures(directory):
    valid = make_zip([
        ("theme.json", MANIFEST),
        ("images/", b"", zipfile.ZIP_STORED),
        ("images/pixel.bin", bytes(range(256)), zipfile.ZIP_STORED),
        ("native-resource.dat", b"opaque native resource\0" * 30, zipfile.ZIP_DEFLATED),
    ])
    results = []

    def save(name, archive, accepted=False, count=0, revision=0):
        path = directory / f"{name}.zip"
        path.write_bytes(archive)
        results.append((path, accepted, count, revision))

    save("valid-mixed-methods-and-directory", valid, True, 3, 7)
    save("valid-data-descriptor", make_zip([
        ("theme.json", MANIFEST), ("images/descriptor.bin", b"descriptor payload" * 50)
    ], nonseekable=True), True, 2, 7)

    stored = make_zip([("theme.json", MANIFEST, zipfile.ZIP_STORED),
                       ("images/crc.bin", b"CRC must be checked", zipfile.ZIP_STORED)],
                      compression=zipfile.ZIP_STORED)
    damaged_crc = bytearray(stored)
    with zipfile.ZipFile(io.BytesIO(stored)) as archive:
        info = archive.getinfo("images/crc.bin")
        damaged_crc[entry_payload_offset(stored, info)] ^= 0x20
    save("bad-content-crc", bytes(damaged_crc))

    mismatch = bytearray(stored)
    with zipfile.ZipFile(io.BytesIO(stored)) as archive:
        info = archive.getinfo("images/crc.bin")
        struct.pack_into("<H", mismatch, info.header_offset + 8, zipfile.ZIP_DEFLATED)
    save("local-central-method-mismatch", bytes(mismatch))

    descriptor = bytearray(make_zip([("theme.json", MANIFEST), ("images/d.bin", b"descriptor" * 20)], nonseekable=True))
    with zipfile.ZipFile(io.BytesIO(descriptor)) as archive:
        info = archive.getinfo("images/d.bin")
        offset = entry_payload_offset(descriptor, info) + info.compress_size
        if struct.unpack_from("<I", descriptor, offset)[0] == 0x08074B50:
            offset += 4
        descriptor[offset] ^= 1
    save("bad-data-descriptor", bytes(descriptor))

    save("path-traversal", make_zip([("theme.json", MANIFEST), ("../escape", b"x")]))
    link = zipfile.ZipInfo("images/link")
    link.create_system = 3
    link.external_attr = (stat.S_IFLNK | 0o777) << 16
    save("symlink", make_zip([("theme.json", MANIFEST), link]))
    save("casefold-duplicate", make_zip([("theme.json", MANIFEST),
                                         ("images/Logo.png", b"a"), ("images/logo.png", b"b")]))
    save("file-directory-collision", make_zip([("theme.json", MANIFEST),
                                                ("images", b"file"), ("images/child", b"child")]))
    with warnings.catch_warnings():
        warnings.simplefilter("ignore", UserWarning)
        save("exact-duplicate", make_zip([("theme.json", MANIFEST),
                                           ("images/same.bin", b"a"), ("images/same.bin", b"b")]))
    save("zip64-extra", make_zip([("theme.json", MANIFEST),
                                  (zipfile.ZipInfo("images/zip64.bin"), b"x")]))
    zip64_path = directory / "zip64-extra.zip"
    with zipfile.ZipFile(zip64_path, "a") as archive:
        info = zipfile.ZipInfo("images/zip64-extra.bin")
        info.extra = struct.pack("<HHQQ", 1, 16, 0, 0)
        archive.writestr(info, b"x")
    results = [item for item in results if item[0] != zip64_path]
    results.append((zip64_path, False, 0, 0))

    encrypted = bytearray(make_zip([("theme.json", MANIFEST, zipfile.ZIP_STORED)], compression=zipfile.ZIP_STORED))
    local = encrypted.find(b"PK\x03\x04")
    central = encrypted.find(b"PK\x01\x02")
    encrypted[local + 6] |= 1
    encrypted[central + 8] |= 1
    save("encrypted-flag", bytes(encrypted))
    save("expanded-size-bomb", make_bomb())
    save("bad-end-record", valid[:-2])
    save("missing-manifest", make_zip([("images/orphan.bin", b"x")]))
    invalid_manifest = json.dumps({"manifest": {"schemaVersion": 1, "revision": 0}}).encode()
    save("invalid-manifest", make_zip([("theme.json", invalid_manifest)]))
    return results


def expected_sample(path):
    known = {
        "EB2496FE-6830-4471-AB91-042275B519DB.linetheme": (182, 328),
        "7E1B5487-DAEA-4DF1-A261-B30054BD5622.linetheme": (121, 132),
    }
    if path.name in known:
        return known[path.name]
    with zipfile.ZipFile(path) as archive:
        regular_files = sum(not entry.is_dir() for entry in archive.infolist())
        document = json.loads(archive.read("theme.json"))
    return regular_files, int(document["manifest"]["revision"])


def main():
    supplied = [pathlib.Path(value).resolve() for value in sys.argv[1:]]
    samples = supplied or [
        ROOT / "build/manual-theme-downloads/34afc5b4-f330-40bc-a2ea-fae94207847a/328/EB2496FE-6830-4471-AB91-042275B519DB.linetheme",
        ROOT / "build/url-theme-study/132/7E1B5487-DAEA-4DF1-A261-B30054BD5622.linetheme",
    ]
    samples = [path for path in samples if path.is_file()]
    with tempfile.TemporaryDirectory(prefix="ruin-theme-archive-") as temporary:
        temp = pathlib.Path(temporary)
        executable = temp / "check_theme_archive"
        subprocess.run([
            "xcrun", "--sdk", "macosx", "clang", "-fobjc-arc", "-fblocks", "-std=gnu11",
            "-Wall", "-Wextra", "-Werror", "-I", str(ROOT / "src/themes"), str(ROOT / "src/themes/ThemeArchive.m"),
            str(ROOT / "tests/check_theme_archive.m"), "-framework", "Foundation", "-lz", "-o", str(executable),
        ], check=True)
        subprocess.run(["codesign", "--force", "--sign", "-", str(executable)], check=True)
        cases = fixtures(temp)
        for path, accepted, count, revision in cases:
            subprocess.run([str(executable), str(path), "accept" if accepted else "reject",
                            str(count), str(revision)], check=True, timeout=30)
        for sample in samples:
            count, revision = expected_sample(sample)
            subprocess.run([str(executable), str(sample), "accept", str(count), str(revision)], check=True, timeout=30)
    print(f"check_theme_archive: PASS ({len(cases)} synthetic archives, {len(samples)} real archives)")


if __name__ == "__main__":
    main()
