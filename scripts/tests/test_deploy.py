import importlib.util
import io
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from contextlib import redirect_stdout
from unittest import mock

SCRIPT = Path(__file__).resolve().parents[2] / "scripts/deploy-ovh.py"
spec = importlib.util.spec_from_file_location("deploy_ovh", SCRIPT)
deployment = importlib.util.module_from_spec(spec)
spec.loader.exec_module(deployment)
REVISION = "a" * 40
IMAGE = deployment.REPOSITORY + "@sha256:" + "b" * 64


class DeploymentTest(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        self.env_file = self.root / ".env"
        self.original = "UPLOAD_TOKEN=test-token\nGOLDBOOK_HOST=gold.example.com\nGOLDBOOK_BIND=127.0.0.1\n"
        self.env_file.write_text(self.original)
        self.env_file.chmod(0o600)
        patch = mock.patch.object(deployment, "ROOT", self.root)
        patch.start()
        self.addCleanup(patch.stop)
        self.active_image = "goldbook"
        self.healthy = True
        self.label = REVISION
        self.starts = []
        self.registry_config = None

    def docker(self, args, **options):
        self.registry_config = Path(options["env"]["DOCKER_CONFIG"])
        self.assertTrue(self.registry_config.is_dir())
        stdout = ""
        if args[:2] == ("docker", "inspect"):
            if len(args) == 3:
                stdout = json.dumps([{"Config": {"Labels": {"org.opencontainers.image.revision": self.label}},
                                      "RepoDigests": [IMAGE]}])
            elif args[-1] == "{{.Config.Image}}":
                stdout = self.active_image
            else:
                stdout = "healthy" if self.healthy else "unhealthy"
        elif args[:2] == ("docker", "compose"):
            if "ps" in args:
                stdout = "container-id"
            else:
                configured = next((line.split("=", 1)[1] for line in self.env_file.read_text().splitlines()
                                   if line.startswith("GOLDBOOK_IMAGE=")), "goldbook")
                if "config" in args:
                    stdout = configured
                elif "up" in args:
                    self.active_image = configured
                    self.starts.append(configured)
                    self.assertIn("--no-build", args)
                    self.assertIn(str(self.root / "app/server/compose.traefik.yaml"), args)
        return subprocess.CompletedProcess(args, 0, stdout=stdout, stderr="")

    def run_deploy(self):
        with mock.patch.object(deployment.subprocess, "run", side_effect=self.docker), redirect_stdout(io.StringIO()):
            deployment.deploy(REVISION, "test-registry-token")

    def test_first_deploy_pins_digest_preserves_settings_and_cleans_registry_credentials(self):
        self.run_deploy()
        self.assertEqual(self.env_file.read_text(), self.original + "GOLDBOOK_IMAGE=" + IMAGE + "\n")
        self.assertEqual(self.starts, [IMAGE])
        backup, = self.root.glob(".env.before-*")
        self.assertEqual(backup.read_text(), self.original)
        self.assertEqual(backup.stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.env_file.stat().st_mode & 0o777, 0o600)
        self.assertFalse(self.registry_config.exists())

    def test_verify_only_does_not_change_running_service_or_configuration(self):
        with mock.patch.object(deployment.subprocess, "run", side_effect=self.docker), redirect_stdout(io.StringIO()):
            deployment.deploy(REVISION, "test-registry-token", verify_only=True)
        self.assertEqual(self.env_file.read_text(), self.original)
        self.assertEqual(self.starts, [])
        self.assertEqual(self.active_image, "goldbook")
        self.assertEqual(list(self.root.glob(".env.before-*")), [])

    def test_repeated_deploy_keeps_one_image_setting(self):
        self.run_deploy()
        self.run_deploy()
        self.assertEqual(self.env_file.read_text(), self.original + "GOLDBOOK_IMAGE=" + IMAGE + "\n")
        self.assertEqual(self.starts, [IMAGE, IMAGE])

    def test_unhealthy_deploy_restores_previous_image_and_configuration(self):
        self.healthy = False
        with self.assertRaisesRegex(RuntimeError, "Goldbook is not healthy"):
            self.run_deploy()
        self.assertEqual(self.starts, [IMAGE, "goldbook"])
        self.assertEqual(self.active_image, "goldbook")
        self.assertEqual(self.env_file.read_text(), self.original)
        self.assertFalse(self.registry_config.exists())

    def test_wrong_revision_stops_before_changing_configuration(self):
        self.label = "c" * 40
        with self.assertRaisesRegex(RuntimeError, "Image revision does not match"):
            self.run_deploy()
        self.assertEqual(self.env_file.read_text(), self.original)
        self.assertEqual(self.starts, [])

    def test_image_drift_stops_before_changing_configuration(self):
        self.active_image = "other-image"
        with self.assertRaisesRegex(RuntimeError, "Running image differs"):
            self.run_deploy()
        self.assertEqual(self.env_file.read_text(), self.original)
        self.assertEqual(self.starts, [])

    def test_ssh_key_rejects_shell_commands(self):
        for command in ("", "true", "deploy main", "deploy " + REVISION + "; id"):
            with self.subTest(command=command), mock.patch.dict(deployment.os.environ, SSH_ORIGINAL_COMMAND=command):
                with self.assertRaisesRegex(SystemExit, "Only 'deploy"):
                    deployment.main()

    def test_untrusted_run_is_rejected_before_any_docker_action(self):
        with mock.patch.dict(deployment.os.environ, SSH_ORIGINAL_COMMAND="deploy 123 " + REVISION), \
             mock.patch.object(deployment.sys, "stdin", io.StringIO("test-token")), \
             mock.patch.object(deployment, "verify_run", side_effect=RuntimeError("untrusted run")), \
             mock.patch.object(deployment, "deploy") as deploy:
            with self.assertRaisesRegex(RuntimeError, "untrusted run"):
                deployment.main()
            deploy.assert_not_called()

    def test_ssh_key_requires_a_registry_token(self):
        with mock.patch.dict(deployment.os.environ, SSH_ORIGINAL_COMMAND="deploy 123 " + REVISION):
            for token in ("", "token with spaces", "x" * 16385):
                with self.subTest(token_length=len(token)), mock.patch.object(deployment.sys, "stdin", io.StringIO(token)):
                    with self.assertRaisesRegex(SystemExit, "Expected a registry token"):
                        deployment.main()


if __name__ == "__main__":
    unittest.main()
