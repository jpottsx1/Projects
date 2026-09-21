"""Profile loading and precedence.

A profile fixes the policy; measurement fixes the treatment. The tests that
matter are about precedence -- an explicit flag must beat a profile, or a
profile could never be overridden for one run -- and about rejecting typos,
since a misspelled key that is silently ignored is a policy that quietly
differs from the one written down.
"""

from __future__ import annotations

import contextlib
import io
import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from loudnesslab import cli, profiles  # noqa: E402


class TestLoading(unittest.TestCase):
    def test_built_ins_are_always_present(self):
        loaded = profiles.load()
        for name in profiles.BUILT_IN:
            self.assertIn(name, loaded)

    def test_a_missing_named_file_is_an_error(self):
        """Silence would mean running under different settings than asked
        for, which is the one thing a profile must not allow."""
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaises(profiles.ProfileError):
                profiles.load(Path(tmp) / "absent.json")

    def test_a_file_adds_and_overrides_by_name(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "profiles.json"
            path.write_text(json.dumps({
                "disco-70s": {"description": "d", "max_amount": 8.0},
                "level-only": {"target": -18.0},
            }))
            loaded = profiles.load(path)
        self.assertIn("disco-70s", loaded)
        self.assertIn("level-only", loaded)
        self.assertEqual(profiles.resolve(loaded, "disco-70s")["max_amount"], 8.0)
        self.assertEqual(profiles.resolve(loaded, "level-only")["target"], -18.0)
        # Overriding one key must not discard the rest of the built-in.
        self.assertEqual(profiles.resolve(loaded, "level-only")["estimator"],
                         "s_p95")

    def test_an_unknown_key_is_rejected(self):
        """A silently ignored typo is a policy that differs from the written
        one, which is the failure this whole idea exists to prevent."""
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "profiles.json"
            path.write_text(json.dumps({"x": {"maximum_amount": 8.0}}))
            with self.assertRaises(profiles.ProfileError) as caught:
                profiles.load(path)
        self.assertIn("maximum_amount", str(caught.exception))

    def test_malformed_json_is_reported(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "profiles.json"
            path.write_text("{not json")
            with self.assertRaises(profiles.ProfileError):
                profiles.load(path)

    def test_an_unknown_profile_name_lists_what_exists(self):
        loaded = dict(profiles.BUILT_IN)
        with self.assertRaises(profiles.ProfileError) as caught:
            profiles.resolve(loaded, "nope")
        self.assertIn("level-only", str(caught.exception))


class TestPrecedence(unittest.TestCase):
    def test_an_explicit_flag_beats_the_profile(self):
        settings = {"target": -16.0}
        self.assertEqual(profiles.setting(-20.0, settings, "target"), -20.0)

    def test_the_profile_beats_the_default(self):
        self.assertEqual(profiles.setting(None, {"target": -16.0}, "target"),
                         -16.0)

    def test_the_default_applies_when_neither_says(self):
        self.assertEqual(profiles.setting(None, {}, "target"),
                         profiles.FIELDS["target"])

    def test_a_flag_equal_to_the_default_still_counts_as_explicit(self):
        """Flags default to None rather than to a value precisely so this
        case can be told apart."""
        default = profiles.FIELDS["target"]
        self.assertEqual(profiles.setting(default, {"target": -9.0}, "target"),
                         default)


class TestDescribe(unittest.TestCase):
    def test_lists_every_profile_and_the_settable_keys(self):
        text = profiles.describe(dict(profiles.BUILT_IN))
        for name in profiles.BUILT_IN:
            self.assertIn(name, text)
        self.assertIn("max_amount", text)

    def test_the_command_prints_them(self):
        buffer = io.StringIO()
        with contextlib.redirect_stdout(buffer):
            code = cli.main(["profiles"])
        self.assertEqual(code, 0)
        self.assertIn("level-only", buffer.getvalue())


if __name__ == "__main__":
    unittest.main()
