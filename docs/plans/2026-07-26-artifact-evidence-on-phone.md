# Artifact evidence the phone can see — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Spec:** `artifact-evidence-on-phone` (approved) — `specs/2026-07-26-artifact-evidence-on-phone.md`

**Goal:** Make a screenshot the agent captured appear next to the acceptance criterion it backs — on the phone, and embedded in the pull request.

**Architecture:** One module (`core/evidence_store.py`) owns where artifact bytes live and how a ref resolves back to them; the persisted ref is a bare filename so traversal is unrepresentable rather than merely rejected. Bytes live at `specs/evidence/<spec-id>/<sha12>.<ext>`, governed by a new `evidence_storage` mode that inherits `spec_storage` when unset and may never be more exposed than it. `mship capture --evidence <spec>:<ac>` promotes a capture into that store in one step; a read-only blob route on `mship serve` lets Ground Control fetch it; and `build_acceptance_block` embeds it in the PR body via a raw URL pinned to the workspace commit.

**Tech Stack:** Python 3.14, Typer, FastAPI, pydantic, pytest (mothership); Kotlin, Compose, JUnit (ground-control).

**Repos:** `mothership` (Tasks 1–12), `ground-control` (Tasks 13–14).

---

## Test helpers (read before Task 7)

This repo does **not** use shared conftest fixtures for these — it defines small
local helpers per test file (`_app` / `_seed_spec` in `tests/core/test_serve.py`,
and `configured_app_with_task` copied into each `tests/cli/*` file). Follow that
convention. Tasks 1–6 need none of this; Tasks 7, 8, 10 and 11 each open by
pasting the helper they need into their own test file.

**`_workspace_with_capture(tmp_path)`** — for Task 7. Model it on
`configured_app_with_task` (`tests/cli/test_log.py:15`), then add: a repo whose
`Taskfile.yml` defines a `capture` target that writes `$MSHIP_CAPTURE_DIR/screen.png`,
and a `needs_review` spec `dq` with one criterion `ac1`.

```python
def _workspace_with_capture(tmp_path: Path) -> Path:
    """Workspace + one repo whose capture target writes a screen.png, plus spec
    `dq` carrying ac1. Mirrors configured_app_with_task, plus the capture bits."""
    from datetime import datetime, timezone

    from mship.core.spec import AcceptanceCriterion
    from mship.core.spec_draft import new_spec
    from mship.core.spec_store import SpecStore

    now = datetime(2026, 7, 26, tzinfo=timezone.utc)
    repo = tmp_path / "app"; repo.mkdir()
    (repo / "Taskfile.yml").write_text(
        "version: '3'\ntasks:\n  capture:\n    cmds:\n"
        "      - 'printf x > $MSHIP_CAPTURE_DIR/screen.png'\n"
    )
    (tmp_path / "mothership.yaml").write_text(
        "workspace: test-ws\nrepos:\n  app:\n    path: app\n    type: service\n"
    )
    specs = tmp_path / "specs"; specs.mkdir()
    spec = new_spec("Decision queue", now=now, task_slug=None)
    spec.id = "dq"
    spec.status = "needs_review"
    spec.acceptance_criteria = [AcceptanceCriterion(id="ac1", text="the screen renders")]
    SpecStore(specs).save(spec)
    return tmp_path
```

**`_app_with_token(tmp_path, token)`** — for Task 8. Copy `_app` and `_seed_spec`
from `tests/core/test_serve.py`, passing a token so the bearer dependency is
active (see `tests/core/test_serve_gh_token.py` for an auth-enabled example), then
store one artifact:

```python
def _seed_evidence(tmp_path: Path) -> str:
    from mship.core.evidence_store import store_artifact

    src = tmp_path / "screen.png"; src.write_bytes(b"\x89PNG fake bytes")
    return store_artifact(tmp_path, "dq", src, mode="committed")
```

**Spec builders** — for Tasks 10 and 11, build the `Spec` inline with
`Spec.model_construct(...)` exactly as Task 9's test does. No fixture needed.

Where the task bodies below name `capture_workspace`, `serve_client_with_evidence`,
`finish_workspace`, `finish_workspace_no_images`, or `spec_with_bare_criteria`,
substitute the corresponding helper above.

---

<!-- mship:task id=1 -->
### Task 1: `evidence_storage` config field

**Files:**
- Modify: `src/mship/core/config.py:342`
- Test: `tests/core/test_config_evidence_storage.py`

- [ ] **Step 1: Write the failing test**

```python
# tests/core/test_config_evidence_storage.py
import pytest
from mship.core.config import load_config


def _write(tmp_path, body: str):
    (tmp_path / "mothership.yaml").write_text(body)
    return tmp_path / "mothership.yaml"


def test_evidence_storage_defaults_to_none(tmp_path):
    p = _write(tmp_path, "workspace: w\nrepos: {}\n")
    cfg = load_config(p)
    assert cfg.evidence_storage is None


def test_evidence_storage_accepts_each_mode(tmp_path):
    for mode in ("committed", "local", "encrypted"):
        p = _write(tmp_path, f"workspace: w\nrepos: {{}}\nevidence_storage: {mode}\n")
        assert load_config(p).evidence_storage == mode


def test_evidence_storage_rejects_unknown_value(tmp_path):
    p = _write(tmp_path, "workspace: w\nrepos: {}\nevidence_storage: public\n")
    with pytest.raises(Exception):
        load_config(p)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `uv run pytest tests/core/test_config_evidence_storage.py -v`
Expected: FAIL with `AttributeError` / `'Config' object has no attribute 'evidence_storage'`

- [ ] **Step 3: Add the field**

In `src/mship/core/config.py`, directly below the existing `spec_storage` field (line 342):

```python
    # Storage mode for acceptance-criterion artifact evidence. `None` inherits
    # `spec_storage` — the safe default, so evidence is governed exactly like the
    # spec it backs unless an operator deliberately diverges (prose is bytes,
    # screenshots are megabytes). Resolved by
    # core/evidence_store.py::resolve_evidence_mode, which also enforces that
    # evidence is never MORE exposed than its spec.
    evidence_storage: Literal["committed", "local", "encrypted"] | None = None
```

- [ ] **Step 4: Run test to verify it passes**

Run: `uv run pytest tests/core/test_config_evidence_storage.py -v`
Expected: PASS (3 tests)

- [ ] **Step 5: Commit**

```bash
git add src/mship/core/config.py tests/core/test_config_evidence_storage.py
git commit -m "feat(config): add evidence_storage mode, defaulting to inherit spec_storage"
mship journal "added evidence_storage config field; 3 tests passing" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=2 -->
### Task 2: Mode resolution and the exposure invariant

**Files:**
- Create: `src/mship/core/evidence_store.py`
- Test: `tests/core/test_evidence_mode.py`

Exposure order is `committed` (most exposed) > `encrypted` > `local` (least). Evidence may never rank above its spec: ciphertext prose beside a plaintext screenshot of the same feature defeats the encryption.

- [ ] **Step 1: Write the failing test**

```python
# tests/core/test_evidence_mode.py
import pytest
from mship.core.evidence_store import EvidenceModeError, resolve_evidence_mode


class _Cfg:
    def __init__(self, spec_storage, evidence_storage=None):
        self.spec_storage = spec_storage
        self.evidence_storage = evidence_storage


def test_unset_inherits_spec_storage():
    for mode in ("committed", "local", "encrypted"):
        assert resolve_evidence_mode(_Cfg(mode)) == mode


def test_explicit_mode_wins_when_not_more_exposed():
    assert resolve_evidence_mode(_Cfg("committed", "local")) == "local"
    assert resolve_evidence_mode(_Cfg("encrypted", "local")) == "local"
    assert resolve_evidence_mode(_Cfg("encrypted", "encrypted")) == "encrypted"


def test_evidence_more_exposed_than_spec_is_refused():
    with pytest.raises(EvidenceModeError) as e:
        resolve_evidence_mode(_Cfg("encrypted", "committed"))
    msg = str(e.value)
    assert "evidence_storage" in msg and "spec_storage" in msg


def test_local_spec_with_committed_evidence_is_refused():
    with pytest.raises(EvidenceModeError):
        resolve_evidence_mode(_Cfg("local", "committed"))
```

