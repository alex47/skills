#!/usr/bin/env bash
# Native consultation runner for Linux, macOS and WSL. Bash 3.2 or newer.
set -eu
umask 077

fail() { printf 'consult: %s\n' "$*" >&2; exit 1; }
[ "${CONSULT_CONSULTANT:-}" != 1 ] || fail 'Consultants must not invoke consult.'
uuid_ok() { [[ $1 =~ ^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$ ]]; }
outside() { case "$1/" in "$repo/"*) fail 'Keep diagnostic files outside the project.';; esac; }
absolute_file() { (cd "$(dirname "$1")" && printf '%s/%s\n' "$(pwd -P)" "$(basename "$1")"); }

provider='' host='' repo='' session_file='' message='' model='' effort='' cli='' artifacts='' seconds=600
while [ "$#" -gt 0 ]; do
    option=$1
    case "$option" in
        --host|--provider|--repo|--session|--message|--model|--effort|--cli|--artifacts|--timeout)
            [[ "$#" -ge 2 && -n "$2" ]] || fail "$option needs a nonempty value."
            case "$2" in *$'\n'*|*$'\r'*) fail 'Options cannot contain line breaks.';; esac
            case "$option" in
                --host) host=$2;; --provider) provider=$2;; --repo) repo=$2;;
                --session) session_file=$2;; --message) message=$2;; --model) model=$2;;
                --effort) effort=$2;; --cli) cli=$2;; --artifacts) artifacts=$2;;
                --timeout) seconds=$2;;
            esac
            shift 2;;
        --help|-h)
            printf '%s\n' 'Usage: bash runner.sh --message FILE [--session SESSION.txt]' \
                'Options: --provider claude|codex --repo DIR --timeout SECONDS' \
                'Advanced: --host --model --effort --cli --artifacts'
            exit 0;;
        *) fail "Unknown option: $option";;
    esac
done
[[ -n "$message" && -f "$message" ]] || fail '--message must name a text file.'
LC_ALL=C grep -q '[^[:space:]]' "$message" || fail 'Message is empty.'
message=$(absolute_file "$message")
case "$seconds" in ''|*[!0-9]*|0|0*) fail '--timeout must be a positive integer.';; esac
case "$provider" in ''|claude|codex) ;; *) fail 'Unknown provider.';; esac
case "$host" in ''|claude|codex) ;; *) fail 'Unknown host.';; esac
case "$effort" in ''|low|medium|high|xhigh|max) ;; *) fail 'Unknown effort.';; esac

