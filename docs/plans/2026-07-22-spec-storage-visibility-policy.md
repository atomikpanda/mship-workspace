# Spec Storage & Visibility Policy Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Spec:** `spec-storage-visibility-policy` (approved) — `specs/2026-07-22-spec-storage-visibility-policy.md`

**Goal:** Add a per-workspace `spec_storage` policy (`committed` | `local` | `encrypted`) that transparently changes how `mship spec` persists specs on disk — plaintext-committed (today), plaintext-but-gitignored, or Fernet-ciphertext-committed — with the command UX identical across all three modes.

**Architecture:** A tiny key module (`core/spec_key.py`) owns a per-workspace Fernet key at `.mothership/spec-key`. A transparent storage layer (`core/spec_storage.py`, `SpecStorage`) decides each spec's on-disk filename and encoding from the mode: committed/local write plaintext `specs/<date>-<id>.md` (local additionally gitignores it), encrypted writes ciphertext `specs/<date>-<id>.md.enc`. Reads are **suffix-driven, not mode-driven** — a `.md` is always plaintext, a `.md.enc` is always decrypted with the key (or reported LOCKED without it) — so mixed/migrating stores and keyless serve readers behave correctly. `SpecStore` delegates its file I/O to a `SpecStorage`; a factory `spec_store_from_config` resolves the mode so every `mship spec` verb, serve, and `mship view spec` reader routes through one seam. Switching modes is an explicit `mship spec migrate-storage` that re-materialises each spec into the target representation and `git rm`s the old one.

**Tech Stack:** Python 3.14, Typer CLI, Pydantic v2 config models, FastAPI (`mship serve`), `cryptography` (Fernet) — added as a direct dependency (currently transitive via `pyjwt[crypto]`). pytest + `typer.testing.CliRunner` + FastAPI `TestClient`. `uv run pytest` to run tests.

---

## Key facts from the real code (read before starting)

The spec's Architecture assumed a `read(id)/write(id, text)` seam and a `specs/<id>.md` path. The **actual** code differs — the plan below is written against reality:

- **`core/spec_store.py`** — `SpecStore(specs_dir)` is **object-based**, not text-based:
  - `path_for(spec) -> Path` returns `<specs_dir>/<created_at:%Y-%m-%d>-<id>.md` (a **dated** filename, not `<id>.md`).
  - `save(spec) -> Path` writes `serialize_spec(spec)` atomically (tempfile + `os.replace`).
  - `load(path) -> Spec` = `parse_spec(path.read_text())`.
  - `list() -> list[Spec]` globs `*.md`; `find_by_id(id)` linear-scans `list()`.
  - Module functions `serialize_spec(spec) -> str` and `parse_spec(text) -> Spec` are the text codec. `SPECS_DIRNAME = "specs"`.
- **Two read paths bypass `SpecStore` entirely** and must also be routed, or encrypted mode silently breaks `mship view spec` and the dev-phase gate:
  - `core/view/spec_discovery.py::_find_in_specs_dir` — globs `*.md`, `parse_spec(p.read_text())`.
  - `core/view/spec_selection.py::scan_canonical_specs` — globs `*.md`, `parse_spec(p.read_text())`.
- **Writes are centralised** in `SpecStore.save` (good) — `core/spec_transition.py` (`approve_spec`/`request_changes_spec`) take a `store` and call `store.save`, so routing the store routes them for free.
- **`core/config.py`** — `WorkspaceConfig` is a Pydantic `BaseModel`; a `Literal[...]` field with a default is the field-add pattern, and an out-of-set value raises `ValidationError` inside `ConfigLoader.load` (fail-loud at load). See `default_scope`/`start_mode` for the exact style.
- **`core/serve.py::create_app`** already receives `config` and `workspace_root`; both `cli/serve.py` call sites pass them. `/specs` and `/specs/{spec_id}` use a `store = SpecStore(specs_dir)` built at the top of `create_app`.
- **`.mothership/` is already gitignored** (workspace repo `.gitignore` line 7), so `.mothership/spec-key` is covered by placement; the key module still ensures it defensively (idempotent).
- **`util/git.py::GitRunner`** already has `is_ignored(repo, pattern)` and `add_to_gitignore(repo, pattern)` (idempotent, line-membership check). It has **no** `rm`/`remove_from_gitignore` — this plan adds them (Task 6).
- **`cryptography`** is importable in the env; `Fernet.generate_key()` is 44 bytes urlsafe, ciphertext does not contain the plaintext, and `Fernet(key).decrypt(...)` round-trips.

## File Structure

**Create:**
- `src/mship/core/spec_key.py` — load/generate the Fernet key at `.mothership/spec-key`; `load_key`/`require_key`/`load_or_generate_key`; `encrypt`/`decrypt`; loud first-generation notice. One responsibility: the key + crypto primitives.
- `src/mship/core/spec_storage.py` — `SpecStorage` (mode → filename + encoding), `SpecLocked`, `spec_id_from_filename`, and the `spec_store_from_config` factory. One responsibility: the transparent on-disk policy.
- `tests/core/test_spec_key.py`, `tests/core/test_spec_storage.py`, `tests/core/test_config_spec_storage.py`, `tests/core/test_serve_spec_locked.py`, `tests/cli/test_spec_storage_cli.py`, `tests/cli/test_spec_migrate_storage.py`.

**Modify:**
- `src/mship/core/spec_store.py` — `SpecStore` delegates file I/O to an injected `SpecStorage` (default = committed, backward compatible).
- `src/mship/core/config.py` — add `spec_storage` field to `WorkspaceConfig`.
- `src/mship/cli/spec.py` — route every verb's store through `spec_store_from_config`; add the `migrate-storage` command; route `validate`'s direct file read.
- `src/mship/core/serve.py` — build a mode-aware store; make `/specs` + `/specs/{id}` LOCKED-aware.
- `src/mship/core/view/spec_discovery.py`, `src/mship/core/view/spec_selection.py` — route their direct globs/parses through `SpecStorage`.
- `src/mship/util/git.py` — add `rm` and `remove_from_gitignore` for migration.
- `pyproject.toml` — add `cryptography` to `dependencies`.
- `src/mship/skills/working-with-mothership/SKILL.md` — document the three modes + the key-loss warning.

---

<!-- mship:task id=1 -->
### Task 1: Spec key module + `cryptography` dependency

**Files:**
- Create: `src/mship/core/spec_key.py`
- Test: `tests/core/test_spec_key.py`
- Modify: `pyproject.toml` (add `cryptography` to `dependencies`)

- [ ] **Step 1: Add the dependency**

In `pyproject.toml`, inside `[project].dependencies`, add a line after `"pyjwt[crypto]>=2.8",`:

```toml
    "cryptography>=42",
```

Then sync: `uv sync` (Expected: resolves without error; `cryptography` was already present transitively).

- [ ] **Step 2: Write the failing tests**

Create `tests/core/test_spec_key.py`:

