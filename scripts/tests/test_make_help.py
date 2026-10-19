"""Run Make's help entry points with all operational commands blocked."""
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
MAKE = shutil.which("make")


class MakeHelpTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        (self.root / "scripts").mkdir()
        shutil.copyfile(ROOT / "Makefile", self.root / "Makefile")
        shutil.copyfile(ROOT / "scripts/make-help.py", self.root / "scripts/make-help.py")
        (self.root / "package-lock.json").write_text("{}")
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.calls = self.root / "operational-calls"
        blocked = f'printf "%s\\n" "$0 $*" >> {shlex.quote(str(self.calls))}\nexit 97\n'
        for name in ("git", "gh", "npm", "cargo", "sudo", "bash", "rm", "touch"):
            self.executable(name, "#!/bin/sh\n" + blocked)
        self.executable("python3", '#!/bin/sh\nif [ "$1" = scripts/make-help.py ]; then\n'
                        f'  exec {shlex.quote(sys.executable)} "$@"\nfi\n' + blocked)
        self.executable("uname", "#!/bin/sh\nprintf 'Darwin\\n'\n")
        self.env = {key: value for key, value in os.environ.items()
                    if key not in ("MAKEFLAGS", "MFLAGS", "MAKEOVERRIDES", "MAKELEVEL", "HELP")}
        self.env["PATH"] = str(self.bin)

    def executable(self, name, content):
        path = self.bin / name
        path.write_text(content)
        path.chmod(0o755)

    def make(self, *args, success=True):
        result = subprocess.run([MAKE, "--no-print-directory", *args], cwd=self.root,
                                env=self.env, capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode == 0, success, result.stdout + result.stderr)
        self.assertFalse(self.calls.exists(), self.calls.read_text() if self.calls.exists() else "")
        return result.stdout + result.stderr

    def test_default_and_overview_explain_help_and_examples(self):
        for args in ((), ("help",), ("HELP=1",)):
            with self.subTest(args=args):
                output = self.make(*args)
                self.assertIn("make help release", output)
                self.assertIn("make release --help shows Make's own help", output)
                self.assertIn("make reset-local DRY_RUN=1", output)

    def test_every_command_has_help_without_running_anything(self):
        targets = [target for match in re.finditer(r"^([a-zA-Z_ -]+):.*## ",
                   (self.root / "Makefile").read_text(), re.MULTILINE) for target in match[1].split()]
        for target in targets:
            for args in (("help", target), (target, "help"), ("help-" + target,), (target, "HELP=1")):
                with self.subTest(target=target, args=args):
                    output = self.make(*args)
                    if target != "help":
                        self.assertIn("make " + target + " - ", output)
                        self.assertIn("Usage: make ", output)

    def test_release_help_describes_revision_and_promotion(self):
        output = self.make("help", "release")
        self.assertIn("Usage: make release [REVISION=<commit-sha>]", output)
        self.assertIn("Without it, uses current main.", output)
        self.assertIn("asks whether to run Release promote", output)
        self.assertIn("docs/releasing.md", output)

    def test_multiple_parallel_goals_skip_recipes_and_prerequisites(self):
        output = self.make("-j8", "build", "install-rpm", "release", "deploy", "clean", "reset-local", "help")
        for target in ("build", "install-rpm", "release", "deploy", "clean", "reset-local"):
            self.assertIn("make " + target + " - ", output)
        self.assertFalse((self.root / "node_modules").exists())

    def test_unknown_help_refuses_all_commands(self):
        for args in (("help", "release", "does-not-exist"), ("help-does-not-exist",)):
            output = self.make(*args, success=False)
            self.assertIn("Unknown command: does-not-exist. Run make help", output)

    def test_unknown_goal_is_not_evaluated_by_the_shell(self):
        output = self.make("help", "release|touch", "unexpected-file", success=False)
        self.assertIn("Unknown command: release|touch, unexpected-file", output)
        self.assertFalse((self.root / "unexpected-file").exists())

    def test_native_help_is_still_make_help(self):
        output = self.make("release", "--help")
        self.assertIn("Usage: make", output)
        self.assertNotIn("Starts and follows Release build", output)

    def test_normal_commands_keep_their_recipes(self):
        output = self.make("-n", "release", "REVISION=1a2b3c4", "HELP=0")
        self.assertIn('python3 scripts/release.py --revision "1a2b3c4"', output)
        self.assertNotIn("scripts/make-help.py", output)
        output = self.make("-n", "build")
        self.assertIn("npm ci", output)
        self.assertIn("npm run desktop:pack", output)
        self.assertIn("--source addon/Goldbook", output)

    def test_missing_version_points_to_command_help(self):
        for target in ("version", "prepare-release"):
            output = self.make(target, success=False)
            self.assertIn("VERSION is required. See make help " + target, output)


if __name__ == "__main__":
    unittest.main()