session='' conversation=''
if [ -n "$session_file" ]; then
    [ -z "$artifacts" ] || fail '--artifacts is only valid for a new conversation.'
    [ -f "$session_file" ] || fail 'Session file does not exist.'
    [ -s "$session_file" ] || fail 'Session file is empty.'
    session_file=$(absolute_file "$session_file")
    # Read session fields as data.
    fields=()
    while IFS= read -r line || [ -n "$line" ]; do fields+=("${line%$'\r'}"); done < "$session_file"
    [[ "${#fields[@]}" -eq 8 && "${fields[0]}" = 'consult-session-1' ]] || fail 'Invalid session file.'
    case "${fields[1]}" in claude|codex) ;; *) fail 'Invalid session provider.';; esac
    uuid_ok "${fields[2]}" || fail 'Invalid conversation ID.'
    [ -z "$provider" ] || [ "$provider" = "${fields[1]}" ] || fail 'Provider differs from the saved session.'
    [ -z "$host" ] || [ "$host" = "${fields[7]}" ] || fail 'Host differs from the saved session.'
    [ -z "$model" ] || [ "$model" = "${fields[4]}" ] || fail 'Model differs from the saved session.'
    [ -z "$effort" ] || [ "$effort" = "${fields[5]}" ] || fail 'Effort differs from the saved session.'
    [ -z "$cli" ] || [ "$cli" = "${fields[6]}" ] || fail 'CLI differs from the saved session.'
    if [ -n "$repo" ]; then
        requested=$(cd "$repo" && pwd -P) || fail 'Working directory does not exist.'
        [ "$requested" = "${fields[3]}" ] || fail 'Working directory differs from the saved session.'
    fi
    provider=${fields[1]} session=${fields[2]} repo=${fields[3]}
    model=${fields[4]} effort=${fields[5]} cli=${fields[6]} host=${fields[7]}
    case "$repo" in /*) ;; *) fail 'Invalid saved working directory.';; esac
    conversation=$(cd "$(dirname "$session_file")/.." && pwd -P)
    [ "$(basename "$session_file")" = session.txt ] || fail 'Invalid session path.'
else
    if [ -z "$host" ]; then
        claude_host='' codex_host=''
        case "${CLAUDECODE:-}" in 1|true|TRUE) claude_host=1;; esac
        [ -z "${CODEX_THREAD_ID:-}${CODEX_SESSION_ID:-}" ] || codex_host=1
        if [ -n "$claude_host" ] && [ -z "$codex_host" ]; then host=claude; fi
        if [ -n "$codex_host" ] && [ -z "$claude_host" ]; then host=codex; fi
    fi
    if [ -z "$provider" ]; then
        case "$host" in claude) provider=codex;; codex) provider=claude;;
            *) fail 'Cannot identify the caller; specify --provider claude or codex.';; esac
    fi
    repo=$(cd "${repo:-.}" && pwd -P) || fail 'Working directory does not exist.'
    if command -v git >/dev/null 2>&1; then
        top=$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null) || top=
        [ -z "$top" ] || repo=$(cd "$top" && pwd -P)
    fi
fi
[ -d "$repo" ] || fail 'Working directory does not exist.'
if [ -z "$cli" ]; then cli=$(command -v "$provider") || fail "$provider is not on PATH."; fi
case "$cli" in /*) ;; *) fail '--cli must be an absolute executable path.';; esac
[[ -x "$cli" && -f "$cli" ]] || fail 'CLI executable does not exist.'
cli=$(absolute_file "$cli")
if [ -z "$conversation" ]; then
    artifacts=${artifacts:-${TMPDIR:-/tmp}}
    ancestor=$artifacts suffix=
    while [ ! -d "$ancestor" ]; do
        name=$(basename "$ancestor")
        case "$name" in .|..) fail 'Diagnostic directory cannot be resolved.';; esac
        suffix="/$name$suffix"
        ancestor=$(dirname "$ancestor")
    done
    artifacts="$(cd "$ancestor" && pwd -P)$suffix"
    outside "$artifacts"
    mkdir -p "$artifacts"
    artifacts=$(cd "$artifacts" && pwd -P)
    conversation=$(mktemp -d "$artifacts/consult.XXXXXX")
fi
outside "$conversation"
mkdir "$conversation/lock" 2>/dev/null || fail 'Conversation has an active or interrupted turn.'
child='' timer='' turn=''
kill_tree() {
    local pid=$1 descendant
    for descendant in $(ps -ax -o pid= -o ppid= | awk -v parent="$pid" '$2 == parent {print $1}'); do
        kill_tree "$descendant"
    done
    kill -KILL "$pid" 2>/dev/null || :
}
cleanup() {
    [ -z "$timer" ] || kill_tree "$timer"
    [ -z "$child" ] || kill_tree "$child"
    rmdir "$conversation/lock" 2>/dev/null || :
} 2>/dev/null
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
if [ -n "$session_file" ]; then
    [[ -f "$conversation/latest.txt" && "$(cat "$conversation/latest.txt")" = "$session_file" ]] || fail 'Session is stale; use only the latest successful turn.'
fi
turn=$(mktemp -d "$conversation/turn.XXXXXX")
printf '%s\n' "$turn/session.txt" > "$conversation/latest.tmp"
mv "$conversation/latest.tmp" "$conversation/latest.txt"
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
cat "$script_dir/consultant.txt" > "$turn/prompt.txt"
printf '\nHOST MESSAGE:\n' >> "$turn/prompt.txt"
cat "$message" >> "$turn/prompt.txt"
args=()
if [ "$provider" = claude ]; then
    args=(-p --output-format text --tools 'Read,Glob,Grep' --allowedTools 'Read,Glob,Grep' --permission-mode dontAsk)
    if [ -n "$session" ]; then args+=(--resume "$session"); else
        session=$(uuidgen 2>/dev/null || od -An -N16 -tx1 /dev/urandom | tr -d ' \n' | sed 's/^\(.\{8\}\)\(.\{4\}\).\(.\{3\}\).\(.\{3\}\)\(.\{12\}\)$/\1-\2-4\3-8\4-\5/')
        uuid_ok "$session" || fail 'Could not create a conversation ID.'
        args+=(--session-id "$session")
    fi
    [ -z "$model" ] || args+=(--model "$model")
    [ -z "$effort" ] || args+=(--effort "$effort")
else
    args=(exec)
    if [ -n "$session" ]; then args+=(resume "$session"); fi
    args+=(-c 'sandbox_mode="read-only"' -c 'approval_policy="never"' --disable multi_agent --json -o "$turn/reply.txt" --skip-git-repo-check)
    [ -z "$model" ] || args+=(-m "$model")
    [ -z "$effort" ] || args+=(-c "model_reasoning_effort=\"$effort\"")
    args+=(-)
fi
printf '%s\n' "$cli" "${args[@]}" > "$turn/command.txt"
# exec makes the monitored PID the CLI, while the subshell sets its working directory.
(cd "$repo" && unset CLAUDECODE && export CONSULT_CONSULTANT=1 && exec "$cli" "${args[@]}") < "$turn/prompt.txt" > "$turn/stdout.txt" 2> "$turn/stderr.txt" &
child=$!
(
    sleep "$seconds"
    : > "$turn/timed-out"
    kill_tree "$child"
) &
timer=$!
code=0
wait "$child" || code=$?
child=
{ kill_tree "$timer"; wait "$timer" || :; } 2>/dev/null
timer=
turn_fail() { printf 'consult: %s\nDiagnostics: %s\n' "$*" "$turn" >&2; exit 1; }
[ ! -f "$turn/timed-out" ] || turn_fail 'Turn timed out.'
[ "$code" -eq 0 ] || turn_fail "$provider exited $code; inspect stderr.txt."
if [ "$provider" = claude ]; then
    cp "$turn/stdout.txt" "$turn/reply.txt"
else
    # Read conversation and completion events; the reply is already in reply.txt.
    ids=$(sed -nE 's/^[[:space:]]*\{[[:space:]]*"type"[[:space:]]*:[[:space:]]*"thread.started"[[:space:]]*,[[:space:]]*"thread_id"[[:space:]]*:[[:space:]]*"([[:xdigit:]-]+)"[[:space:]]*\}[[:space:]]*$/\1/p' "$turn/stdout.txt")
    uuid_ok "$ids" || turn_fail 'Missing or ambiguous Codex conversation ID.'
    [ -z "$session" ] || [ "$ids" = "$session" ] || turn_fail 'Codex resumed a different conversation.'
    session=$ids
    completions=$(grep -Ec '^[[:space:]]*\{[[:space:]]*"type"[[:space:]]*:[[:space:]]*"turn.completed"[[:space:]]*[,}]' "$turn/stdout.txt" || :)
    [ "$completions" = 1 ] || turn_fail 'Missing or ambiguous Codex completion event.'
    if grep -Eq '^[[:space:]]*\{[[:space:]]*"type"[[:space:]]*:[[:space:]]*"(error|turn.failed)"[[:space:]]*[,}]' "$turn/stdout.txt"; then turn_fail 'Codex reported a failed turn.'; fi
fi
if [ ! -f "$turn/reply.txt" ] || ! LC_ALL=C grep -q '[^[:space:]]' "$turn/reply.txt"; then turn_fail 'CLI returned an empty reply.'; fi
printf '%s\n' consult-session-1 "$provider" "$session" "$repo" "$model" "$effort" "$cli" "$host" > "$turn/session.txt"
printf 'Reply: %s\nSession: %s\n' "$turn/reply.txt" "$turn/session.txt"
