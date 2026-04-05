#!/bin/bash
# subtract OS installer
# copies handler + lookup table to ~/.subtract/, sources handler in .bashrc.
# no dependencies for tier 1 (lookup). ollama optional for tier 4 (model).
set -e

SUBTRACT_DIR="$HOME/.subtract"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCE_LINE='[ -f ~/.subtract/handler.sh ] && source ~/.subtract/handler.sh'

# copy files
mkdir -p "$SUBTRACT_DIR"
cp "$SCRIPT_DIR/subtract/handler.sh" "$SUBTRACT_DIR/"
cp "$SCRIPT_DIR/subtract/motd" "$SUBTRACT_DIR/"
cp "$SCRIPT_DIR/subtract/skills-rebuild.sh" "$SUBTRACT_DIR/"
cp "$SCRIPT_DIR/onboard.sh" "$SUBTRACT_DIR/"

# only copy lookup.tsv if it doesn't exist (don't overwrite user edits)
if [ ! -f "$SUBTRACT_DIR/lookup.tsv" ]; then
    cp "$SCRIPT_DIR/subtract/lookup.tsv" "$SUBTRACT_DIR/"
else
    echo "lookup.tsv already exists, keeping yours."
fi

# copy skills if not already present (don't overwrite user edits)
if [ ! -d "$SUBTRACT_DIR/skills" ]; then
    cp -r "$SCRIPT_DIR/skills" "$SUBTRACT_DIR/skills"
    bash "$SUBTRACT_DIR/skills-rebuild.sh"
else
    echo "skills directory already exists, keeping yours."
fi

# add source line to .bashrc if not already present
if ! grep -qF 'subtract/handler.sh' ~/.bashrc 2>/dev/null; then
    echo "" >> ~/.bashrc
    echo "# subtract OS" >> ~/.bashrc
    echo "$SOURCE_LINE" >> ~/.bashrc
fi

# install motd (requires sudo)
echo ""
read -r -p "set login message (requires sudo)? [y/n] " motd_yn
if [ "$motd_yn" = "y" ]; then
    sudo cp "$SUBTRACT_DIR/motd" /etc/motd
fi

echo "installed to $SUBTRACT_DIR"
echo "open a new terminal or run: source ~/.bashrc"

# optional: ollama for tier 2
if ! command -v ollama &>/dev/null; then
    echo ""
    read -r -p "install ollama for model-backed translation? [y/n] " yn
    if [ "$yn" = "y" ]; then
        # jq needed for JSON handling in T2 path
        if ! command -v jq &>/dev/null; then
            echo "installing jq..."
            sudo apt-get install -y jq 2>/dev/null || sudo yum install -y jq 2>/dev/null || echo "please install jq manually."
        fi
        curl -fsSL https://ollama.com/install.sh | sh
        echo "pulling qwen2.5:7b (4.7GB)..."
        ollama pull qwen2.5:7b
        echo "qwen2.5:7b" > "$SUBTRACT_DIR/model"
        echo "tier 4 ready."
    fi
fi