- [ ] **Step 2: Run test to verify it fails**

Run: `uv run pytest tests/core/test_evidence_mode.py -v`
Expected: FAIL with `ModuleNotFoundError: No module named 'mship.core.evidence_store'`

- [ ] **Step 3: Create the module with mode resolution**

```python
# src/mship/core/evidence_store.py
"""Where acceptance-criterion artifact evidence lives, and how a ref resolves
back to it.

Single owner of the path math: both `mship capture --evidence` and serve's blob
route go through this module, so nothing else computes an evidence path.

The persisted ref is a BARE FILENAME, never a path. Because the resolver joins
exactly one root — the spec's own evidence directory — a ref has no way to
express a location outside it. Validation still rejects malformed names, but the
primary defence is that the data model cannot say "elsewhere".
"""
from __future__ import annotations

from pathlib import Path
from typing import Literal

EvidenceMode = Literal["committed", "local", "encrypted"]

# Ordered least-exposed to most-exposed. `local` never leaves the machine;
# `encrypted` leaves but is unreadable without the key; `committed` leaves in the
# clear. Evidence may never rank above the spec it backs.
_EXPOSURE: dict[str, int] = {"local": 0, "encrypted": 1, "committed": 2}


class EvidenceModeError(Exception):
    """The configured evidence_storage is more exposed than spec_storage."""


def resolve_evidence_mode(config) -> EvidenceMode:
    """The effective evidence mode. `evidence_storage` unset inherits
    `spec_storage`; set, it must not be more exposed than the spec's mode."""
    spec_mode: EvidenceMode = getattr(config, "spec_storage", "committed")
    declared = getattr(config, "evidence_storage", None)
    if declared is None:
        return spec_mode
    if _EXPOSURE[declared] > _EXPOSURE[spec_mode]:
        raise EvidenceModeError(
            f"evidence_storage={declared!r} is more exposed than "
            f"spec_storage={spec_mode!r}. A screenshot discloses what the spec "
            f"prose was protecting, so evidence may never be less protected "
            f"than its spec. Use one of: "
            f"{', '.join(m for m in _EXPOSURE if _EXPOSURE[m] <= _EXPOSURE[spec_mode])}."
        )
    return declared
```

- [ ] **Step 4: Run test to verify it passes**

Run: `uv run pytest tests/core/test_evidence_mode.py -v`
Expected: PASS (4 tests)

- [ ] **Step 5: Commit**

```bash
git add src/mship/core/evidence_store.py tests/core/test_evidence_mode.py
git commit -m "feat(evidence): resolve evidence mode with an exposure invariant"
mship journal "evidence mode resolution + exposure invariant; 4 tests passing" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=3 -->
### Task 3: Store an artifact (content-hashed filename)

**Files:**
- Modify: `src/mship/core/evidence_store.py`
- Test: `tests/core/test_evidence_store.py`

- [ ] **Step 1: Write the failing test**

```python
# tests/core/test_evidence_store.py
from pathlib import Path

from mship.core.evidence_store import evidence_dir, store_artifact


def test_store_returns_bare_filename_and_writes_bytes(tmp_path):
    src = tmp_path / "screen.png"
    src.write_bytes(b"\x89PNG fake bytes")

    ref = store_artifact(tmp_path, "my-spec", src, mode="committed")

    assert "/" not in ref and "\\" not in ref
    assert ref.endswith(".png")
    landed = evidence_dir(tmp_path, "my-spec") / ref
    assert landed.read_bytes() == b"\x89PNG fake bytes"


def test_identical_content_yields_identical_ref(tmp_path):
    a = tmp_path / "a.png"; a.write_bytes(b"same")
    b = tmp_path / "b.png"; b.write_bytes(b"same")
    assert store_artifact(tmp_path, "s", a, mode="committed") == \
           store_artifact(tmp_path, "s", b, mode="committed")


def test_different_content_yields_different_ref(tmp_path):
    a = tmp_path / "a.png"; a.write_bytes(b"one")
    b = tmp_path / "b.png"; b.write_bytes(b"two")
    assert store_artifact(tmp_path, "s", a, mode="committed") != \
           store_artifact(tmp_path, "s", b, mode="committed")


def test_store_lands_under_specs_evidence_spec_id(tmp_path):
    src = tmp_path / "layout.xml"; src.write_text("<hierarchy/>")
    store_artifact(tmp_path, "my-spec", src, mode="committed")
    assert (tmp_path / "specs" / "evidence" / "my-spec").is_dir()
```

- [ ] **Step 2: Run test to verify it fails**

Run: `uv run pytest tests/core/test_evidence_store.py -v`
Expected: FAIL with `ImportError: cannot import name 'store_artifact'`

- [ ] **Step 3: Implement storing**

Append to `src/mship/core/evidence_store.py`:

```python
import hashlib
import re
import shutil

SPECS_DIRNAME = "specs"
EVIDENCE_DIRNAME = "evidence"
ENC_SUFFIX = ".enc"

# Extensions we are willing to store and serve. Anything else is refused rather
# than guessed at — the content-type of a served blob is derived from this.
CONTENT_TYPES: dict[str, str] = {
    ".png": "image/png",
    ".jpg": "image/jpeg",
    ".jpeg": "image/jpeg",
    ".webp": "image/webp",
    ".xml": "application/xml",
    ".json": "application/json",
    ".html": "text/html",
}
IMAGE_EXTS: frozenset[str] = frozenset({".png", ".jpg", ".jpeg", ".webp"})

_HASH_CHARS = 12


class EvidenceStoreError(Exception):
    """An artifact could not be stored (unsupported extension, unreadable)."""


def evidence_dir(workspace_root: Path, spec_id: str) -> Path:
    """The one directory a spec's artifact evidence may live in."""
    return Path(workspace_root) / SPECS_DIRNAME / EVIDENCE_DIRNAME / spec_id


