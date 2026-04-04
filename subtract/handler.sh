# subtract OS -- translation layer
# type what you mean. the computer figures out the command.
#
# tier 1: lookup table. instant, local, no dependencies.
# tier 2: local generative model (optional). requires ollama + a pulled model.
#
# everything lives in ~/.subtract/. read it, edit it, delete it.

SUBTRACT_DIR="$HOME/.subtract"
SUBTRACT_LOOKUP="$SUBTRACT_DIR/lookup.tsv"
SUBTRACT_LAST_OUTPUT=""
SUBTRACT_MAX_CONTEXT=20

# destructive verbs that always gate behind explicit confirmation
SUBTRACT_DESTRUCTIVE="rm rmdir dd mkfs chmod chown shred truncate"

# --- internal helpers ---

__subtract_truncate() {
    local lines
    lines=$(echo "$1" | wc -l)
    if [ "$lines" -gt "$SUBTRACT_MAX_CONTEXT" ]; then
        echo "$1" | tail -n "$SUBTRACT_MAX_CONTEXT"
        echo "[truncated: $lines lines total]"
    else
        echo "$1"
    fi
}

__subtract_capture() {
    if [ -z "$_SUBTRACT_FROM_HANDLER" ]; then
        SUBTRACT_LAST_OUTPUT="last command: $(fc -ln -1 2>/dev/null | sed "s/^[[:space:]]*//")"
    fi
    _SUBTRACT_FROM_HANDLER=""
}
PROMPT_COMMAND="__subtract_capture;${PROMPT_COMMAND:+$PROMPT_COMMAND}"

# --- tier 1: lookup table ---

