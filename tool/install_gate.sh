#!/usr/bin/env bash
# The install gate: run before installing any Striso Live build on the user's machines.
#   1. the audio gate: the candidate's striso_audio against the release the user approved by ear
#      (tool/audio_gate.py: the device tap, no device opened);
#   2. striso_virtual's slow tests on the virtual board the build plays (a 4.5 MB console write
#      through the transport, about 75 s), skipped by the default runs.
# Usage: tool/install_gate.sh <reference striso_audio> <candidate striso_audio> <striso_virtual library>
# Exit status: 0 pass; anything else: do not install.
set -euo pipefail
cd "$(dirname "$0")/.."
[ $# -eq 3 ] || { sed -n '2,8p' "$0"; exit 2; }
ref="$1" cand="$2" virt="$3"
echo "== audio gate"
python tool/audio_gate.py "$ref" "$cand"
echo "== striso_virtual, slow tests, on $virt"
(cd packages/striso_virtual && STRISO_VIRTUAL_LIB="$virt" dart test -t slow --run-skipped)
echo "install gate: PASS"
