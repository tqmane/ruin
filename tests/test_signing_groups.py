"""Signing must not infer App Group purpose from entitlement order."""
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
from package import app_group_mapping


class SigningGroupsTests(unittest.TestCase):
    def test_unrelated_profile_groups_do_not_switch_storage(self):
        groups = ['group.profile.one', 'group.profile.two', 'group.com.linecorp.line']
        for allowed in (groups, list(reversed(groups)), []):
            self.assertEqual(app_group_mapping({}, {'com.apple.security.application-groups': allowed}), {})

    def test_explicit_authorized_binding_is_preserved(self):
        mapping = {'group.com.linecorp.line': 'group.profile.line'}
        result = app_group_mapping({'RUINAppGroupMap': mapping},
            {'com.apple.security.application-groups': ['group.profile.other', 'group.profile.line']})
        self.assertEqual(result, mapping)
        self.assertIsNot(result, mapping)

    def test_invalid_or_unavailable_binding_is_not_reassigned(self):
        for mapping in (None, [], {'group.com.linecorp.line': 'group.missing'},
                        {'group.other.app': 'group.profile.line'}, {'group.com.linecorp.line': 1}):
            with self.assertRaises(ValueError):
                app_group_mapping({'RUINAppGroupMap': mapping},
                    {'com.apple.security.application-groups': ['group.profile.line']})


if __name__ == '__main__':
    unittest.main()
