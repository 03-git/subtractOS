# subtract OS

A Linux shell where you type what you mean.

```
$ what time is it
[T1] date +%T
14:32:07

$ how much disk space
[T1] df -h
Filesystem      Size  Used Avail Use% Mounted on
/dev/sda1       477G  8.2G  445G   2% /
```

## What it does

You type natural language at a bash prompt. A translation layer converts your intent to the right command. You see the command before it runs. Press enter to confirm, `n` to cancel.

There are two tiers:

- **T1 (lookup table):** Instant. Pattern-matches your input against `~/.subtract/lookup.tsv`. No model, no network, no dependencies. This is the product on constrained hardware.
- **T4 (generative model):** Optional. If [ollama](https://ollama.com) is installed with a pulled model, intents that miss T1 fall to a local language model that generates the command. Slower (300ms-1s) but handles anything.

T1 alone covers common operations. T4 handles the long tail. Both run locally. Nothing leaves your machine.

## Install

```
git clone https://github.com/03-git/subtractOS.git
cd subtract
./install.sh
```

Open a new terminal. Type "what time is it".

## How it works

The entire system is two files in `~/.subtract/`:

- **handler.sh** -- bash functions that intercept unknown commands and translate them. Sourced in `.bashrc`.
- **lookup.tsv** -- tab-separated intent patterns and commands. Glob syntax. First match wins. Edit this file to teach your machine new intents.

When you type something that isn't a real command, bash calls `command_not_found_handle`, which is overridden by the handler. The handler tries T1 (lookup), then T4 (model), then tells you it doesn't know.

Destructive commands (`rm`, `dd`, `mkfs`, etc.) always require explicit `y` confirmation.

## Personalize

Edit `~/.subtract/lookup.tsv`. Add a line:

```
show*my*project	ls ~/code/myproject/
```

Now "show my project" works. The table is yours.

## Binary collisions

Some natural language verbs are also real binaries (`find`, `make`, `write`, `open`). By default, bash runs the binary. The handler ships with optional shadow shims (commented out in handler.sh) that intercept these. Uncomment them if you want "find my pdf files" to hit the handler instead of `/usr/bin/find`. To reach the real binary when shadows are active, use the full path.

## Escape hatch

Full paths always work. `/usr/bin/find`, `/usr/bin/make`, etc. The translation layer only intercepts unrecognized input. Real commands run normally.

## Uninstall

Remove the source line from `~/.bashrc` and delete `~/.subtract/`.

## License

GPL-3.0
