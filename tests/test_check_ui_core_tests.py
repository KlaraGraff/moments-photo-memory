import importlib.util
from pathlib import Path
import tempfile
import unittest


ROOT = Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location(
    "check_ui_core_tests", ROOT / "scripts" / "check_ui_core_tests.py"
)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class CoreUITestManifestTests(unittest.TestCase):
    def test_checked_in_core_tests_exist(self):
        self.assertEqual(MODULE.check(), [])

    def test_each_non_comment_line_is_resolved_in_its_named_class(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            sources = root / "macos" / "Tests" / "MomentsUITests"
            sources.mkdir(parents=True)
            (sources / "Fixtures.swift").write_text(
                "final class FirstTests: XCTestCase {\n"
                "    func testSelectedTest() throws {\n"
                "    }\n"
                "}\n"
                "final class SecondTests: XCTestCase {\n"
                "    func testOtherTest() {\n"
                "    }\n"
                "}\n",
                encoding="utf-8",
            )
            manifest = root / "scripts"
            manifest.mkdir()
            manifest_file = manifest / "ui_core_tests.txt"
            manifest_file.write_text(
                "# Comment and blank lines are ignored.\n\n"
                "MomentsUITests/FirstTests/testSelectedTest\n",
                encoding="utf-8",
            )
            self.assertEqual(MODULE.check(root), [])

            manifest_file.write_text(
                "MomentsUITests/SecondTests/testSelectedTest\n",
                encoding="utf-8",
            )
            errors = MODULE.check(root)
            self.assertEqual(len(errors), 1)
            self.assertIn(
                "MomentsUITests/SecondTests/testSelectedTest", errors[0]
            )

    def test_malformed_and_wrong_target_ids_fail(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            sources = root / "macos" / "Tests" / "MomentsUITests"
            sources.mkdir(parents=True)
            (sources / "Fixtures.swift").write_text(
                "final class FirstTests: XCTestCase {\n"
                "    func testSelectedTest() {\n"
                "    }\n"
                "}\n",
                encoding="utf-8",
            )
            scripts = root / "scripts"
            scripts.mkdir()
            (scripts / "ui_core_tests.txt").write_text(
                "MomentsUITests/FirstTests\n"
                "OtherTarget/FirstTests/testSelectedTest\n",
                encoding="utf-8",
            )
            errors = MODULE.check(root)
            self.assertEqual(len(errors), 2)
            self.assertIn("invalid test ID", errors[0])
            self.assertIn("unexpected target", errors[1])


if __name__ == "__main__":
    unittest.main()
