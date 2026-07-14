#!/usr/bin/env bash
#
# redeploy-serve.sh — deploy a server-side (mothership) change to the running mship serve(s).
#
# Merging a mothership PR updates the repo checkout but NOT the installed `mship` tool that
# `mship serve` actually runs, so newly-merged endpoints stay dark (the phone gets 404s /
# "couldn't approve") until the tool is reinstalled AND every serve is restarted. This script
# does both, in place, so a server-side change is one command instead of a manual dance:
#
#   1. sync the workspace (pull merged main) unless --no-sync
#   2. snapshot every running `mship serve` (its workspace dir + flags) BEFORE touching anything
#   3. reinstall the installed tool from the merged workspace source
#   4. stop the serves + ALL relay tunnels (clears orphaned/duplicate subdomain tunnels too)
#   5. relaunch each serve from its own dir + flags, daemonized (survives this shell)
#   6. verify each serve is back up (401/200 on /health)
#
# Usage:
#   scripts/redeploy-serve.sh              # sync main, then redeploy every running serve
#   scripts/redeploy-serve.sh --no-sync    # redeploy without pulling main first
#
set -euo pipefail

WORKSPACE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MOTHERSHIP_SRC="$WORKSPACE/mothership"
RELAY_HOST="mship-relay.atomikpanda.com"
LOGDIR="$HOME/.mothership"
mkdir -p "$LOGDIR"

say() { printf '\033[1;36m[redeploy]\033[0m %s\n' "$*"; }

# --- 1. optional sync -------------------------------------------------------
if [[ "${1:-}" != "--no-sync" ]]; then
  say "syncing workspace (mship sync)…"
  ( cd "$WORKSPACE" && mship sync ) || say "warning: mship sync failed — continuing with local source"
fi

# --- 2. snapshot running serves (before killing anything) -------------------
# Capture each serve's working dir (which workspace it serves — resolved from cwd) and the
# flags after the literal 'serve', so we can relaunch it identically.
say "snapshotting running serves…"
declare -a CWDS=() FLAGS=()
while read -r pid _; do
  [[ -z "${pid:-}" ]] && continue
  cwd="$(readlink "/proc/$pid/cwd" 2>/dev/null || true)"
  [[ -z "$cwd" ]] && continue
  cmd="$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || true)"
  flags="${cmd#*mship serve }"
  [[ "$flags" == "$cmd" ]] && flags=""          # 'serve' with no trailing flags
  flags="${flags%% }"
  CWDS+=("$cwd"); FLAGS+=("$flags")
  say "  serve pid=$pid dir=$cwd flags=[${flags:-none}]"
done < <(pgrep -af 'mship serve' | grep -v 'redeploy-serve' || true)

[[ ${#CWDS[@]} -eq 0 ]] && say "no running 'mship serve' found — reinstalling only (start serves yourself after)."

# --- 3. reinstall the tool from merged source -------------------------------
say "reinstalling mship from $MOTHERSHIP_SRC …"
uv tool install --force --no-cache "$MOTHERSHIP_SRC" >/dev/null
say "  tool reinstalled."

# --- 4. stop serves + relay tunnels -----------------------------------------
if [[ ${#CWDS[@]} -gt 0 ]]; then
  say "stopping serves + relay tunnels…"
  pkill -f 'mship serve' 2>/dev/null || true
  pkill -f "ssh .*-R .*${RELAY_HOST}" 2>/dev/null || true   # legit + orphaned duplicate tunnels
  for _ in $(seq 1 20); do
    pgrep -f 'mship serve' >/dev/null 2>&1 || break
    sleep 0.5
  done
  pkill -9 -f 'mship serve' 2>/dev/null || true
fi

# --- 5. relaunch each serve, daemonized -------------------------------------
for i in "${!CWDS[@]}"; do
  cwd="${CWDS[$i]}"; flags="${FLAGS[$i]}"; name="$(basename "$cwd")"
  say "relaunching serve for $name …"
  # shellcheck disable=SC2086  # flags must word-split into args
  ( cd "$cwd" && setsid nohup mship serve $flags >> "$LOGDIR/serve-$name.log" 2>&1 </dev/null & )
done

# --- 6. verify --------------------------------------------------------------
port_of() { local f="$1"; if [[ "$f" =~ --port[[:space:]]+([0-9]+) ]]; then echo "${BASH_REMATCH[1]}"; else echo 47100; fi; }

if [[ ${#CWDS[@]} -gt 0 ]]; then
  say "verifying…"
  for _ in $(seq 1 30); do
    up=1
    for i in "${!CWDS[@]}"; do
      code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 4 "http://127.0.0.1:$(port_of "${FLAGS[$i]}")/health" || echo 000)"
      [[ "$code" == "401" || "$code" == "200" ]] || up=0
    done
    [[ "$up" == "1" ]] && break
    sleep 0.5
  done
  ok=1
  for i in "${!CWDS[@]}"; do
    port="$(port_of "${FLAGS[$i]}")"; name="$(basename "${CWDS[$i]}")"
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 4 "http://127.0.0.1:$port/health" || echo 000)"
    if [[ "$code" == "401" || "$code" == "200" ]]; then say "  ✓ $name (:$port) up ($code)"; else say "  ✗ $name (:$port) NOT up ($code) — see $LOGDIR/serve-$name.log"; ok=0; fi
  done
  [[ "$ok" == "1" ]] && say "serve redeploy complete." || { say "serve redeploy FAILED."; exit 1; }
else
  say "reinstall done."
fi
