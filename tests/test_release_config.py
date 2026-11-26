"""Release identity, entitlements and the Developer ID release script.

The Mac build itself runs on the hosted runner; these checks cover what a
Linux sandbox can see: the committed configuration and the script's plan
(--dry-run prints the commands instead of running them).
"""
import os
import plistlib
import re
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MACOS = ROOT / "macos"
SCRIPT = ROOT / "scripts" / "release_mac.sh"
BUNDLE_ID = "com.momentsphotomemory.Moments"
CONTAINER = "iCloud.com.momentsphotomemory.Moments"


def xcconfig(name):
    values = {}
    for line in (MACOS / "Config" / name).read_text(encoding="utf-8").splitlines():
        line = line.split("//", 1)[0].strip()
        if "=" in line and not line.startswith("#"):
            key, value = line.split("=", 1)
            values[key.strip()] = value.strip()
    return values


class ReleaseConfigurationTests(unittest.TestCase):
    def test_signing_config_names_the_final_identity_and_stays_unsigned(self):
        values = xcconfig("Signing.xcconfig")
        self.assertEqual(values["MOMENTS_BUNDLE_ID"], BUNDLE_ID)
        self.assertEqual(values["MOMENTS_ICLOUD_CONTAINER"], CONTAINER)
        self.assertEqual(values["PRODUCT_BUNDLE_IDENTIFIER"], "$(MOMENTS_BUNDLE_ID)")
        self.assertEqual(values["CODE_SIGNING_ALLOWED"], "NO")
        # CI signs UI-test builds ad hoc; an ad-hoc app claiming iCloud is
        # killed at launch, so committed builds carry no entitlements.
        self.assertEqual(values["MOMENTS_ENTITLEMENTS"], "")
        self.assertEqual(values["MOMENTS_HARDENED_RUNTIME"], "NO")

    def test_local_example_does_not_override_the_identity(self):
        values = xcconfig("Local.xcconfig.example")
        self.assertNotIn("MOMENTS_BUNDLE_ID", values)
        self.assertNotIn("MOMENTS_ICLOUD_CONTAINER", values)

    def test_entitlements_declare_cloudkit_push_and_photos(self):
        with open(MACOS / "Config" / "Moments.entitlements", "rb") as handle:
            entitlements = plistlib.load(handle)
        self.assertEqual(entitlements["com.apple.developer.icloud-services"], ["CloudKit"])
        self.assertEqual(
            entitlements["com.apple.developer.icloud-container-identifiers"],
            ["$(MOMENTS_ICLOUD_CONTAINER)"],
        )
        self.assertEqual(entitlements["com.apple.developer.aps-environment"], "$(MOMENTS_APS_ENVIRONMENT)")
        self.assertIs(entitlements["com.apple.security.personal-information.photos-library"], True)
        # Not sandboxed: the app reads folders and other placeholder builds' settings.
        self.assertNotIn("com.apple.security.app-sandbox", entitlements)

    def test_info_plist_exposes_the_container_and_accepts_shares(self):
        with open(MACOS / "Config" / "Moments-Info.plist", "rb") as handle:
            info = plistlib.load(handle)
        self.assertEqual(info["MomentsCloudKitContainerIdentifier"], "$(MOMENTS_ICLOUD_CONTAINER)")
        self.assertIs(info["CKSharingSupported"], True)

    def test_project_wires_entitlements_version_icon_and_runtime_into_the_app_only(self):
        project = (MACOS / "project.yml").read_text(encoding="utf-8")
        app_block = project.split("  Moments:\n", 1)[1].split("\n  MomentsTests:\n", 1)[0]
        for setting in (
            "INFOPLIST_FILE: Config/Moments-Info.plist",
            "CODE_SIGN_ENTITLEMENTS: $(MOMENTS_ENTITLEMENTS)",
            "ENABLE_HARDENED_RUNTIME: $(MOMENTS_HARDENED_RUNTIME)",
            "ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon",
        ):
            self.assertIn(setting, app_block)
        self.assertRegex(app_block, r'MARKETING_VERSION: "\d+\.\d+\.\d+"')
        self.assertEqual(project.count("CODE_SIGN_ENTITLEMENTS"), 1)
        self.assertIn("ARCHS: arm64", project)

    def test_app_icon_set_has_every_mac_slot(self):
        import json
        contents = json.loads(
            (MACOS / "Sources/Moments/Assets.xcassets/AppIcon.appiconset/Contents.json").read_text(encoding="utf-8")
        )
        slots = {(image["size"], image["scale"]) for image in contents["images"] if image["idiom"] == "mac"}
        expected = {(f"{p}x{p}", f"{s}x") for p in (16, 32, 128, 256, 512) for s in (1, 2)}
        self.assertEqual(slots, expected)
        folder = MACOS / "Sources/Moments/Assets.xcassets/AppIcon.appiconset"
        for image in contents["images"]:
            points = int(image["size"].split("x")[0])
            pixels = points * int(image["scale"][0])
            data = (folder / image["filename"]).read_bytes()
            self.assertEqual(data[:8], b"\x89PNG\r\n\x1a\n", image["filename"])
            width, height = int.from_bytes(data[16:20], "big"), int.from_bytes(data[20:24], "big")
            self.assertEqual((width, height), (pixels, pixels), image["filename"])


