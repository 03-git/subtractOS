# subtractOS

An operating system that does what you mean.

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

Type, talk, convey your intent. A translation layer converts it to the right command. You see the command before it runs. Press enter to confirm, `n` to cancel.

There are two tiers:

- **T1 (lookup table):** Instant. Pattern-matches your input against `~/.subtract/lookup.tsv`. No model, no network, no dependencies. This is the product on constrained hardware.
- **T4 (generative model):** Optional. If [ollama](https://ollama.com) is installed with a pulled model, intents that miss T1 fall to a local language model that generates the command. Slower (300ms-1s) but handles anything.

T1 alone covers common operations. T4 handles the long tail. Both run locally. Nothing leaves your machine.

## Why

The translation layer is scaffolding. T4 shows you the command. T1 pattern-matches it. Eventually you type it yourself. The inference stops. That's the point -- a system that you stop needing and start using.

The telos is literacy, not dependency. You graduate from "show my files" to `ls`, from subtractOS to `claude -p` (or whatever the real prompt is). No wrapper. No subscription. No intermediary between you and the machine.

A lookup table is microseconds and nanowatts. Every layer of abstraction between a human and a syscall multiplies energy by orders of magnitude. subtractOS is the exit from that trajectory.

$$E_{\text{subtract}}(t) \to E_{\text{syscall}} \approx 10^{-5} \text{ J} \quad \text{as learned commands grow}$$

$$E_{\text{local}} = 10^{2} \text{ J/request} \quad \text{(flat, per inference)}$$

$$E_{\text{api}} \geq 10^{4} \text{ J/request} \quad \text{(flat or increasing with orchestration)}$$

The first equation decreases over time. The other two don't. subtractOS is the only architecture with a thermodynamic argument for its own obsolescence.

## Install

```
git clone https://github.com/03-git/subtractOS.git
cd subtract
./install.sh
```

Open a new terminal. Ask "what time is it".

## How it works

The entire system is two files in `~/.subtract/`:

- **handler.sh** -- bash functions that intercept unknown commands and translate them. Sourced in `.bashrc`.
- **lookup.tsv** -- tab-separated intent patterns and commands. Glob syntax. First match wins. Edit this file to teach your machine new intents.

When you convey something that isn't a real command, bash calls `command_not_found_handle`, which is overridden by the handler. The handler tries T1 (lookup), then T4 (model), then tells you it doesn't know.

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
