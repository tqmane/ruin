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
            self.assertIn(mapping["messaging"]["readUntilABIStatus"], VALID_STATUSES)
            self.assertIn(mapping["nativeTabs"]["status"], VALID_STATUSES)

    def test_26_17_read_adapter_is_scoped_and_host_remains_unverified(self):
        mapping = next(row for row in self.mappings if row["host"]["version"] == "26.17.0")
        eligibility = mapping["themes"]["shopEligibility"]
        self.assertEqual(mapping["host"]["supportStatus"], "unverified")
        self.assertEqual(eligibility["status"], "unsupported")
        self.assertEqual(eligibility["nativeReadAdapterStatus"], "verified")
        self.assertEqual(eligibility["shopSchemeScopeStatus"], "unverified")
        self.assertEqual(eligibility["modeReturnPC"], "0x106af1c60")
        self.assertEqual(eligibility["modeCopyReturnPC"], "0x106ad9b30")
        self.assertEqual(eligibility["accountReturnPC"], "0x106ad9cd4")
        self.assertEqual(eligibility["plainModeStackOffset"], "0xb4")
        self.assertIsNone(eligibility["themeActionReturnPC"])
        self.assertIsNone(eligibility["preflightAccountReturnPC"])
        self.assertEqual(eligibility["accountChain"], [])
        self.assertEqual(eligibility["accountChainAlternatives"], [
            {"count": 4, "returnPCs": ["0x1028b6154", "0x1028b5abc", "0x1028b5a68", "0x1028b5cf4"]},
            {"count": 3, "returnPCs": ["0x1028b6154", "0x1028b5a74", "0x1028b5cf4"]}
        ])
        self.assertEqual(eligibility["shopSchemeReturnPCs"], ["0x1003ac4ac", "0x1003ac4b8"])
        self.assertEqual(eligibility["shopSchemeHandlerReturnPCs"], ["0x1003acd98", "0x1003acf20"])
        self.assertGreater(len(eligibility["anchors"]), 0)
        self.assertEqual(mapping["messaging"]["unsendOperation"]["lookupStatus"], "verified")
        self.assertEqual(len(mapping["messaging"]["unsendOperation"]["orderedLookupReturnAddresses"]), 6)
        self.assertEqual(mapping["messaging"]["readUntilABIStatus"], "verified")

    def test_26_16_keeps_its_legacy_fixed_account_chain(self):
        mapping = next(row for row in self.mappings if row["host"]["version"] == "26.16.0")
        eligibility = mapping["themes"]["shopEligibility"]
        self.assertEqual(eligibility["accountChain"], ["0x10285e8a0", "0x10285e1c0", "0x10285e440"])
        self.assertEqual(eligibility["accountChainAlternatives"], [])
        self.assertEqual(eligibility["nativeReadAdapterStatus"], "verified")
        self.assertEqual(eligibility["shopSchemeScopeStatus"], "verified")


if __name__ == "__main__":
    unittest.main()
