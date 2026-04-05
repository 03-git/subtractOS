# subtract OS -- translation layer
# type what you mean. the computer figures out the command.
#
# tier 1: lookup table. instant, local, no dependencies.
# tier 2: local generative model (optional). requires ollama + a pulled model.
# kiwix: questions (input ending in ?) route to local kiwix corpus.
#
# everything lives in ~/.subtract/. read it, edit it, delete it.

SUBTRACT_DIR="${SUBTRACT_DIR:-$HOME/.subtract}"
SUBTRACT_LOOKUP="$SUBTRACT_DIR/lookup.tsv"
SUBTRACT_SKILLS="$SUBTRACT_DIR/skills"
SUBTRACT_KIWIX="${SUBTRACT_KIWIX:-http://localhost:8888}"
SUBTRACT_LAST_OUTPUT=""
SUBTRACT_MAX_CONTEXT=20

# skills prefix patterns: procedural queries ("how do I X", "teach me X")
# matched after T1, before kiwix. triggers grep against skills index.
SUBTRACT_SKILLS_PREFIXES="how do i |how to |teach me |steps to |guide to |tutorial |tutorial for "

# destructive verbs that always gate behind explicit confirmation
SUBTRACT_DESTRUCTIVE="rm rmdir dd mkfs chmod chown shred truncate"

# --- internal helpers ---

__subtract_lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

