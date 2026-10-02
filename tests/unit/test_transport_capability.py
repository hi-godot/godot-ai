"""Security contract for the local transport-capability bootstrap record."""

from __future__ import annotations

import errno
import json
import os
import stat
import subprocess
from pathlib import Path
from types import SimpleNamespace

import pytest

from godot_ai.transport import capability as capability_module
from godot_ai.transport.capability import (
    HTTP_CAPABILITY_ENV,
    MAX_RECORD_BYTES,
    WS_CAPABILITY_ENV,
    PortClaimUnavailable,
    acquire_port_claim,
    capability_directory,
    generate_capabilities,
    launch_capabilities_from_env,
    read_capabilities,
    record_path,
    remove_capabilities,
    validate_launch_capabilities,
    validate_record,
    write_capabilities,
)

HTTP = "h" * 32
WEBSOCKET = "b" * 64
NONCE = "a" * 32


def test_generated_capabilities_are_distinct_and_valid() -> None:
    generated = generate_capabilities()

    assert validate_launch_capabilities(generated.http, generated.websocket) == generated
    assert generated.http != generated.websocket


@pytest.mark.skipif(os.name == "nt", reason="POSIX directory-mode contract")
def test_missing_capability_ancestors_are_created_private(tmp_path) -> None:
    directory = tmp_path / "first" / "second"
    previous_umask = os.umask(0)
    try:
        write_capabilities(
            8122,
            HTTP,
            WEBSOCKET,
            instance_nonce=NONCE,
            directory=directory,
        )
    finally:
        os.umask(previous_umask)

    assert stat.S_IMODE((tmp_path / "first").stat().st_mode) == 0o700
    assert stat.S_IMODE(directory.stat().st_mode) == 0o700


@pytest.mark.skipif(os.name == "nt", reason="POSIX ancestor mode contract")
def test_only_root_owned_sticky_directory_is_safe_as_writable_ancestor() -> None:
    root_sticky = SimpleNamespace(st_mode=stat.S_IFDIR | 0o1777, st_uid=0)
    user_writable = SimpleNamespace(st_mode=stat.S_IFDIR | 0o0777, st_uid=os.getuid())
    other_sticky = SimpleNamespace(st_mode=stat.S_IFDIR | 0o1777, st_uid=os.getuid() + 1)

    assert capability_module._is_safe_posix_ancestor(Path("/tmp"), root_sticky)
    assert not capability_module._is_safe_posix_ancestor(Path("/tmp"), user_writable)
    assert not capability_module._is_safe_posix_ancestor(Path("/tmp"), other_sticky)
    assert not capability_module._is_safe_posix_ancestor(Path("/untrusted-sticky"), root_sticky)


@pytest.mark.parametrize("length", [31, 129])
def test_capability_length_is_bounded(length: int) -> None:
    with pytest.raises(ValueError, match="32-128"):
        validate_launch_capabilities("h" * length, WEBSOCKET)


def test_websocket_capability_has_one_canonical_encoding() -> None:
    for value in ("b" * 63, "B" * 64, "z" * 64):
        with pytest.raises(ValueError, match="64 lowercase hexadecimal"):
            validate_launch_capabilities(HTTP, value)


def test_capability_rejects_header_injection() -> None:
    with pytest.raises(ValueError, match="ASCII bearer-token"):
        validate_launch_capabilities("secret\r\nX-Injected: yes", WEBSOCKET)


def test_launch_capabilities_require_one_complete_pair(monkeypatch) -> None:
    monkeypatch.setenv(HTTP_CAPABILITY_ENV, HTTP)
    monkeypatch.delenv(WS_CAPABILITY_ENV, raising=False)
    with pytest.raises(ValueError, match="supplied together"):
        launch_capabilities_from_env()

    monkeypatch.setenv(WS_CAPABILITY_ENV, WEBSOCKET)
    assert launch_capabilities_from_env() == validate_launch_capabilities(HTTP, WEBSOCKET)


def test_missing_pair_is_generated_only_when_explicitly_allowed(monkeypatch) -> None:
    monkeypatch.delenv(HTTP_CAPABILITY_ENV, raising=False)
    monkeypatch.delenv(WS_CAPABILITY_ENV, raising=False)

    with pytest.raises(ValueError, match="required"):
        launch_capabilities_from_env(generate_if_missing=False)

    generated = launch_capabilities_from_env()
    assert generated.http != generated.websocket


def test_record_round_trips_as_one_private_canonical_value(tmp_path) -> None:
    directory = tmp_path / "capabilities"
    path = write_capabilities(8122, HTTP, WEBSOCKET, instance_nonce=NONCE, directory=directory)

    assert read_capabilities(8122, directory) == validate_record(HTTP, WEBSOCKET, NONCE)
    assert json.loads(path.read_text(encoding="ascii")) == {
        "version": 1,
        "http": HTTP,
        "websocket": WEBSOCKET,
        "instance_nonce": NONCE,
    }
    if os.name != "nt":
        assert stat.S_IMODE(directory.stat().st_mode) == 0o700
        assert stat.S_IMODE(path.stat().st_mode) == 0o600


def test_port_claim_excludes_a_second_owner_until_release(tmp_path) -> None:
    first = acquire_port_claim(8123, tmp_path)
    try:
        with pytest.raises(PortClaimUnavailable):
            acquire_port_claim(8123, tmp_path)
    finally:
        first.release()

    acquire_port_claim(8123, tmp_path).release()