```python
from pathlib import Path

import pytest

from mship.core import spec_key
from mship.core.spec_key import SpecKeyMissing


def test_load_key_returns_none_when_absent(tmp_path: Path):
    assert spec_key.load_key(tmp_path) is None


def test_require_key_raises_when_absent(tmp_path: Path):
    with pytest.raises(SpecKeyMissing):
        spec_key.require_key(tmp_path)


def test_generate_creates_gitignored_keyfile_with_loud_notice(tmp_path: Path, capsys):
    key = spec_key.load_or_generate_key(tmp_path)
    keyfile = spec_key.keyfile_path(tmp_path)
    assert keyfile.is_file()
    assert keyfile.read_bytes() == key
    # 0600 perms so a stray key isn't world-readable.
    assert (keyfile.stat().st_mode & 0o077) == 0
    # Loud, one-time backup notice on first generation (stderr).
    err = capsys.readouterr().err
    assert "BACK THIS FILE UP" in err
    assert "unrecoverable" in err.lower()
    # Ensured gitignored: an entry exists (this tmp dir is not a git repo, so the
    # module falls back to appending to .gitignore).
    assert ".mothership/spec-key" in (tmp_path / ".gitignore").read_text()


def test_generate_is_idempotent_and_quiet_second_time(tmp_path: Path, capsys):
    first = spec_key.load_or_generate_key(tmp_path)
    capsys.readouterr()  # drain the first-generation notice
    second = spec_key.load_or_generate_key(tmp_path)
    assert first == second
    assert "BACK THIS FILE UP" not in capsys.readouterr().err


def test_encrypt_output_excludes_plaintext_and_round_trips(tmp_path: Path):
    key = spec_key.load_or_generate_key(tmp_path)
    plaintext = "## Problem\n\nsecret design intent\n"
    blob = spec_key.encrypt(key, plaintext)
    assert b"secret design intent" not in blob
    assert spec_key.decrypt(key, blob) == plaintext
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `uv run pytest tests/core/test_spec_key.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'mship.core.spec_key'`.

- [ ] **Step 4: Write the implementation**

Create `src/mship/core/spec_key.py`:

```python
"""Per-workspace Fernet key for encrypted-mode specs (spec-storage-visibility-policy).

The key lives at `<workspace_root>/.mothership/spec-key` (git-ignored — `.mothership/`
is already ignored in an mship workspace; we ensure it defensively). It is a single
symmetric key: the operator holds it and injects it into agents/workers the same way
the run token is injected. Losing it loses every encrypted spec — there is no escrow.
"""
from __future__ import annotations

import sys
from pathlib import Path

from cryptography.fernet import Fernet

from mship.util.git import GitRunner

KEYFILE_RELPATH = Path(".mothership") / "spec-key"

_GENERATED_NOTICE = (
    "\n"
    "  mship generated a new spec encryption key at:\n"
    "    {path}\n"
    "  BACK THIS FILE UP. It is the ONLY key to your encrypted specs.\n"
    "  Losing it makes every encrypted spec permanently unrecoverable — there is\n"
    "  no escrow or recovery. It is git-ignored and never committed or pushed.\n"
)


class SpecKeyMissing(Exception):
    """Encrypted-mode operation needs the key but `.mothership/spec-key` is absent."""


def keyfile_path(workspace_root: Path) -> Path:
    return Path(workspace_root) / KEYFILE_RELPATH


def load_key(workspace_root: Path) -> bytes | None:
    """The raw Fernet key bytes, or None when no keyfile exists (no generation)."""
    path = keyfile_path(workspace_root)
    if not path.is_file():
        return None
    return path.read_bytes()


def require_key(workspace_root: Path) -> bytes:
    """The key, or raise SpecKeyMissing (fail loud — never fall back to plaintext)."""
    key = load_key(workspace_root)
    if key is None:
        raise SpecKeyMissing(
            f"encrypted spec_storage requires a key at {keyfile_path(workspace_root)}, "
            f"but none was found. Generate one with an encrypted write, or restore your backup."
        )
    return key


def load_or_generate_key(workspace_root: Path, *, git: GitRunner | None = None) -> bytes:
    """Return the existing key, else generate + persist one (0600), ensure it is
    git-ignored, and print a loud one-time backup notice to stderr."""
    existing = load_key(workspace_root)
    if existing is not None:
        return existing

    path = keyfile_path(workspace_root)
    path.parent.mkdir(parents=True, exist_ok=True)
    key = Fernet.generate_key()
    # Write then tighten perms so the key is never briefly world-readable.
    path.write_bytes(key)
    path.chmod(0o600)

    _ensure_gitignored(Path(workspace_root), git or GitRunner())
    print(_GENERATED_NOTICE.format(path=path), file=sys.stderr)
    return key


def _ensure_gitignored(workspace_root: Path, git: GitRunner) -> None:
    pattern = str(KEYFILE_RELPATH)
    # `.mothership/` is already ignored in a real workspace, so is_ignored is True
    # and we skip. In a bare tmp dir (tests, fresh repo) it is not — append it.
    if not git.is_ignored(workspace_root, pattern):
        git.add_to_gitignore(workspace_root, pattern)


def encrypt(key: bytes, text: str) -> bytes:
    return Fernet(key).encrypt(text.encode("utf-8"))


def decrypt(key: bytes, blob: bytes) -> str:
    return Fernet(key).decrypt(blob).decode("utf-8")
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `uv run pytest tests/core/test_spec_key.py -v`
Expected: PASS (5 tests).

- [ ] **Step 6: Commit**

```bash
git add src/mship/core/spec_key.py tests/core/test_spec_key.py pyproject.toml uv.lock
git commit -m "feat(spec): per-workspace Fernet key module (spec-storage-visibility-policy ac5)"
mship journal "spec_key module: load/generate .mothership/spec-key, require_key fail-loud, encrypt/decrypt; cryptography dep; tests passing" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=2 -->
### Task 2: `spec_storage` config field + validation

**Files:**
- Modify: `src/mship/core/config.py` (add field to `WorkspaceConfig`)
- Test: `tests/core/test_config_spec_storage.py`

- [ ] **Step 1: Write the failing tests**

Create `tests/core/test_config_spec_storage.py`:

```python
from pathlib import Path

import pytest
from pydantic import ValidationError

from mship.core.config import ConfigLoader, WorkspaceConfig


def test_spec_storage_defaults_to_committed():
    cfg = WorkspaceConfig(workspace="demo")
    assert cfg.spec_storage == "committed"


def test_spec_storage_accepts_each_mode():
    for mode in ("committed", "local", "encrypted"):
        assert WorkspaceConfig(workspace="demo", spec_storage=mode).spec_storage == mode


def test_invalid_spec_storage_value_rejected_by_model():
    with pytest.raises(ValidationError):
        WorkspaceConfig(workspace="demo", spec_storage="public")


def test_invalid_spec_storage_fails_at_config_load(tmp_path: Path):
    (tmp_path / "mothership.yaml").write_text(
        "workspace: demo\nspec_storage: public\n"
    )
    with pytest.raises(ValidationError):
        ConfigLoader.load(tmp_path / "mothership.yaml", require_paths=False)
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `uv run pytest tests/core/test_config_spec_storage.py -v`
Expected: FAIL — `test_spec_storage_defaults_to_committed` errors on the missing attribute; the invalid-value tests fail because `public` is currently accepted (extra field ignored / no field).

- [ ] **Step 3: Write the implementation**

In `src/mship/core/config.py`, add to `WorkspaceConfig` (next to `default_scope`, keeping the commented-field style). The `Literal` import is already present at the top of the file:

