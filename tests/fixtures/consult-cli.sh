#!/usr/bin/env bash
# An offline CLI double. All state lives in the test's temporary directory.
set -eu
cat > "$FAKE_CAPTURE/prompt.txt"
printf '%s\n' "$PWD" > "$FAKE_CAPTURE/cwd.txt"
printf '%s\n' "$@" > "$FAKE_CAPTURE/args.txt"
printf '%s\n' "${CONSULT_CONSULTANT:-}" > "$FAKE_CAPTURE/consultant.txt"
session='' output=''
if [ "${1:-}" = exec ]; then
    provider=codex
    if [ "${2:-}" = resume ]; then session=$3; fi
else provider=claude; fi
while [ "$#" -gt 0 ]; do
    case "$1" in
        --session-id|--resume) session=$2; shift;;
        -o) output=$2; shift;;
    esac
    shift
done
if [ -z "$session" ]; then
    session=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n' | sed 's/^\(.\{8\}\)\(.\{4\}\)\(.\{4\}\)\(.\{4\}\)\(.\{12\}\)$/\1-\2-\3-\4-\5/')
fi
printf '%s\n' "$session" > "$FAKE_CAPTURE/id.txt"
case "${FAKE_CASE:-}" in
    exit) printf 'provider failure\n' >&2; exit 7;;
    sleep) sleep 30 & echo "$!" > "$FAKE_CAPTURE/child.txt"; wait;;
    nested)
        bash "$FAKE_RUNNER" --provider claude --message "$FAKE_CAPTURE/prompt.txt" > "$FAKE_CAPTURE/nested-out.txt" 2> "$FAKE_CAPTURE/nested-err.txt" && exit 9
        ;;
esac
body=${FAKE_REPLY:-Independent finding}
case "${FAKE_CASE:-}" in empty) body='   ';; wrong-id) session=aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa;; esac
if [ "$provider" = claude ]; then printf '%s' "$body"; exit 0; fi
case "${FAKE_CASE:-}" in
    malformed) printf 'not an event\n'; exit 0;;
    no-id) ;;
    *) printf '{"type":"thread.started","thread_id":"%s"}\n' "$session";;
esac
if [ "${FAKE_CASE:-}" = duplicate-id ]; then printf '{"type":"thread.started","thread_id":"%s"}\n' "$session"; fi
if [ "${FAKE_CASE:-}" = failed-event ]; then printf '{"type":"turn.failed","error":{"message":"failed"}}\n'; fi
if [ "${FAKE_CASE:-}" != no-completion ]; then printf '{"type":"turn.completed","usage":{}}\n'; fi
if [ "${FAKE_CASE:-}" = duplicate-completion ]; then printf '{"type":"turn.completed","usage":{}}\n'; fi
printf '%s' "$body" > "$output"