def test_record_removal_is_bound_to_the_published_instance(tmp_path) -> None:
    write_capabilities(8123, HTTP, WEBSOCKET, instance_nonce=NONCE, directory=tmp_path)

    assert remove_capabilities(8123, "b" * 32, tmp_path) is False
    assert read_capabilities(8123, tmp_path) is not None
    assert remove_capabilities(8123, NONCE, tmp_path) is True
    assert read_capabilities(8123, tmp_path) is None


@pytest.mark.parametrize("port", [0, 65536])
def test_record_path_rejects_invalid_ports(port: int, tmp_path) -> None:
    with pytest.raises(ValueError, match="between 1 and 65535"):
        record_path(port, tmp_path)


@pytest.mark.parametrize(
    "raw",
    [
        f'{{"version":1,"http":"{HTTP}","websocket":"{WEBSOCKET}"}}',
        f'{{"version":1,"http":"{HTTP}","websocket":"{WEBSOCKET}","instance_nonce":"{NONCE}","extra":1}}',
        f'{{"version":1,"version":1,"http":"{HTTP}","websocket":"{WEBSOCKET}","instance_nonce":"{NONCE}"}}',
        f'{{"version":true,"http":"{HTTP}","websocket":"{WEBSOCKET}","instance_nonce":"{NONCE}"}}',
        f'{{"version":1,"http":"{WEBSOCKET}","websocket":"{WEBSOCKET}","instance_nonce":"{NONCE}"}}',
        f'{{"version":1,"http":"{HTTP}","websocket":"{WEBSOCKET}","instance_nonce":"not-hex"}}',
    ],
    ids=["missing", "extra", "duplicate", "boolean", "shared", "nonce"],
)
def test_record_rejects_partial_or_ambiguous_schema(raw: str, tmp_path) -> None:
    path = write_capabilities(8124, HTTP, WEBSOCKET, instance_nonce=NONCE, directory=tmp_path)
    path.write_text(raw, encoding="ascii")

    assert read_capabilities(8124, tmp_path) is None


def test_launch_capabilities_must_be_independent() -> None:
    with pytest.raises(ValueError, match="independent"):
        validate_launch_capabilities(WEBSOCKET, WEBSOCKET)


def test_record_rejects_oversize_and_non_ascii(tmp_path) -> None:
    path = write_capabilities(8125, HTTP, WEBSOCKET, instance_nonce=NONCE, directory=tmp_path)
    for raw in (b"x" * (MAX_RECORD_BYTES + 2), "café".encode()):
        path.write_bytes(raw)
        assert read_capabilities(8125, tmp_path) is None


@pytest.mark.skipif(os.name == "nt", reason="POSIX link and mode contract")
def test_record_rejects_leaf_link_and_permissive_mode(tmp_path) -> None:
    directory = tmp_path / "capabilities"
    path = write_capabilities(8126, HTTP, WEBSOCKET, instance_nonce=NONCE, directory=directory)
    path.chmod(0o644)
    assert read_capabilities(8126, directory) is None

    target = tmp_path / "target"
    target.write_text(path.read_text(encoding="ascii"), encoding="ascii")
    target.chmod(0o600)
    path.unlink()
    path.symlink_to(target)
    assert read_capabilities(8126, directory) is None


@pytest.mark.skipif(os.name == "nt", reason="POSIX link contract")
def test_record_round_trips_through_same_user_linked_directory(tmp_path) -> None:
    real = tmp_path / "real"
    linked = tmp_path / "linked"
    real.mkdir(mode=0o700)
    linked.symlink_to(real, target_is_directory=True)

    written = write_capabilities(8127, HTTP, WEBSOCKET, instance_nonce=NONCE, directory=linked)
    assert written == real / "http-8127.json"
    assert read_capabilities(8127, linked) == validate_record(HTTP, WEBSOCKET, NONCE)


@pytest.mark.skipif(os.name == "nt", reason="POSIX ancestor mode contract")
def test_capability_directory_override_rejects_writable_ancestor(monkeypatch, tmp_path) -> None:
    unsafe = tmp_path / "unsafe"
    unsafe.mkdir(mode=0o700)
    unsafe.chmod(0o777)
    monkeypatch.setenv("GODOT_AI_CAPABILITY_DIR", str(unsafe / "records"))

    with pytest.raises(OSError, match="unsafe ancestor"):
        capability_directory()


@pytest.mark.skipif(os.name == "nt", reason="POSIX ancestor owner contract")
def test_capability_directory_override_rejects_other_owner(monkeypatch, tmp_path) -> None:
    other_owned = os.stat_result((stat.S_IFDIR | 0o755, 0, 0, 0, os.getuid() + 1, 0, 0, 0, 0, 0))
    monkeypatch.setenv("GODOT_AI_CAPABILITY_DIR", str(tmp_path / "records"))
    monkeypatch.setattr(type(tmp_path), "lstat", lambda _path: other_owned)

    with pytest.raises(OSError, match="unsafe ancestor"):
        capability_directory()


@pytest.mark.skipif(os.name == "nt", reason="POSIX XDG path contract")
def test_capability_directory_rejects_relative_xdg(monkeypatch) -> None:
    monkeypatch.delenv("GODOT_AI_CAPABILITY_DIR", raising=False)
    monkeypatch.setenv("XDG_CONFIG_HOME", "relative/config")
    monkeypatch.setattr(capability_module.sys, "platform", "linux")

    with pytest.raises(ValueError, match="XDG_CONFIG_HOME must be an absolute path"):
        capability_directory()


