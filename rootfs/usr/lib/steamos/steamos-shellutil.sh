#!/bin/bash
# -*- mode: sh; indent-tabs-mode: nil; sh-basic-offset: 4; -*-
# vim: et sts=4 sw=4

#  SPDX-License-Identifier: LGPL-2.1+
#
#  Copyright © 2023 Valve Corporation.
#
#  This file is part of steamos-customizations.
#
#  steamos-customizations is free software; you can redistribute it and/or
#  modify it under the terms of the GNU Lesser General Public License as
#  published by the Free Software Foundation; either version 2.1 of the License,
#  or (at your option) any later version.

###
### Shared utility library for steamos shell scripts
###
###   Usage:
###     set -euo pipefail
###     # shellcheck source=../libexec/steamos-shellutil.sh
###     source /usr/lib/steamos/steamos-shellutil.sh
###
###   Unless otherwise noted, this library expects:
###    - Bash version 5.1+
###    - Default shell options, with the addition of errexit, nounset, and pipefail
###    - Default/standard settings for IFS and possible other uncommonly-changed shell settings
###    - Utilities on PATH:
###      - coreutils
###      - util-linux
###      - GNU sed
###      - GNU grep
###      - (optional) ncurses for ANSI color support
###

##
## Misc shell utility
##

# echo all arguments with shell escaping.  Similar to ${foo@Q}, but using 'printf %q' for slightly more readable output.
sh_quote()
{
  # In zsh we can do "echo ${@:q}", but the bash equivalent (${@@Q}) aggressively quotes everything rather than just
  # what needs it, making for less human readable output.
  local args=()
  for arg in "$@"; do
    args+=("$(printf '%q' "$arg")")
  done
  echo "${args[@]}"
}

##
## Colors and output/formatting
##

# Output a SGR escape code (often just called a 'ansi escape code' or 'ansi color code') in a more readable fashion, for
# setting shell color/bold rendering.  Outputs nothing if stderr is not a compatible terminal.
# Intended for stderr status messages etc. output.
#
# See console_codes(4) in the linux man pages
#
# Arguments are codes to pass
#
# Outputs nothing if stderr is not a terminal or doesn't support ANSI colors according to tput
#
# Without arguments, defaults to a single 0
#
# Example:
#   sh_c 1 32
# On a color-enabled terminal, outputs the evaluated string
#   $'\e[1;32m'
# Outputs nothing if stderr is not a terminal or not color capable
sh_c() { [[ ! -t 2 ]] || _sh_c "$@"; }
# sh_c but for codes intended for stdout, rather than stderr
sh_c_stdout() { [[ ! -t 1 ]] || _sh_c "$@"; }

