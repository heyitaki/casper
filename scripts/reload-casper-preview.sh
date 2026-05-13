#!/usr/bin/env bash
# Rebuild the dedicated "Casper Preview" iteration target.
#
# Why this exists: the user's lived-in Casper.app (built from
# `reload.sh --tag casper --name "Casper"` and pinned to the Dock) holds
# open workspaces, terminals, and panels we don't want to nuke on every
# UI edit. `casper-preview` is a parallel tagged build with a distinct
# bundle id (com.cmuxterm.app.debug.casper.preview), distinct
# DerivedData (~/Library/.../DerivedData/cmux-casper-preview/), and a
# distinct pkill target ("Casper Preview.app/..."). Rebuilding it
# leaves the main Casper.app untouched.
#
# The stable DerivedData path means the built
# `~/Library/Developer/Xcode/DerivedData/cmux-casper-preview/Build/Products/Debug/Casper Preview.app`
# can be Dock-pinned and survives across rebuilds.
#
# CMUX_SKIP_ZIG_BUILD=1 is required locally — see
# ~/.claude/projects/-Users-aki-code-cmux/memory/reload_zig_skip.md.
#
# Pass --launch to open the preview after build; default is no-launch.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec env CMUX_SKIP_ZIG_BUILD=1 \
  "$SCRIPT_DIR/reload.sh" \
  --tag casper-preview \
  --name "Casper Preview" \
  "$@"