@pytest.mark.skipif(os.name == "nt", reason="POSIX XDG ancestor mode contract")
def test_default_xdg_capability_directory_rejects_writable_ancestor(monkeypatch, tmp_path) -> None:
    unsafe = tmp_path / "unsafe-xdg-parent"
    unsafe.mkdir(mode=0o700)
    unsafe.chmod(0o777)
    monkeypatch.delenv("GODOT_AI_CAPABILITY_DIR", raising=False)
    monkeypatch.setenv("XDG_CONFIG_HOME", str(unsafe / "xdg"))
    monkeypatch.setattr(capability_module.sys, "platform", "linux")

    with pytest.raises(OSError, match="unsafe ancestor"):
        capability_directory()


@pytest.mark.skipif(os.name == "nt", reason="POSIX explicit-directory contract")
def test_explicit_capability_directory_rejects_writable_ancestor(tmp_path) -> None:
    unsafe = tmp_path / "unsafe-explicit-parent"
    unsafe.mkdir(mode=0o700)
    unsafe.chmod(0o777)

    with pytest.raises(OSError, match="unsafe ancestor"):
        record_path(8128, unsafe / "records")


FAKE_ROOT = "/godot-ai-fake-root"


def _directory(uid: int, mode: int = 0o755) -> os.stat_result:
    return os.stat_result((stat.S_IFDIR | mode, 0, 0, 0, uid, 0, 0, 0, 0, 0))


def _link(uid: int) -> os.stat_result:
    return os.stat_result((stat.S_IFLNK | 0o777, 0, 0, 0, uid, 0, 0, 0, 0, 0))


def _fake_tree(monkeypatch, entries: dict[str, os.stat_result], links: dict[str, str]) -> None:
    """Overlay a synthetic directory tree onto lstat/readlink for the listed paths only."""

    real_lstat = Path.lstat
    real_readlink = os.readlink

    def lstat(self):
        key = str(self)
        if key in entries:
            return entries[key]
        if key.startswith(FAKE_ROOT):
            raise FileNotFoundError(key)
        return real_lstat(self)

    def readlink(path, *args, **kwargs):
        key = str(path)
        if key in links:
            return links[key]
        return real_readlink(path, *args, **kwargs)

    monkeypatch.setattr(Path, "lstat", lstat)
    monkeypatch.setattr(capability_module.os, "readlink", readlink)


def _ostree_home(monkeypatch, link_uid: int = 0, parent_mode: int = 0o755) -> None:
    """Fedora Atomic's layout: ``/home -> var/home`` (relative, root-owned)."""

    me = os.getuid()
    _fake_tree(
        monkeypatch,
        {
            FAKE_ROOT: _directory(0, parent_mode),
            f"{FAKE_ROOT}/home": _link(link_uid),
            f"{FAKE_ROOT}/var": _directory(0),
            f"{FAKE_ROOT}/var/home": _directory(0),
            f"{FAKE_ROOT}/var/home/me": _directory(me, 0o700),
            f"{FAKE_ROOT}/var/home/me/.config": _directory(me, 0o700),
        },
        {f"{FAKE_ROOT}/home": "var/home"},
    )


@pytest.mark.skipif(os.name == "nt", reason="POSIX link contract")
def test_root_owned_home_link_is_followed_to_its_canonical_path(monkeypatch) -> None:
    _ostree_home(monkeypatch)
    requested = Path(f"{FAKE_ROOT}/home/me/.config/godot-ai/capabilities")

    resolved = capability_module._reject_unsafe_posix_ancestors(requested)

    assert resolved == Path(f"{FAKE_ROOT}/var/home/me/.config/godot-ai/capabilities")
    assert record_path(8000, requested) == resolved / "http-8000.json"


@pytest.mark.skipif(os.name == "nt", reason="POSIX link contract")
def test_default_directory_resolves_through_the_home_link(monkeypatch) -> None:
    _ostree_home(monkeypatch)
    monkeypatch.delenv("GODOT_AI_CAPABILITY_DIR", raising=False)
    monkeypatch.delenv("XDG_CONFIG_HOME", raising=False)
    monkeypatch.setenv("HOME", f"{FAKE_ROOT}/home/me")
    monkeypatch.setattr(capability_module.sys, "platform", "linux")

    assert capability_directory() == Path(f"{FAKE_ROOT}/var/home/me/.config/godot-ai/capabilities")


@pytest.mark.skipif(os.name == "nt", reason="POSIX link contract")
def test_links_owned_by_another_account_fail_closed(monkeypatch) -> None:
    _ostree_home(monkeypatch, link_uid=os.getuid() + 1)

    with pytest.raises(OSError, match="link or reparse"):
        capability_module._reject_unsafe_posix_ancestors(Path(f"{FAKE_ROOT}/home/me/.config"))


@pytest.mark.skipif(os.name == "nt", reason="POSIX link contract")
def test_root_owned_link_in_a_writable_directory_fails_closed(monkeypatch) -> None:
    # /tmp is an accepted sticky ancestor, but a link inside it is not followed.
    me = os.getuid()
    _fake_tree(
        monkeypatch,
        {
            "/tmp": _directory(0, 0o1777),
            "/tmp/godot-ai-link": _link(0),
            f"{FAKE_ROOT}": _directory(0),
            f"{FAKE_ROOT}/real": _directory(me, 0o700),
        },
        {"/tmp/godot-ai-link": f"{FAKE_ROOT}/real"},
    )

    with pytest.raises(OSError, match="link or reparse"):
        capability_module._reject_unsafe_posix_ancestors(Path("/tmp/godot-ai-link/records"))


