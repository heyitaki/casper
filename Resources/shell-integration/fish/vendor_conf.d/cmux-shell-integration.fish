# vim:ft=fish
#
# CASPER: env-based loader for cmux's fish integration. Upstream's --init-command
# path is skipped whenever cmux spawns the shell with a command of its own (e.g. a
# restored panel's resume script), leaving those panels with no integration at all.
# vendor_conf.d is sourced on every fish startup, so it survives that.
# See docs/casper-fork.md #13.

# config.fish has no interactivity guard of its own — upstream only ever loads it
# from `fish -il`. Without this, every `fish -c` writes a shim and mutates PATH.
status is-interactive; or return

# config.fish sources the user's own conf.d + config.fish when this is unset,
# assuming it runs from --init-command (after fish already loaded them). From
# vendor_conf.d we run *before* fish loads them, so leaving it unset double-sources
# the user's whole config. cmux only sets it when $SHELL is fish.
set -q CMUX_FISH_USER_CONFIG_ALREADY_LOADED; or set -g CMUX_FISH_USER_CONFIG_ALREADY_LOADED 1

set -l _cmux_config (status dirname)/../config.fish
test -r "$_cmux_config"; and source "$_cmux_config"
