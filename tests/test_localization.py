import json
from pathlib import Path
import plistlib
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]
BUNDLE = ROOT / "resources/RUINResources.bundle"
LANGUAGES = ("en", "ja", "ko", "zh-Hans", "zh-Hant")
FORMAT = re.compile(r"%(?:\d+\$)?[-+#0 ]*(?:\d+|\*)?(?:\.(?:\d+|\*))?(?:hh|ll|[hljztLq])?[@diuoxXfFeEgGaAcCsSp%]")
LITERAL = r'@"((?:\\.|[^"\\])*)"'


class LocalizationTests(unittest.TestCase):
    def test_catalogs_and_format_arguments(self):
        catalogs = {language: plistlib.loads((BUNDLE / f"{language}.lproj/Localizable.strings").read_bytes())
                    for language in LANGUAGES}
        source = catalogs["ja"]
        self.assertTrue(source)
        for language, catalog in catalogs.items():
            self.assertEqual(set(source), set(catalog), language)
            for key, value in catalog.items():
                self.assertIsInstance(value, str)
                self.assertTrue(value, (language, key))
                self.assertEqual(FORMAT.findall(key), FORMAT.findall(value), (language, key))
        for path in (ROOT / "src").rglob("*"):
            if path.suffix not in (".m", ".x"):
                continue
            for match in re.finditer(r"RUINLocalizedString\(\s*" + LITERAL, path.read_text()):
                key = json.loads('"' + match[1] + '"')
                self.assertTrue(key in catalogs["en"], f"{path.relative_to(ROOT)}: {key}")


if __name__ == "__main__":
    unittest.main()