@pytest.mark.skipif(os.name == "nt", reason="POSIX link contract")
def test_link_chain_past_the_hop_bound_fails_closed(monkeypatch) -> None:
    _fake_tree(
        monkeypatch,
        {FAKE_ROOT: _directory(0), f"{FAKE_ROOT}/a": _link(0), f"{FAKE_ROOT}/b": _link(0)},
        {f"{FAKE_ROOT}/a": f"{FAKE_ROOT}/b", f"{FAKE_ROOT}/b": f"{FAKE_ROOT}/a"},
    )

    with pytest.raises(OSError, match="link or reparse"):
        capability_module._reject_unsafe_posix_ancestors(Path(f"{FAKE_ROOT}/a/records"))


@pytest.mark.skipif(os.name == "nt", reason="POSIX link contract")
def test_relative_parent_link_target_resolves_against_the_walked_parent(monkeypatch) -> None:
    # ostree's tmpfiles line: L /var/home - - - - ../sysroot/home
    me = os.getuid()
    _fake_tree(
        monkeypatch,
        {
            FAKE_ROOT: _directory(0),
            f"{FAKE_ROOT}/var": _directory(0),
            f"{FAKE_ROOT}/var/home": _link(0),
            f"{FAKE_ROOT}/sysroot": _directory(0),
            f"{FAKE_ROOT}/sysroot/home": _directory(0),
            f"{FAKE_ROOT}/sysroot/home/me": _directory(me, 0o700),
        },
        {f"{FAKE_ROOT}/var/home": "../sysroot/home"},
    )

    resolved = capability_module._reject_unsafe_posix_ancestors(
        Path(f"{FAKE_ROOT}/var/home/me/.config")
    )

    assert resolved == Path(f"{FAKE_ROOT}/sysroot/home/me/.config")


@pytest.mark.skipif(os.name == "nt", reason="POSIX link contract")
def test_target_ancestors_are_held_to_the_same_rule(monkeypatch) -> None:
    # A root-owned link may not lead into a tree another account can write to.
    _fake_tree(
        monkeypatch,
        {
            FAKE_ROOT: _directory(0),
            f"{FAKE_ROOT}/home": _link(0),
            f"{FAKE_ROOT}/shared": _directory(0, 0o777),
        },
        {f"{FAKE_ROOT}/home": f"{FAKE_ROOT}/shared"},
    )

    with pytest.raises(OSError, match="unsafe ancestor"):
        capability_module._reject_unsafe_posix_ancestors(Path(f"{FAKE_ROOT}/home/me"))


def test_private_mkdir_passes_no_mode_on_windows(tmp_path, monkeypatch) -> None:
    """CPython turns mode=0o700 into an OWNER RIGHTS-only DACL on Windows (#988)."""
    modes: list[int] = []
    real_mkdir = Path.mkdir

    def record(self, mode=0o777, parents=False, exist_ok=False):
        modes.append(mode)
        return real_mkdir(self, parents=parents, exist_ok=exist_ok)

    monkeypatch.setattr(Path, "mkdir", record)
    capability_module.private_mkdir(tmp_path / "windows", windows=True)
    capability_module.private_mkdir(tmp_path / "posix", windows=False)
    assert modes == [0o777, 0o700]


@pytest.mark.parametrize(
    "relative", ["godot-ai/capabilities", "godot-ai/.worktrees/project/custom/runtime"]
)
def test_windows_repair_hint_names_only_the_directory_to_repair(tmp_path, relative) -> None:
    directory = tmp_path / relative
    hint = capability_module.windows_repair_hint(directory)
    assert str(directory) in hint
    assert "Remove-Item" not in hint
    assert "permissions" in hint
    assert "elevated" in hint


def test_windows_repair_hint_is_non_destructive_outside_a_godot_ai_tree(tmp_path) -> None:
    hint = capability_module.windows_repair_hint(tmp_path / "custom" / "runtime")
    assert "Remove-Item" not in hint
    assert str(tmp_path / "custom" / "runtime") in hint
    assert "permissions" in hint


def test_directory_access_error_is_none_when_missing_or_writable(tmp_path) -> None:
    assert capability_module.directory_access_error(tmp_path / "missing") is None
    assert capability_module.directory_access_error(tmp_path) is None


@pytest.mark.skipif(os.name != "nt", reason="Windows access probe")
def test_directory_access_error_reports_a_failed_probe(tmp_path, monkeypatch) -> None:
    monkeypatch.setattr(
        capability_module, "_windows_access_probe", lambda _d: PermissionError(13, "denied")
    )
    hint = capability_module.directory_access_error(tmp_path)
    assert hint is not None
    assert str(tmp_path) in hint


