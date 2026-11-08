import json
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / "tests/fixtures/version-mappings.json"
VALID_STATUSES = {"unsupported", "unverified", "verified"}


class VersionMappingManifestTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.data = json.loads(MANIFEST.read_text())
        cls.mappings = cls.data["mappings"]

    def test_identities_are_unique(self):
        identities = [tuple(row["host"][key] for key in ("version", "build", "uuid"))
                      for row in self.mappings]
        self.assertEqual(len(identities), len(set(identities)))

    def test_all_mapped_features_have_typed_status(self):
        for mapping in self.mappings:
            self.assertIn(mapping["host"]["supportStatus"], VALID_STATUSES)
            for feature in mapping["themes"].values():
                self.assertIn(feature["status"], VALID_STATUSES)
            self.assertIn(mapping["messaging"]["readBoundary"]["status"], VALID_STATUSES)
            self.assertIn(mapping["messaging"]["unsendOperation"]["parserStatus"], VALID_STATUSES)
            self.assertIn(mapping["messaging"]["unsendOperation"]["lookupStatus"], VALID_STATUSES)
            self.assertIn(mapping["nativeTabs"]["status"], VALID_STATUSES)

    def test_26_17_keeps_unmapped_capabilities_unavailable(self):
        mapping = next(row for row in self.mappings if row["host"]["version"] == "26.17.0")
        self.assertEqual(mapping["themes"]["shopEligibility"]["status"], "unsupported")
        self.assertEqual(mapping["messaging"]["unsendOperation"]["lookupStatus"], "unsupported")
        self.assertEqual(mapping["messaging"]["unsendOperation"]["orderedLookupReturnAddresses"], [])
        self.assertEqual(mapping["themes"]["shopEligibility"]["anchors"], [])


if __name__ == "__main__":
    unittest.main()