__subtract_lookup() {
    local input_lower="${1,,}"
    local pattern tag cmd rest
    while IFS=$'\t' read -r pattern rest; do
        [[ "$pattern" =~ ^#.*$ || -z "$pattern" ]] && continue
        local pattern_lower="${pattern,,}"
        # shellcheck disable=SC2254
        if [[ "$input_lower" == $pattern_lower ]]; then
            # three-column: pattern<TAB>[tag]<TAB>command
            # two-column:   pattern<TAB>command (backwards compat)
            if [[ "$rest" =~ ^\[([a-z]+)\] ]]; then
                tag="${BASH_REMATCH[1]}"
                cmd="${rest#*$'\t'}"
            else
                tag="stdout"
                cmd="$rest"
            fi
            echo "${tag}	${cmd}"
            return 0
        fi
    done < "$SUBTRACT_LOOKUP"
    return 1
}

# --- tier 2: local generative model (optional) ---

__subtract_generate() {
    # requires: ollama running on localhost:11434, curl, jq
    curl -s --connect-timeout 1 http://localhost:11434/api/tags &>/dev/null || return 1
    command -v jq &>/dev/null || return 1

    local input="$1"
    local context=""
    if [ -n "$SUBTRACT_LAST_OUTPUT" ]; then
        context=$(__subtract_truncate "$SUBTRACT_LAST_OUTPUT")
    fi

    local model
    model=$(/usr/bin/head -1 "$SUBTRACT_DIR/model" 2>/dev/null)
    [ -z "$model" ] && model="qwen2.5:7b"

    local ctx_str=""
    [ -n "$context" ] && ctx_str=" Context: $context."

    local prompt="Translate to a single bash command. Output ONLY the command, nothing else. No explanation. No markdown. No code fences.${ctx_str} Input: ${input}"

    local payload result
    payload=$(jq -n --arg model "$model" --arg prompt "$prompt" \
        '{model: $model, prompt: $prompt, stream: false}')
    result=$(curl -s --connect-timeout 3 -X POST -H "Content-Type: application/json" \
        -d "$payload" http://localhost:11434/api/generate 2>/dev/null)
    [ -z "$result" ] && return 1

    result=$(echo "$result" | jq -r '.response // empty')
    [ -z "$result" ] && return 1

    # strip markdown fences if model ignores the instruction
    result="${result//\`\`\`bash/}"
    result="${result//\`\`\`/}"
    result=$(echo "$result" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

    echo "$result"
}

# --- tier 4: cloud escalation (optional) ---

__subtract_cloud() {
    local cloud_ai
    cloud_ai=$(cat "$SUBTRACT_DIR/cloud_ai" 2>/dev/null)
    [ -z "$cloud_ai" ] && return 1

    local input="$1"
    local context=""
    if [ -n "$SUBTRACT_LAST_OUTPUT" ]; then
        context=$(__subtract_truncate "$SUBTRACT_LAST_OUTPUT")
    fi

    local ctx_str=""
    [ -n "$context" ] && ctx_str=" Context: $context."

    local prompt="Translate to a single bash command. Output ONLY the command, nothing else. No explanation. No markdown. No code fences.${ctx_str} Input: ${input}"

    local result
    case "$cloud_ai" in
        claude)
            command -v claude &>/dev/null || return 1
            result=$(claude -p "$prompt" 2>/dev/null)
            ;;
        *)
            # codex, gemini: stub for when CLIs exist
            return 1
            ;;
    esac

    [ -z "$result" ] && return 1

    # strip markdown fences if model ignores the instruction
    result="${result//\`\`\`bash/}"
    result="${result//\`\`\`/}"
    result=$(echo "$result" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

    echo "$result"
}

# --- destructive command check ---

__subtract_is_destructive() {
    local cmd="$1"
    local word verb
    for word in $cmd; do
        for verb in $SUBTRACT_DESTRUCTIVE; do
            [ "$word" = "$verb" ] && return 0
        done
    done
    return 1
}

# --- core handler ---

__subtract_handle() {
    local input="$*"
    local cmd tier tag output result

    # onboard gate: if not yet configured, run onboard first (interactive only)
    if [ ! -f "$SUBTRACT_DIR/.onboarded" ] && [[ -t 0 ]]; then
        bash "$SUBTRACT_DIR/onboard.sh" < /dev/tty
        if [ -f "$SUBTRACT_DIR/.onboarded" ]; then
            echo "you said: $input"
            read -r -p "[enter to run / ctrl-c to skip] " _ < /dev/tty
            __subtract_handle "$@"
        else
            echo "setup deferred. type 'reconfigure' when ready."
        fi
        return
    fi

    # tier 1: local lookup (returns tag<TAB>cmd)
    result=$(__subtract_lookup "$input")
    if [ -n "$result" ]; then
        tier="T1"
        tag="${result%%	*}"
        cmd="${result#*	}"
    else
        # tier 2: local generative model (if available)
        cmd=$(__subtract_generate "$input")
        if [ -n "$cmd" ]; then
            tier="T2"
            tag="stdout"
        else
            # tier 4: cloud escalation (if configured)
            cmd=$(__subtract_cloud "$input")
            if [ -n "$cmd" ]; then
                tier="T4"
                tag="stdout"
            fi
        fi
    fi

    if [ -n "$cmd" ] && [ "$cmd" != "null" ]; then
        if __subtract_is_destructive "$cmd"; then
            echo "[DESTRUCTIVE] $cmd"
            read -r -p "[y/n] " confirm
            [ "$confirm" != "y" ] && { echo "aborted."; return 1; }
        else
            echo "[$tier:$tag] $cmd"
            read -r -p "[enter/n] " confirm
            [ "$confirm" = "n" ] && return 1
        fi

        case "$tag" in
            canvas)
                # two [canvas] patterns:
                #   web-as-apps: cmd is subtract-canvas (launches renderer directly, no pipe)
                #   generators:  cmd produces HTML, handler pipes output to subtract-canvas
                # subtract-canvas outputs ACTION: lines on stdout when user taps
                local action
                output=$(eval "$cmd" 2>&1)
                local exit_code=$?
                if [ $exit_code -eq 0 ] && [ -n "$output" ]; then
                    action=$(echo "$output" | subtract-canvas -)
                else
                    action=$(eval "$cmd")
                fi
                # canvas actions are trusted (we control the templates)
                # eval directly instead of routing back through lookup
                if [ -n "$action" ]; then
                    echo "[action] $action"
                    eval "$action"
                fi
                ;;
            player)
                eval "$cmd"
                ;;
            *)
                output=$(eval "$cmd" 2>&1)
                local exit_code=$?
                echo "$output"
                if [ $exit_code -eq 0 ]; then
                    SUBTRACT_LAST_OUTPUT="output of '$cmd': $(__subtract_truncate "$output")"
                fi
                ;;
        esac
        _SUBTRACT_FROM_HANDLER=1
    else
        echo "not found: $input"
    fi
}

command_not_found_handle() {
    __subtract_handle "$@"
}

# --- optional: shadow shims ---
# uncomment to intercept binaries that collide with natural language:
# write, make, find, open, touch, sort, head, watch, host, nice
# when shadowed, "find my pdf files" hits the handler instead of /usr/bin/find.
# to reach the real binary: use the full path (e.g. /usr/bin/find).
#
# SUBTRACT_SHADOW=(write make find open touch sort head watch host nice)
# for __cmd in "${SUBTRACT_SHADOW[@]}"; do
#     eval "${__cmd}() { __subtract_handle ${__cmd} \"\$@\"; }"
# done
# unset __cmd