@pytest.mark.skipif(os.name != "nt", reason="Windows access probe")
def test_publishing_into_an_unwritable_directory_raises_the_repair_hint(
    tmp_path, monkeypatch
) -> None:
    monkeypatch.setattr(
        capability_module, "_windows_access_probe", lambda _d: PermissionError(13, "denied")
    )
    directory = tmp_path / "godot-ai" / "capabilities"
    with pytest.raises(OSError) as exc_info:
        write_capabilities(8122, HTTP, WEBSOCKET, instance_nonce=NONCE, directory=directory)
    assert exc_info.value.errno == errno.EACCES
    assert "Remove-Item" not in str(exc_info.value)
    assert "permissions" in str(exc_info.value)
    assert str(directory) in str(exc_info.value)


@pytest.mark.skipif(os.name != "nt", reason="Windows DACL inheritance")
def test_windows_capability_directory_inherits_the_parent_acl(tmp_path) -> None:
    """The regression behind #988: the capability directory gets what a plain
    mkdir gets in this parent, never the explicit ``mode=0o700`` DACL."""
    directory = tmp_path / "godot-ai" / "capabilities"
    write_capabilities(8122, HTTP, WEBSOCKET, instance_nonce=NONCE, directory=directory)
    ## Two siblings define the environment: what a plain mkdir yields here is
    ## the baseline, and what ``mode=0o700`` yields is the #988 signature. A
    ## CI temp root can hand a plain child explicit, non-inherited ACEs of its
    ## own (pytest creates its temp tree with 0o700, and the release
    ## qualification row's C: profile temp shows OWNER RIGHTS on plain
    ## children), so the assertions compare against these siblings rather
    ## than against an absolute picture of inherited entries.
    control = directory.parent / "control"
    control.mkdir()
    restricted = directory.parent / "restricted"
    restricted.mkdir(mode=0o700)

    def aces(path: Path) -> list[str]:
        listing = subprocess.run(
            ["icacls", str(path)], capture_output=True, text=True, check=True
        ).stdout
        return sorted(
            line.replace(str(path), "").strip() for line in listing.splitlines() if ":(" in line
        )

    if aces(restricted) == aces(control):
        pytest.skip("this interpreter or volume gives mode=0o700 the plain-mkdir DACL")
    assert aces(directory) == aces(control)
    assert aces(directory) != aces(restricted)


@pytest.mark.skipif(os.name == "nt", reason="POSIX namespace ownership")
def test_steam_user_owned_root_and_home_link_resolve(monkeypatch) -> None:
    me = os.getuid()
    _fake_tree(
        monkeypatch,
        {
            "/": _directory(me),
            FAKE_ROOT: _directory(me),
            f"{FAKE_ROOT}/home": _link(me),
            f"{FAKE_ROOT}/var": _directory(me),
            f"{FAKE_ROOT}/var/home": _directory(me),
            f"{FAKE_ROOT}/var/home/me": _directory(me, 0o700),
        },
        {f"{FAKE_ROOT}/home": "var/home"},
    )
    assert capability_module._reject_unsafe_posix_ancestors(
        Path(f"{FAKE_ROOT}/home/me/.config/godot-ai/capabilities")
    ) == Path(f"{FAKE_ROOT}/var/home/me/.config/godot-ai/capabilities")


@pytest.mark.skipif(os.name == "nt", reason="POSIX namespace ownership")
@pytest.mark.parametrize("uid,mode", [("other", 0o755), ("self", 0o777)])
def test_namespace_root_must_be_trusted(monkeypatch, uid, mode) -> None:
    _fake_tree(
        monkeypatch,
        {
            "/": _directory(os.getuid() + 1 if uid == "other" else os.getuid(), mode),
        },
        {},
    )
    with pytest.raises(OSError, match="unsafe ancestor"):
        capability_module._reject_unsafe_posix_ancestors(Path(f"{FAKE_ROOT}/records"))


@pytest.mark.skipif(os.name == "nt", reason="POSIX link ownership")
@pytest.mark.parametrize("mode", [0o775, 0o777])
def test_same_user_link_does_not_bypass_writable_target(monkeypatch, mode) -> None:
    me = os.getuid()
    _fake_tree(
        monkeypatch,
        {
            FAKE_ROOT: _directory(me),
            f"{FAKE_ROOT}/home": _link(me),
            f"{FAKE_ROOT}/target": _directory(me, mode),
        },
        {f"{FAKE_ROOT}/home": "target"},
    )
    with pytest.raises(OSError, match="unsafe ancestor"):
        capability_module._reject_unsafe_posix_ancestors(Path(f"{FAKE_ROOT}/home/records"))


@pytest.mark.skipif(os.name == "nt", reason="POSIX namespace ownership contract")
@pytest.mark.parametrize("owner_uid", [65534, 1001])
def test_untrusted_ancestor_owner_remains_refused_with_shared_directory_guidance(
    monkeypatch, tmp_path, owner_uid
) -> None:
    from godot_ai import runtime_info

    monkeypatch.setattr(capability_module.os, "getuid", lambda: 1000)
    _fake_tree(
        monkeypatch,
        {
            FAKE_ROOT: _directory(1000),
            f"{FAKE_ROOT}/home": _link(1000),
            f"{FAKE_ROOT}/var": _directory(1000),
            f"{FAKE_ROOT}/var/home": _directory(owner_uid),
        },
        {f"{FAKE_ROOT}/home": "var/home"},
    )
    requested = Path(f"{FAKE_ROOT}/home/me/.config/godot-ai/capabilities")
    with pytest.raises(PermissionError) as failure:
        capability_module._reject_unsafe_posix_ancestors(requested)
    assert failure.value.errno == errno.EACCES
    assert Path(failure.value.filename) == Path(f"{FAKE_ROOT}/var/home")
    assert f"owner UID {owner_uid}" in str(failure.value)
    assert "current UID 1000" in str(failure.value)
    report = tmp_path / "startup.json"
    monkeypatch.setattr(runtime_info, "_STARTUP_REPORT_PATH", report)
    monkeypatch.setattr(runtime_info, "_STARTUP_REPORT_WRITTEN", False)
    assert runtime_info.report_startup_failure(failure.value) == report
    payload = json.loads(report.read_text(encoding="utf-8"))
    assert payload["error"] == "PermissionError"
    assert "GODOT_AI_CAPABILITY_DIR" in payload["message"]
    assert "Godot's launch environment" in payload["message"]
    assert "outside AI client's environment" in payload["message"]
    assert "Do not change system-directory" in payload["message"]
    assert payload["hint"] == ""
    assert len(payload["message"]) < 600