# Implementation for sh_c, skips the check that the intended output is a terminal
# See sh_c / sh_c_stdout
_sh_c()
{
  # cache output of `tput colors` unless TERM changes
  if [[ -z ${_sh_c_term+x} || ${TERM-} != "${_sh_c_term-}" ]]; then
    _sh_c_colors=0
    # Not a failure if tput fails or doesn't exist
    # Don't invoke tput at all if term is unset or dumb or some versions get upset
    [[ -n ${TERM-} && $TERM != dumb ]] && _sh_c_colors=$(tput colors 2>/dev/null || echo 0)
    _sh_c_term=${TERM-}
  fi

  # Don't output ansi codes if we don't support colors
  [[ $_sh_c_colors -gt 0 ]] || return
  # https://no-color.org/ - if we output color when this is set someone will email me.
  [[ -z ${NO_COLOR-} ]] || return

  # ANSI codes we care about are of the form `\e[a;bm` where \e is 0x1b and there are 0 or more codes separated by a
  # semicolon (ESC [, this might be defined by ECMA-48?)
  local args=("$@")
  # single 0 if no args
  [[ ${#args[@]} -gt 0 ]] || args=(0)
  # glue args together with semicolon, wrapped in '\e[' and 'm'
  # This is a "Select Graphic Rendition" control sequence defined in ECMA-48, FWIW
  ( IFS=\; && echo -n $'\e['"${args[*]}m"; );
}

## Pre-defined color codes

# Primary message types/colors, estat/emsg/einfo
sh_stat=$(sh_c 32 1)
sh_msg=$( sh_c 34 1)
sh_warn=$(sh_c 33 1)
sh_info=$(sh_c 30 1)
sh_err=$( sh_c 31 1)

# Other generic colors
sh_header=$(sh_c 0 35)
sh_header_bold=$(sh_c 1 35)
sh_highlight=$(sh_c 0 33)
sh_highlight_bold=$(sh_c 1 31)
sh_italic=$(sh_c 3)
sh_note=$(sh_c 0 36)
sh_note_bold=$(sh_c 1 36)
sh_reset=$(sh_c 0)

##
## Pretty output & helpers
##

# Output arguments to stdout followed by a newline, without the other caveats of echo.
out() { printf "%s\n" "$*"; }
# Output arguments to stdout with no trailing newline, and without the other caveats of echo.
out_raw() { printf "%s" "$*"; }

# Output arguments to stderr followed by a newline, without the other caveats of echo.
msg() { printf >&2 "%s\n" "$*"; }
# Output arguments to stderr with no trailing newline, and without the other caveats of echo.
msg_raw() { printf >&2 "%s" "$*"; }

# Prints its arguments as an error message and then terminates the script with exit 1
#
# With no arguments, prints the unhelpful message "Internal error"
die() { eerr "${*:-Internal error}"; exit 1; }

# Output a prominent success/forward-progress message to stderr
estat()   { echo >&2 "${sh_stat}::${sh_reset} $*"; }
# Output a prominent success/forward-progress message to stderr
#   Nested or indented one level compared to estat
estat2()  { echo >&2 "   ${sh_msg}->${sh_reset} $*"; }
# Output a standard status message to stderr.
emsg()    { echo >&2 "${sh_msg}::${sh_reset} $*"; }
# Output a standard status message to stderr.
#   Nested or indented one level compared to emsg
emsg2()   { echo >&2 "   ${sh_msg}->${sh_reset} $*"; }
# Output a warning message to stderr
ewarn()   { echo >&2 "${sh_warn};;${sh_reset} $*"; }
# Output a warning message to stderr
#   Nested or indented one level compared to ewarn
ewarn2()  { echo >&2 "   ${sh_warn}=>${sh_reset} $*"; }
# Output a low priority or more-verbose informational message to stderr.
einfo()   { echo >&2 "${sh_info}::${sh_reset} $*"; }
# Output a low priority or more-verbose informational message to stderr.
#   Nested or indented one level compared to einfo2
einfo2()  { echo >&2 "   ${sh_info}->${sh_reset} $*"; }
# Output a prominent error message to stderr
eerr()    { echo >&2 "${sh_err}!!${sh_reset} $*"; }
# Output a prominent error message to stderr
#   Nested or indented one level compared to einfo2
eerr2()   { echo >&2 "   ${sh_err}~>${sh_reset} $*"; }
# Output a warning message to stderr, decorated as a prompt/question
#   See eprompt
ewarnprompt() { echo >&2 -n "${sh_warn}?${sh_reset} $*"; }

# Invoke eerr with the arguments, and then return 1
#
# Useful for preserving a failure return in constructs such as `foo || eerr_fail blah`
eerr_fail() { eerr "$@"; return 1; }

_eblock() { local x; for x in "" "${@:2}" ""; do "$1" "$x"; done; }

# Output an estat level message with each argument on its own line, and vertical padding on either side
# Useful for blocks of prominent text or section headings
estat_block() { _eblock estat "$@"; }
# Output an emsg level message with each argument on its own line, and vertical padding on either side
# Useful for blocks of prominent text or section headings
emsg_block()  { _eblock emsg  "$@"; }
# Output an ewarn level message with each argument on its own line, and vertical padding on either side
# Useful for blocks of prominent text or section headings
ewarn_block() { _eblock ewarn "$@"; }
# Output an einfo level message with each argument on its own line, and vertical padding on either side
# Useful for blocks of prominent text or section headings
einfo_block() { _eblock einfo "$@"; }
# Output an eerr level message with each argument on its own line, and vertical padding on either side
# Useful for blocks of prominent text or section headings
eerr_block()  { _eblock eerr  "$@"; }

# Output an estat level message with vertical padding on either side to make it especially prominent, for section
# headings or critical messages.
estat_title() { _eblock estat "$*"; }
# Output an emsg level message with vertical padding on either side to make it especially prominent, for section
# headings or critical messages.
emsg_title()  { _eblock emsg  "$*"; }
# Output an ewarn level message with vertical padding on either side to make it especially prominent, for section
# headings or critical messages.
ewarn_title() { _eblock ewarn "$*"; }
# Output an einfo level message with vertical padding on either side to make it especially prominent, for section
# headings or critical messages.
einfo_title() { _eblock einfo "$*"; }
# Output an eerr level message with vertical padding on either side to make it especially prominent, for section
# headings or critical messages.
eerr_title()  { _eblock eerr  "$*"; }

##
## Command helpers
##

# Shows "+ command" as stderr, info style
showcmd() { showcmd_unquoted "$(sh_quote "$@")"; }
# Shows "+ command" but unquoted, e.g. for displaying things that are going to be eval'd or where
# you are manually formatting the displayed command.
showcmd_unquoted() { echo >&2 "$(sh_c 30 1)+$(sh_c) $*"; }
# Shows "`#` command" as stdout, copy-pasteable by user (`#` is a bash no-op)
offercmd() { echo "$(sh_c 30 1)\`#\`$(sh_c) $(sh_quote "$@")"; }
# showcmd and also actually run it
cmd() { showcmd "$@"; "$@"; }
# showcmd and actually run it, with stderr to /dev/null. This is helpful since
#   showcmd echos to stderr, so $(cmd 2>/dev/null ...) is self-defeating
scmd() { showcmd "$@"; "$@" 2>/dev/null; }
# showcmd and actually run it, with stdout to /dev/null
qcmd() { showcmd "$@"; "$@" >/dev/null; }
# showcmd and actually run it, with all output to /dev/null
qqcmd() { showcmd "$@"; "$@" &>/dev/null; }

##
## Prompts
##

# Display a prompt with ewarnprompt and get a reply
eprompt() {
  local msg="$1"
  [[ -n $msg ]] || msg="?"
  ewarnprompt "$msg "
  local reply
  read -e -r reply
  echo >&2 "" # Clear prompt line
  printf "%s" "$reply"
}

# Prompt for a single y/N, treating N as default.  Returns success on Y, failure on N
eprompt_yn() {
  local msg="$1"
  [[ -n $msg ]] || msg="Proceed?"
  ewarnprompt "$msg [y/N] "
  local reply
  read -n 1 -r reply
  echo >&2 "" # Clear prompt line
  [[ $reply = y || $reply = Y ]] || return 1
}

# Display and prompt y/N to run a command
promptcmd() {
  emsg "Will execute:"
  emsg "  $(sh_quote "$@")"
  eprompt_yn 'Continue?' || return 1
  cmd "$@"
}
