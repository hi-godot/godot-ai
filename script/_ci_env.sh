## Shared env preamble for every ``script/ci-*`` runner. Sourced from the
## top of each ci-* script via ``source "$(dirname "$0")/_ci_env.sh"``.
##
## Match the workflow ``env:`` block opt-out for telemetry: no fake
## "installs" or stray streaming-insert quota from local dev runs of
## these scripts either. The collector treats this flag as a hard
## opt-out (no UUID generated, no worker thread, no _send). See
## docs/TELEMETRY.md.
export GODOT_AI_DISABLE_TELEMETRY=true