@pytest.mark.skipif(os.name == "nt", reason="POSIX namespace ownership contract")
def test_trusted_owner_writable_ancestor_keeps_permission_refusal(monkeypatch) -> None:
    monkeypatch.setattr(capability_module.os, "getuid", lambda: 1000)
    _fake_tree(
        monkeypatch,
        {FAKE_ROOT: _directory(1000), f"{FAKE_ROOT}/shared": _directory(1000, 0o777)},
        {},
    )
    with pytest.raises(PermissionError) as failure:
        capability_module._reject_unsafe_posix_ancestors(Path(f"{FAKE_ROOT}/shared/records"))
    assert failure.value.errno == errno.EACCES
    assert Path(failure.value.filename) == Path(f"{FAKE_ROOT}/shared")
    assert failure.value.strerror == "capability path has an unsafe ancestor"


HIDDEN_UID = 65534


@pytest.fixture(autouse=True)
def _outside_flatpak(monkeypatch, tmp_path) -> None:
    """Keep every test independent of whether the suite itself runs in Flatpak."""

    monkeypatch.setattr(capability_module, "_FLATPAK_INFO", tmp_path / "no-flatpak-info")


def _sandboxed_home(
    monkeypatch,
    *,
    ostree: bool = False,
    hidden_uid: int | None = HIDDEN_UID,
    home_parent: os.stat_result | None = None,
    extra: dict[str, os.stat_result] | None = None,
) -> Path:
    """A bubblewrap view: own tmpfs root, host-owned home parent bind-mounted in.

    Flatpak and Steam's pressure-vessel map only the invoking user, so the
    host's root-owned ``/home`` (``/var/home`` on ostree) reads as the overflow
    UID. Returns the capability directory requested through ``$HOME``.
    """

    me = os.getuid()
    parent = home_parent if home_parent is not None else _directory(HIDDEN_UID)
    entries = {FAKE_ROOT: _directory(me)}
    links = {}
    if ostree:
        entries[f"{FAKE_ROOT}/home"] = _link(me)
        entries[f"{FAKE_ROOT}/var"] = _directory(me)
        entries[f"{FAKE_ROOT}/var/home"] = parent
        links[f"{FAKE_ROOT}/home"] = "var/home"
        real_home = f"{FAKE_ROOT}/var/home/me"
    else:
        entries[f"{FAKE_ROOT}/home"] = parent
        real_home = f"{FAKE_ROOT}/home/me"
    entries[real_home] = _directory(me, 0o700)
    entries[f"{real_home}/.config"] = _directory(me, 0o700)
    entries.update(extra or {})
    _fake_tree(monkeypatch, entries, links)
    monkeypatch.setenv("HOME", f"{FAKE_ROOT}/home/me")
    monkeypatch.setattr(capability_module, "_unnameable_owner_uid", lambda: hidden_uid)
    return Path(f"{FAKE_ROOT}/home/me/.config/godot-ai/capabilities")


@pytest.mark.skipif(os.name == "nt", reason="POSIX namespace ownership")
@pytest.mark.parametrize("ostree", [False, True])
def test_hidden_owner_above_home_is_accepted_inside_a_user_namespace(monkeypatch, ostree) -> None:
    requested = _sandboxed_home(monkeypatch, ostree=ostree)
    home = f"{FAKE_ROOT}/var/home/me" if ostree else f"{FAKE_ROOT}/home/me"

    resolved = capability_module._reject_unsafe_posix_ancestors(requested)

    assert resolved == Path(f"{home}/.config/godot-ai/capabilities")
    assert record_path(8000, requested) == resolved / "http-8000.json"


@pytest.mark.skipif(os.name == "nt", reason="POSIX namespace ownership")
def test_hidden_owner_above_home_stays_refused_outside_a_user_namespace(monkeypatch) -> None:
    # In the initial namespace 65534 is the real ``nobody`` account.
    requested = _sandboxed_home(monkeypatch, hidden_uid=None)

    with pytest.raises(PermissionError, match="owner UID 65534") as failure:
        capability_module._reject_unsafe_posix_ancestors(requested)
    assert Path(failure.value.filename) == Path(f"{FAKE_ROOT}/home")


@pytest.mark.skipif(os.name == "nt", reason="POSIX namespace ownership")
def test_nameable_foreign_owner_above_home_stays_refused_in_a_user_namespace(monkeypatch) -> None:
    requested = _sandboxed_home(monkeypatch, home_parent=_directory(os.getuid() + 1))

    with pytest.raises(PermissionError, match="unsafe ancestor"):
        capability_module._reject_unsafe_posix_ancestors(requested)


