import tempfile
import unittest
from pathlib import Path

from scripts.keep_last_token import convert_file, extract_tokens


class KeepLastTokenTests(unittest.TestCase):
    def test_extracts_last_field_and_keeps_token_only_lines(self):
        self.assertEqual(
            extract_tokens([
                "user@example.com----password----token-1\n",
                "token-2\n",
                "\n",
                "user----password----token----with-separator\n",
            ]),
            ["token-1", "token-2", "with-separator"],
        )

    def test_converts_in_place_and_removes_blank_lines(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            path = Path(temp_dir) / "accounts.txt"
            path.write_text("a----p----t1\n\nb----p----t2\n", encoding="utf-8")

            count = convert_file(path)

            self.assertEqual(count, 2)
            self.assertEqual(path.read_text(encoding="utf-8"), "t1\nt2\n")

    def test_can_write_to_separate_output(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            source = Path(temp_dir) / "accounts.txt"
            output = Path(temp_dir) / "tokens.txt"
            source.write_text("a----p----t1\n", encoding="utf-8")

            convert_file(source, output)

            self.assertEqual(source.read_text(encoding="utf-8"), "a----p----t1\n")
            self.assertEqual(output.read_text(encoding="utf-8"), "t1\n")


if __name__ == "__main__":
    unittest.main()
