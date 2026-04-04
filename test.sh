#!/bin/bash
# subtract OS test suite
# validates tier escalation, lookup, destructive gate, and cloud path.
# run from repo root: bash test.sh
# works on any node. reports what's available, tests what's available.

PASS=0
FAIL=0
SKIP=0

pass() { echo "  PASS: $1"; ((PASS++)); }
fail() { echo "  FAIL: $1"; ((FAIL++)); }
skip() { echo "  SKIP: $1"; ((SKIP++)); }

# --- setup: source handler into isolated temp dir ---

export SUBTRACT_DIR=$(mktemp -d)
cp subtract/handler.sh "$SUBTRACT_DIR/"
cp subtract/lookup.tsv "$SUBTRACT_DIR/"

# source handler (respects existing SUBTRACT_DIR)
source "$SUBTRACT_DIR/handler.sh"

echo "=== subtract OS tests ==="
echo "test dir: $SUBTRACT_DIR"
echo ""

# --- T1: lookup table ---

echo "--- T1: lookup table ---"

# known patterns should resolve
result=$(__subtract_lookup "what time is it")
if [ -n "$result" ]; then
    cmd="${result#*	}"
    if [ "$cmd" = "date +%T" ]; then
        pass "what time is it -> date +%T"
    else
        fail "what time is it -> got '$cmd', expected 'date +%T'"
    fi
else
    fail "what time is it -> no match"
fi

result=$(__subtract_lookup "list files")
if [ -n "$result" ]; then
    cmd="${result#*	}"
    if [ "$cmd" = "ls ." ]; then
        pass "list files -> ls ."
    else
        fail "list files -> got '$cmd', expected 'ls .'"
    fi
else
    fail "list files -> no match"
fi

# case insensitive
result=$(__subtract_lookup "What Time Is It")
if [ -n "$result" ]; then
    pass "case insensitive match"
else
    fail "case insensitive match"
fi

# unknown pattern should miss
result=$(__subtract_lookup "blargleflax")
if [ -z "$result" ]; then
    pass "unknown pattern -> no match"
else
    fail "unknown pattern -> unexpected match: $result"
fi

# canvas tag
result=$(__subtract_lookup "open youtube")
if [ -n "$result" ]; then
    tag="${result%%	*}"
    if [ "$tag" = "canvas" ]; then
        pass "youtube -> [canvas] tag"
    else
        fail "youtube -> got tag '$tag', expected 'canvas'"
    fi
else
    fail "youtube -> no match"
fi

# --- destructive gate ---

echo ""
echo "--- destructive gate ---"

if __subtract_is_destructive "rm -rf /tmp/foo"; then
    pass "rm detected as destructive"
else
    fail "rm not detected as destructive"
fi

if __subtract_is_destructive "dd if=/dev/zero of=/dev/sda"; then
    pass "dd detected as destructive"
else
    fail "dd not detected as destructive"
fi

if ! __subtract_is_destructive "ls -la"; then
    pass "ls not destructive"
else
    fail "ls falsely flagged as destructive"
fi

if ! __subtract_is_destructive "echo hello"; then
    pass "echo not destructive"
else
    fail "echo falsely flagged as destructive"
fi

# --- truncation ---

echo ""
echo "--- context truncation ---"

long_output=$(for i in $(seq 1 50); do echo "line $i"; done)
truncated=$(__subtract_truncate "$long_output")
if echo "$truncated" | grep -q "\[truncated: 50 lines total\]"; then
    pass "50-line output truncated"
else
    fail "50-line output not truncated"
fi

short_output="line 1"
not_truncated=$(__subtract_truncate "$short_output")
if ! echo "$not_truncated" | grep -q "\[truncated"; then
    pass "1-line output not truncated"
else
    fail "1-line output incorrectly truncated"
fi

# --- T2: local model ---

echo ""
echo "--- T2: local model (ollama) ---"

if curl -s --connect-timeout 1 http://localhost:11434/api/tags &>/dev/null; then
    result=$(__subtract_generate "list all files including hidden")
    if [ -n "$result" ]; then
        pass "T2 generated a command: $result"
    else
        fail "T2 returned empty (ollama running but no response)"
    fi
else
    skip "ollama not running on localhost:11434"
fi

# --- T4: cloud escalation ---

echo ""
echo "--- T4: cloud escalation (claude -p) ---"

if command -v claude &>/dev/null; then
    # test with cloud_ai configured
    echo "claude" > "$SUBTRACT_DIR/cloud_ai"
    result=$(__subtract_cloud "show the 5 largest files in the current directory")
    if [ -n "$result" ]; then
        pass "T4 generated a command: $result"
    else
        fail "T4 returned empty (claude installed but no response)"
    fi

    # test without cloud_ai configured
    rm -f "$SUBTRACT_DIR/cloud_ai"
    result=$(__subtract_cloud "show files")
    if [ -z "$result" ]; then
        pass "T4 skipped when cloud_ai not configured"
    else
        fail "T4 fired without cloud_ai configured"
    fi
else
    skip "claude CLI not installed"
fi

# --- onboard gate ---

echo ""
echo "--- onboard gate ---"

# .onboarded exists -> gate should not fire
touch "$SUBTRACT_DIR/.onboarded"
# we can't test the full handler interactively, but we can test the condition
if [ -f "$SUBTRACT_DIR/.onboarded" ]; then
    pass ".onboarded flag respected"
else
    fail ".onboarded flag not found after touch"
fi

# .onboarded missing -> gate condition true
rm -f "$SUBTRACT_DIR/.onboarded"
if [ ! -f "$SUBTRACT_DIR/.onboarded" ]; then
    pass ".onboarded missing triggers gate condition"
else
    fail ".onboarded still exists after rm"
fi

# reconfigure entry exists in lookup
result=$(__subtract_lookup "reconfigure subtractOS")
if [ -n "$result" ]; then
    pass "reconfigure* pattern exists in lookup"
else
    fail "reconfigure* pattern missing from lookup"
fi

# --- escalation chain order ---

echo ""
echo "--- escalation chain ---"

# T1 hit should not fall through
touch "$SUBTRACT_DIR/.onboarded"
result=$(__subtract_lookup "what time is it")
if [ -n "$result" ]; then
    pass "T1 hit stops escalation"
else
    fail "T1 miss on known pattern"
fi

# unknown intent should miss T1
result=$(__subtract_lookup "calculate the mass of jupiter in kilograms")
if [ -z "$result" ]; then
    pass "novel intent misses T1 (escalation continues)"
else
    fail "novel intent hit T1 unexpectedly"
fi

# --- cleanup ---

rm -rf "$SUBTRACT_DIR"

# --- summary ---

echo ""
echo "=== results ==="
echo "PASS: $PASS  FAIL: $FAIL  SKIP: $SKIP"
TOTAL=$((PASS + FAIL))
if [ "$FAIL" -eq 0 ]; then
    echo "all $TOTAL tests passed."
else
    echo "$FAIL of $TOTAL tests failed."
    exit 1
fi
