"""校验备份点和迁移元数据, 安全解压归档; 命令行参数为外部文件边界."""

import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import sys
import tarfile


def archive_filter(member: tarfile.TarInfo, destination: str) -> tarfile.TarInfo:
    """使用标准库阻止越界与特殊设备, 保留服务数据所需的数字 UID/GID."""
    name = PurePosixPath(member.name)
    if name.is_absolute() or ".." in name.parts or "\\" in member.name:
        raise ValueError(f"归档路径不安全: {member.name}")
    filtered = tarfile.data_filter(member, destination)
    return filtered.replace(uid=member.uid, gid=member.gid, uname=None, gname=None)


def extract_archive(archive: str, destination: Path) -> None:
    """对归档成员应用路径过滤, 支持文件或解密后的标准输入流."""
    destination.mkdir(parents=True, exist_ok=True)
    if archive == "-":
        with tarfile.open(fileobj=sys.stdin.buffer, mode="r|*") as stream:
            stream.extractall(destination, filter=archive_filter, numeric_owner=True)
    else:
        with tarfile.open(archive, mode="r:*") as stream:
            stream.extractall(destination, filter=archive_filter, numeric_owner=True)


def verify_archive(path: Path) -> None:
    """核对当前归档的摘要, 不执行校验文件中提供的任意路径."""
    line = Path(str(path) + ".sha256").read_text(encoding="utf-8").strip()
    match = re.fullmatch(r"([0-9a-fA-F]{64}) [ *](.+)", line)
    if not match or match[2] != path.name:
        raise ValueError(f"摘要文件格式或目标文件名错误: {path.name}")
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    if digest.hexdigest() != match[1].lower():
        raise ValueError(f"归档摘要不一致: {path.name}")


def verify_point(directory: Path, complete: bool = False) -> None:
    """按 manifest 核对成功 scope 的存在性和摘要, 可要求备份全部成功."""
    root = directory.resolve()
    manifest = json.loads((root / "manifest.json").read_text(encoding="utf-8"))
    scopes = manifest["scopes_ok"]
    failed = manifest["scopes_fail"]
    if not isinstance(scopes, list) or not scopes or not isinstance(failed, list):
        raise ValueError("备份 manifest 必须包含非空成功 scope 列表与失败列表")
    if complete and failed:
        raise ValueError("备份有失败 scope, 已停止后续操作")
    if any(not isinstance(scope, str) or not re.fullmatch(r"[a-z][a-z0-9-]*", scope) for scope in scopes):
        raise ValueError("备份 scope 名称无效")
    if len(scopes) != len(set(scopes)):
        raise ValueError("备份 scope 重复")
    expected = {f"{scope}.tar.gz" for scope in scopes}
    present = {path.name for path in root.glob("*.tar.gz")}
    if present != expected:
        raise ValueError("备份归档与 manifest 不一致, 存在缺失或额外 scope")
    for name in expected:
        archive = root / name
        if archive.is_symlink() or archive.resolve().parent != root or not archive.is_file():
            raise ValueError(f"备份归档必须是当前备份点中的普通文件: {name}")
        verify_archive(archive)


def migration_timestamp(directory: Path) -> str:
    """校验当前格式的迁移包, 返回可安全用于目录名的备份标识."""
    verify_point(directory, complete=True)
    migration = json.loads((directory / "migration.json").read_text(encoding="utf-8"))
    timestamp = migration["backup_ts"]
    if not isinstance(timestamp, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", timestamp):
        raise ValueError("迁移包 backup_ts 不是合法目录标识")
    manifest = json.loads((directory / "migrate-manifest.json").read_text(encoding="utf-8"))
    if manifest["format_version"] != 2 or not isinstance(manifest["scopes"], list):
        raise ValueError("仅支持当前迁移 manifest v2")
    scopes = manifest["scopes"]
    expected = json.loads((directory / "manifest.json").read_text(encoding="utf-8"))["scopes_ok"]
    if len(scopes) != len(expected) or {scope["scope"] for scope in scopes} != set(expected):
        raise ValueError("迁移 manifest 与备份 scope 不一致")
    for scope in scopes:
        if scope["file"] != f"{scope['scope']}.tar.gz":
            raise ValueError("迁移 manifest 的归档路径无效")
        strategies = scope["unpack_strategies"]
        if not strategies or not any(strategy["id"] != "skip" for strategy in strategies):
            raise ValueError("迁移 scope 必须声明实际可用的恢复策略")
    return timestamp


def select_scopes(directory: Path, selected: list[str]) -> None:
    """在临时副本中保留明确选择的 scope, 不改变原备份点."""
    manifest_file = directory / "manifest.json"
    manifest = json.loads(manifest_file.read_text(encoding="utf-8"))
    if not set(selected).issubset(manifest["scopes_ok"]):
        raise ValueError("所选 scope 不在备份成功列表中")
    wanted = {f"{scope}.tar.gz" for scope in selected}
    for path in directory.glob("*.tar.gz"):
        if path.name not in wanted:
            path.unlink()
            Path(str(path) + ".sha256").unlink(missing_ok=True)
    manifest["scopes_ok"] = selected
    manifest["scopes_fail"] = []
    manifest_file.write_text(json.dumps(manifest, ensure_ascii=False), encoding="utf-8")
    path = directory / "migrate-manifest.json"
    migration = json.loads(path.read_text(encoding="utf-8"))
    migration["scopes"] = [scope for scope in migration["scopes"] if scope["scope"] in selected]
    path.write_text(json.dumps(migration, ensure_ascii=False), encoding="utf-8")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    extract = sub.add_parser("extract")
    extract.add_argument("archive")
    extract.add_argument("destination", type=Path)
    verify = sub.add_parser("verify")
    verify.add_argument("directory", type=Path)
    verify.add_argument("--complete", action="store_true")
    check = sub.add_parser("verify-archive")
    check.add_argument("archive", type=Path)
    timestamp = sub.add_parser("migration-ts")
    timestamp.add_argument("directory", type=Path)
    selected = sub.add_parser("select")
    selected.add_argument("directory", type=Path)
    selected.add_argument("scopes", nargs="+")
    args = parser.parse_args()
    try:
        if args.command == "extract":
            extract_archive(args.archive, args.destination)
        elif args.command == "verify":
            verify_point(args.directory, args.complete)
        elif args.command == "verify-archive":
            verify_archive(args.archive)
        elif args.command == "select":
            select_scopes(args.directory, args.scopes)
        else:
            print(migration_timestamp(args.directory))
    except (OSError, ValueError, KeyError, TypeError, tarfile.TarError) as exc:
        parser.exit(1, f"归档处理失败 ({args.command}): {exc}\n")


if __name__ == "__main__":
    main()
