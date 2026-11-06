"""Check the release package layout and deterministic archive construction."""
import importlib.util
import hashlib
import io
from pathlib import Path
import plistlib
import tempfile
import tarfile
import unittest
import zipfile

spec = importlib.util.spec_from_file_location(
    "distribute", Path(__file__).resolve().parents[1] / "tools/distribute.py")
distribute = importlib.util.module_from_spec(spec)
spec.loader.exec_module(distribute)


class DistributionTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.dylib = self.root / "RUIN.dylib"
        self.dylib.write_bytes(b"fixture dylib")
        self.resources = self.root / "RUINResources.bundle"
        self.resources.mkdir()
        (self.resources / "Info.plist").write_text("fixture bundle", encoding="utf-8")
        for language in ("en", "ja", "ko", "zh-Hans", "zh-Hant"):
            directory = self.resources / f"{language}.lproj"
            directory.mkdir()
            (directory / "Localizable.strings").write_text(
                f'"Hello" = "{language}";\n', encoding="utf-8")
        nested = self.resources / "icons"
        nested.mkdir()
        for icon in ("tabler-eye@2x.png", "tabler-eye@3x.png",
                     "tabler-eye-off@2x.png", "tabler-eye-off@3x.png"):
            (nested / icon).write_bytes(icon.encode("ascii"))
        self.output = self.root / "dist"

    def tearDown(self):
        self.temporary.cleanup()

    @staticmethod
    def read_ar(path):
        data = path.read_bytes()
        if not data.startswith(b"!<arch>\n"):
            raise AssertionError("invalid ar magic")
        offset, members = 8, []
        while offset < len(data):
            header = data[offset:offset + 60]
            if len(header) != 60 or header[58:60] != b"`\n":
                raise AssertionError("invalid ar member header")
            name = header[:16].decode("ascii").strip()
            size = int(header[48:58].decode("ascii").strip())
            offset += 60
            members.append((name, data[offset:offset + size]))
            offset += size + (size % 2)
        if offset != len(data):
            raise AssertionError("invalid ar member padding")
        return members

    def test_deb_and_zip_include_all_resources_and_are_reproducible(self):
        artifacts = distribute.build_distribution(
            self.dylib, self.resources, self.output, "0.4.0", epoch=123456789)
        first = [path.read_bytes() for path in artifacts]
        standalone, package, manual, notices, sums = artifacts
        self.assertEqual(standalone.read_bytes(), b"fixture dylib")

        members = self.read_ar(package)
        self.assertEqual([name for name, _ in members],
                         ["debian-binary", "control.tar.gz", "data.tar.gz"])
        self.assertEqual(members[0][1], b"2.0\n")
        with tarfile.open(fileobj=io.BytesIO(members[1][1]), mode="r:gz") as archive:
            self.assertEqual(set(archive.getnames()), {".", "./control"})
            control = archive.extractfile("./control").read().decode("utf-8")
        self.assertIn("Version: 0.4.0\n", control)
        self.assertNotIn("Depends:", control)

        localized_path = "./Library/MobileSubstrate/DynamicLibraries/RUINResources.bundle/ja.lproj/Localizable.strings"
        icon_path = "./Library/MobileSubstrate/DynamicLibraries/RUINResources.bundle/icons/tabler-eye@2x.png"
        with tarfile.open(fileobj=io.BytesIO(members[2][1]), mode="r:gz") as archive:
            self.assertEqual(archive.extractfile(localized_path).read(),
                             (self.resources / "ja.lproj/Localizable.strings").read_bytes())
            self.assertEqual(archive.extractfile(icon_path).read(), b"tabler-eye@2x.png")
            for path in self.resources.rglob("*"):
                if path.is_file():
                    member = f"./Library/MobileSubstrate/DynamicLibraries/RUINResources.bundle/{path.relative_to(self.resources).as_posix()}"
                    self.assertIsNotNone(archive.extractfile(member), member)
            self.assertIn("./Library/MobileSubstrate/DynamicLibraries/RUIN.plist",
                          archive.getnames())
            filter_plist = plistlib.loads(archive.extractfile(
                "./Library/MobileSubstrate/DynamicLibraries/RUIN.plist").read())
            self.assertEqual(filter_plist["Filter"]["Bundles"], ["jp.naver.line"])
            self.assertIsNotNone(archive.extractfile(
                "./usr/share/doc/com.tqmane.ruin/RUIN-ThirdPartyNotices.txt"))

        with zipfile.ZipFile(manual) as archive:
            self.assertEqual(archive.read(localized_path[2:]),
                             (self.resources / "ja.lproj/Localizable.strings").read_bytes())
            for path in self.resources.rglob("*"):
                if path.is_file():
                    member = f"Library/MobileSubstrate/DynamicLibraries/RUINResources.bundle/{path.relative_to(self.resources).as_posix()}"
                    self.assertIn(member, archive.namelist())
            self.assertIn("Library/MobileSubstrate/DynamicLibraries/RUIN.dylib",
                          archive.namelist())
            self.assertIn("usr/share/doc/com.tqmane.ruin/RUIN-ThirdPartyNotices.txt",
                          archive.namelist())
        self.assertTrue((self.output / "RUIN-ThirdPartyNotices.txt").is_file())
        self.assertIn(b"fishhook", notices.read_bytes())
        self.assertIn(b"MIT License", notices.read_bytes())
        checksum_text = sums.read_text(encoding="ascii")
        for artifact in (standalone, package, manual, notices):
            self.assertIn(
                f"{hashlib.sha256(artifact.read_bytes()).hexdigest()}  {artifact.name}",
                checksum_text)

        second = [path.read_bytes() for path in distribute.build_distribution(
            self.dylib, self.resources, self.output, "0.4.0", epoch=123456789)]
        self.assertEqual(first, second)

    def test_manual_and_tag_versions_must_be_semver(self):
        for invalid in ("v0.4.0", "0.4", "01.2.3", "0.4.0-01"):
            with self.subTest(version=invalid), self.assertRaises(ValueError):
                distribute.validate_version(invalid)
        self.assertEqual(distribute.validate_version("0.4.0-rc.1+build.2"),
                         "0.4.0-rc.1+build.2")

    def test_otool_dependency_check_rejects_external_libraries(self):
        output = "/tmp/RUIN.dylib:\n"
        output += "\t@rpath/RUIN.dylib (compatibility version 0.0.0)\n"
        output += "\t/System/Library/Frameworks/Foundation.framework/Foundation (compatibility version 1.0.0)\n"
        output += "\t@rpath/libswiftCore.dylib (compatibility version 1.0.0)\n"
        distribute.validate_dependencies(distribute.dependencies_from_otool(output))
        output += "\t/opt/homebrew/lib/libexample.dylib (compatibility version 1.0.0)\n"
        with self.assertRaisesRegex(ValueError, "not an Apple system"):
            distribute.validate_dependencies(distribute.dependencies_from_otool(output))
        for disguised in ("/usr/lib/libexample.dylib", "@rpath/libswiftExample.dylib",
                          "/System/Library/Frameworks/Example.framework/Example"):
            with self.subTest(dependency=disguised), self.assertRaises(ValueError):
                distribute.validate_dependencies([disguised])


if __name__ == "__main__":
    unittest.main()
