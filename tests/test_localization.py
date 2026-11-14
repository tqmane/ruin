import json
from pathlib import Path
import plistlib
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]
BUNDLE = ROOT / "resources/RUINResources.bundle"
LANGUAGES = ("en", "ja", "ko", "zh-Hans", "zh-Hant")
FORMAT = re.compile(r"%(?:\d+\$)?[-+#0 ]*(?:\d+|\*)?(?:\.(?:\d+|\*))?(?:hh|ll|[hljztLq])?[@diuoxXfFeEgGaAcCsSp%]")
TOKENS = re.compile(r'//[^\n]*|/\*.*?\*/|@?"(?:\\.|[^"\\])*"|[A-Za-z_]\w*|[()\[\]?:]', re.S)


def localized_literal_keys(source, swift=False):
    """Collect direct keys and literal ternary branches, ignoring comments/messages."""
    tokens = [match[0] for match in TOKENS.finditer(source) if not match[0].startswith(("//", "/*"))]
    keys = set()
    for index, token in enumerate(tokens[:-1]):
        if token != "RUINLocalizedString" or tokens[index + 1] != "(":
            continue
        depth, brackets = 1, 0
        for position in range(index + 2, len(tokens)):
            token = tokens[position]
            if token == "(":
                depth += 1
            elif token == ")":
                depth -= 1
                if not depth:
                    break
            elif token == "[":
                brackets += 1
            elif token == "]":
                brackets -= 1
            elif not brackets and depth == 1 and (token.startswith('@"') or (swift and token.startswith('"'))):
                keys.add(json.loads(token[1:] if token.startswith("@") else token))
    return keys


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
            if path.suffix not in (".h", ".m", ".x", ".xm", ".mm", ".swift"):
                continue
            for key in localized_literal_keys(path.read_text(), swift=path.suffix == ".swift"):
                self.assertIn(key, catalogs["en"], f"{path.relative_to(ROOT)}: {key}")

    def test_ternary_keys_and_escaped_literals(self):
        source = r'''
            // RUINLocalizedString(@"not a key")
            /* RUINLocalizedString(@"also not a key") */
            RUINLocalizedString(flag ? @"First" : @"Second");
            RUINLocalizedString(@"Quoted \"key\"\nnext");
            RUINLocalizedString([value isEqual:@"protocol"] ? @"Yes" : @"No");
        '''
        keys = localized_literal_keys(source)
        self.assertEqual(keys, {"First", "Second", 'Quoted "key"\nnext', "Yes", "No"})
        with self.assertRaises(AssertionError):
            self.assertTrue(keys <= {"First", 'Quoted "key"\nnext', "Yes", "No"})
        self.assertEqual(localized_literal_keys('RUINLocalizedString(flag ? "A" : "B")', swift=True), {"A", "B"})


if __name__ == "__main__":
    unittest.main()