__subtract_truncate() {
    local lines
    lines=$(echo "$1" | wc -l | tr -d ' ')
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

# --- skills: procedural knowledge lookup ---

__subtract_skills_stale() {
    # check if index needs rebuild: any .md file newer than index
    local index="$SUBTRACT_SKILLS/.index"
    [ ! -f "$index" ] && return 0
    local newer
    newer=$(find "$SUBTRACT_SKILLS" -name '*.md' -newer "$index" -print -quit 2>/dev/null)
    [ -n "$newer" ] && return 0
    return 1
}

__subtract_strip_prefix() {
    local input
    input=$(__subtract_lower "$1")
    local prefix
    # try each skills prefix; return the residual if one matches
    while IFS='|' read -ra prefixes; do
        for prefix in "${prefixes[@]}"; do
            prefix="${prefix# }"
            [ -z "$prefix" ] && continue
            if [[ "$input" == ${prefix}* ]]; then
                echo "${input#$prefix}"
                return 0
            fi
        done
    done <<< "$SUBTRACT_SKILLS_PREFIXES"
    return 1
}

__subtract_skills() {
    local input="$1"
    [ ! -d "$SUBTRACT_SKILLS" ] && return 1

    local index="$SUBTRACT_SKILLS/.index"

    # auto-rebuild if stale
    if __subtract_skills_stale; then
        bash "$SUBTRACT_DIR/skills-rebuild.sh" > /dev/null 2>&1 || true
    fi
    [ ! -f "$index" ] && return 1

    # strip prefix to get query terms
    local residual
    residual=$(__subtract_strip_prefix "$input") || return 1
    [ -z "$residual" ] && return 1

    # tokenize residual, filter stopwords, grep index for each token
    local -a tokens matches
    local token
    read -ra tokens <<< "$residual"

    # find files matching ALL non-stopword tokens
    local stopwords=" a an and are at be by do for from how i if in is it me my no not of on or so the to up us we "
    local -a search_tokens
    for token in "${tokens[@]}"; do
        token=$(__subtract_lower "$token")
        [ ${#token} -lt 3 ] && continue
        case "$stopwords" in *" $token "*) continue ;; esac
        search_tokens+=("$token")
    done
    [ ${#search_tokens[@]} -eq 0 ] && return 1

    # first token: get candidate files
    local candidates
    candidates=$(grep -i "^${search_tokens[0]}	" "$index" 2>/dev/null | cut -f2 | sort -u)
    [ -z "$candidates" ] && return 1

    # intersect with remaining tokens
    local i
    for ((i=1; i<${#search_tokens[@]}; i++)); do
        local next_candidates
        next_candidates=$(grep -i "^${search_tokens[$i]}	" "$index" 2>/dev/null | cut -f2 | sort -u)
        candidates=$(comm -12 <(echo "$candidates") <(echo "$next_candidates"))
        [ -z "$candidates" ] && return 1
    done

    # count matches
    local count
    count=$(echo "$candidates" | wc -l | tr -d ' ')

    if [ "$count" -eq 1 ]; then
        # single match: display it
        local filepath="$SUBTRACT_SKILLS/${candidates}.md"
        if [ -f "$filepath" ]; then
            echo "skill:${candidates}"
            return 0
        else
            # index references deleted file, rebuild and retry
            bash "$SUBTRACT_DIR/skills-rebuild.sh" > /dev/null 2>&1 || true
            return 1
        fi
    else
        # multi-match: return list for handler to display
        local list=""
        local n=1
        while IFS= read -r match; do
            list="${list}${n}. ${match}"$'\n'
            n=$((n+1))
        done <<< "$candidates"
        # cache for "show N" retrieval
        echo "$candidates" > ${TMPDIR:-/tmp}/.subtract-skills-lastmatch.${USER:-$$}
        echo "list:${count}"$'\n'"${list}"
        return 0
    fi
    return 1
}

# --- tier 1: lookup table ---

__subtract_lookup() {
    local input_lower
    input_lower=$(__subtract_lower "$1")
    local pattern tag cmd rest
    while IFS=$'\t' read -r pattern rest; do
        [[ "$pattern" =~ ^#.*$ || -z "$pattern" ]] && continue
        local pattern_lower
        pattern_lower=$(__subtract_lower "$pattern")
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

# --- kiwix: local corpus lookup for questions ---

__subtract_kiwix() {
    local query="$1"
    [ -z "$query" ] && return 1
    local encoded
    encoded=$(printf '%s' "$query" | jq -sRr @uri 2>/dev/null)
    [ -z "$encoded" ] && return 1
    curl -s --connect-timeout 1 --max-time 3 "$SUBTRACT_KIWIX/search?pattern=${encoded}&pageLength=1" 2>/dev/null \
        | sed -n 's/.*<cite>\(.*\)<\/cite>.*/\1/p' \
        | sed 's/<[^>]*>//g; s/&amp;/\&/g; s/&lt;/</g; s/&gt;/>/g; s/&#39;/'"'"'/g; s/&quot;/"/g' \
        | head -1
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

    # --- skill management commands (before main routing chain) ---
    local input_lower
    input_lower=$(__subtract_lower "$input")
    case "$input_lower" in
        "skills")
            echo "[skill] domains:"
            ls "$SUBTRACT_SKILLS/" 2>/dev/null | grep -v '^\.' || echo "  (none)"
            _SUBTRACT_FROM_HANDLER=1
            return 0
            ;;
        "skills rebuild")
            bash "$SUBTRACT_DIR/skills-rebuild.sh"
            _SUBTRACT_FROM_HANDLER=1
            return 0
            ;;
        "skills "*)
            local domain="${input_lower#skills }"
            if [ -d "$SUBTRACT_SKILLS/$domain" ]; then
                echo "[skill] $domain:"
                ls "$SUBTRACT_SKILLS/$domain/" 2>/dev/null | sed 's/\.md$//'
            else
                echo "no skills domain: $domain"
            fi
            _SUBTRACT_FROM_HANDLER=1
            return 0
            ;;
        "skill add "*)
            local skill_path="${input#* add }"
            local skill_dir="$SUBTRACT_SKILLS/$(dirname "$skill_path")"
            local skill_file="$SUBTRACT_SKILLS/${skill_path}.md"
            mkdir -p "$skill_dir"
            if [ ! -f "$skill_file" ]; then
                cat > "$skill_file" <<'TMPL'
---
aliases:
tags:
---

TITLE

Steps:
1.
TMPL
            fi
            ${EDITOR:-vi} "$skill_file"
            bash "$SUBTRACT_DIR/skills-rebuild.sh"
            _SUBTRACT_FROM_HANDLER=1
            return 0
            ;;
        "skill rm "*)
            local skill_path="${input#* rm }"
            local skill_file="$SUBTRACT_SKILLS/${skill_path}.md"
            if [ -f "$skill_file" ]; then
                echo "[DESTRUCTIVE] remove skill: $skill_path"
                read -r -p "[y/n] " confirm
                if [ "$confirm" = "y" ]; then
                    rm "$skill_file"
                    bash "$SUBTRACT_DIR/skills-rebuild.sh"
                    echo "removed."
                else
                    echo "kept."
                fi
            else
                echo "skill not found: $skill_path"
            fi
            _SUBTRACT_FROM_HANDLER=1
            return 0
            ;;
        "show "[0-9]*)
            local num="${input_lower#show }"
            if ! [[ "$num" =~ ^[0-9]+$ ]]; then
                echo "usage: show N (where N is a number)"
                _SUBTRACT_FROM_HANDLER=1
                return 0
            fi
            local lastmatch="${TMPDIR:-/tmp}/.subtract-skills-lastmatch.${USER:-$$}"
            if [ -f "$lastmatch" ]; then
                local match
                match=$(sed -n "${num}p" "$lastmatch")
                if [ -n "$match" ] && [ -f "$SUBTRACT_SKILLS/${match}.md" ]; then
                    echo "[skill:${match}]"
                    awk '/^---$/{if(!fm){fm=1;next}else if(fm==1){fm=2;next}} fm==1{next} fm==0||fm==2{print}' "$SUBTRACT_SKILLS/${match}.md"
                    SUBTRACT_LAST_OUTPUT="skill lookup: $match"
                else
                    echo "no match at position $num"
                fi
            else
                echo "no recent skill search to show from"
            fi
            _SUBTRACT_FROM_HANDLER=1
            return 0
            ;;
    esac

    # --- routing chain: T1(raw) > T1(stripped) > Skills > Kiwix > T2 > T4 ---

    # tier 1 pass 1: exact lookup on raw input
    result=$(__subtract_lookup "$input")
    if [ -n "$result" ]; then
        tier="T1"
        tag="${result%%	*}"
        cmd="${result#*	}"
    fi

    # tier 1 pass 2: strip skills prefix, re-lookup
    # catches "how do I list my files" -> "list my files" -> T1 match
    if [ -z "$cmd" ]; then
        local stripped
        stripped=$(__subtract_strip_prefix "$input")
        if [ -n "$stripped" ]; then
            result=$(__subtract_lookup "$stripped")
            if [ -n "$result" ]; then
                tier="T1"
                tag="${result%%	*}"
                cmd="${result#*	}"
            fi
        fi
    fi

    # skills: procedural knowledge lookup (prefix match + grep index)
    if [ -z "$cmd" ]; then
        local skills_result
        skills_result=$(__subtract_skills "$input")
        if [ -n "$skills_result" ]; then
            if [[ "$skills_result" == skill:* ]]; then
                # single match: display the skill file
                local skill_path="${skills_result#skill:}"
                local skill_file="$SUBTRACT_SKILLS/${skill_path}.md"
                echo "[skill:${skill_path}]"
                # strip frontmatter, display content
                awk '/^---$/{if(!fm){fm=1;next}else if(fm==1){fm=2;next}} fm==1{next} fm==0||fm==2{print}' "$skill_file"
                SUBTRACT_LAST_OUTPUT="skill lookup: $skill_path"
                _SUBTRACT_FROM_HANDLER=1
                return 0
            elif [[ "$skills_result" == list:* ]]; then
                # multi-match: show numbered list
                local header="${skills_result%%$'\n'*}"
                local count="${header#list:}"
                echo "[skill] ${count} matches:"
                echo "$skills_result" | tail -n +2
                echo "type: show N"
                SUBTRACT_LAST_OUTPUT="skills search returned ${count} matches"
                _SUBTRACT_FROM_HANDLER=1
                return 0
            fi
        fi
    fi

    # kiwix: questions route to local corpus
    if [ -z "$cmd" ] && [[ "$input" == *\? ]]; then
        local query="${input%\?}"
        local query_lower
        query_lower=$(__subtract_lower "$query")
        query_lower="${query_lower#what is }"
        query_lower="${query_lower#what are }"
        query_lower="${query_lower#who is }"
        query_lower="${query_lower#who was }"
        query_lower="${query_lower#how do i }"
        query_lower="${query_lower#how to }"
        query="$query_lower"
        local snippet
        snippet=$(__subtract_kiwix "$query")
        if [ -n "$snippet" ]; then
            echo "[kiwix] $snippet"
            SUBTRACT_LAST_OUTPUT="kiwix answer for '$input': $(__subtract_truncate "$snippet")"
            _SUBTRACT_FROM_HANDLER=1
            return 0
        fi
    fi

    # kiwix: also try bare "what is" / "who is" without trailing ?
    if [ -z "$cmd" ]; then
        local kiwix_query=""
        local input_lower
        input_lower=$(__subtract_lower "$input")
        case "$input_lower" in
            "what is "*|"what are "*|"who is "*|"who was "*|"when was "*|"when did "*|"where is "*|"define "*)
                case "$input_lower" in
                    "what is "*) kiwix_query="${input_lower#what is }" ;;
                    "what are "*) kiwix_query="${input_lower#what are }" ;;
                    "who is "*) kiwix_query="${input_lower#who is }" ;;
                    "who was "*) kiwix_query="${input_lower#who was }" ;;
                    "when was "*) kiwix_query="${input_lower#when was }" ;;
                    "when did "*) kiwix_query="${input_lower#when did }" ;;
                    "where is "*) kiwix_query="${input_lower#where is }" ;;
                    "define "*) kiwix_query="${input_lower#define }" ;;
                esac
                ;;
        esac
        if [ -n "$kiwix_query" ]; then
            local snippet
            snippet=$(__subtract_kiwix "$kiwix_query")
            if [ -n "$snippet" ]; then
                echo "[kiwix] $snippet"
                SUBTRACT_LAST_OUTPUT="kiwix answer for '$input': $(__subtract_truncate "$snippet")"
                _SUBTRACT_FROM_HANDLER=1
                return 0
            fi
        fi
    fi

    # tier 2: local generative model (if available)
    if [ -z "$cmd" ]; then
        cmd=$(__subtract_generate "$input")
        if [ -n "$cmd" ]; then
            tier="T2"
            tag="stdout"
        fi
    fi

    # tier 4: cloud escalation (if configured)
    if [ -z "$cmd" ]; then
        cmd=$(__subtract_cloud "$input")
        if [ -n "$cmd" ]; then
            tier="T4"
            tag="stdout"
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
                local _subtract_tmp="${TMPDIR:-/tmp}/.subtract_out.$$"
                eval "$cmd" > >(tee "$_subtract_tmp") 2>&1
                local exit_code=$?
                if [ $exit_code -eq 0 ]; then
                    SUBTRACT_LAST_OUTPUT="output of '$cmd': $(__subtract_truncate "$(cat "$_subtract_tmp")")"
                fi
                rm -f "$_subtract_tmp"
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
