---
id: coordination-workspace-lsp-activation
title: Coordination workspace LSP activation
status: draft
created_at: '2026-08-13T01:11:26.010557Z'
updated_at: '2026-08-13T01:49:24.155812Z'
affected_repos:
- mship-workspace
acceptance_criteria:
- id: ac1
  text: A tracked coordination-root `.omp/lsp.json` exists and is valid according
    to OMP's LSP configuration schema.
  verdict: approved
  evidence: []
  comment: null
- id: ac2
  text: The configuration overrides Pyright root markers so the existing coordination-root
    `mothership.yaml` marker can activate/configure Pyright when OMP starts at the
    workspace root.
  verdict: approved
  evidence: []
  comment: null
- id: ac3
  text: The configuration overrides the Kotlin LSP root markers so the same existing
    `mothership.yaml` marker can activate/configure the Kotlin server when OMP starts
    at the workspace root.
  verdict: approved
  evidence: []
  comment: null
- id: ac4
  text: Starting OMP directly from either member repository continues to use that
    member's built-in Python or Gradle root markers because coordination-root `.omp/lsp.json`
    is cwd-scoped and not inherited.
  verdict: approved
  evidence: []
  comment: null
- id: ac5
  text: No fake `pyproject.toml`, `setup.py`, `setup.cfg`, Gradle settings/build files,
    Gradle wrapper files, or equivalent language/build markers are added at the coordination
    root.
  verdict: approved
  evidence: []
  comment: null
- id: ac6
  text: After reloading/restarting OMP from the coordination root, both Pyright and
    the Kotlin LSP are shown as configured/active for the workspace.
  verdict: approved
  evidence: []
  comment: null
- id: ac7
  text: Pyright can analyze a representative nested Python file under `mothership`
    and return diagnostics through OMP.
  verdict: approved
  evidence: []
  comment: null
- id: ac8
  text: The Kotlin LSP can analyze a representative nested Android Kotlin file under
    `ground-control` and return diagnostics through OMP.
  verdict: approved
  evidence: []
  comment: null
- id: ac9
  text: Verification confirms that each server models the appropriate nested member
    project rather than merely starting against a misleading coordination-root project.
  verdict: approved
  evidence: []
  comment: null
- id: ac10
  text: If nested project modeling fails for either language server, the implementation
    is rejected as a failed design rather than worked around by adding false root-level
    project markers.
  verdict: approved
  evidence: []
  comment: null
- id: ac11
  text: No installed user binaries or machine-local tool artifacts are committed or
    otherwise treated as repository artifacts.
  verdict: approved
  evidence: []
  comment: null
- id: ac12
  text: The final change remains limited to workspace configuration, with any temporary
    diagnostic test edits reverted before completion.
  verdict: approved
  evidence: []
  comment: null
open_questions: []
non_goals:
- Adding a root-level `pyproject.toml`, Gradle settings/build file, wrapper, or any
  other fake language-ecosystem marker.
- Changing application source code or member-project build configuration except where
  strictly necessary to test diagnostics without committing changes.
- Installing, vendoring, or tracking Pyright, Kotlin LSP, Java, Python, Gradle, or
  other user-level binaries/toolchains.
- Replacing or weakening built-in language-server detection at actual member roots.
- Expanding scope beyond coordination-root OMP workspace configuration and its verification.
risks:
- The coordination-root `rootMarkers` override intentionally replaces each server's
  defaults for that cwd; an incorrect server key or marker would prevent activation.
- Activating a server at the coordination root may not guarantee that it correctly
  discovers or models nested projects, particularly the Android/Gradle Kotlin project.
- A server may appear configured after reload but fail to publish meaningful diagnostics
  because its nested project model did not initialize.
- The exact OMP LSP configuration schema or registered Kotlin server identifier may
  differ from assumptions and must match the repository's installed/supported OMP
  configuration format.
- Diagnostics can be affected by local tool availability, but local binaries must
  not be added to repository artifacts.
task_slug: null
work_item_id: null
clarification_reason: 'Superseded after verification: OMP root markers select servers
  but cannot assign per-server member roots. Operator chose separate member-root sessions;
  Kotlin uses a user-level fallback server because official Kotlin LSP issue #189
  leaves Android app source sets empty.'
prose_verdicts:
  problem:
    verdict: approved
    comment: null
  user_story:
    verdict: approved
    comment: null
  approach:
    verdict: approved
    comment: null
  non_goals:
    verdict: approved
    comment: null
  risks:
    verdict: approved
    comment: null
---
## Problem

OMP started at the coordination/workspace root does not currently activate both Pyright and the Kotlin language server for source files located in the nested `mothership` Python and `ground-control` Android Kotlin projects. The workspace needs a tracked OMP LSP configuration that recognizes the existing coordination-root marker without fabricating ecosystem-specific project files.

## User story

As a developer starting OMP at the workspace coordination root, I want Pyright and the Kotlin LSP to activate for representative nested `mothership` Python files and `ground-control` Android Kotlin files, so that I receive diagnostics across both member projects while preserving each language server's normal member-root project discovery and modeling.

## Approach

Add and track `.omp/lsp.json` at the coordination root. Override the built-in `rootMarkers` for `pyright` and `kotlin-lsp` with the existing `mothership.yaml` coordination-root marker, allowing both servers to be selected when OMP starts there. This cwd-scoped config is not inherited when OMP starts directly inside a member repository, because OMP does not walk parent directories for project config; member-root built-in detection therefore remains unchanged. Reload OMP, confirm both servers are configured, and validate diagnostics against representative nested files. If either server cannot correctly model its nested member project, reject the design rather than adding misleading root-level project manifests.

## Implementation Constraints

Use the existing `mothership.yaml` as the shared coordination-root activation marker. Preserve the language servers' native project-root semantics within nested members. Do not represent the coordination root as a Python package or Gradle/Android project when it is not one.

## Verification Plan

1. Validate `.omp/lsp.json` syntax/schema. 2. Start or reload OMP at the coordination root. 3. Inspect OMP/LSP status or logs and confirm both Pyright and the Kotlin server are configured. 4. Open or request diagnostics for an existing representative Python file under `mothership`; confirm Pyright initializes against the nested Python project and publishes diagnostics. 5. Open or request diagnostics for an existing representative Android Kotlin file under `ground-control`; confirm the Kotlin server discovers the nested Gradle/Android project and publishes diagnostics. 6. If a deterministic signal is needed, introduce a temporary in-memory or uncommitted diagnostic error in each representative file, confirm the expected server diagnostic, and revert it. 7. Review the final diff to ensure only the intended tracked workspace configuration is present and no local binaries, caches, generated files, temporary edits, or fake project markers are included.

## Definition of Failure

The design fails if either server is only nominally activated but cannot resolve and diagnose its nested member files, if built-in member-root detection is lost, or if success depends on adding deceptive coordination-root Python or Gradle metadata.
