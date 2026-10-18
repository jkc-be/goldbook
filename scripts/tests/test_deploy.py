import importlib.util
import io
import json
from pathlib import Path
import sqlite3
import subprocess
import tempfile
import unittest
import zipfile
from contextlib import closing, redirect_stdout
from datetime import datetime, timezone
from unittest import mock

SCRIPT = Path(__file__).resolve().parents[2] / "scripts/deploy-ovh.py"
spec = importlib.util.spec_from_file_location("deploy_ovh", SCRIPT)
deployment = importlib.util.module_from_spec(spec)
spec.loader.exec_module(deployment)
REVISION = "a" * 40
DIGEST = "sha256:" + "b" * 64
IMAGE = deployment.REPOSITORY + "@" + DIGEST
REPOINTED = deployment.REPOSITORY + "@sha256:" + "c" * 64


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
        (self.root / "data").mkdir()
        (self.root / "backups").mkdir()
        # The running server keeps its connection open, so committed rows may
        # still be in the write-ahead log when the backup starts.
        self.database = sqlite3.connect(self.root / "data/goldbook.sqlite")
        self.addCleanup(self.database.close)
        self.database.execute("PRAGMA journal_mode=WAL")
        self.database.execute("CREATE TABLE realms (name TEXT)")
        self.database.execute("CREATE INDEX realms_name ON realms (name)")
        self.database.execute("INSERT INTO realms VALUES ('Silvermoon')")
        self.database.commit()
        self.active_image = "goldbook"
        self.healthy = True
        self.label = REVISION
        self.starts = []
        self.pulls = []
        self.registry_config = None
        # A later build for the same commit has repointed the tag.
        self.registry = {deployment.REPOSITORY + ":" + REVISION: REPOINTED, IMAGE: IMAGE}
        self.image_record = {"revision": REVISION, "digest": DIGEST}
        self.artifacts = [{"id": 456, "name": "Goldbook-server-image", "expired": False},
                          {"id": 789, "name": "Goldbook-update-feed", "expired": False}]

    def github(self, request, **_):
        if request.full_url.endswith("/actions/runs/123/artifacts"):
            return io.BytesIO(json.dumps({"artifacts": self.artifacts}).encode())
        self.assertTrue(request.full_url.endswith("/actions/artifacts/456/zip"))
        archive = io.BytesIO()
        with zipfile.ZipFile(archive, "w") as output:
            output.writestr("image.json", json.dumps(self.image_record))
        return io.BytesIO(archive.getvalue())

    def docker(self, args, **options):
        self.registry_config = Path(options["env"]["DOCKER_CONFIG"])
        self.assertTrue(self.registry_config.is_dir())
        stdout = ""
        if args[:2] == ("docker", "pull"):
            self.pulls.append(args[2])
        elif args[:2] == ("docker", "inspect"):
            if len(args) == 3:
                stdout = json.dumps([{"Config": {"Labels": {"org.opencontainers.image.revision": self.label}},
                                      "RepoDigests": [self.registry[args[2]]]}])
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

    def run_deploy(self, verify_only=False):
        with mock.patch.object(deployment.subprocess, "run", side_effect=self.docker), \
             mock.patch.object(deployment.OPENER, "open", side_effect=self.github), \
             redirect_stdout(io.StringIO()) as output:
            deployment.deploy("123", REVISION, "test-registry-token", verify_only=verify_only)
        return json.loads(output.getvalue())

    def assert_refused(self, message):
        with self.assertRaisesRegex(RuntimeError, message):
            self.run_deploy()
        self.assertIsNone(self.registry_config)
        self.assertEqual(self.env_file.read_text(), self.original)
        self.assertEqual(self.starts, [])

    def run_main(self, command, workflow):
        run = dict(head_sha=REVISION, head_branch="main", path=workflow + "@refs/heads/main",
                   event="workflow_dispatch", repository={"full_name": "jkc-be/goldbook"},
                   head_repository={"full_name": "jkc-be/goldbook"},
                   actor={"id": 156444954}, triggering_actor={"id": 156444954})
        with mock.patch.dict(deployment.os.environ, SSH_ORIGINAL_COMMAND=command + " 123 " + REVISION), \
             mock.patch.object(deployment.sys, "stdin", io.StringIO("test-token")), \
             mock.patch.object(deployment.OPENER, "open", return_value=io.BytesIO(json.dumps(run).encode())), \
             mock.patch.object(deployment, "deploy") as deploy:
            try:
                deployment.main()
            finally:
                self.deploy_calls = deploy.call_args_list

    def test_first_deploy_pins_digest_preserves_settings_and_cleans_registry_credentials(self):
        self.run_deploy()
        self.assertEqual(self.env_file.read_text(), self.original + "GOLDBOOK_IMAGE=" + IMAGE + "\n")
        self.assertEqual(self.starts, [IMAGE])
        backup, = self.root.glob(".env.before-*")
        self.assertEqual(backup.read_text(), self.original)
        self.assertEqual(backup.stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.env_file.stat().st_mode & 0o777, 0o600)
        self.assertFalse(self.registry_config.exists())

    def test_deploys_the_digest_the_run_recorded_not_the_current_tag(self):
        result = self.run_deploy()
        self.assertEqual(self.pulls, [IMAGE])
        self.assertEqual(result["active_image"], IMAGE)
        self.assertEqual(self.starts, [IMAGE])
        self.assertEqual(self.env_file.read_text(), self.original + "GOLDBOOK_IMAGE=" + IMAGE + "\n")

    def test_run_needs_exactly_one_unexpired_image_artifact(self):
        image = self.artifacts[0]
        for artifacts, count in [([], 0), ([dict(image, expired=True)], 0), ([image, dict(image, id=457)], 2)]:
            self.artifacts = artifacts
            with self.subTest(artifacts=artifacts):
                self.assert_refused(f"^Run 123 has {count} unexpired Goldbook-server-image artifacts; expected exactly one$")

    def test_image_record_for_another_revision_is_refused(self):
        self.image_record["revision"] = "c" * 40
        self.assert_refused("^Run 123's image.json is for revision " + "c" * 40 + ", not " + REVISION + "$")

    def test_image_record_with_an_invalid_digest_is_refused(self):
        for digest in ("sha256:" + "B" * 64, "sha256:" + "b" * 63, "b" * 64, "sha256:" + "b" * 64 + "\n", 1):
            self.image_record["digest"] = digest
            with self.subTest(digest=digest):
                self.assert_refused("^Run 123's image.json has an invalid digest$")
        self.image_record = {"revision": REVISION, "digest": DIGEST, "tag": "latest"}
        self.assert_refused("^Run 123's image.json must hold exactly a revision and a digest$")

    def test_verify_only_does_not_change_running_service_or_configuration(self):
        self.run_deploy(verify_only=True)
        self.assertEqual(self.pulls, [IMAGE])
        self.assertEqual(self.env_file.read_text(), self.original)
        self.assertEqual(self.starts, [])
        self.assertEqual(self.active_image, "goldbook")
        self.assertEqual(list(self.root.glob(".env.before-*")), [])
        self.assertEqual(list((self.root / "backups").iterdir()), [])

    def test_deploy_backs_up_the_database_before_starting_the_new_image(self):
        clock = mock.Mock(now=mock.Mock(return_value=datetime(2026, 10, 18, 12, 30, 5, 123456, timezone.utc)))
        with mock.patch.object(deployment, "datetime", clock):
            result = self.run_deploy()
        backup = self.root / "backups" / ("goldbook-20261018T123005123456Z-" + REVISION + ".sqlite")
        self.assertEqual(result, {"revision": REVISION, "active_image": IMAGE, "previous_image": "goldbook",
                                  "health": "healthy",
                                  "rollback_config": str(self.root / ".env.before-20261018T123005123456Z-aaaaaaaaaaaa"),
                                  "database_backup": str(backup)})
        self.assertEqual(backup.stat().st_mode & 0o777, 0o600)
        with closing(sqlite3.connect(backup)) as copy:
            self.assertEqual(copy.execute("SELECT name FROM realms").fetchall(), [("Silvermoon",)])

    def test_failed_database_integrity_check_stops_before_changing_configuration(self):
        self.database.close()
        database = self.root / "data/goldbook.sqlite"
        content = database.read_bytes()
        # Change the copy of the key stored in the index so the table and index disagree.
        index_key = content.rindex(b"Silvermoon")
        database.write_bytes(content[:index_key] + b"Silvermoom" + content[index_key + 10:])
        with self.assertRaisesRegex(RuntimeError, "failed its integrity check: row 1 missing from index realms_name"):
            self.run_deploy()
        self.assertEqual(self.env_file.read_text(), self.original)
        self.assertEqual(list(self.root.glob(".env.before-*")), [])
        self.assertEqual(self.starts, [])

    def test_missing_database_stops_before_changing_configuration(self):
        self.database.close()
        (self.root / "data/goldbook.sqlite").unlink()
        with self.assertRaisesRegex(RuntimeError, "Expected the database at " + str(self.root / "data/goldbook.sqlite")):
            self.run_deploy()
        self.assertEqual(self.env_file.read_text(), self.original)
        self.assertEqual(list((self.root / "backups").iterdir()), [])
        self.assertEqual(self.starts, [])

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

    def test_deploy_and_release_build_runs_can_deploy_and_verify(self):
        for command, workflow in [("deploy", ".github/workflows/release-build.yml"),
                                  ("verify", ".github/workflows/release-build.yml"),
                                  ("deploy", ".github/workflows/deploy.yml")]:
            with self.subTest(command=command, workflow=workflow):
                self.run_main(command, workflow)
                self.assertEqual(self.deploy_calls,
                                 [mock.call("123", REVISION, "test-token", verify_only=command == "verify")])

    def test_other_workflows_cannot_deploy(self):
        for workflow in (".github/workflows/release-desktop.yml", ".github/workflows/update-addon.yml",
                         ".github/workflows/other.yml"):
            with self.subTest(workflow=workflow):
                with self.assertRaisesRegex(RuntimeError, "Only a maintainer Goldbook workflow on main"):
                    self.run_main("deploy", workflow)
                self.assertEqual(self.deploy_calls, [])

    def test_ssh_key_requires_a_registry_token(self):
        with mock.patch.dict(deployment.os.environ, SSH_ORIGINAL_COMMAND="deploy 123 " + REVISION):
            for token in ("", "token with spaces", "x" * 16385):
                with self.subTest(token_length=len(token)), mock.patch.object(deployment.sys, "stdin", io.StringIO(token)):
                    with self.assertRaisesRegex(SystemExit, "Expected a registry token"):
                        deployment.main()


if __name__ == "__main__":
    unittest.main()
