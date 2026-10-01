#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../cardano-kes-rotate.sh
source "$ROOT/cardano-kes-rotate.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
touch "$tmp/one"

selected=""
choose_candidate selected "test file" "$tmp/one"
[[ "$selected" == "$(canonical "$tmp/one")" ]] || fail "single candidate was not selected"

args='cardano-node run --socket-path /run/cardano/node.socket --shelley-kes-key=/keys/kes.skey'
[[ "$(arg_value "$args" --socket-path)" == /run/cardano/node.socket ]] || fail "space-separated argument parsing"
[[ "$(arg_value "$args" --shelley-kes-key)" == /keys/kes.skey ]] || fail "equals argument parsing"

mkdir "$tmp/transfer-root" "$tmp/transfer-root/kes-rotation-1"
touch "$tmp/transfer-root/kes-rotation-1/node.cert"
[[ "$(find_returned_transfer kes-rotation-1 "$tmp/transfer-root")" == "$tmp/transfer-root/kes-rotation-1" ]] || fail "returned transfer detection"

bash -n "$ROOT/cardano-kes-rotate.sh"
echo "All tests passed"