class ReleaseScriptTests(unittest.TestCase):
    def run_script(self, *arguments, team="ABCDE12345"):
        environment = dict(os.environ)
        environment.pop("MOMENTS_TEAM_ID", None)
        if team is not None:
            environment["MOMENTS_TEAM_ID"] = team
        return subprocess.run(
            ["bash", str(SCRIPT), "--dry-run", *arguments],
            cwd=ROOT, env=environment, capture_output=True, text=True,
        )

    def test_dry_run_plans_archive_export_checks_and_notarization(self):
        with tempfile.TemporaryDirectory() as directory:
            out = Path(directory) / "builds.noindex" / "x"
            result = self.run_script("--notarize", "--out", str(out))
            self.assertEqual(result.returncode, 0, result.stderr)
            plan = result.stdout
            self.assertIn("xcodebuild archive", plan)
            self.assertIn("ARCHS=arm64", plan)
            self.assertIn("MOMENTS_APS_ENVIRONMENT=development", plan)
            self.assertIn("MOMENTS_ENTITLEMENTS=Config/Moments.entitlements", plan)
            self.assertIn("MOMENTS_HARDENED_RUNTIME=YES", plan)
            self.assertIn("DEVELOPMENT_TEAM=ABCDE12345", plan)
            self.assertIn("xcodebuild -exportArchive", plan)
            self.assertIn("check_app_archs.sh", plan)
            self.assertIn("check_date_symbols.sh", plan)
            self.assertIn("notarytool submit", plan)
            self.assertIn("--keychain-profile moments-notary", plan)
            self.assertIn("stapler staple", plan)
            self.assertNotIn("git tag", plan)
            self.assertNotIn("git push", plan)
            with open(out / "ExportOptions.plist", "rb") as handle:
                options = plistlib.load(handle)
            self.assertEqual(options["method"], "developer-id")
            self.assertEqual(options["teamID"], "ABCDE12345")
            self.assertEqual(options["iCloudContainerEnvironment"], "Development")

    def test_without_notarize_nothing_goes_to_apple(self):
        with tempfile.TemporaryDirectory() as directory:
            result = self.run_script("--out", str(Path(directory) / "b.noindex"))
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertNotIn("notarytool", result.stdout)
            self.assertIn("notarized: no", result.stdout)

    def test_production_switches_push_and_cloudkit_environment(self):
        with tempfile.TemporaryDirectory() as directory:
            out = Path(directory) / "b.noindex"
            result = self.run_script("--cloudkit-env", "production", "--out", str(out))
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("MOMENTS_APS_ENVIRONMENT=production", result.stdout)
            with open(out / "ExportOptions.plist", "rb") as handle:
                self.assertEqual(plistlib.load(handle)["iCloudContainerEnvironment"], "Production")

    def test_refuses_output_outside_a_noindex_folder(self):
        with tempfile.TemporaryDirectory() as directory:
            result = self.run_script("--out", str(Path(directory) / "plain"))
            self.assertEqual(result.returncode, 2)
            self.assertIn(".noindex", result.stderr)

    def test_refuses_without_a_team(self):
        if (MACOS / "Config" / "Local.xcconfig").exists():
            self.skipTest("a local signing config is present")
        result = self.run_script(team=None)
        self.assertEqual(result.returncode, 1)
        self.assertIn("DEVELOPMENT_TEAM", result.stderr)

    def test_refuses_an_unknown_cloudkit_environment(self):
        result = self.run_script("--cloudkit-env", "staging")
        self.assertEqual(result.returncode, 2)

    def test_script_holds_no_credentials(self):
        text = SCRIPT.read_text(encoding="utf-8")
        self.assertIsNone(re.search(r"--password\s+\S", text))
        self.assertNotIn("APPLE_ID=", text)


if __name__ == "__main__":
    unittest.main()
