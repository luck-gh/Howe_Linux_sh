"""归档输入边界回归, Windows 与 Linux 使用相同的 Python 标准库测试."""

import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import tarfile
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location("backup_archive", Path(__file__).resolve().parents[1] / "ai_stack/backup_archive.py")
archive = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(archive)


class ArchiveTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.point = self.root / "point"
        self.point.mkdir()
        self.tar = self.point / "ai-config.tar.gz"
        self.write_tar("value", b"synthetic")
        self.seal()
        self.manifest = {"scopes_ok": ["ai-config"], "scopes_fail": []}
        self.save_manifest()
        (self.point / "migration.json").write_text(json.dumps({"backup_ts": "20261102-123456"}), encoding="utf-8")
        self.migration = {"format_version": 2, "scopes": [{"scope": "ai-config", "file": "ai-config.tar.gz", "unpack_strategies": [{"id": "restore"}]}]}
        self.save_migration()

    def tearDown(self):
        self.temporary.cleanup()

    def write_tar(self, name, payload=b"", kind=tarfile.REGTYPE, link=""):
        with tarfile.open(self.tar, "w:gz") as output:
            member = tarfile.TarInfo(name)
            member.type, member.linkname = kind, link
            member.size = len(payload) if kind == tarfile.REGTYPE else 0
            output.addfile(member, io.BytesIO(payload) if kind == tarfile.REGTYPE else None)

    def seal(self):
        Path(str(self.tar) + ".sha256").write_text(hashlib.sha256(self.tar.read_bytes()).hexdigest() + "  " + self.tar.name + "\n", encoding="utf-8")

    def save_manifest(self):
        (self.point / "manifest.json").write_text(json.dumps(self.manifest), encoding="utf-8")

    def save_migration(self):
        (self.point / "migrate-manifest.json").write_text(json.dumps(self.migration), encoding="utf-8")

    def test_roundtrip(self):
        archive.verify_point(self.point)
        archive.extract_archive(str(self.tar), self.root / "out")
        self.assertEqual((self.root / "out/value").read_bytes(), b"synthetic")

    def test_absolute_path_rejected(self):
        self.write_tar("/outside", b"no")
        with self.assertRaises(ValueError):
            archive.extract_archive(str(self.tar), self.root / "out")

    def test_parent_path_rejected(self):
        self.write_tar("../outside", b"no")
        with self.assertRaises(ValueError):
            archive.extract_archive(str(self.tar), self.root / "out")
        self.assertFalse((self.root / "outside").exists())

    def test_backslash_path_rejected(self):
        self.write_tar("..\\outside", b"no")
        with self.assertRaises(ValueError):
            archive.extract_archive(str(self.tar), self.root / "out")

    def test_symlink_escape_rejected(self):
        self.write_tar("escape", kind=tarfile.SYMTYPE, link="../../outside")
        with self.assertRaises(tarfile.FilterError):
            archive.extract_archive(str(self.tar), self.root / "out")

    def test_hardlink_escape_rejected(self):
        self.write_tar("escape", kind=tarfile.LNKTYPE, link="../../outside")
        with self.assertRaises(tarfile.FilterError):
            archive.extract_archive(str(self.tar), self.root / "out")

    def test_device_rejected(self):
        self.write_tar("device", kind=tarfile.CHRTYPE)
        with self.assertRaises(tarfile.FilterError):
            archive.extract_archive(str(self.tar), self.root / "out")

    @unittest.skipIf(os.name == "nt", "Windows 创建符号链接需要额外权限, 此用例在 Linux 验证")
    def test_existing_destination_symlink_rejected(self):
        target = self.root / "out"
        target.mkdir()
        outside = self.root / "outside"
        outside.mkdir()
        (target / "escape").symlink_to(outside, target_is_directory=True)
        self.write_tar("escape/value", b"no")
        with self.assertRaises(tarfile.FilterError):
            archive.extract_archive(str(self.tar), target)
        self.assertFalse((outside / "value").exists())

    def test_corrupt_archive_rejected(self):
        self.tar.write_bytes(b"changed")
        with self.assertRaises(ValueError):
            archive.verify_archive(self.tar)

    def test_checksum_cannot_redirect_filename(self):
        checksum = Path(str(self.tar) + ".sha256")
        checksum.write_text(hashlib.sha256(self.tar.read_bytes()).hexdigest() + "  ../other\n", encoding="utf-8")
        with self.assertRaises(ValueError):
            archive.verify_archive(self.tar)

    def test_missing_archive_rejected(self):
        self.tar.unlink()
        with self.assertRaises(ValueError):
            archive.verify_point(self.point)

    def test_missing_checksum_rejected(self):
        Path(str(self.tar) + ".sha256").unlink()
        with self.assertRaises(FileNotFoundError):
            archive.verify_point(self.point)

    def test_extra_archive_rejected(self):
        (self.point / "custom.tar.gz").write_bytes(b"extra")
        with self.assertRaises(ValueError):
            archive.verify_point(self.point)

    def test_duplicate_scope_rejected(self):
        self.manifest["scopes_ok"] *= 2
        self.save_manifest()
        with self.assertRaises(ValueError):
            archive.verify_point(self.point)

    def test_scope_path_rejected(self):
        self.manifest["scopes_ok"] = ["../escape"]
        self.save_manifest()
        with self.assertRaises(ValueError):
            archive.verify_point(self.point)

    def test_partial_point_not_accepted_for_upgrade(self):
        self.manifest["scopes_fail"] = ["ai-pg"]
        self.save_manifest()
        archive.verify_point(self.point)
        with self.assertRaises(ValueError):
            archive.verify_point(self.point, complete=True)

    def test_valid_migration(self):
        self.assertEqual(archive.migration_timestamp(self.point), "20261102-123456")

    def test_timestamp_escape_rejected(self):
        (self.point / "migration.json").write_text('{"backup_ts":"../escape"}', encoding="utf-8")
        with self.assertRaises(ValueError):
            archive.migration_timestamp(self.point)

    def test_obsolete_manifest_rejected(self):
        self.migration["format_version"] = 1
        self.save_migration()
        with self.assertRaises(ValueError):
            archive.migration_timestamp(self.point)

    def test_migration_scope_mismatch_rejected(self):
        self.migration["scopes"] = []
        self.save_migration()
        with self.assertRaises(ValueError):
            archive.migration_timestamp(self.point)

    def test_migration_filename_escape_rejected(self):
        self.migration["scopes"][0]["file"] = "../escape"
        self.save_migration()
        with self.assertRaises(ValueError):
            archive.migration_timestamp(self.point)

    def test_migration_without_restore_strategy_rejected(self):
        self.migration["scopes"][0]["unpack_strategies"] = [{"id": "skip"}]
        self.save_migration()
        with self.assertRaises(ValueError):
            archive.migration_timestamp(self.point)

    def test_only_selected_scopes_are_kept(self):
        other = self.point / "custom.tar.gz"
        other.write_bytes(self.tar.read_bytes())
        Path(str(other) + ".sha256").write_text(hashlib.sha256(other.read_bytes()).hexdigest() + "  " + other.name + "\n", encoding="utf-8")
        self.manifest["scopes_ok"].append("custom")
        self.save_manifest()
        self.migration["scopes"].append({"scope": "custom", "file": "custom.tar.gz", "unpack_strategies": [{"id": "restore_original"}]})
        self.save_migration()
        archive.select_scopes(self.point, ["ai-config"])
        self.assertFalse(other.exists())
        archive.verify_point(self.point, complete=True)
        self.assertEqual(archive.migration_timestamp(self.point), "20261102-123456")


if __name__ == "__main__":
    unittest.main()