```python
    # Where this workspace's specs live on disk + who can read them
    # (spec-storage-visibility-policy). `committed` (default) = today's behaviour:
    # plaintext `specs/<date>-<id>.md`, committed + pushed. `local` = same plaintext
    # file but git-ignored (kept on this machine, never pushed). `encrypted` =
    # Fernet ciphertext `specs/<date>-<id>.md.enc`, committed to the repo but
    # unreadable without `.mothership/spec-key`. Applied transparently by
    # core/spec_storage.py; an invalid value fails loud at config load.
    spec_storage: Literal["committed", "local", "encrypted"] = "committed"
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `uv run pytest tests/core/test_config_spec_storage.py -v`
Expected: PASS (4 tests).

- [ ] **Step 5: Run the full config suite (no regressions)**

Run: `uv run pytest tests/core/test_config.py -q`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add src/mship/core/config.py tests/core/test_config_spec_storage.py
git commit -m "feat(config): spec_storage policy field, default committed (spec-storage-visibility-policy ac1)"
mship journal "spec_storage config field (committed|local|encrypted); invalid value fails at load; tests passing" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=3 -->
### Task 3: The `SpecStorage` layer + `SpecStore` delegation (the security core)

**Files:**
- Create: `src/mship/core/spec_storage.py`
- Modify: `src/mship/core/spec_store.py` (delegate I/O to a `SpecStorage`)
- Test: `tests/core/test_spec_storage.py`

- [ ] **Step 1: Write the failing tests**

Create `tests/core/test_spec_storage.py`:

```python
import subprocess
from datetime import datetime, timezone
from pathlib import Path

import pytest

from mship.core import spec_key
from mship.core.spec import Spec
from mship.core.spec_key import SpecKeyMissing
from mship.core.spec_storage import SpecLocked, SpecStorage, spec_id_from_filename
from mship.core.spec_store import SPECS_DIRNAME, SpecStore, serialize_spec


def _spec():
    now = datetime(2026, 7, 22, 10, 0, 0, tzinfo=timezone.utc)
    return Spec(
        id="secret-thing", title="Secret thing", status="draft",
        created_at=now, updated_at=now,
        body="## Problem\n\nTHE-SECRET-MARKER design intent\n",
    )


def _git_init(root: Path) -> None:
    subprocess.run(["git", "init", "-q"], cwd=root, check=True)
    subprocess.run(["git", "config", "user.email", "t@t"], cwd=root, check=True)
    subprocess.run(["git", "config", "user.name", "t"], cwd=root, check=True)


def _store(root: Path, mode: str) -> SpecStore:
    specs_dir = root / SPECS_DIRNAME
    storage = SpecStorage(specs_dir, mode=mode, workspace_root=root)
    return SpecStore(specs_dir, storage=storage)


def test_committed_write_is_byte_identical_to_serialize(tmp_path: Path):
    spec = _spec()
    path = _store(tmp_path, "committed").save(spec)
    assert path.name == "2026-07-22-secret-thing.md"
    assert path.read_text() == serialize_spec(spec)


def test_committed_round_trips(tmp_path: Path):
    store = _store(tmp_path, "committed")
    store.save(_spec())
    assert store.find_by_id("secret-thing").body.startswith("## Problem")


def test_encrypted_write_leaves_ciphertext_on_disk(tmp_path: Path):
    """SECURITY: the plaintext markdown must NOT appear in the committed file, and
    the plaintext `.md` path must never be written under encrypted mode."""
    store = _store(tmp_path, "encrypted")
    path = store.save(_spec())
    assert path.name == "2026-07-22-secret-thing.md.enc"
    blob = path.read_bytes()
    assert b"THE-SECRET-MARKER" not in blob
    assert b"## Problem" not in blob
    # The plaintext committed path was never created.
    assert not (tmp_path / SPECS_DIRNAME / "2026-07-22-secret-thing.md").exists()


def test_encrypted_round_trips_with_key(tmp_path: Path):
    store = _store(tmp_path, "encrypted")
    store.save(_spec())
    loaded = store.find_by_id("secret-thing")
    assert "THE-SECRET-MARKER" in loaded.body


def test_no_key_holder_cannot_read_encrypted_spec(tmp_path: Path):
    """SECURITY: after the key is removed, decoding yields SpecLocked, never plaintext."""
    store = _store(tmp_path, "encrypted")
    path = store.save(_spec())
    spec_key.keyfile_path(tmp_path).unlink()
    storage = SpecStorage(tmp_path / SPECS_DIRNAME, mode="encrypted", workspace_root=tmp_path)
    with pytest.raises(SpecLocked) as exc:
        storage.decode_file(path)
    assert exc.value.spec_id == "secret-thing"


def test_encrypted_read_without_key_never_returns_plaintext(tmp_path: Path):
    store = _store(tmp_path, "encrypted")
    path = store.save(_spec())
    spec_key.keyfile_path(tmp_path).unlink()
    # Nothing on disk or reachable exposes the marker.
    assert b"THE-SECRET-MARKER" not in path.read_bytes()


def test_local_write_is_plaintext_but_gitignored_and_untracked(tmp_path: Path):
    """SECURITY: local mode is fully readable locally yet never a committable file."""
    _git_init(tmp_path)
    store = _store(tmp_path, "local")
    path = store.save(_spec())
    assert path.name == "2026-07-22-secret-thing.md"
    assert "THE-SECRET-MARKER" in path.read_text()  # plaintext, usable locally
    # Gitignored:
    check = subprocess.run(
        ["git", "check-ignore", "-q", str(path.relative_to(tmp_path))], cwd=tmp_path
    )
    assert check.returncode == 0
    # And absent from `git status` as a trackable file:
    status = subprocess.run(
        ["git", "status", "--porcelain"], cwd=tmp_path, capture_output=True, text=True
    ).stdout
    assert "secret-thing" not in status


def test_read_is_suffix_driven_across_mixed_store(tmp_path: Path):
    """A committed .md and an encrypted .md.enc coexist (mid-migration); list() surfaces both."""
    _store(tmp_path, "committed").save(_spec())
    other = _spec()
    other.id = "also-secret"
    _store(tmp_path, "encrypted").save(other)
    ids = {s.id for s in _store(tmp_path, "committed").list()}
    assert ids == {"secret-thing", "also-secret"}


def test_spec_id_from_filename():
    assert spec_id_from_filename(Path("2026-07-22-foo-bar.md")) == "foo-bar"
    assert spec_id_from_filename(Path("2026-07-22-foo-bar.md.enc")) == "foo-bar"
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `uv run pytest tests/core/test_spec_storage.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'mship.core.spec_storage'`.

- [ ] **Step 3: Write `core/spec_storage.py`**

Create `src/mship/core/spec_storage.py`:

