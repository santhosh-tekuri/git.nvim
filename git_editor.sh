#!/bin/bash

PIPE=$(mktemp -u)
mkfifo "$PIPE"
trap 'rm -f "$PIPE"' EXIT

NVIM_ADDR="$1"
NVIM_CMD=":lua vim.api.nvim_exec_autocmds('User', { pattern = 'GitCommit', data = { pipe = '${PIPE}', file='$2' } })<CR>"

# Send the command to the Neovim server
nvim --server "$NVIM_ADDR" --remote-send "$NVIM_CMD"

code=$(cat "${PIPE}")
exit "$code"