def _digest(src: Path) -> str:
    h = hashlib.sha256()
    with open(src, "rb") as fh:
        for chunk in iter(lambda: fh.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()[:_HASH_CHARS]


def store_artifact(
    workspace_root: Path, spec_id: str, src: Path, *, mode: EvidenceMode
) -> str:
    """Copy `src` into the spec's evidence directory under a content-hashed
    name. Returns the BARE FILENAME to persist as the evidence ref."""
    src = Path(src)
    ext = src.suffix.lower()
    if ext not in CONTENT_TYPES:
        raise EvidenceStoreError(
            f"unsupported evidence extension {ext!r}; expected one of "
            f"{', '.join(sorted(CONTENT_TYPES))}"
        )
    ref = f"{_digest(src)}{ext}"
    dest_dir = evidence_dir(workspace_root, spec_id)
    dest_dir.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(src, dest_dir / ref)
    return ref
```

- [ ] **Step 4: Run test to verify it passes**

Run: `uv run pytest tests/core/test_evidence_store.py -v`
Expected: PASS (4 tests)

- [ ] **Step 5: Commit**

```bash
git add src/mship/core/evidence_store.py tests/core/test_evidence_store.py
git commit -m "feat(evidence): store artifacts under a content-hashed bare filename"
mship journal "evidence store_artifact + hashing; 4 tests passing" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=4 -->
### Task 4: Resolve a ref, and refuse everything that escapes

**Files:**
- Modify: `src/mship/core/evidence_store.py`
- Test: `tests/core/test_evidence_resolve.py`

- [ ] **Step 1: Write the failing test**

```python
# tests/core/test_evidence_resolve.py
import os
import pytest

from mship.core.evidence_store import (
    BadEvidenceRef,
    evidence_dir,
    resolve_ref,
    store_artifact,
)


def _stored(tmp_path):
    src = tmp_path / "screen.png"; src.write_bytes(b"bytes")
    return store_artifact(tmp_path, "s", src, mode="committed")


def test_resolves_a_stored_ref(tmp_path):
    ref = _stored(tmp_path)
    assert resolve_ref(tmp_path, "s", ref).read_bytes() == b"bytes"


@pytest.mark.parametrize("bad", [
    "../../etc/passwd",
    "/etc/passwd",
    "..%2Fescape.png",
    "sub/dir.png",
    "no-extension",
    "deadbeef.exe",
    "",
])
def test_refuses_malformed_or_escaping_refs(tmp_path, bad):
    _stored(tmp_path)
    with pytest.raises(BadEvidenceRef):
        resolve_ref(tmp_path, "s", bad)


def test_refuses_a_symlink_pointing_out_of_the_store(tmp_path):
    _stored(tmp_path)
    secret = tmp_path / "secret.png"; secret.write_bytes(b"nope")
    link = evidence_dir(tmp_path, "s") / "aaaaaaaaaaaa.png"
    os.symlink(secret, link)
    with pytest.raises(BadEvidenceRef):
        resolve_ref(tmp_path, "s", "aaaaaaaaaaaa.png")


def test_missing_ref_raises(tmp_path):
    _stored(tmp_path)
    with pytest.raises(BadEvidenceRef):
        resolve_ref(tmp_path, "s", "ffffffffffff.png")
```

- [ ] **Step 2: Run test to verify it fails**

Run: `uv run pytest tests/core/test_evidence_resolve.py -v`
Expected: FAIL with `ImportError: cannot import name 'BadEvidenceRef'`

- [ ] **Step 3: Implement resolution**

Append to `src/mship/core/evidence_store.py`:

```python
# A ref is exactly a content hash plus a known extension. Anything else never
# reaches the filesystem.
_REF_RE = re.compile(r"^[0-9a-f]{%d}\.[a-z0-9]{2,5}$" % _HASH_CHARS)


class BadEvidenceRef(Exception):
    """A ref was malformed, escaped its spec's evidence directory, or is absent."""


def resolve_ref(workspace_root: Path, spec_id: str, ref: str) -> Path:
    """The on-disk path for a stored ref. Raises BadEvidenceRef for anything
    malformed, absent, or resolving outside the spec's evidence directory."""
    if not isinstance(ref, str) or not _REF_RE.match(ref):
        raise BadEvidenceRef(f"malformed evidence ref {ref!r}")
    if Path(ref).suffix.lower() not in CONTENT_TYPES:
        raise BadEvidenceRef(f"unsupported evidence extension in {ref!r}")

    root = Path(os.path.realpath(evidence_dir(workspace_root, spec_id)))
    candidate = Path(os.path.realpath(root / ref))
    # realpath resolves symlinks, so a link pointing out of the store fails here.
    if candidate != root / ref and root not in candidate.parents:
        raise BadEvidenceRef(f"evidence ref {ref!r} resolves outside its store")
    if not candidate.is_file():
        raise BadEvidenceRef(f"no evidence at {ref!r}")
    return candidate
```

Add `import os` to the module's imports.

- [ ] **Step 4: Run test to verify it passes**

Run: `uv run pytest tests/core/test_evidence_resolve.py -v`
Expected: PASS (10 tests — 8 parametrized cases plus 2)

- [ ] **Step 5: Commit**

```bash
git add src/mship/core/evidence_store.py tests/core/test_evidence_resolve.py
git commit -m "feat(evidence): resolve refs, refusing traversal, symlinks, and bad names"
mship journal "evidence resolve_ref with traversal/symlink refusal; 10 tests passing" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=5 -->
### Task 5: Per-mode write behaviour (gitignore and encryption)

**Files:**
- Modify: `src/mship/core/evidence_store.py`
- Test: `tests/core/test_evidence_modes_on_disk.py`

Reuse `core/spec_key` rather than introducing a second crypto path, so the "an encrypted workspace never emits plaintext" guarantee holds for artifacts by construction.

- [ ] **Step 1: Write the failing test**

```python
# tests/core/test_evidence_modes_on_disk.py
from mship.core.evidence_store import ENC_SUFFIX, evidence_dir, store_artifact


def _png(tmp_path):
    p = tmp_path / "screen.png"; p.write_bytes(b"\x89PNG plaintext marker")
    return p


def test_committed_mode_writes_plaintext(tmp_path):
    ref = store_artifact(tmp_path, "s", _png(tmp_path), mode="committed")
    assert (evidence_dir(tmp_path, "s") / ref).read_bytes().endswith(b"marker")


def test_local_mode_gitignores_the_evidence_dir(tmp_path):
    store_artifact(tmp_path, "s", _png(tmp_path), mode="local")
    assert "specs/evidence/" in (tmp_path / ".gitignore").read_text()


def test_encrypted_mode_writes_ciphertext_with_enc_suffix(tmp_path):
    ref = store_artifact(tmp_path, "s", _png(tmp_path), mode="encrypted")
    assert ref.endswith(ENC_SUFFIX)
    raw = (evidence_dir(tmp_path, "s") / ref).read_bytes()
    assert b"marker" not in raw
```

- [ ] **Step 2: Run test to verify it fails**

Run: `uv run pytest tests/core/test_evidence_modes_on_disk.py -v`
Expected: FAIL — `local` writes no `.gitignore`, `encrypted` writes plaintext

- [ ] **Step 3: Add mode handling to `store_artifact`**

Replace the final three lines of `store_artifact` (from `dest_dir = ...` onward) with:

```python
    dest_dir = evidence_dir(workspace_root, spec_id)
    dest_dir.mkdir(parents=True, exist_ok=True)

    if mode == "encrypted":
        from mship.core import spec_key
        from mship.util.git import GitRunner

        ref = ref + ENC_SUFFIX
        key = spec_key.load_or_generate_key(Path(workspace_root), git=GitRunner())
        (dest_dir / ref).write_bytes(spec_key.encrypt_bytes(key, src.read_bytes()))
        return ref

    shutil.copyfile(src, dest_dir / ref)
    if mode == "local":
        from mship.util.git import GitRunner

        GitRunner().add_to_gitignore(
            Path(workspace_root), f"{SPECS_DIRNAME}/{EVIDENCE_DIRNAME}/"
        )
    return ref
```

**Then make `resolve_ref` accept an encrypted ref — two changes, not one.** Task 4
hardened the resolver beyond what this plan originally specified, so read the real
code before editing it. As committed it uses `fullmatch` (not `$`-anchored
`match`, because `$` also matches before a trailing newline), validates `spec_id`
containment as well as `ref`, and refuses **any** symlink in the store. Extend
that; do not replace it.

1. The ref pattern must admit the suffix:

```python
_REF_RE = re.compile(r"[0-9a-f]{%d}\.[a-z0-9]{2,5}(\.enc)?" % _HASH_CHARS)
```

2. **The extension check must look beneath `.enc`.** `Path("abc.png.enc").suffix`
is `".enc"`, which is not in `CONTENT_TYPES`, so the existing check would refuse
every encrypted ref even once the regex admits it. Strip the suffix before
checking:

```python
    logical = ref[: -len(ENC_SUFFIX)] if ref.endswith(ENC_SUFFIX) else ref
    if Path(logical).suffix.lower() not in CONTENT_TYPES:
        raise BadEvidenceRef(f"unsupported evidence extension in {ref!r}")
```

Add a test asserting a stored **encrypted** ref round-trips through `resolve_ref`.
Missing either change leaves encrypted-mode evidence unservable — which the Task 4
implementer flagged specifically because it would not surface until someone set
`evidence_storage: encrypted`.

If `spec_key` exposes only text helpers, add a bytes pair beside them in `src/mship/core/spec_key.py`:

```python
def encrypt_bytes(key: bytes, data: bytes) -> bytes:
    from cryptography.fernet import Fernet
    return Fernet(key).encrypt(data)


def decrypt_bytes(key: bytes, data: bytes) -> bytes:
    from cryptography.fernet import Fernet
    return Fernet(key).decrypt(data)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `uv run pytest tests/core/test_evidence_modes_on_disk.py tests/core/test_evidence_resolve.py -v`
Expected: PASS (13 tests — the resolve suite must stay green with the relaxed pattern)

- [ ] **Step 5: Commit**

```bash
git add src/mship/core/evidence_store.py src/mship/core/spec_key.py tests/core/test_evidence_modes_on_disk.py
git commit -m "feat(evidence): honour committed/local/encrypted modes on write"
mship journal "evidence per-mode write behaviour; 13 tests passing" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=6 -->
### Task 6: `mship capture --evidence <spec>:<ac>` attaches in one step

**Files:**
- Modify: `src/mship/cli/capture.py:45-62` (add the option), and the two artifact-discovery sites
- Create: `src/mship/core/evidence_attach.py`
- Test: `tests/core/test_evidence_attach.py`

Both the local and `--remote` branches converge on a list of `Artifact`. Put the attach logic in one function called from both rather than duplicating it.

- [ ] **Step 1: Write the failing test**

```python
# tests/core/test_evidence_attach.py
import pytest

from mship.core.evidence_attach import EvidenceTarget, parse_evidence_target


def test_parses_spec_and_criterion():
    t = parse_evidence_target("my-spec:ac3")
    assert t == EvidenceTarget(spec_id="my-spec", criterion_id="ac3")


@pytest.mark.parametrize("bad", ["nocolon", ":ac1", "spec:", "a:b:c", ""])
def test_rejects_malformed_targets(bad):
    with pytest.raises(ValueError):
        parse_evidence_target(bad)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `uv run pytest tests/core/test_evidence_attach.py -v`
Expected: FAIL with `ModuleNotFoundError: No module named 'mship.core.evidence_attach'`

- [ ] **Step 3: Implement the target parser and attach helper**

```python
# src/mship/core/evidence_attach.py
"""Promote a capture into acceptance-criterion evidence.

Bare `mship capture` is untouched: it writes to the ephemeral, gitignored
captures directory and nothing here runs. Only `--evidence` promotes artifacts
into the durable, spec-scoped, mode-governed store.
"""
from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class EvidenceTarget:
    spec_id: str
    criterion_id: str


def parse_evidence_target(raw: str) -> EvidenceTarget:
    """`<spec-id>:<ac-id>` -> EvidenceTarget. Raises ValueError otherwise."""
    parts = (raw or "").split(":")
    if len(parts) != 2 or not parts[0] or not parts[1]:
        raise ValueError(
            f"--evidence expects <spec-id>:<criterion-id> (e.g. my-spec:ac3), got {raw!r}"
        )
    return EvidenceTarget(spec_id=parts[0], criterion_id=parts[1])


def provenance_note(worktree: Path, shell) -> str:
    """Where the capture was taken from. A capture of uncommitted work or of a
    throwaway run ref is still useful evidence, but a reviewer must be able to
    see that is what it is.

    `shell` is util/shell.py::Shell — its `run` takes a command STRING (it uses
    shell=True), not an argv list.
    """
    rev = shell.run("git rev-parse --short HEAD", cwd=worktree)
    sha = (rev.stdout or "").strip() or "unknown"
    status = shell.run("git status --porcelain", cwd=worktree)
    dirty = bool((status.stdout or "").strip())
    return f"at {sha} (uncommitted working tree)" if dirty else f"at {sha}"
```

- [ ] **Step 4: Run test to verify it passes**

Run: `uv run pytest tests/core/test_evidence_attach.py -v`
Expected: PASS (6 tests)

- [ ] **Step 5: Commit**

```bash
git add src/mship/core/evidence_attach.py tests/core/test_evidence_attach.py
git commit -m "feat(evidence): parse --evidence targets and build a provenance note"
mship journal "evidence target parsing + provenance note; 6 tests passing" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=7 -->
### Task 7: Wire `--evidence` into the capture command, fail-open

**Files:**
- Modify: `src/mship/cli/capture.py`
- Test: `tests/cli/test_capture_evidence.py`

A store failure must never fail a capture that otherwise succeeded — same posture as the `--closes` linking fail-open in `spawn`.

- [ ] **Step 1: Write the failing test**

```python
# tests/cli/test_capture_evidence.py
import json
from typer.testing import CliRunner

runner = CliRunner()


def test_evidence_attaches_to_the_named_criterion(capture_workspace):
    """capture_workspace: fixture with one repo, a stubbed capture target that
    writes screen.png, and a needs_review spec 'dq' carrying ac1."""
    from mship.cli.main import app
    result = runner.invoke(app, ["capture", "--evidence", "dq:ac1"])
    assert result.exit_code == 0, result.output

    from mship.core.spec_store import SpecStore
    ac = SpecStore(capture_workspace / "specs").find_by_id("dq").acceptance_criteria[0]
    assert [e.kind for e in ac.evidence] == ["artifact"]
    assert ac.evidence[0].ref.endswith(".png")
    assert "at " in (ac.evidence[0].note or "")


def test_bare_capture_attaches_nothing(capture_workspace):
    from mship.cli.main import app
    result = runner.invoke(app, ["capture"])
    assert result.exit_code == 0, result.output

    from mship.core.spec_store import SpecStore
    ac = SpecStore(capture_workspace / "specs").find_by_id("dq").acceptance_criteria[0]
    assert ac.evidence == []
    assert not (capture_workspace / "specs" / "evidence").exists()


def test_store_failure_warns_but_capture_succeeds(capture_workspace, monkeypatch):
    import mship.core.evidence_store as es
    monkeypatch.setattr(es, "store_artifact", lambda *a, **k: (_ for _ in ()).throw(OSError("disk full")))

    from mship.cli.main import app
    result = runner.invoke(app, ["capture", "--evidence", "dq:ac1"])
    assert result.exit_code == 0, result.output
    assert "disk full" in result.output or "could not attach" in result.output
```

- [ ] **Step 2: Run test to verify it fails**

Run: `uv run pytest tests/cli/test_capture_evidence.py -v`
Expected: FAIL with `No such option: --evidence`

- [ ] **Step 3: Add the option and the attach call**

In `src/mship/cli/capture.py`, add the option after `out` (around line 51):

```python
        evidence: Optional[str] = typer.Option(
            None, "--evidence", metavar="SPEC:AC",
            help="Attach the captured artifact(s) to an acceptance criterion as "
                 "kind=artifact evidence, e.g. --evidence my-spec:ac3. Without "
                 "this flag the capture stays an ephemeral develop-verify-iterate "
                 "artifact and nothing is stored or attached.",
        ),
```

Add this helper near the bottom of the module (module level, above `register`):

```python
def _attach_evidence(
    *, artifacts, evidence: str, container, output, worktree: Path, platform: str | None
) -> None:
    """Promote captured artifacts into acceptance-criterion evidence.

    Fail-open: the capture already succeeded, so a storage or spec failure warns
    and returns. It must never turn a good capture into a bad exit code.
    """
    from mship.core.evidence_attach import parse_evidence_target, provenance_note
    from mship.core.evidence_store import resolve_evidence_mode, store_artifact
    from mship.core.spec import AcceptanceEvidence
    from mship.core.spec_store import SpecStore

    try:
        target = parse_evidence_target(evidence)
        workspace_root = Path(container.config_path()).parent
        mode = resolve_evidence_mode(container.config())
        store = SpecStore(workspace_root / "specs")
        spec = store.find_by_id(target.spec_id)
        if spec is None:
            output.warning(f"could not attach evidence: no spec {target.spec_id!r}")
            return
        crit = next((c for c in spec.acceptance_criteria if c.id == target.criterion_id), None)
        if crit is None:
            output.warning(
                f"could not attach evidence: {target.spec_id!r} has no criterion "
                f"{target.criterion_id!r}"
            )
            return
        note_where = provenance_note(worktree, container.shell())
        for a in artifacts:
            ref = store_artifact(workspace_root, target.spec_id, a.path, mode=mode)
            crit.evidence.append(
                AcceptanceEvidence(
                    kind="artifact",
                    ref=ref,
                    note=f"{a.kind} · {platform or 'default'} · {note_where}",
                )
            )
        store.save(spec)
        output.success(
            f"attached {len(artifacts)} artifact(s) to {target.spec_id}:{target.criterion_id}"
        )
    except Exception as e:
        output.warning(f"could not attach evidence: {e}")
```

Call it from **both** discovery sites. In the remote branch, immediately after the `landed` success check:

```python
                if evidence:
                    _attach_evidence(
                        artifacts=landed, evidence=evidence, container=container,
                        output=output, worktree=worktree, platform=resolved_platform,
                    )
```

And in the local branch, immediately after `run_capture` returns its artifacts:

```python
        if evidence:
            _attach_evidence(
                artifacts=artifacts, evidence=evidence, container=container,
                output=output, worktree=worktree, platform=resolved_platform,
            )
```

- [ ] **Step 4: Run test to verify it passes**

Run: `uv run pytest tests/cli/test_capture_evidence.py -v`
Expected: PASS (3 tests)

- [ ] **Step 5: Commit**

```bash
git add src/mship/cli/capture.py tests/cli/test_capture_evidence.py
git commit -m "feat(capture): --evidence attaches artifacts to a criterion, fail-open"
mship journal "capture --evidence wired for local and remote, fail-open; 3 tests passing" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=8 -->
### Task 8: The serve blob route

**Files:**
- Modify: `src/mship/core/serve.py` (add beside `@app.get("/specs/{spec_id}/review")`, ~line 545)
- Test: `tests/core/test_serve_evidence_blob.py`

- [ ] **Step 1: Write the failing test**

```python
# tests/core/test_serve_evidence_blob.py
import pytest
from fastapi.testclient import TestClient


def test_returns_bytes_with_content_type(serve_client_with_evidence):
    client, token, spec_id, ref = serve_client_with_evidence
    r = client.get(
        f"/specs/{spec_id}/evidence/{ref}/blob",
        headers={"Authorization": f"Bearer {token}"},
    )
    assert r.status_code == 200
    assert r.headers["content-type"].startswith("image/png")
    assert r.content == b"\x89PNG fake bytes"


def test_requires_the_bearer(serve_client_with_evidence):
    client, _token, spec_id, ref = serve_client_with_evidence
    assert client.get(f"/specs/{spec_id}/evidence/{ref}/blob").status_code == 401


@pytest.mark.parametrize("bad", ["../../etc/passwd", "sub%2Fdir.png", "nope.png", "x"])
def test_unresolvable_refs_are_404_not_403(serve_client_with_evidence, bad):
    client, token, spec_id, _ref = serve_client_with_evidence
    r = client.get(
        f"/specs/{spec_id}/evidence/{bad}/blob",
        headers={"Authorization": f"Bearer {token}"},
    )
    assert r.status_code == 404
```

- [ ] **Step 2: Run test to verify it fails**

Run: `uv run pytest tests/core/test_serve_evidence_blob.py -v`
Expected: FAIL with 404 on the happy path (route does not exist)

- [ ] **Step 3: Add the route**

In `src/mship/core/serve.py`, directly after the `/specs/{spec_id}/review` route:

```python
    @app.get("/specs/{spec_id}/evidence/{name}/blob")
    def get_evidence_blob(spec_id: str, name: str):
        """Read-only artifact bytes for a criterion's evidence.

        Inherits the app-wide bearer like every other route. Everything
        unresolvable is a 404 rather than a 403 so the route never confirms what
        exists. Resolution is owned by core/evidence_store.py — the ref is a bare
        filename, so it cannot name a location outside the spec's own directory.
        """
        from fastapi.responses import FileResponse

        from mship.core.evidence_store import (
            BadEvidenceRef,
            CONTENT_TYPES,
            ENC_SUFFIX,
            resolve_ref,
        )

        _load_or_404(spec_id)
        try:
            path = resolve_ref(workspace_root, spec_id, name)
        except BadEvidenceRef:
            raise HTTPException(status_code=404, detail="no such evidence")

        if name.endswith(ENC_SUFFIX):
            from mship.core import spec_key

            key = spec_key.load_key(workspace_root)
            if key is None:
                raise HTTPException(
                    status_code=409,
                    detail="evidence is encrypted and no key is available on this host",
                )
            from fastapi.responses import Response

            plain = spec_key.decrypt_bytes(key, path.read_bytes())
            inner = name[: -len(ENC_SUFFIX)]
            media = CONTENT_TYPES.get(Path(inner).suffix.lower(), "application/octet-stream")
            return Response(content=plain, media_type=media)

        media = CONTENT_TYPES.get(path.suffix.lower(), "application/octet-stream")
        return FileResponse(path, media_type=media)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `uv run pytest tests/core/test_serve_evidence_blob.py -v`
Expected: PASS (6 tests)

- [ ] **Step 5: Commit**

```bash
git add src/mship/core/serve.py tests/core/test_serve_evidence_blob.py
git commit -m "feat(serve): read-only evidence blob route behind the existing bearer"
mship journal "serve evidence blob route incl. traversal 404s; 6 tests passing" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=9 -->
### Task 9: PR body embeds the image

**Files:**
- Modify: `src/mship/core/pr.py:451-474` (`build_acceptance_block`)
- Create: `src/mship/core/evidence_url.py`
- Test: `tests/core/test_pr_evidence_embed.py`

- [ ] **Step 1: Write the failing test**

```python
# tests/core/test_pr_evidence_embed.py
from mship.core.pr import build_acceptance_block
from mship.core.spec import AcceptanceCriterion, AcceptanceEvidence, Spec


def _spec(evidence):
    s = Spec.model_construct(
        id="my-spec", title="t", status="approved",
        acceptance_criteria=[
            AcceptanceCriterion(id="ac1", text="the screen renders", evidence=evidence)
        ],
    )
    return s


BASE = "https://raw.githubusercontent.com/o/r/abc123/specs/evidence"


def test_image_artifact_is_embedded_when_a_base_url_is_available():
    body = build_acceptance_block(
        _spec([AcceptanceEvidence(kind="artifact", ref="a1b2c3d4e5f6.png")]),
        evidence_base_url=BASE,
    )
    assert f"![ac1]({BASE}/my-spec/a1b2c3d4e5f6.png)" in body


def test_without_a_base_url_the_artifact_is_named_not_embedded():
    body = build_acceptance_block(
        _spec([AcceptanceEvidence(kind="artifact", ref="a1b2c3d4e5f6.png")]),
        evidence_base_url=None,
    )
    assert "![" not in body
    assert "a1b2c3d4e5f6.png" in body


def test_non_image_artifact_is_never_embedded():
    body = build_acceptance_block(
        _spec([AcceptanceEvidence(kind="artifact", ref="a1b2c3d4e5f6.xml")]),
        evidence_base_url=BASE,
    )
    assert "![" not in body
    assert "a1b2c3d4e5f6.xml" in body


def test_test_and_commit_refs_render_as_before():
    body = build_acceptance_block(
        _spec([AcceptanceEvidence(kind="test", ref="test-runs/7")]),
        evidence_base_url=BASE,
    )
    assert "test:test-runs/7" in body
```

- [ ] **Step 2: Run test to verify it fails**

Run: `uv run pytest tests/core/test_pr_evidence_embed.py -v`
Expected: FAIL with `TypeError: build_acceptance_block() got an unexpected keyword argument 'evidence_base_url'`

- [ ] **Step 3: Implement embedding and the URL builder**

Replace the render loop in `build_acceptance_block` (`src/mship/core/pr.py`) and widen its signature:

```python
def build_acceptance_block(spec, evidence_base_url: str | None = None) -> str:
    """Render an 'Acceptance criteria' PR-body section listing each AC as verified
    (with its evidence refs) or unverified.

    `evidence_base_url`, when given, is the raw base under which this workspace's
    committed evidence is fetchable; image artifacts are then embedded rather than
    named. It is None whenever the bytes are not on GitHub (local/encrypted
    storage, or an evidence commit that has not been pushed), in which case the
    artifact is named — never emitted as a broken image.
    """
    acs = getattr(spec, "acceptance_criteria", None) or []
    if not acs:
        return ""
    from mship.core.evidence_store import IMAGE_EXTS

    lines = ["", "---", "", "## Acceptance criteria", ""]
    for c in acs:
        if not c.evidence:
            lines.append(f"- [ ] `{c.id}` {c.text} — _no evidence_")
            continue
        refs, embeds = [], []
        for e in c.evidence:
            is_image = (
                e.kind == "artifact"
                and Path(e.ref).suffix.lower() in IMAGE_EXTS
                and evidence_base_url
            )
            if is_image:
                embeds.append(f"![{c.id}]({evidence_base_url}/{spec.id}/{e.ref})")
            else:
                refs.append(f"{e.kind}:{e.ref}")
        suffix = " — " + ", ".join(refs) if refs else ""
        lines.append(f"- [x] `{c.id}` {c.text}{suffix}")
        for embed in embeds:
            lines.append("")
            lines.append(f"  {embed}")
    return "\n".join(lines)
```

Ensure `from pathlib import Path` is imported in `pr.py`.

```python
# src/mship/core/evidence_url.py
"""The raw base URL under which this workspace's committed evidence is fetchable.

Returns None whenever an embed would break: non-committed storage, a non-GitHub
remote, or an evidence commit that has not been pushed. Callers name the artifact
instead of emitting an image that 404s.
"""
from __future__ import annotations

import re
from pathlib import Path

_GH = re.compile(r"github\.com[:/](?P<owner>[^/]+)/(?P<repo>[^/.]+)")


def workspace_raw_base(workspace_root: Path, shell) -> str | None:
    def _run(args):
        r = shell.run(args, cwd=workspace_root)
        return (r.stdout or "").strip() if r.returncode == 0 else ""

    remote = _run(["git", "remote", "get-url", "origin"])
    m = _GH.search(remote or "")
    if not m:
        return None
    sha = _run(["git", "rev-parse", "HEAD"])
    if not sha:
        return None
    # Unpushed HEAD would give a raw URL that 404s.
    branch = _run(["git", "rev-parse", "--abbrev-ref", "HEAD"]) or "HEAD"
    pushed = shell.run(
        ["git", "merge-base", "--is-ancestor", "HEAD", f"origin/{branch}"],
        cwd=workspace_root,
    )
    if pushed.returncode != 0:
        return None
    return (
        f"https://raw.githubusercontent.com/{m.group('owner')}/{m.group('repo')}"
        f"/{sha}/specs/evidence"
    )
```

- [ ] **Step 4: Run test to verify it passes**

Run: `uv run pytest tests/core/test_pr_evidence_embed.py -v`
Expected: PASS (4 tests)

- [ ] **Step 5: Commit**

```bash
git add src/mship/core/pr.py src/mship/core/evidence_url.py tests/core/test_pr_evidence_embed.py
git commit -m "feat(pr): embed image evidence in the acceptance block when it is fetchable"
mship journal "PR body embeds image evidence with a name-only fallback; 4 tests passing" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=10 -->
### Task 10: Call the URL builder from `finish`, and warn when unpushed

**Files:**
- Modify: the `build_acceptance_block` call site in `src/mship/core/pr.py` (find with `rg 'build_acceptance_block\('`)
- Test: `tests/core/test_finish_evidence_warning.py`

- [ ] **Step 1: Write the failing test**

```python
# tests/core/test_finish_evidence_warning.py
def test_warns_when_image_evidence_cannot_be_embedded(finish_workspace, capsys):
    """finish_workspace: a workspace whose spec carries an image artifact and
    whose evidence commit has NOT been pushed."""
    from mship.core.pr import acceptance_block_for_finish

    block, warning = acceptance_block_for_finish(
        finish_workspace.spec, finish_workspace.root, finish_workspace.shell
    )
    assert "![" not in block
    assert warning is not None and "not pushed" in warning.lower()


def test_no_warning_when_there_is_no_image_evidence(finish_workspace_no_images):
    from mship.core.pr import acceptance_block_for_finish

    _block, warning = acceptance_block_for_finish(
        finish_workspace_no_images.spec,
        finish_workspace_no_images.root,
        finish_workspace_no_images.shell,
    )
    assert warning is None
```

- [ ] **Step 2: Run test to verify it fails**

Run: `uv run pytest tests/core/test_finish_evidence_warning.py -v`
Expected: FAIL with `ImportError: cannot import name 'acceptance_block_for_finish'`

- [ ] **Step 3: Add the wrapper and use it at the call site**

Append to `src/mship/core/pr.py`:

```python
def acceptance_block_for_finish(spec, workspace_root, shell) -> tuple[str, str | None]:
    """The acceptance block plus an optional operator warning.

    Split from build_acceptance_block so the pure renderer stays testable without
    a git repo. The warning fires only when there IS image evidence that could
    have been embedded and wasn't — an operator with no screenshots needs no
    message.
    """
    from pathlib import Path as _Path

    from mship.core.evidence_store import IMAGE_EXTS
    from mship.core.evidence_url import workspace_raw_base

    base = workspace_raw_base(_Path(workspace_root), shell)
    block = build_acceptance_block(spec, evidence_base_url=base)
    if base is None:
        has_images = any(
            e.kind == "artifact" and _Path(e.ref).suffix.lower() in IMAGE_EXTS
            for c in (getattr(spec, "acceptance_criteria", None) or [])
            for e in c.evidence
        )
        if has_images:
            return block, (
                "image evidence is attached but could not be embedded in the PR "
                "body — the workspace evidence commit is not pushed (or storage "
                "is local/encrypted). Commit and push `specs/` to embed it."
            )
    return block, None
```

At the existing `build_acceptance_block(spec)` call site, switch to `acceptance_block_for_finish(...)` and emit the warning through the same `Output` the surrounding code already uses.

- [ ] **Step 4: Run test to verify it passes**

Run: `uv run pytest tests/core/test_finish_evidence_warning.py -v`
Expected: PASS (2 tests)

- [ ] **Step 5: Commit**

```bash
git add src/mship/core/pr.py tests/core/test_finish_evidence_warning.py
git commit -m "feat(finish): warn when image evidence exists but cannot be embedded"
mship journal "finish warns on unembeddable image evidence; 2 tests passing" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=11 -->
### Task 11: Phase warning names capture as the remedy

**Files:**
- Modify: `src/mship/core/phase.py:295-311`
- Test: `tests/core/test_phase_evidence_hint.py`

- [ ] **Step 1: Write the failing test**

```python
# tests/core/test_phase_evidence_hint.py
def test_hint_names_capture_when_a_repo_has_a_capture_target(spec_with_bare_criteria):
    from mship.core.phase import unevidenced_warning

    msg = unevidenced_warning(spec_with_bare_criteria, capture_repos=["ground-control"])
    assert "mship capture --evidence" in msg
    assert "ground-control" in msg


def test_hint_omits_capture_when_no_repo_defines_one(spec_with_bare_criteria):
    from mship.core.phase import unevidenced_warning

    msg = unevidenced_warning(spec_with_bare_criteria, capture_repos=[])
    assert "mship capture" not in msg
```

- [ ] **Step 2: Run test to verify it fails**

Run: `uv run pytest tests/core/test_phase_evidence_hint.py -v`
Expected: FAIL with `ImportError: cannot import name 'unevidenced_warning'`

- [ ] **Step 3: Extract and extend the warning**

In `src/mship/core/phase.py`, replace the inline unevidenced-criteria message with:

```python
def unevidenced_warning(spec, capture_repos: list[str]) -> str:
    """Warning text for criteria carrying no evidence. Names capture as the
    remedy only for repos that actually define a capture target — suggesting a
    command that cannot run is worse than saying nothing."""
    bare = [c.id for c in (spec.acceptance_criteria or []) if not c.evidence]
    if not bare:
        return ""
    msg = f"{len(bare)} acceptance criteria carry no evidence: {', '.join(bare)}"
    if capture_repos:
        msg += (
            f"\n  For visible behaviour, attach a screenshot with: "
            f"mship capture --evidence {spec.id}:<criterion> "
            f"(capture targets: {', '.join(capture_repos)})"
        )
    return msg
```

Call it from the existing phase-transition check, passing the affected repos that define a `capture` task.

- [ ] **Step 4: Run test to verify it passes**

Run: `uv run pytest tests/core/test_phase_evidence_hint.py -v`
Expected: PASS (2 tests)

- [ ] **Step 5: Commit**

```bash
git add src/mship/core/phase.py tests/core/test_phase_evidence_hint.py
git commit -m "feat(phase): name capture --evidence as the remedy for bare criteria"
mship journal "phase warning names capture remedy; 2 tests passing" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=12 -->
### Task 12: Docs — what travels and what does not

**Files:**
- Modify: `docs/guides/run-and-observe.md` (the "Capturing what's on screen" section, ~line 51)
- Modify: `docs/configuration.md` (beside the `spec_storage` documentation)

- [ ] **Step 1: Document the two capture modes and evidence storage**

Add to `docs/guides/run-and-observe.md` under "Capturing what's on screen":

```markdown
### Promoting a capture to evidence

Most captures are part of the develop–verify–iterate loop: screenshot, look,
adjust, capture again. Those stay ephemeral — `mship capture` writes them under
`.mothership/captures/`, which is gitignored, and nothing else happens.

Passing `--evidence <spec-id>:<criterion-id>` promotes a capture into durable
evidence for that acceptance criterion:

```bash
mship capture --evidence my-spec:ac3
```

The artifact is copied into `specs/evidence/<spec-id>/` under a content-hashed
name, attached to the criterion as `kind=artifact`, and recorded with the
revision it was taken from — marked when that revision is an uncommitted tree or
a throwaway run ref, so a reviewer can tell work-in-progress evidence from a
screenshot taken at a real commit.

**What travels:** the phone fetches evidence from `mship serve` over the relay.
The PR body embeds it when the bytes are fetchable on GitHub — which means
`evidence_storage: committed` **and** the evidence commit pushed. Otherwise the
PR names the artifact instead of showing it, and `mship finish` says so.

**What does not travel:** secrets, platform state, and anything else git cannot
carry.
```

Add to `docs/configuration.md` beside `spec_storage`:

```markdown
### `evidence_storage`

Storage mode for acceptance-criterion artifact evidence: `committed`, `local`, or
`encrypted`. When unset it **inherits `spec_storage`**, which is what you want
unless the cost profiles differ — prose is bytes, screenshots are megabytes, so
`spec_storage: committed` with `evidence_storage: local` is a reasonable pairing.

Evidence may never be **more exposed** than its spec. Ordering the modes
`committed` > `encrypted` > `local`, a configuration where evidence outranks the
spec is refused at load: a plaintext screenshot beside an encrypted spec
discloses exactly what the encryption was protecting.

Embedding evidence in a pull-request body requires `committed` — the other two
modes are not fetchable by GitHub, so the PR names the artifact instead. Note
that embedding therefore means the screenshots are readable by anyone who can
read the workspace repo.
```

- [ ] **Step 2: Verify the docs build**

Run: `uv run mkdocs build --strict`
Expected: build succeeds with no warnings

- [ ] **Step 3: Commit**

```bash
git add docs/guides/run-and-observe.md docs/configuration.md
git commit -m "docs: capture-to-evidence promotion and evidence_storage"
mship journal "documented evidence promotion + storage modes" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=13 -->
### Task 13: Ground Control — the image-ref helper

**Files:**
- Modify: `android/app/src/main/java/com/atomikpanda/groundcontrol/ui/specdetail/Evidence.kt`
- Test: `android/app/src/test/java/com/atomikpanda/groundcontrol/EvidenceImageTest.kt`

**Repo:** `ground-control`. JVM unit tests only — no emulator in this environment.

- [ ] **Step 1: Write the failing test**

```kotlin
// android/app/src/test/java/com/atomikpanda/groundcontrol/EvidenceImageTest.kt
package com.atomikpanda.groundcontrol

import com.atomikpanda.groundcontrol.data.dto.Evidence
import com.atomikpanda.groundcontrol.ui.specdetail.imageBlobPathOrNull
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class EvidenceImageTest {
    private fun ev(kind: String, ref: String) = Evidence(kind = kind, ref = ref, note = null)

    @Test
    fun `image artifact yields a blob path`() {
        assertEquals(
            "/specs/my-spec/evidence/a1b2c3d4e5f6.png/blob",
            imageBlobPathOrNull(ev("artifact", "a1b2c3d4e5f6.png"), "my-spec"),
        )
    }

    @Test
    fun `non-image artifact yields null`() {
        assertNull(imageBlobPathOrNull(ev("artifact", "a1b2c3d4e5f6.xml"), "my-spec"))
    }

    @Test
    fun `test and commit evidence yield null`() {
        assertNull(imageBlobPathOrNull(ev("test", "test-runs/7"), "my-spec"))
        assertNull(imageBlobPathOrNull(ev("commit", "abc123"), "my-spec"))
    }

    @Test
    fun `extension matching is case insensitive`() {
        assertEquals(
            "/specs/s/evidence/a1b2c3d4e5f6.PNG/blob",
            imageBlobPathOrNull(ev("artifact", "a1b2c3d4e5f6.PNG"), "s"),
        )
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `source ~/toolchains/android-env.sh && cd android && ./gradlew testDebugUnitTest --tests "*EvidenceImageTest*"`
Expected: FAIL — `Unresolved reference: imageBlobPathOrNull`

- [ ] **Step 3: Add the helper**

Append to `ui/specdetail/Evidence.kt`:

```kotlin
private val IMAGE_EXTS = setOf("png", "jpg", "jpeg", "webp")

/** Blob path for an image artifact, or null for everything else (non-image
 *  artifacts, and `test`/`commit` refs, which keep the existing text label).
 *  Sibling to [evidenceLabels]: one helper, so both are consumed the same way. */
fun imageBlobPathOrNull(e: Evidence, specId: String): String? {
    if (e.kind != "artifact") return null
    val ext = e.ref.substringAfterLast('.', "").lowercase()
    if (ext !in IMAGE_EXTS) return null
    return "/specs/$specId/evidence/${e.ref}/blob"
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `source ~/toolchains/android-env.sh && cd android && ./gradlew testDebugUnitTest --tests "*EvidenceImageTest*"`
Expected: PASS (4 tests)

- [ ] **Step 5: Commit**

```bash
git add android/app/src/main/java/com/atomikpanda/groundcontrol/ui/specdetail/Evidence.kt \
        android/app/src/test/java/com/atomikpanda/groundcontrol/EvidenceImageTest.kt
git commit -m "feat(evidence): helper mapping image artifacts to their blob path"
mship journal "GC imageBlobPathOrNull helper; 4 JVM tests passing" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=14 -->
### Task 14: Ground Control — render the image on the spec-detail row

**Files:**
- Modify: `android/app/src/main/java/com/atomikpanda/groundcontrol/ui/specdetail/SpecDetailScreen.kt:286-296`
- Test: manual verification (Compose rendering is not JVM-unit-testable here)

Renders on spec detail only — **not** the Queue. The Queue shows specs awaiting approval, which is before implementation, so no evidence exists at that point. See the spec's Approach section.

- [ ] **Step 0: Add the image-loading dependency**

Ground Control has **no image-loading library** — the dependency list is Compose,
Ktor, zxing, and a markdown renderer. Coil was chosen over hand-rolling
(2026-07-26): it handles caching, cancellation, and loading/error states, and
supports a per-request bearer header, all of which would otherwise be written by
hand and worse.

In `android/app/build.gradle.kts`, beside the other `implementation` lines:

```kotlin
    implementation("io.coil-kt:coil-compose:2.7.0")
```

Verify the version resolves against this project's Compose BOM before relying on
it, and confirm the app's `INTERNET` permission is already declared (it must be —
the app talks to `mship serve` over HTTP already).

- [ ] **Step 1: Render the image beside the existing labels**

In `SpecDetailScreen.kt`, replace the evidence block at lines 286–296:

```kotlin
            if (isUnverified(c.evidence)) {
                Text(
                    "unverified",
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            } else {
                c.evidence.forEach { e ->
                    val blob = imageBlobPathOrNull(e, s.detail.id)
                    if (blob != null) {
                        EvidenceImage(
                            path = blob,
                            note = e.note,
                            onZoom = { zoomed = blob },
                        )
                    }
                }
                evidenceLabels(c.evidence.filter { imageBlobPathOrNull(it, s.detail.id) == null })
                    .forEach { line ->
                        Text(
                            line,
                            style = MaterialTheme.typography.labelSmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
            }
```

- [ ] **Step 2: Add the composable**

Create `ui/specdetail/EvidenceImage.kt`:

```kotlin
package com.atomikpanda.groundcontrol.ui.specdetail

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.unit.dp
import coil.compose.AsyncImage

/** An artifact screenshot, full width on the spec-detail criterion row.
 *  `note` carries the capture kind, platform, and the revision it was taken
 *  from — including the marker when that revision is not a real commit, so a
 *  work-in-progress screenshot is visibly distinguishable. */
@Composable
fun EvidenceImage(path: String, note: String?, onZoom: () -> Unit) {
    Column(Modifier.fillMaxWidth().padding(top = 4.dp)) {
        AsyncImage(
            model = authedEvidenceRequest(path),
            contentDescription = note ?: "captured evidence",
            contentScale = ContentScale.FitWidth,
            modifier = Modifier.fillMaxWidth().clickable { onZoom() },
        )
        note?.takeIf { it.isNotBlank() }?.let {
            Text(
                it,
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}
```

`authedEvidenceRequest(path)` builds a Coil request against the active
`WorkspaceConnection`, adding the same `Authorization: Bearer` header
`MshipClient.auth(conn)` applies. Place it beside the existing client wiring so
there is one place that knows how to authenticate a request.

- [ ] **Step 3: Build to verify it compiles**

Run: `source ~/toolchains/android-env.sh && cd android && ./gradlew assembleDebug`
Expected: BUILD SUCCESSFUL

- [ ] **Step 4: Run the full unit suite**

Run: `source ~/toolchains/android-env.sh && cd android && ./gradlew testDebugUnitTest`
Expected: PASS — no regressions in the existing evidence tests

- [ ] **Step 5: Commit**

```bash
git add android/app/src/main/java/com/atomikpanda/groundcontrol/ui/specdetail/
git commit -m "feat(specdetail): render image evidence full-width with tap to zoom"
mship journal "GC renders image evidence on spec detail; suite green" --action committed
```
<!-- /mship:task -->

---

## Task 15 (inserted during execution)

<!-- mship:task id=15 -->
### Task 15: Enforce the exposure invariant at config load

Added after Task 7 exposed that **ac4 was unsatisfied**. Task 2's
`resolve_evidence_mode` implements the check correctly, but nothing called it at
config load — so a misconfigured exposure invariant surfaced only as a swallowed
warning from `_attach_evidence`'s fail-open path ("could not attach evidence"),
telling the operator nothing about their config being rejected, and failing the
same quiet way on every subsequent capture.

A config error is not transient, and the guarantee it protects is a security
property. Validate at the boundary; let the core assume clean state.

**Implemented as** a pydantic `model_validator(mode="after")` on `WorkspaceConfig`
(`src/mship/core/config.py`), beside the other cross-field validators, calling
`resolve_evidence_mode(self)` and re-raising `EvidenceModeError` as `ValueError`
to match the file's existing convention. Chosen over a check inside
`ConfigLoader.load` because it also covers direct model construction. No circular
import — `evidence_store` imports nothing from `config`. No existing test in
`tests/core/test_config.py` required modification, which was the signal the
placement was correct.

Commit `7a62be0`. 7 tests in `test_config_evidence_storage.py`; 123 green across
the config and evidence-mode suites.
<!-- /mship:task -->

---

## Verification

```bash
mship test                      # both repos, dependency order
```

Then end-to-end, by hand:

1. `mship capture --evidence <spec>:<ac>` in ground-control against a running emulator.
2. Confirm `specs/evidence/<spec>/` holds a hashed `.png` and the criterion carries `kind=artifact` with a provenance note.
3. Open the spec in Ground Control — the screenshot renders on the criterion row.
4. Commit and push `specs/`, then `mship finish` — the PR body embeds the image.
5. Re-run without pushing and confirm finish warns instead of emitting a broken image.

## Spec coverage

| AC | Task |
|---|---|
| ac1 one-step attach | 6, 7 |
| ac2 hashed name, bare-filename ref | 3 |
| ac3 evidence_storage key + inheritance | 1, 2 |
| ac4 exposure violation refused | 2, **15** |
| ac5 per-mode tracking/encryption | 5 |
| ac6 blob route returns bytes | 8 |
| ac7 traversal → 404 | 4, 8 |
| ac8 encrypted, key unavailable | 8 |
| ac9 spec-detail rendering | 13, 14 |
| ac10 graceful degradation | 9, 14 |
| ac11 attach failure non-fatal | 7 |
| ac12 phase warning names remedy | 11 |
| ac13 `--remote --evidence` | 7 |
| ac14 bare capture attaches nothing | 7 |
| ac15 provenance recorded and shown | 6, 7, 14 |
| ac16 PR body embeds | 9, 10 |
| ac17 fallback + finish warning | 9, 10 |
| ac18 existing refs unchanged | 9 |
