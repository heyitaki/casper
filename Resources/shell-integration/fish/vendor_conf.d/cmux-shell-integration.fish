# vim:ft=fish
#
# cmux shell integration for fish.
#
# Inside a cmux terminal the bundled `claude` wrapper at
# $CMUX_SHELL_INTEGRATION_DIR/../bin/claude injects --session-id / --settings
# flags so Claude Code lifecycle hooks fire back into cmux. Without that
# wrapper, snapshot/restore for Claude sessions has no metadata to persist.
#
# The wrapper must win over any user-installed `claude` binary. .zprofile /
# .zshrc that prepends bun/.local/bin/etc demotes our bin dir to the end of
# PATH (e.g. via a ghostty-fish-login bootstrap script), so we re-prepend it
# and install a `claude` shell function that calls the wrapper by absolute
# path.

status is-interactive
or return

set -q CMUX_SURFACE_ID
or return

set -q CMUX_SHELL_INTEGRATION_DIR
or return

set -l _cmux_integration_dir (string trim --right --chars=/ -- $CMUX_SHELL_INTEGRATION_DIR)
set -l _cmux_bin_dir (string replace --regex -- '/shell-integration$' '/bin' $_cmux_integration_dir)

if not test -x $_cmux_bin_dir/claude
    return
end

set -g _CMUX_CLAUDE_WRAPPER $_cmux_bin_dir/claude

set -l _cmux_new_path $_cmux_bin_dir
for entry in $PATH
    if test $entry != $_cmux_bin_dir
        set -a _cmux_new_path $entry
    end
end
set -gx PATH $_cmux_new_path

# vendor_conf.d runs BEFORE ~/.config/fish/config.fish, so any
# `fish_add_path -g` in the user's config will re-prepend its entries
# AFTER ours, demoting our bin dir again. Re-fix PATH once on the first
# prompt (after all init has run), then unregister.
function _cmux_fix_path --on-event fish_prompt --description "cmux PATH re-fix"
    set -l bin_dir (string replace --regex -- '/claude$' '' $_CMUX_CLAUDE_WRAPPER)
    set -l fixed_path $bin_dir
    for entry in $PATH
        if test $entry != $bin_dir
            set -a fixed_path $entry
        end
    end
    set -gx PATH $fixed_path
    functions -e _cmux_fix_path
end

# Belt-and-suspenders: a function always wins over PATH resolution. Use an
# absolute path so we never re-enter PATH lookup (which a user alias or a
# stale PATH could break).
function claude --description "cmux Claude wrapper"
    $_CMUX_CLAUDE_WRAPPER $argv
end
