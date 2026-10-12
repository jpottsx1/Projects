"""Output file names.

A track's name is free text and dots are common in it -- "Sheila E.",
"Pt. 1", "03. Phil Collins", and the processed copy's own label
"sub+10.8dB". None of them is an extension, and treating the text after
the last dot as one wrote a track's A and B copies to the same file.
"""

from __future__ import annotations

import sys
import tempfile
import unittest
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from loudnesslab import write  # noqa: E402

RATE = 48000


class TestDotsInNamesAreKept(unittest.TestCase):

    def test_the_whole_name_survives_and_gains_the_extension(self):
        tone = np.zeros((RATE // 10, 2), dtype=np.float32)
        with tempfile.TemporaryDirectory() as tmp:
            for name in ("012 - Sheila E. - A Love Bizarre -- A original",
                         "021 - Prince - 1999 -- B sub+10.8dB punch+4dB",
                         "024 - 03. Phil Collins - Take Me Home"):
                written = write.write(Path(tmp) / name, tone, RATE, fmt="flac")
                self.assertEqual(written.name, name + ".flac")
                self.assertTrue(written.exists())

    def test_a_and_b_of_a_dotted_name_are_two_files(self):
        tone = np.zeros((RATE // 10, 2), dtype=np.float32)
        with tempfile.TemporaryDirectory() as tmp:
            a = write.write(Path(tmp) / "Sheila E. - Glamorous Life -- A original",
                            tone, RATE, fmt="flac")
            b = write.write(Path(tmp) / "Sheila E. - Glamorous Life -- B punch+4dB",
                            tone, RATE, fmt="flac")
            self.assertNotEqual(a, b)
            self.assertTrue(a.exists() and b.exists())


if __name__ == "__main__":
    unittest.main()