@pytest.mark.skipif(os.name == "nt", reason="POSIX namespace ownership")
@pytest.mark.parametrize("mode", [0o775, 0o757, 0o777, 0o1777])
def test_hidden_owner_above_home_must_be_closed_to_group_and_other(monkeypatch, mode) -> None:
    requested = _sandboxed_home(monkeypatch, home_parent=_directory(HIDDEN_UID, mode))

    with pytest.raises(OSError, match="unsafe ancestor") as failure:
        capability_module._reject_unsafe_posix_ancestors(requested)
    assert Path(failure.value.filename) == Path(f"{FAKE_ROOT}/home")


@pytest.mark.skipif(os.name == "nt", reason="POSIX namespace ownership")
def test_hidden_owner_at_or_below_home_stays_refused(monkeypatch) -> None:
    home = f"{FAKE_ROOT}/home/me"
    requested = _sandboxed_home(monkeypatch, extra={f"{home}/.config": _directory(HIDDEN_UID)})
    with pytest.raises(PermissionError, match="owner UID 65534") as below:
        capability_module._reject_unsafe_posix_ancestors(requested)
    assert Path(below.value.filename) == Path(f"{home}/.config")

    requested = _sandboxed_home(monkeypatch, extra={home: _directory(HIDDEN_UID)})
    with pytest.raises(PermissionError, match="owner UID 65534") as at_home:
        capability_module._reject_unsafe_posix_ancestors(requested)
    assert Path(at_home.value.filename) == Path(home)


@pytest.mark.skipif(os.name == "nt", reason="POSIX namespace ownership")
def test_hidden_owner_outside_the_home_ancestry_stays_refused(monkeypatch) -> None:
    _sandboxed_home(
        monkeypatch,
        extra={
            f"{FAKE_ROOT}/srv": _directory(HIDDEN_UID),
            f"{FAKE_ROOT}/srv/shared": _directory(os.getuid(), 0o700),
        },
    )

    with pytest.raises(PermissionError, match="owner UID 65534") as failure:
        capability_module._reject_unsafe_posix_ancestors(Path(f"{FAKE_ROOT}/srv/shared/records"))
    assert Path(failure.value.filename) == Path(f"{FAKE_ROOT}/srv")


@pytest.mark.skipif(os.name == "nt", reason="POSIX namespace ownership")
def test_hidden_owner_link_is_followed_only_above_home(monkeypatch) -> None:
    # A plain ``bwrap --bind / /`` shows the host's own root-owned /home link.
    me = os.getuid()
    home = f"{FAKE_ROOT}/var/home/me"
    entries = {
        FAKE_ROOT: _directory(HIDDEN_UID),
        f"{FAKE_ROOT}/home": _link(HIDDEN_UID),
        f"{FAKE_ROOT}/var": _directory(HIDDEN_UID),
        f"{FAKE_ROOT}/var/home": _directory(HIDDEN_UID),
        home: _directory(me, 0o700),
        f"{home}/linked": _link(HIDDEN_UID),
        f"{home}/real": _directory(me, 0o700),
    }
    _fake_tree(
        monkeypatch,
        entries,
        {f"{FAKE_ROOT}/home": "var/home", f"{home}/linked": "real"},
    )
    monkeypatch.setenv("HOME", f"{FAKE_ROOT}/home/me")
    monkeypatch.setattr(capability_module, "_unnameable_owner_uid", lambda: HIDDEN_UID)

    assert capability_module._reject_unsafe_posix_ancestors(
        Path(f"{FAKE_ROOT}/home/me/real/records")
    ) == Path(f"{home}/real/records")
    with pytest.raises(OSError, match="link or reparse"):
        capability_module._reject_unsafe_posix_ancestors(
            Path(f"{FAKE_ROOT}/home/me/linked/records")
        )


@pytest.mark.skipif(os.name == "nt", reason="POSIX namespace ownership")
def test_unsafe_home_ancestry_grants_no_hidden_owner_trust(monkeypatch) -> None:
    # A writable directory on the way home voids the whole ancestry, so the
    # namespace root does not inherit trust from it.
    requested = _sandboxed_home(
        monkeypatch,
        home_parent=_directory(HIDDEN_UID, 0o777),
        extra={FAKE_ROOT: _directory(HIDDEN_UID)},
    )

    with pytest.raises(PermissionError, match="owner UID 65534") as failure:
        capability_module._reject_unsafe_posix_ancestors(requested)
    assert Path(failure.value.filename) == Path(FAKE_ROOT)


@pytest.mark.parametrize(
    "uid_map,overflow,expected",
    [
        ("         0          0 4294967295\n", "65534\n", None),
        ("      1000       1000          1\n", "65534\n", 65534),
        ("      1000          0          1\n", "65533\n", 65533),
        ("         0     100000      65536\n", "65534\n", 65534),
        ("      1000       1000          1\n", "not-a-uid\n", None),
        (None, "65534\n", None),
        ("      1000       1000          1\n", None, None),
    ],
)
def test_unnameable_owner_uid_exists_only_inside_a_user_namespace(
    monkeypatch, tmp_path, uid_map, overflow, expected
) -> None:
    for name, constant, content in (
        ("uid_map", "_USER_NAMESPACE_MAP", uid_map),
        ("overflowuid", "_OVERFLOW_UID", overflow),
    ):
        path = tmp_path / name
        if content is not None:
            path.write_text(content, encoding="ascii")
        monkeypatch.setattr(capability_module, constant, path)

    assert capability_module._unnameable_owner_uid() == expected


