"""Verify that generated C resources preserve the shipped files byte for byte."""
import importlib.util
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("embed_resources", ROOT / "tools/embed_resources.py")
embed_resources = importlib.util.module_from_spec(spec)
spec.loader.exec_module(embed_resources)


class EmbeddedResourceTests(unittest.TestCase):
    def test_shipped_bundle_round_trips_through_c(self):
        compiler = shutil.which("cc")
        if not compiler:
            self.skipTest("A C compiler is required for the generated-header fixture")
        files = embed_resources.bundle_files(ROOT / "resources/RUINResources.bundle")
        # Exercise zero-length files and C string escaping as well as every
        # shipped .strings catalog, Info.plist, and binary icon.
        files += [('empty "quote" \\ 日本.txt', b""), ("binary", bytes(range(256)))]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "EmbeddedResources.h").write_text(embed_resources.render_header(files))
            source = root / "fixture.c"
            source.write_text(r'''
#include <stdio.h>
#include <string.h>
#include "EmbeddedResources.h"
int main(void) {
    puts(RUINEmbeddedResourceDigest);
    for (size_t i = 0; i < sizeof(RUINEmbeddedResourceFiles) / sizeof(RUINEmbeddedResourceFiles[0]); i++) {
        const RUINEmbeddedResourceFile *file = &RUINEmbeddedResourceFiles[i];
        fwrite(file->path, 1, strlen(file->path) + 1, stdout);
        printf("%zu\n", file->length);
        fwrite(file->bytes, 1, file->length, stdout);
    }
    return ferror(stdout) != 0;
}
''')
            executable = root / "fixture"
            subprocess.run([compiler, "-std=c11", "-Wall", "-Wextra", "-Werror", str(source), "-o", str(executable)],
                           check=True, capture_output=True)
            output = subprocess.run([str(executable)], check=True, capture_output=True).stdout
        expected = (embed_resources.bundle_digest(files) + "\n").encode("ascii")
        for name, data in files:
            expected += name.encode("utf-8") + b"\0" + str(len(data)).encode("ascii") + b"\n" + data
        self.assertEqual(output, expected)

    def test_digest_tracks_paths_contents_and_removals(self):
        files = [("Info.plist", b"plist"), ("en.lproj/Localizable.strings", b"text")]
        digest = embed_resources.bundle_digest(files)
        for changed in (files[:1], files + [("new", b"")],
                        [files[0], ("ja.lproj/Localizable.strings", b"text")],
                        [files[0], (files[1][0], b"changed")]):
            self.assertNotEqual(embed_resources.bundle_digest(changed), digest)

    def test_generator_is_deterministic_and_rejects_symlinks(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            bundle = root / "RUINResources.bundle"
            bundle.mkdir()
            (bundle / "Info.plist").write_bytes(b"plist")
            (bundle / "z.txt").write_bytes(b"z")
            (bundle / "a.txt").write_bytes(b"a")
            original = embed_resources.render_header(embed_resources.bundle_files(bundle))
            (bundle / "a.txt").unlink()
            (bundle / "a.txt").write_bytes(b"a")
            self.assertEqual(embed_resources.render_header(embed_resources.bundle_files(bundle)), original)
            self.assertNotIn(str(root), original)
            (bundle / "link").symlink_to(bundle / "a.txt")
            with self.assertRaisesRegex(ValueError, "symlink"):
                embed_resources.bundle_files(bundle)


if __name__ == "__main__":
    unittest.main()
