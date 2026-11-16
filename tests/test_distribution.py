"""Check the release package layout and deterministic archive construction."""
import importlib.util
import hashlib
import io
from pathlib import Path
import plistlib
import subprocess
import tempfile
import tarfile
import unittest
from types import ModuleType
from unittest.mock import Mock, patch

spec = importlib.util.spec_from_file_location(
    "distribute", Path(__file__).resolve().parents[1] / "tools/distribute.py")
distribute = importlib.util.module_from_spec(spec)
spec.loader.exec_module(distribute)


class DistributionTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.dylib = self.root / "RUIN.dylib"
        self.dylib.write_bytes(b"fat fixture dylib: arm64 + arm64e")
        self.resources = self.root / "RUINResources.bundle"
        self.resources.mkdir()
        (self.resources / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": "com.tqmane.ruin.resources"}))
        for language in ("en", "ja", "ko", "zh-Hans", "zh-Hant"):
            directory = self.resources / f"{language}.lproj"
            directory.mkdir()
            (directory / "Localizable.strings").write_text(
                f'"Hello" = "{language}";\n', encoding="utf-8")
        nested = self.resources / "icons"
        nested.mkdir()
        for icon in ("tabler-eye@2x.png", "tabler-eye@3x.png",
                     "tabler-eye-off@2x.png", "tabler-eye-off@3x.png",
                     "tabler-checks@2x.png", "tabler-checks@3x.png"):
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

    def test_three_debs_include_resources_and_are_reproducible(self):
        self.output.mkdir()
        obsolete = ["RUIN-0.4.0-ios-arm64.dylib", "RUIN-0.4.0-manual-injection.zip",
                    "RUIN-ThirdPartyNotices.txt", "com.tqmane.ruin_0.4.0_iphoneos-arm64.deb"]
        for name in obsolete:
            (self.output / name).write_bytes(b"old output")
        signed_ipa = self.output / "RUIN-LINE-26.16.0.ipa"
        signed_ipa.write_bytes(b"private signing output")
        artifacts = distribute.build_distribution(
            self.dylib, self.resources, self.output, "0.4.0", epoch=123456789)
        self.assertEqual([p.name for p in artifacts],
                         ["RUIN-0.4.0-rootful.deb", "RUIN-0.4.0-rootless.deb",
                          "RUIN-0.4.0-jailed.deb", "RUIN-0.4.0-LiveContainer.dylib", "SHA256SUMS"])
        self.assertTrue(all(not (self.output / name).exists() for name in obsolete))
        self.assertEqual(signed_ipa.read_bytes(), b"private signing output")
        first = [path.read_bytes() for path in artifacts]
        dylib_payloads = []
        expected = [("rootful", "", "iphoneos-arm"),
                    ("rootless", "var/jb/", "iphoneos-arm64"),
                    ("jailed", "", "iphoneos-arm64")]
        for package, (variant, prefix, architecture) in zip(artifacts[:3], expected):
            members = self.read_ar(package)
            self.assertEqual([name for name, _ in members],
                             ["debian-binary", "control.tar.gz", "data.tar.gz"])
            self.assertEqual(members[0][1], b"2.0\n")
            with tarfile.open(fileobj=io.BytesIO(members[1][1]), mode="r:gz") as archive:
                self.assertEqual(set(archive.getnames()), {".", "./control"})
                control = archive.extractfile("./control").read().decode("utf-8")
            self.assertIn("Version: 0.4.0\n", control)
            self.assertIn(f"Architecture: {architecture}\n", control)
            self.assertIn(f"X-RUIN-Variant: {variant}\n", control)
            if variant == "jailed":
                self.assertNotIn("Depends:", control)
            else:
                self.assertIn("Depends: firmware (>= 18.0), mobilesubstrate\n", control)
            install = "./" + prefix + "Library/MobileSubstrate/DynamicLibraries/"
            with tarfile.open(fileobj=io.BytesIO(members[2][1]), mode="r:gz") as archive:
                dylib_payload = archive.extractfile(install + "RUIN.dylib").read()
                dylib_payloads.append(dylib_payload)
                self.assertEqual(dylib_payload, self.dylib.read_bytes())
                for path in self.resources.rglob("*"):
                    if path.is_file():
                        member = install + "RUINResources.bundle/" + path.relative_to(self.resources).as_posix()
                        self.assertEqual(archive.extractfile(member).read(), path.read_bytes())
                filter_plist = plistlib.loads(archive.extractfile(install + "RUIN.plist").read())
                self.assertEqual(filter_plist["Filter"]["Bundles"], ["jp.naver.line"])
                notices = archive.extractfile("./" + prefix +
                    "usr/share/doc/com.tqmane.ruin/RUIN-ThirdPartyNotices.txt").read()
                self.assertIn(b"fishhook", notices)
                self.assertIn(b"MIT License", notices)
                self.assertTrue(all(member.name.startswith("./" + prefix)
                                    for member in archive.getmembers() if member.isfile()))
        checksum_text = artifacts[-1].read_text(encoding="ascii")
        self.assertEqual(artifacts[3].read_bytes(), self.dylib.read_bytes())
        self.assertEqual(dylib_payloads, [self.dylib.read_bytes()] * 3)
        self.assertEqual(len(checksum_text.splitlines()), 4)
        for artifact in artifacts[:-1]:
            self.assertIn(f"{hashlib.sha256(artifact.read_bytes()).hexdigest()}  {artifact.name}",
                          checksum_text)
        second = [path.read_bytes() for path in distribute.build_distribution(
            self.dylib, self.resources, self.output, "0.4.0", epoch=123456789)]
        self.assertEqual(first, second)

    def test_main_verifies_dylib_then_embedded_resources_before_packaging(self):
        events = []
        verifier = ModuleType("verify_embedded_resources")

        def verify_resources(dylib, resources):
            self.assertEqual((dylib, resources), (self.dylib, self.resources))
            self.assertFalse(self.output.exists())
            events.append("resources")
            return {"arm64": {}, "arm64e": {}}

        verifier.verify_embedded_resources = Mock(side_effect=verify_resources)
        arguments = ["distribute.py", "--dylib", str(self.dylib), "--resources", str(self.resources),
                     "--output", str(self.output), "--version", "0.5.3-rc.1+build.2"]
        with patch("sys.argv", arguments), patch.dict("sys.modules", {verifier.__name__: verifier}), \
                patch.object(distribute, "verify_dylib", side_effect=lambda path, **kwargs:
                             events.append("dylib") or []) as verify, \
                patch.object(distribute, "build_distribution", wraps=distribute.build_distribution) as build, \
                patch("builtins.print"):
            distribute.main()
        self.assertEqual(events, ["dylib", "resources"])
        verify.assert_called_once_with(self.dylib, for_livecontainer=True)
        build.assert_called_once_with(self.dylib, self.resources, self.output, "0.5.3-rc.1+build.2")
        verifier.verify_embedded_resources.assert_called_once_with(self.dylib, self.resources)
        names = {path.name for path in self.output.iterdir()}
        self.assertEqual(names, {
            "RUIN-0.5.3-rc.1+build.2-rootful.deb", "RUIN-0.5.3-rc.1+build.2-rootless.deb",
            "RUIN-0.5.3-rc.1+build.2-jailed.deb", "RUIN-0.5.3-rc.1+build.2-LiveContainer.dylib", "SHA256SUMS"})

    def test_main_does_not_package_after_either_verification_fails(self):
        verifier = ModuleType("verify_embedded_resources")
        arguments = ["distribute.py", "--dylib", str(self.dylib), "--resources", str(self.resources),
                     "--output", str(self.output), "--version", "0.5.3"]
        for failure in ("dylib", "resources"):
            with self.subTest(failure=failure):
                verifier.verify_embedded_resources = Mock(side_effect=ValueError("resource mismatch"))
                with patch("sys.argv", arguments), patch.dict("sys.modules", {verifier.__name__: verifier}), \
                        patch.object(distribute, "verify_dylib", side_effect=ValueError("invalid dylib")
                                     if failure == "dylib" else None), \
                        patch.object(distribute, "build_distribution") as build, \
                        self.assertRaises(ValueError):
                    distribute.main()
                build.assert_not_called()
                self.assertEqual(verifier.verify_embedded_resources.call_count, int(failure == "resources"))
                self.assertFalse(self.output.exists())

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

    @staticmethod
    def otool_slices(second_slice_dependency=None):
        foundation = "/System/Library/Frameworks/Foundation.framework/Foundation"
        second_slice = f"\t{foundation} (compatibility version 1.0.0)\n"
        if second_slice_dependency:
            second_slice += f"\t{second_slice_dependency} (compatibility version 1.0.0)\n"
        return (
            "/tmp/RUIN.dylib (architecture arm64):\n"
            "\t@rpath/RUIN.dylib (compatibility version 0.0.0)\n"
            f"\t{foundation} (compatibility version 1.0.0)\n"
            "/tmp/RUIN.dylib (architecture arm64e):\n"
            "\t@rpath/RUIN.dylib (compatibility version 0.0.0)\n" + second_slice
        )

    def verify_dylib_with_tools(self, archs="arm64 arm64e", signature_status=0,
                                otool_output=None, calls=None, rpaths=None):
        calls = calls if calls is not None else []

        def run(args, check=False, capture_output=False, text=False):
            args = [str(arg) for arg in args]
            calls.append(args)
            if args[0] == "lipo" and args[-1] == "-archs":
                result = subprocess.CompletedProcess(args, 0, stdout=archs + "\n", stderr="")
            elif args[0] == "lipo" and "-verify_arch" in args:
                result = subprocess.CompletedProcess(args, 0, stdout="", stderr="")
            elif args[0] == "codesign":
                result = subprocess.CompletedProcess(args, signature_status, stdout="", stderr="unsigned")
            elif args[:4] == ["otool", "-arch", "all", "-L"]:
                result = subprocess.CompletedProcess(args, 0,
                    stdout=otool_output or self.otool_slices(), stderr="")
            elif args[:2] == ["otool", "-L"]:
                # Some macOS versions default to one native slice without an architecture header.
                host_output = self.otool_slices().split("/tmp/RUIN.dylib (architecture arm64e):")[0]
                result = subprocess.CompletedProcess(args, 0,
                    stdout=host_output.replace(" (architecture arm64)", ""), stderr="")
            elif args[:2] == ["otool", "-arch"] and args[3] == "-l":
                paths = (rpaths or {}).get(args[2], ["/usr/lib/swift"])
                output = "/tmp/RUIN.dylib:\n" + "".join(
                    f"Load command {index}\n          cmd LC_RPATH\n      cmdsize 48\n"
                    f"         path {path} (offset 12)\n" for index, path in enumerate(paths))
                result = subprocess.CompletedProcess(args, 0, stdout=output, stderr="")
            else:
                raise AssertionError(f"Unexpected command: {args}")
            if check and result.returncode:
                raise subprocess.CalledProcessError(result.returncode, args,
                    output=result.stdout, stderr=result.stderr)
            return result

        return patch.object(distribute.subprocess, "run", side_effect=run), calls

    def test_fat_dylib_verifies_exact_slices_signature_and_dependencies(self):
        calls = []
        patcher, calls = self.verify_dylib_with_tools(calls=calls)
        with patcher:
            dependencies = distribute.verify_dylib(self.dylib)
        self.assertEqual(dependencies, [
            "/System/Library/Frameworks/Foundation.framework/Foundation"])
        self.assertIn(["lipo", str(self.dylib), "-verify_arch", "arm64", "arm64e"], calls)
        self.assertIn(["codesign", "--verify", "--strict", str(self.dylib)], calls)
        self.assertIn(["otool", "-arch", "all", "-L", str(self.dylib)], calls)

    def test_fat_dylib_rejects_missing_or_extra_architectures(self):
        for archs in ("arm64", "arm64e", "arm64 arm64e x86_64"):
            with self.subTest(architectures=archs):
                calls = []
                patcher, _ = self.verify_dylib_with_tools(archs=archs, calls=calls)
                with patcher, self.assertRaisesRegex(ValueError, "exactly arm64 and arm64e"):
                    distribute.verify_dylib(self.dylib)
                self.assertFalse(any(call[0] == "codesign" for call in calls))

    def test_fat_dylib_rejects_unsigned_and_missing_otool_slice(self):
        patcher, calls = self.verify_dylib_with_tools(signature_status=1)
        with patcher, self.assertRaises(subprocess.CalledProcessError):
            distribute.verify_dylib(self.dylib)
        self.assertFalse(any(call[0] == "otool" for call in calls))

        output = self.otool_slices().split("/tmp/RUIN.dylib (architecture arm64e):")[0]
        for missing_slice in (output, output.replace(" (architecture arm64)", "")):
            with self.subTest(header=missing_slice.splitlines()[0]):
                patcher, _ = self.verify_dylib_with_tools(otool_output=missing_slice)
                with patcher, self.assertRaisesRegex(ValueError, "one dependency list for each"):
                    distribute.verify_dylib(self.dylib)

    def test_fat_dylib_rejects_dependency_from_either_slice(self):
        external = "/opt/homebrew/lib/libexample.dylib"
        patcher, _ = self.verify_dylib_with_tools(
            otool_output=self.otool_slices(second_slice_dependency=external))
        with patcher, self.assertRaisesRegex(ValueError, "not an Apple system"):
            distribute.verify_dylib(self.dylib)

    def test_otool_install_name_is_ignored_once_per_architecture_and_deps_deduplicate(self):
        output = self.otool_slices()
        self.assertEqual(distribute.dependencies_from_otool(output), [
            "/System/Library/Frameworks/Foundation.framework/Foundation"])

    def test_rpath_parser_ignores_other_load_commands_and_preserves_spaces(self):
        output = """/tmp/RUIN.dylib:
Load command 0
          cmd LC_LOAD_DYLIB
      cmdsize 64
         name /usr/lib/swift/libswiftCore.dylib (offset 24)
Load command 1
          cmd LC_RPATH
      cmdsize 32
         path /usr/lib/swift (offset 12)
Load command 2
          cmd LC_RPATH
      cmdsize 56
         path @loader_path/Folder With Spaces (offset 12)
"""
        self.assertEqual(distribute.rpaths_from_otool(output),
                         ["/usr/lib/swift", "@loader_path/Folder With Spaces"])
        for invalid in ("cmd LC_RPATH\n", "cmd LC_RPATH\ncmd LC_CODE_SIGNATURE\n",
                        "cmd LC_RPATH\npath @loader_path\n"):
            with self.subTest(output=invalid), self.assertRaises(ValueError):
                distribute.rpaths_from_otool(invalid)

    def test_fat_dylib_checks_duplicate_rpaths_independently_in_both_slices(self):
        # One occurrence in each slice is valid; duplicate entries in either
        # individual slice are not, including paths unrelated to LiveContainer.
        patcher, _ = self.verify_dylib_with_tools()
        with patcher:
            distribute.verify_dylib(self.dylib, for_livecontainer=True)
        for arch in distribute.DYLIB_ARCHITECTURES:
            for path in (*distribute.LIVECONTAINER_RPATHS, "/usr/lib/swift"):
                patcher, _ = self.verify_dylib_with_tools(rpaths={arch: [path, path]})
                with self.subTest(architecture=arch, path=path), patcher, \
                        self.assertRaisesRegex(ValueError, f"{arch}: duplicate LC_RPATH"):
                    distribute.verify_dylib(self.dylib)

    def test_livecontainer_artifact_rejects_even_one_preimported_path(self):
        for arch in distribute.DYLIB_ARCHITECTURES:
            for path in distribute.LIVECONTAINER_RPATHS:
                patcher, _ = self.verify_dylib_with_tools(rpaths={arch: ["/usr/lib/swift", path]})
                with self.subTest(architecture=arch, path=path), patcher:
                    # These unique paths remain legal for ordinary dylib users.
                    distribute.verify_dylib(self.dylib)
                    with self.assertRaisesRegex(ValueError, "already added by LiveContainer"):
                        distribute.verify_dylib(self.dylib, for_livecontainer=True)


if __name__ == "__main__":
    unittest.main()