FLATPAK_INFO = """[Application]
name=org.godotengine.Godot
runtime=runtime/org.freedesktop.Sdk/x86_64/25.08

[Context]
shared=network;ipc;
sockets=x11;pulseaudio;
devices=all;
filesystems={filesystems}

[Instance]
instance-id=1234567890
flatpak-version=1.16.6
"""


def _flatpak_info(monkeypatch, tmp_path, filesystems: str | None) -> None:
    path = tmp_path / "flatpak-info"
    if filesystems is not None:
        path.write_text(FLATPAK_INFO.format(filesystems=filesystems), encoding="utf-8")
    monkeypatch.setattr(capability_module, "_FLATPAK_INFO", path)


@pytest.mark.parametrize(
    "filesystems,expected",
    [
        ("xdg-run/speech-dispatcher;host;", True),
        ("home;", True),
        ("xdg-run/speech-dispatcher;", False),
        ("home:ro;xdg-run/speech-dispatcher;", False),
        ("host:ro;", False),
        ("!home;xdg-config/godot-ai;", False),
        ("~/projects;host-os;host-etc;", False),
        ("", False),
        (None, False),
    ],
)
def test_flatpak_shares_home_only_with_a_read_write_home_grant(
    monkeypatch, tmp_path, filesystems, expected
) -> None:
    _flatpak_info(monkeypatch, tmp_path, filesystems)

    assert capability_module._flatpak_shares_home() is expected


def test_flatpak_filesystem_grants_are_read_from_the_context_group_only(
    monkeypatch, tmp_path
) -> None:
    path = tmp_path / "flatpak-info"
    path.write_text(
        "[Instance]\nfilesystems=host;\n\n[Context]\nfilesystems=xdg-run/app;\n", encoding="utf-8"
    )
    monkeypatch.setattr(capability_module, "_FLATPAK_INFO", path)

    assert capability_module._flatpak_shares_home() is False


@pytest.mark.skipif(os.name == "nt", reason="POSIX XDG path contract")
def test_flatpak_sharing_home_publishes_to_the_host_config_directory(monkeypatch, tmp_path) -> None:
    home = tmp_path / "home"
    sandbox_config = home / ".var" / "app" / "org.godotengine.Godot" / "config"
    sandbox_config.mkdir(parents=True, mode=0o700)
    monkeypatch.delenv("GODOT_AI_CAPABILITY_DIR", raising=False)
    monkeypatch.delenv("HOST_XDG_CONFIG_HOME", raising=False)
    monkeypatch.setenv("HOME", str(home))
    monkeypatch.setenv("XDG_CONFIG_HOME", str(sandbox_config))
    monkeypatch.setattr(capability_module.sys, "platform", "linux")
    host_default = (home / ".config" / "godot-ai" / "capabilities").resolve()

    _flatpak_info(monkeypatch, tmp_path, "xdg-run/speech-dispatcher;host;")
    assert capability_directory() == host_default

    # The host's own XDG_CONFIG_HOME reaches the sandbox under another name.
    host_config = tmp_path / "host-config"
    monkeypatch.setenv("HOST_XDG_CONFIG_HOME", str(host_config))
    assert capability_directory() == (host_config / "godot-ai" / "capabilities").resolve()
    monkeypatch.setenv("HOST_XDG_CONFIG_HOME", "relative/config")
    with pytest.raises(ValueError, match="HOST_XDG_CONFIG_HOME must be an absolute path"):
        capability_directory()


@pytest.mark.skipif(os.name == "nt", reason="POSIX XDG path contract")
@pytest.mark.parametrize("filesystems", ["xdg-run/speech-dispatcher;", "home:ro;", None])
def test_flatpak_without_a_writable_home_keeps_its_own_config_directory(
    monkeypatch, tmp_path, filesystems
) -> None:
    sandbox_config = tmp_path / "home" / ".var" / "app" / "org.godotengine.Godot" / "config"
    sandbox_config.mkdir(parents=True, mode=0o700)
    monkeypatch.delenv("GODOT_AI_CAPABILITY_DIR", raising=False)
    monkeypatch.setenv("HOST_XDG_CONFIG_HOME", str(tmp_path / "host-config"))
    monkeypatch.setenv("HOME", str(tmp_path / "home"))
    monkeypatch.setenv("XDG_CONFIG_HOME", str(sandbox_config))
    monkeypatch.setattr(capability_module.sys, "platform", "linux")
    _flatpak_info(monkeypatch, tmp_path, filesystems)

    assert capability_directory() == (sandbox_config / "godot-ai" / "capabilities").resolve()


@pytest.mark.skipif(os.name == "nt", reason="POSIX override contract")
def test_capability_directory_override_wins_inside_flatpak(monkeypatch, tmp_path) -> None:
    override = tmp_path / "shared"
    monkeypatch.setenv("GODOT_AI_CAPABILITY_DIR", str(override))
    monkeypatch.setenv("HOME", str(tmp_path / "home"))
    monkeypatch.setattr(capability_module.sys, "platform", "linux")
    _flatpak_info(monkeypatch, tmp_path, "host;")

    assert capability_directory() == override.resolve()
