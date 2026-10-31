#!/usr/bin/env bash
# Keep a Claude conversation in memory when its session directory is unavailable.
set -eu
umask 077
mode=$1 conversation=$2 turn=${3:-} seconds=${4:-}
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
json="$script_dir/stream-json.awk"
fail() { printf 'consult: %s\nDiagnostics: %s\n' "$*" "$turn" >&2; exit 1; }
finish() { printf 'Reply: %s\nSession: %s\n' "$turn/reply.txt" "$turn/session.txt"; }
alive() {
    [ -f "$conversation/live-process.txt" ] || return 1
    IFS= read -r pid < "$conversation/live-process.txt"
    born=$(sed -n '2p' "$conversation/live-process.txt")
    [ "$(LC_ALL=C ps -p "$pid" -o lstart= 2>/dev/null)" = "$born" ]
}
if [ "$mode" = close ]; then
    : > "$conversation/stop"
    tries=0
    while alive && [ "$tries" -lt 20 ]; do sleep 0.1; tries=$((tries + 1)); done
    if alive; then kill -TERM "$pid"; fi
    exit 0
fi
if [ "$mode" = request ]; then
    trap 'rmdir "$conversation/lock" 2>/dev/null || :' EXIT
    alive || fail 'The live Claude conversation has ended.'
    exec 9<> "$conversation/requests"
    printf '%s\n%s\n' "$turn" "$seconds" >&9
    exec 9>&-
    deadline=$(( $(date +%s) + seconds + 5 ))
    while [ ! -f "$turn/completed" ]; do
        alive || fail 'The live Claude conversation ended before replying.'
        if [ "$(date +%s)" -ge "$deadline" ]; then
            : > "$conversation/stop"
            fail 'Turn timed out.'
        fi
        sleep 0.1
    done
    [ ! -f "$turn/error.txt" ] || fail "$(cat "$turn/error.txt")"
    finish
    exit 0
fi

fields=()
while IFS= read -r line || [ -n "$line" ]; do fields+=("$line"); done < "$conversation/live-state.txt"
session=${fields[2]} repo=${fields[3]} model=${fields[4]} effort=${fields[5]} cli=${fields[6]}
args=(-p --input-format stream-json --output-format stream-json --verbose --no-session-persistence
    --tools 'Read,Glob,Grep' --allowedTools 'Read,Glob,Grep' --permission-mode dontAsk --session-id "$session")
[ -z "$model" ] || args+=(--model "$model")
[ -z "$effort" ] || args+=(--effort "$effort")
printf '%s\n' "$cli" "${args[@]}" > "$conversation/live-command.txt"
mkfifo "$conversation/input" "$conversation/output" "$conversation/requests"
child='' timer=''
kill_tree() {
    local process=$1 descendant
    for descendant in $(ps -ax -o pid= -o ppid= | awk -v parent="$process" '$2 == parent {print $1}'); do kill_tree "$descendant"; done
    kill -KILL "$process" 2>/dev/null || :
}
cleanup() {
    [ -z "$timer" ] || kill_tree "$timer"
    [ -z "$child" ] || kill_tree "$child"
    if [ -n "$turn" ] && [ -f "$conversation/live-stderr.txt" ]; then cp "$conversation/live-stderr.txt" "$turn/stderr.txt" 2>/dev/null || :; fi
    rm -f "$conversation/live-process.txt"
} 2>/dev/null
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
(cd "$repo" && unset CLAUDECODE && export CONSULT_CONSULTANT=1 && exec "$cli" "${args[@]}") < "$conversation/input" > "$conversation/output" 2> "$conversation/live-stderr.txt" &
child=$!
exec 3> "$conversation/input"
exec 4< "$conversation/output"
exec 9<> "$conversation/requests"
printf '%s\n%s\n' "$$" "$(LC_ALL=C ps -p $$ -o lstart=)" > "$conversation/live-process.txt"
rmdir "$conversation/lock"
first=1
while :; do
    cp "$conversation/live-command.txt" "$turn/command.txt"
    : > "$turn/stdout.txt"
    (
        sleep "$seconds"
        : > "$turn/timed-out"
        kill_tree "$child"
    ) &
    timer=$!
    {
        printf '{"type":"user","message":{"role":"user","content":'
        LC_ALL=C awk -v mode=quote -v bytes="$(wc -c < "$turn/prompt.txt")" -f "$json" "$turn/prompt.txt"
        printf '},"parent_tool_use_id":null,"session_id":"%s"}\n' "$session"
    } >&3 || fail 'The live Claude conversation has ended.'
    error=''
    got_result=''
    while IFS= read -r line <&4; do
        printf '%s\n' "$line" >> "$turn/stdout.txt"
        kind=$(printf '%s\n' "$line" | LC_ALL=C awk -v field=type -f "$json") || { error='Claude returned an invalid event.'; break; }
        [ "$kind" = result ] || continue
        got_result=1
        id=$(printf '%s\n' "$line" | LC_ALL=C awk -v field=session_id -f "$json") || id=''
        success=$(printf '%s\n' "$line" | LC_ALL=C awk -v field=is_error -f "$json") || success=''
        if [ "$id" != "$session" ]; then error='Claude returned a different conversation ID.'
        elif [ "$success" != false ]; then error='Claude reported an unsuccessful turn.'
        elif ! printf '%s\n' "$line" | LC_ALL=C awk -v field=result -f "$json" > "$turn/reply.txt"; then error='Claude returned no reply.'
        elif ! LC_ALL=C grep -q '[^[:space:]]' "$turn/reply.txt"; then error='CLI returned an empty reply.'
        fi
        break
    done
    { kill_tree "$timer"; wait "$timer" || :; } 2>/dev/null
    timer=''
    cp "$conversation/live-stderr.txt" "$turn/stderr.txt"
    if [ -f "$turn/timed-out" ]; then error='Turn timed out.'
    elif [ -z "$got_result" ] && [ -z "$error" ]; then error='Claude exited before replying; inspect stderr.txt.'
    fi
    if [ -n "$error" ]; then
        printf '%s' "$error" > "$turn/error.txt"
        : > "$turn/completed"
        fail "$error"
    fi
    cp "$conversation/live-state.txt" "$turn/session.txt"
    : > "$turn/completed"
    if [ -n "$first" ]; then finish; first=''; fi
    while :; do
        [ ! -f "$conversation/stop" ] || exit 0
        if IFS= read -r -t 1 turn <&9; then
            IFS= read -r seconds <&9
            break
        fi
    done
done
