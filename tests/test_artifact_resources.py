"""Detect missing/stale static resources independently in the released slices."""
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
from embed_resources import bundle_digest
from verify_embedded_resources import verify_embedded_resources, verify_slice_resources


def payload(files):
    return (bundle_digest(files).encode() + b"\0" +
            b"".join(name.encode() + b"\0" + data for name, data in files))


class ArtifactResourcesTests(unittest.TestCase):
    def test_catalogs_and_binary_images_must_match(self):
        files = [("Info.plist", b"bundle"), ("ja.lproj/Localizable.strings", b'"key" = "value";'),
                 ("tabler-eye@2x.png", bytes(range(256))), ("empty", b"")]
        data = payload(files)
        self.assertEqual(verify_slice_resources(data, files), bundle_digest(files))
        for broken in (data.replace(files[1][1], b"stale-catalog"),
                       data.replace(files[2][1], b"missing-icon"),
                       data.replace(b"tabler-eye@2x.png\0", b"other-name\0"),
                       data.replace(bundle_digest(files).encode(), b"old-digest")):
            with self.assertRaises(ValueError):
                verify_slice_resources(broken, files)

    def test_arm64e_cannot_borrow_arm64_resources(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            bundle = root / "Resources.bundle"
            bundle.mkdir()
            (bundle / "Info.plist").write_bytes(b"fixture-info")
            files = [("Info.plist", b"fixture-info")]
            calls = []

            def thin(arguments, **kwargs):
                architecture = arguments[arguments.index("-thin") + 1]
                calls.append(architecture)
                data = payload(files) if architecture == "arm64" else b"no-resources"
                Path(arguments[arguments.index("-output") + 1]).write_bytes(data)

            with patch("verify_embedded_resources.subprocess.run", side_effect=thin):
                with self.assertRaisesRegex(ValueError, "arm64e"):
                    verify_embedded_resources(root / "RUIN.dylib", bundle)
            self.assertEqual(calls, ["arm64", "arm64e"])


if __name__ == "__main__":
    unittest.main()