```python
"""Transparent per-workspace spec storage policy (spec-storage-visibility-policy).

`SpecStorage` decides each spec's on-disk filename + encoding from the workspace
`spec_storage` mode. WRITES honour the mode:
  - committed -> plaintext `specs/<date>-<id>.md`
  - local     -> plaintext `specs/<date>-<id>.md` + ensure `specs/*.md` gitignored
  - encrypted -> Fernet ciphertext `specs/<date>-<id>.md.enc`
READS are suffix-driven, NOT mode-driven: a `.md` is always plaintext, a `.md.enc`
is always decrypted with the key (or reported LOCKED without it). That keeps
half-migrated stores and keyless serve readers correct regardless of the mode.
"""
from __future__ import annotations

import re
import tempfile
from pathlib import Path
from typing import Iterator, Literal

from mship.core import spec_key
from mship.util.git import GitRunner

SpecMode = Literal["committed", "local", "encrypted"]

# Physical encrypted file is `<date>-<id>.md.enc` (the logical stem keeps `.md`).
ENC_SUFFIX = ".enc"

_ID_RE = re.compile(r"^\d{4}-\d{2}-\d{2}-(?P<id>.+)$")


class SpecLocked(Exception):
    """A `.md.enc` spec could not be decoded because no key is present."""

    def __init__(self, spec_id: str) -> None:
        super().__init__(f"spec {spec_id!r} is encrypted and no key is available")
        self.spec_id = spec_id


def spec_id_from_filename(path: Path) -> str:
    """`2026-07-22-foo-bar.md[.enc]` -> `foo-bar`. Best-effort: strips the suffix
    and the leading `YYYY-MM-DD-`, so a locked spec's id is still knowable."""
    name = path.name
    if name.endswith(ENC_SUFFIX):
        name = name[: -len(ENC_SUFFIX)]
    if name.endswith(".md"):
        name = name[: -len(".md")]
    m = _ID_RE.match(name)
    return m.group("id") if m else name


class SpecStorage:
    def __init__(
        self,
        specs_dir: Path,
        mode: SpecMode = "committed",
        *,
        workspace_root: Path | None = None,
        git: GitRunner | None = None,
    ) -> None:
        self.specs_dir = Path(specs_dir)
        self.mode: SpecMode = mode
        # specs_dir is `<workspace_root>/specs`; derive the root when not given so
        # read-only callers (spec_discovery/spec_selection) need no extra plumbing.
        self.workspace_root = Path(workspace_root) if workspace_root else self.specs_dir.parent
        self._git = git or GitRunner()

    # --- path resolution -------------------------------------------------
    def physical_path(self, stem: Path) -> Path:
        """Map a logical `.md` stem (from SpecStore.path_for) to the on-disk file
        for the current WRITE mode."""
        stem = Path(stem)
        if self.mode == "encrypted":
            return stem.with_name(stem.name + ENC_SUFFIX)
        return stem

    def iter_physical(self) -> list[Path]:
        """Every on-disk spec file, both plaintext and ciphertext, sorted."""
        if not self.specs_dir.is_dir():
            return []
        return sorted(
            [*self.specs_dir.glob("*.md"), *self.specs_dir.glob("*.md" + ENC_SUFFIX)]
        )

    # --- write -----------------------------------------------------------
    def write(self, stem: Path, text: str) -> Path:
        self.specs_dir.mkdir(parents=True, exist_ok=True)
        physical = self.physical_path(stem)
        if self.mode == "encrypted":
            key = spec_key.load_or_generate_key(self.workspace_root, git=self._git)
            self._atomic_write_bytes(physical, spec_key.encrypt(key, text))
        else:
            self._atomic_write_text(physical, text)
            if self.mode == "local":
                self._git.add_to_gitignore(self.workspace_root, f"{self.specs_dir.name}/*.md")
        return physical

    # --- read ------------------------------------------------------------
    def decode_file(self, path: Path) -> str:
        """Plaintext of an on-disk spec file. Raises SpecLocked for a `.md.enc`
        with no key — never returns ciphertext or plaintext-fallback."""
        path = Path(path)
        if path.name.endswith(".md" + ENC_SUFFIX):
            key = spec_key.load_key(self.workspace_root)
            if key is None:
                raise SpecLocked(spec_id_from_filename(path))
            return spec_key.decrypt(key, path.read_bytes())
        return path.read_text()

    def read_all(self) -> Iterator[tuple[object | None, str | None, Path]]:
        """Yield (spec_or_None, locked_id_or_None, path) for every spec file.
        Locked (undecryptable) files yield (None, <id>, path); unparseable files
        are skipped. Used by LOCKED-aware readers (serve)."""
        from mship.core.spec_store import SpecParseError, parse_spec

        for path in self.iter_physical():
            try:
                text = self.decode_file(path)
            except SpecLocked as locked:
                yield (None, locked.spec_id, path)
                continue
            try:
                yield (parse_spec(text), None, path)
            except SpecParseError:
                continue

    # --- atomic write helpers (mirror SpecStore.save) --------------------
    def _atomic_write_text(self, path: Path, text: str) -> None:
        self._atomic_write_bytes(path, text.encode("utf-8"))

    def _atomic_write_bytes(self, path: Path, data: bytes) -> None:
        fd, tmp = tempfile.mkstemp(dir=self.specs_dir, suffix=".tmp")
        try:
            with open(fd, "wb") as f:
                f.write(data)
            Path(tmp).replace(path)
        except Exception:
            Path(tmp).unlink(missing_ok=True)
            raise


def spec_store_from_config(workspace_root: Path, config) -> "SpecStore":
    """Build a mode-aware SpecStore from a WorkspaceConfig. Single source of the
    mode->store mapping: every `mship spec` verb / serve / view reader uses this."""
    from mship.core.spec_store import SPECS_DIRNAME, SpecStore

    specs_dir = Path(workspace_root) / SPECS_DIRNAME
    mode = getattr(config, "spec_storage", "committed")
    storage = SpecStorage(specs_dir, mode=mode, workspace_root=Path(workspace_root))
    return SpecStore(specs_dir, storage=storage)
```

- [ ] **Step 4: Wire `SpecStore` to delegate to a `SpecStorage`**

In `src/mship/core/spec_store.py`, change `SpecStore` so its I/O goes through a `SpecStorage`. Replace the `save`/`load`/`list` bodies and the `__init__`:

```python
class SpecStore:
    """Filesystem registry for markdown-canonical specs under `specs/`.

    All on-disk representation (plaintext vs Fernet ciphertext, filename suffix,
    gitignore) is delegated to a `SpecStorage` (spec-storage-visibility-policy).
    A None storage defaults to committed mode — today's behaviour — so the many
    call sites and tests that construct `SpecStore(dir)` are unchanged.
    """

    def __init__(self, specs_dir: Path, storage=None) -> None:
        self._dir = Path(specs_dir)
        if storage is None:
            from mship.core.spec_storage import SpecStorage
            storage = SpecStorage(self._dir, mode="committed")
        self._storage = storage

    def path_for(self, spec: Spec) -> Path:
        """Logical `.md` stem for a spec: `<specs_dir>/<created_at date>-<id>.md`.
        The physical filename (e.g. `.md.enc` under encrypted mode) is resolved by
        the storage layer at write time."""
        if not spec.id or "/" in spec.id or "\\" in spec.id or spec.id in (".", "..") or spec.id.startswith("."):
            raise ValueError(f"unsafe spec id for filename: {spec.id!r}")
        return self._dir / f"{spec.created_at:%Y-%m-%d}-{spec.id}.md"

    def save(self, spec: Spec) -> Path:
        return self._storage.write(self.path_for(spec), serialize_spec(spec))

    def load(self, path: Path) -> Spec:
        return parse_spec(self._storage.decode_file(Path(path)))

    def list(self) -> list[Spec]:
        out: list[Spec] = []
        for p in self._storage.iter_physical():
            out.append(self.load(p))
        return out

    def find_by_id(self, spec_id: str) -> Spec | None:
        for spec in self.list():
            if spec.id == spec_id:
                return spec
        return None
```

Leave `parse_spec`, `serialize_spec`, `SPECS_DIRNAME`, and `SpecParseError` exactly as they are. (The old `save` body's `tempfile`/`yaml`/`ValidationError` imports at the top of the file stay — `tempfile` is now unused by `SpecStore` but is still imported at module scope; leave the import block untouched to keep the diff surgical, or drop `import tempfile` if your linter flags it, since the atomic write moved into `SpecStorage`.)

- [ ] **Step 5: Run the tests to verify they pass**

Run: `uv run pytest tests/core/test_spec_storage.py tests/core/test_spec_store.py -v`
Expected: PASS — the new storage tests plus the existing `test_spec_store.py` suite (backward-compatible default).

- [ ] **Step 6: Commit**

```bash
git add src/mship/core/spec_storage.py src/mship/core/spec_store.py tests/core/test_spec_storage.py
git commit -m "feat(spec): transparent SpecStorage layer + SpecStore delegation (spec-storage-visibility-policy ac3,ac4)"
mship journal "SpecStorage: committed/local/encrypted write, suffix-driven read, SpecLocked; SpecStore delegates I/O; ciphertext-on-disk + local-untracked + fail-loud tests passing" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=4 -->
### Task 4: Route `mship spec` verbs + view readers through the layer

**Files:**
- Modify: `src/mship/cli/spec.py` (every verb's store; `validate`'s direct read)
- Modify: `src/mship/core/view/spec_discovery.py` (`_find_in_specs_dir`)
- Modify: `src/mship/core/view/spec_selection.py` (`scan_canonical_specs`)
- Test: `tests/cli/test_spec_storage_cli.py`

- [ ] **Step 1: Write the failing test**

Create `tests/cli/test_spec_storage_cli.py`:

```python
import json
from pathlib import Path

import pytest
from typer.testing import CliRunner

from mship.cli import app, container

runner = CliRunner()


@pytest.fixture
def encrypted_workspace(tmp_path: Path):
    (tmp_path / "mothership.yaml").write_text(
        "workspace: demo\nspec_storage: encrypted\n"
    )
    state_dir = tmp_path / ".mothership"
    state_dir.mkdir()
    container.config.reset()
    container.state_manager.reset()
    container.log_manager.reset()
    container.config_path.override(tmp_path / "mothership.yaml")
    container.state_dir.override(state_dir)
    yield tmp_path
    container.config_path.reset()
    container.state_dir.reset()
    container.config.reset()


def test_spec_new_under_encrypted_writes_ciphertext(encrypted_workspace: Path):
    res = runner.invoke(app, ["--json", "spec", "new", "--title", "Hidden plan", "--id", "hidden-plan"])
    assert res.exit_code == 0, res.output
    enc = list((encrypted_workspace / "specs").glob("*.md.enc"))
    assert len(enc) == 1
    assert b"Hidden plan" not in enc[0].read_bytes()
    # No plaintext committed path exists.
    assert list((encrypted_workspace / "specs").glob("*.md")) == []


def test_spec_show_decrypts_with_key(encrypted_workspace: Path):
    runner.invoke(app, ["spec", "new", "--title", "Hidden plan", "--id", "hidden-plan"])
    res = runner.invoke(app, ["--json", "spec", "show", "hidden-plan"])
    assert res.exit_code == 0, res.output
    data = json.loads(res.output)
    assert data["title"] == "Hidden plan"


def test_spec_list_under_encrypted(encrypted_workspace: Path):
    runner.invoke(app, ["spec", "new", "--title", "Hidden plan", "--id", "hidden-plan"])
    res = runner.invoke(app, ["--json", "spec", "list"])
    assert res.exit_code == 0, res.output
    ids = [s["id"] for s in json.loads(res.output)["specs"]]
    assert "hidden-plan" in ids
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `uv run pytest tests/cli/test_spec_storage_cli.py -v`
Expected: FAIL — the verbs still build a committed-mode `SpecStore`, so `spec new` writes plaintext `.md` (the `*.md.enc` assertion and the empty-`*.md` assertion both fail).

- [ ] **Step 3: Route the CLI verbs**

In `src/mship/cli/spec.py`, every command builds `store = SpecStore(workspace_root / SPECS_DIRNAME)` (or the `Path(container.config_path()).parent / SPECS_DIRNAME` variant). Replace each of those constructions with the config-aware factory. The mechanical change in each verb:

```python
# was: from mship.core.spec_store import SpecStore, SPECS_DIRNAME
#      store = SpecStore(workspace_root / SPECS_DIRNAME)
from mship.core.spec_storage import spec_store_from_config
store = spec_store_from_config(workspace_root, container.get_container().config()) \
    if False else spec_store_from_config(Path(container.config_path()).parent, container.config())
```

Concretely, in **each** verb (`new`, `draft`, `apply`, `review`, `verdict`, `evidence`, `questions`, `ask`, `answer`, `approve`, `from_thread`, `dispatch`, `request_changes`, `list_specs`, `show_spec`, `_simple_transition`) do:

```python
from mship.core.spec_storage import spec_store_from_config
workspace_root = Path(container.config_path()).parent
store = spec_store_from_config(workspace_root, container.config())
```

replacing the existing `SpecStore(...)` line (keep the existing `workspace_root` local where a verb already computes it; drop the now-unused `SpecStore` import from that verb if it becomes unused). `container.config()` returns the loaded `WorkspaceConfig`.

For `from_thread`, the local is named `spec_store` — keep the name:
```python
spec_store = spec_store_from_config(workspace_root, container.config())
```

For `validate`, which reads the file **directly** (`parse_spec(matches[0].read_text())`) and globs `*.md`, route it through the store's decode so encrypted specs validate:

```python
# was: matches = sorted(specs_dir.glob(f"*-{spec_id}.md")) ; parse_spec(matches[0].read_text())
from mship.core.spec_storage import spec_store_from_config
store = spec_store_from_config(workspace_root, container.config())
spec = store.find_by_id(spec_id)
if spec is None:
    output.error(f"No spec file for id {spec_id!r} in {workspace_root / SPECS_DIRNAME}.")
    raise typer.Exit(1)
# then use `spec` for the id/body checks below (drop the raw glob + read_text + parse_spec)
```

- [ ] **Step 4: Route the two direct view readers**

In `src/mship/core/view/spec_discovery.py`, `_find_in_specs_dir` currently globs `*.md` and calls `parse_spec`. Replace its body to use `SpecStorage` so it also finds `.md.enc` and decrypts:

```python
def _find_in_specs_dir(workspace_root: Path, *, spec_id=None, task_slug=None):
    """Return the path of a spec file in `<workspace_root>/specs` matching
    `spec_id` (frontmatter id) or `task_slug` (bound task), else None. Suffix-aware
    (plaintext + encrypted); a locked encrypted spec is skipped."""
    from mship.core.spec_storage import SpecStorage
    specs_dir = workspace_root / SPECS_DIR
    if not specs_dir.is_dir():
        return None
    storage = SpecStorage(specs_dir, workspace_root=workspace_root)
    for spec, locked_id, path in storage.read_all():
        if spec is None:
            continue  # locked: cannot match on frontmatter
        if spec_id is not None and spec.id == spec_id:
            return path
        if task_slug is not None and spec.task_slug == task_slug:
            return path
    return None
```

In `src/mship/core/view/spec_selection.py`, `scan_canonical_specs` similarly:

```python
def scan_canonical_specs(specs_dir: Path) -> list[tuple[Spec, Path]]:
    """... (docstring unchanged) ... Suffix-aware: reads plaintext `.md` and
    decrypts `.md.enc` with the workspace key; a locked encrypted spec is skipped."""
    from mship.core.spec_storage import SpecStorage
    if not specs_dir.is_dir():
        return []
    storage = SpecStorage(specs_dir)  # workspace_root defaults to specs_dir.parent
    out: list[tuple[Spec, Path]] = []
    for spec, locked_id, path in storage.read_all():
        if spec is None:
            continue
        out.append((spec, path))
    return sorted(out, key=lambda sp: _sort_key(sp[0]))
```

(`read_all` already swallows `SpecParseError`; `SpecStorage` reading a `.md` never raises `SpecLocked`, so plaintext workspaces behave exactly as before.)

- [ ] **Step 5: Run the tests to verify they pass**

Run: `uv run pytest tests/cli/test_spec_storage_cli.py tests/cli/test_spec.py tests/cli/test_spec_list_show.py -v`
Expected: PASS — new encrypted-CLI tests plus the existing committed-mode CLI suites (unchanged behaviour when no `spec_storage` key / committed).

- [ ] **Step 6: Commit**

```bash
git add src/mship/cli/spec.py src/mship/core/view/spec_discovery.py src/mship/core/view/spec_selection.py tests/cli/test_spec_storage_cli.py
git commit -m "feat(spec): route mship spec verbs + view readers through storage layer (spec-storage-visibility-policy ac2)"
mship journal "routed all mship spec verbs + spec_discovery/spec_selection through spec_store_from_config; encrypted CLI create/show/list tests passing" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=5 -->
### Task 5: serve / Ground Control encrypted display + LOCKED state

**Files:**
- Modify: `src/mship/core/serve.py` (`create_app`: mode-aware store; LOCKED-aware `/specs` + `/specs/{id}`)
- Test: `tests/core/test_serve_spec_locked.py`

- [ ] **Step 1: Write the failing test**

Create `tests/core/test_serve_spec_locked.py`:

```python
from datetime import datetime, timezone
from pathlib import Path

from fastapi.testclient import TestClient

from mship.core import spec_key
from mship.core.config import WorkspaceConfig
from mship.core.serve import create_app
from mship.core.spec import Spec
from mship.core.spec_storage import SpecStorage
from mship.core.spec_store import SPECS_DIRNAME, SpecStore


class _NullState:
    def load(self):
        from mship.core.state import WorkspaceState
        return WorkspaceState(tasks={})


def _write_encrypted_spec(root: Path) -> None:
    now = datetime(2026, 7, 22, tzinfo=timezone.utc)
    spec = Spec(id="locked-one", title="Locked one", status="needs_review",
                created_at=now, updated_at=now, body="## Problem\n\nSECRET\n")
    storage = SpecStorage(root / SPECS_DIRNAME, mode="encrypted", workspace_root=root)
    SpecStore(root / SPECS_DIRNAME, storage=storage).save(spec)


def _client(root: Path) -> TestClient:
    cfg = WorkspaceConfig(workspace="demo", spec_storage="encrypted")
    app = create_app(
        specs_dir=root / SPECS_DIRNAME,
        state_manager=_NullState(),
        log_manager=None,
        workspace_root=root,
        config=cfg,
    )
    return TestClient(app)


def test_serve_decrypts_specs_with_key(tmp_path: Path):
    _write_encrypted_spec(tmp_path)
    body = _client(tmp_path).get("/specs").json()
    row = next(s for s in body if s["id"] == "locked-one")
    assert row["title"] == "Locked one"
    assert row.get("locked") is False


def test_serve_shows_locked_state_without_key(tmp_path: Path):
    _write_encrypted_spec(tmp_path)
    spec_key.keyfile_path(tmp_path).unlink()
    body = _client(tmp_path).get("/specs").json()
    row = next(s for s in body if s["id"] == "locked-one")
    assert row["locked"] is True
    assert row["status"] == "locked"
    assert row["title"] is None
    # No ciphertext leaked into the response.
    assert "gAAAA" not in str(body)


def test_serve_get_locked_spec_returns_marker_not_error(tmp_path: Path):
    _write_encrypted_spec(tmp_path)
    spec_key.keyfile_path(tmp_path).unlink()
    resp = _client(tmp_path).get("/specs/locked-one")
    assert resp.status_code == 200
    data = resp.json()
    assert data["id"] == "locked-one" and data["locked"] is True
    assert "SECRET" not in resp.text
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `uv run pytest tests/core/test_serve_spec_locked.py -v`
Expected: FAIL — `create_app` builds `store = SpecStore(specs_dir)` (committed mode), so it globs `*.md`, misses the `.md.enc`, and returns an empty list; and there is no `locked` key.

- [ ] **Step 3: Build a mode-aware store + LOCKED-aware endpoints**

In `src/mship/core/serve.py`, inside `create_app`, replace the `store = SpecStore(specs_dir)` construction (around line 291) with a mode-aware store plus its storage handle:

```python
    from mship.core.spec_store import SpecStore
    from mship.core.spec_storage import SpecStorage

    _spec_mode = getattr(config, "spec_storage", "committed") if config is not None else "committed"
    _spec_storage = SpecStorage(specs_dir, mode=_spec_mode, workspace_root=workspace_root)
    store = SpecStore(specs_dir, storage=_spec_storage)
```

Replace the `/specs` list handler (around line 359) to be LOCKED-aware:

```python
    @app.get("/specs")
    def list_specs():
        out = []
        for spec, locked_id, _path in _spec_storage.read_all():
            if spec is None:
                out.append({
                    "id": locked_id, "locked": True, "status": "locked",
                    "title": None, "task_slug": None, "affected_repos": [],
                })
            else:
                out.append({
                    "id": spec.id, "title": spec.title, "status": spec.status,
                    "task_slug": spec.task_slug, "affected_repos": spec.affected_repos,
                    "locked": False,
                })
        return out
```

Replace the `/specs/{spec_id}` handler (around line 366) so a locked spec returns a marker (200), not ciphertext and not a 500. The existing `store.find_by_id` will raise `SpecLocked` when the key is absent, so guard it:

```python
    @app.get("/specs/{spec_id}")
    def get_spec(spec_id: str):
        from mship.core.spec_storage import SpecLocked
        try:
            spec = store.find_by_id(spec_id)
        except SpecLocked:
            return {"id": spec_id, "locked": True, "status": "locked"}
        if spec is None:
            raise HTTPException(status_code=404, detail=f"no spec {spec_id!r}")
        data = spec.model_dump(mode="json")
        data["locked"] = False
        # ... existing work_item_kind resolution unchanged ...
        data["work_item_kind"] = None
        if spec.work_item_id:
            try:
                wi = workitems.get(spec.work_item_id)
                data["work_item_kind"] = wi.kind if wi is not None else None
            except Exception:
                data["work_item_kind"] = None
        return data
```

(The `/specs/{spec_id}/review` handler also calls `store.find_by_id`; under encrypted-without-key that is an author/serve-with-key path in practice. Leave it as-is — a `SpecLocked` there surfaces as a 500, which is acceptable for v1 since review always runs where the key is; the operator-facing list/detail LOCKED state is what AC7 requires.)

- [ ] **Step 4: Run the tests to verify they pass**

Run: `uv run pytest tests/core/test_serve_spec_locked.py -v`
Expected: PASS (3 tests).

- [ ] **Step 5: Run the serve suite (no regressions)**

Run: `uv run pytest tests/core/test_serve.py -q`
Expected: PASS (committed-mode specs still list/get as before — `locked: False` added to rows is additive).

- [ ] **Step 6: Commit**

```bash
git add src/mship/core/serve.py tests/core/test_serve_spec_locked.py
git commit -m "feat(serve): decrypt specs for GC + LOCKED state without key (spec-storage-visibility-policy ac7)"
mship journal "serve /specs + /specs/{id} mode-aware + LOCKED-aware; decrypts with key, shows locked marker without it (no ciphertext, no 500); tests passing" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=6 -->
### Task 6: `mship spec migrate-storage` — mode-switch migration

**Files:**
- Modify: `src/mship/util/git.py` (add `rm`, `remove_from_gitignore`)
- Modify: `src/mship/cli/spec.py` (add `migrate-storage` command)
- Test: `tests/cli/test_spec_migrate_storage.py`

- [ ] **Step 1: Write the failing test**

Create `tests/cli/test_spec_migrate_storage.py`:

```python
import subprocess
from pathlib import Path

import pytest
from typer.testing import CliRunner

from mship.cli import app, container

runner = CliRunner()


def _git(root: Path, *args: str) -> subprocess.CompletedProcess:
    return subprocess.run(["git", *args], cwd=root, capture_output=True, text=True, check=True)


@pytest.fixture
def workspace(tmp_path: Path):
    _git(tmp_path, "init", "-q")
    _git(tmp_path, "config", "user.email", "t@t")
    _git(tmp_path, "config", "user.name", "t")
    (tmp_path / "mothership.yaml").write_text("workspace: demo\nspec_storage: committed\n")
    state_dir = tmp_path / ".mothership"
    state_dir.mkdir()
    container.config.reset(); container.state_manager.reset(); container.log_manager.reset()
    container.config_path.override(tmp_path / "mothership.yaml")
    container.state_dir.override(state_dir)
    # Create + commit a committed spec.
    runner.invoke(app, ["spec", "new", "--title", "Design X", "--id", "design-x"])
    _git(tmp_path, "add", "specs")
    _git(tmp_path, "commit", "-q", "-m", "add spec")
    yield tmp_path
    container.config_path.reset(); container.state_dir.reset(); container.config.reset()


def _set_mode(root: Path, mode: str) -> None:
    (root / "mothership.yaml").write_text(f"workspace: demo\nspec_storage: {mode}\n")
    container.config.reset()


def test_migrate_committed_to_encrypted(workspace: Path):
    _set_mode(workspace, "encrypted")
    res = runner.invoke(app, ["spec", "migrate-storage"])
    assert res.exit_code == 0, res.output
    specs = workspace / "specs"
    enc = list(specs.glob("*.md.enc"))
    assert len(enc) == 1 and b"Design X" not in enc[0].read_bytes()
    # Plaintext removed from disk AND from the git index.
    assert list(specs.glob("*.md")) == []
    tracked = _git(workspace, "ls-files", "specs").stdout
    assert "design-x.md" not in tracked or "design-x.md.enc" in tracked
    assert ".enc" in _git(workspace, "ls-files", "specs").stdout


def test_migrate_committed_to_local(workspace: Path):
    _set_mode(workspace, "local")
    res = runner.invoke(app, ["spec", "migrate-storage"])
    assert res.exit_code == 0, res.output
    md = list((workspace / "specs").glob("*.md"))
    assert len(md) == 1 and "Design X" in md[0].read_text()  # still readable locally
    # Untracked + gitignored now.
    assert "design-x" not in _git(workspace, "ls-files", "specs").stdout
    check = subprocess.run(
        ["git", "check-ignore", "-q", str(md[0].relative_to(workspace))], cwd=workspace
    )
    assert check.returncode == 0


def test_migrate_encrypted_back_to_committed(workspace: Path):
    _set_mode(workspace, "encrypted")
    runner.invoke(app, ["spec", "migrate-storage"])
    _set_mode(workspace, "committed")
    res = runner.invoke(app, ["spec", "migrate-storage"])
    assert res.exit_code == 0, res.output
    md = list((workspace / "specs").glob("*.md"))
    assert len(md) == 1 and "Design X" in md[0].read_text()
    assert list((workspace / "specs").glob("*.md.enc")) == []  # ciphertext gone
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `uv run pytest tests/cli/test_spec_migrate_storage.py -v`
Expected: FAIL — `Usage: ... No such command 'migrate-storage'`.

- [ ] **Step 3: Add git helpers**

In `src/mship/util/git.py`, add two methods to `GitRunner` (mirror the existing `subprocess.run` style):

```python
    def rm(self, repo_path: Path, path: Path, *, cached: bool = False) -> None:
        args = ["git", "rm", "-q"]
        if cached:
            args.append("--cached")
        args += ["--", str(path)]
        subprocess.run(args, cwd=repo_path, check=True, capture_output=True, text=True)

    def remove_from_gitignore(self, repo_path: Path, pattern: str) -> None:
        gitignore = repo_path / ".gitignore"
        if not gitignore.exists():
            return
        kept = [ln for ln in gitignore.read_text().splitlines() if ln.strip() != pattern]
        gitignore.write_text("\n".join(kept) + ("\n" if kept else ""))
```

- [ ] **Step 4: Add the `migrate-storage` command**

In `src/mship/cli/spec.py`, add a new command inside `register` (before `parent.add_typer(...)`):

```python
    @spec_app.command("migrate-storage")
    def migrate_storage():
        """Re-materialise every spec into the workspace's current `spec_storage`
        mode, removing the old representation (git rm the plaintext when moving to
        local/encrypted). Run after editing `spec_storage` in mothership.yaml."""
        from pathlib import Path
        from mship.core.spec_store import SPECS_DIRNAME, SpecStore
        from mship.core.spec_storage import SpecStorage
        from mship.util.git import GitRunner

        output = Output()
        container = get_container()
        workspace_root = Path(container.config_path()).parent
        specs_dir = workspace_root / SPECS_DIRNAME
        target = container.config().spec_storage
        git = GitRunner()

        # Read every current file suffix-agnostically (needs the key for any .md.enc).
        reader = SpecStorage(specs_dir, workspace_root=workspace_root)
        target_storage = SpecStorage(specs_dir, mode=target, workspace_root=workspace_root)
        target_store = SpecStore(specs_dir, storage=target_storage)

        migrated = 0
        for spec, locked_id, old_path in reader.read_all():
            if spec is None:
                output.error(
                    f"Cannot migrate {locked_id!r}: it is encrypted and no key is present. "
                    f"Restore `.mothership/spec-key` first."
                )
                raise typer.Exit(1)
            new_path = target_store.save(spec)  # writes target representation
            if new_path.resolve() != old_path.resolve():
                # Suffix changed (.md <-> .md.enc): drop the old file from disk + index.
                try:
                    git.rm(workspace_root, old_path)
                except Exception:
                    old_path.unlink(missing_ok=True)
            elif target == "local":
                # committed -> local: same .md path, but must stop tracking it.
                try:
                    git.rm(workspace_root, new_path, cached=True)
                except Exception:
                    pass
            if target == "committed":
                # local/encrypted -> committed: specs are public again.
                git.remove_from_gitignore(workspace_root, f"{SPECS_DIRNAME}/*.md")
            migrated += 1

        if output.human_mode:
            output.success(f"Migrated {migrated} spec(s) to spec_storage={target!r}.")
        else:
            output.json({"migrated": migrated, "spec_storage": target})
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `uv run pytest tests/cli/test_spec_migrate_storage.py -v`
Expected: PASS (3 transitions: committed→encrypted, committed→local, encrypted→committed).

- [ ] **Step 6: Run the git-util suite (no regressions)**

Run: `uv run pytest tests/ -k "git" -q`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add src/mship/util/git.py src/mship/cli/spec.py tests/cli/test_spec_migrate_storage.py
git commit -m "feat(spec): mship spec migrate-storage re-materialises specs across modes (spec-storage-visibility-policy ac6)"
mship journal "migrate-storage command + GitRunner.rm/remove_from_gitignore; committed<->local<->encrypted transitions git-remove the old representation; tests passing" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=7 -->
### Task 7: Docs — modes + key-loss warning

**Files:**
- Modify: `src/mship/skills/working-with-mothership/SKILL.md`

- [ ] **Step 1: Add the documentation section**

In `src/mship/skills/working-with-mothership/SKILL.md`, add a section (place near the spec/workflow content):

````markdown
## Spec storage & visibility (`spec_storage`)

A workspace's `spec_storage:` policy in `mothership.yaml` controls where specs live
and who can read them. The `mship spec` UX is identical across all modes — only the
on-disk representation changes.

- `committed` (default): plaintext `specs/<date>-<id>.md`, committed + pushed. A public
  design record. Existing workspaces are unchanged.
- `local`: the same plaintext file, but git-ignored (`specs/*.md`). Present + fully
  usable on your machine, never committed or pushed.
- `encrypted`: Fernet ciphertext `specs/<date>-<id>.md.enc`, committed to the repo.
  It round-trips through clone/pull like any file, but a repo-reader without the key
  sees only ciphertext. This also delivers specs to cloud workers: a worker holding
  the key clones the repo and decrypts.

The key is a single per-workspace Fernet key at `.mothership/spec-key` (git-ignored),
generated on the first encrypted write. `mship serve`/Ground Control decrypt for
display with the local key and show a LOCKED state when the key is absent.

**⚠ Back up `.mothership/spec-key`.** It is the ONLY key to your encrypted specs.
Losing it makes every encrypted spec permanently unrecoverable — there is no escrow
or recovery. Rotation is manual: generate a new key and re-encrypt (re-run
`mship spec migrate-storage`).

**Switching modes:** edit `spec_storage:` in `mothership.yaml`, then run
`mship spec migrate-storage`. It re-materialises every spec into the new mode and
git-removes the old representation, so no spec is left readable in a mode that should
hide it.
````

- [ ] **Step 2: Verify the skill still parses**

Run: `uv run pytest tests/ -k "skill" -q` (if skill-doc tests exist; otherwise skip).
Expected: PASS / no skill tests.

- [ ] **Step 3: Commit**

```bash
git add src/mship/skills/working-with-mothership/SKILL.md
git commit -m "docs(spec): document spec_storage modes + key-loss warning (spec-storage-visibility-policy)"
mship journal "documented spec_storage modes + back-up-your-key warning + migrate-storage flow" --action committed
```
<!-- /mship:task -->

---

## Final verification

- [ ] Run the whole suite: `uv run pytest -q`. Expected: PASS.
- [ ] Manual smoke (committed default unchanged): in a scratch workspace with no `spec_storage:` key, `mship spec new --title X` writes plaintext `specs/*.md` exactly as before.
- [ ] Manual smoke (encrypted): set `spec_storage: encrypted`, `mship spec new --title Secret`, confirm `specs/*.md.enc` exists, `grep -r Secret specs/` finds nothing, `mship spec show <id>` prints the title, delete `.mothership/spec-key`, confirm `mship serve` `/specs` shows the spec as `locked`.

## Self-Review

**Spec coverage (each AC → a task):**

- **ac1** (per-workspace `spec_storage` = committed|local|encrypted, default committed, invalid fails loud at load) → **Task 2** (`Literal` field + config-load ValidationError tests).
- **ac2** (all `mship spec` reads/writes go through the storage layer; UX identical) → **Task 4** (every verb routed via `spec_store_from_config`), on the layer built in **Task 3**.
- **ac3** (`local` writes plaintext + gitignored + untracked, still usable locally) → **Task 3** (`SpecStorage.write` local branch + `test_local_write_is_plaintext_but_gitignored_and_untracked`), surfaced via CLI in **Task 4**.
- **ac4** (`encrypted` persists ciphertext committed; `show` with key decrypts; plaintext never at committed path) → **Task 3** (`test_encrypted_write_leaves_ciphertext_on_disk` asserts plaintext absent + no `.md` written) + **Task 4** (`test_spec_show_decrypts_with_key`).
- **ac5** (single Fernet key at `.mothership/spec-key`, gitignored, loud first-gen notice, fail-loud on no key) → **Task 1** (`spec_key`: `load_or_generate_key` notice + gitignore; `require_key` raises; `test_require_key_raises_when_absent`).
- **ac6** (mode switch migrates via explicit step, removes old representation) → **Task 6** (`mship spec migrate-storage`; git-rm old repr; three transition tests).
- **ac7** (serve/GC decrypt under encrypted; LOCKED state when key absent, not ciphertext/error) → **Task 5** (`test_serve_shows_locked_state_without_key`, `test_serve_get_locked_spec_returns_marker_not_error`).
- **ac8** (end-to-end: round-trip; ciphertext-on-disk; no-key can't read; local gitignored+untracked; default committed; each migration transition; fail-loud) → distributed: **Task 3** (round-trip, ciphertext, no-key, local untracked, suffix-driven), **Task 2** (default committed), **Task 6** (migration transitions), **Task 5** (serve). Every clause has an explicit assertion.

**Placeholder scan:** No TBD/TODO. Every code step shows real code; every test step shows real assertions. The only prose-only step is Task 4 Step 3's mechanical repeat across ~15 verbs — the exact replacement snippet is given and applies uniformly.

**Type consistency:** `SpecStorage(specs_dir, mode=..., workspace_root=...)`, `SpecStorage.write(stem, text)`, `SpecStorage.decode_file(path)`, `SpecStorage.read_all() -> (spec|None, locked_id|None, path)`, `SpecStorage.iter_physical()`, `SpecLocked(spec_id)` with `.spec_id`, `spec_id_from_filename(path)`, `spec_store_from_config(workspace_root, config)`, `spec_key.load_key/require_key/load_or_generate_key/encrypt/decrypt/keyfile_path`, `SpecKeyMissing`, `GitRunner.rm(cached=)`, `GitRunner.remove_from_gitignore` — names are used identically in every task that references them. `SpecStore.__init__(specs_dir, storage=None)` and `path_for` (logical `.md` stem) are consistent across Tasks 3–6.

## Risks & one thing to confirm before building

- **The `SpecStore` seam is wrappable, but reads are not fully centralised.** Writes funnel through `SpecStore.save` (clean), but **two readers bypass it** (`spec_discovery`, `spec_selection`) — Task 4 routes both. Beyond the AC-named surfaces, other modules also construct `SpecStore(...)` directly (`cli/workitem.py`, `cli/view/*`, `cli/export.py`, `core/workitem_gate.py`, `core/spec_lifecycle.py`, `core/workitem_lifecycle.py`, `cli/worktree.py`). Under `committed`/`local` they behave correctly (default committed storage reads plaintext `.md`); under `encrypted` a **reader-only** site would just not surface specs, and a **writer** site (`cli/worktree.py:1478` `save(bound_spec)`, and the lifecycle helpers that persist a spec) could write plaintext `.md` while the workspace expects `.md.enc` — a leak. **Recommendation:** treat this plan as covering the AC surfaces (spec CLI, serve, view spec, gates) and follow with a mechanical sweep routing the remaining writer sites through `spec_store_from_config`. I kept that sweep out of the AC-scoped tasks to keep the diff reviewable — **confirm whether you want the full writer-site sweep folded into Task 4** (recommended for a real encrypted deployment) or tracked as a fast follow.
- **Filename is dated (`<date>-<id>.md`), not `<id>.md`** as the spec's Architecture wrote — the plan uses the real convention; encrypted just appends `.enc`.
- **`spec migrate-storage` reads the target from config**, matching AC6's "explicit migrate step" (edit yaml → run command). If you'd prefer `migrate-storage --to <mode>` (set + migrate in one shot), that is a small addition — say the word and I'll adjust Task 6.
- **Rotation/escrow are non-goals** (per the spec) — losing the key loses the specs; documented loudly in Task 1's notice and Task 7's docs.
