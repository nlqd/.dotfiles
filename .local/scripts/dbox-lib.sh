#!/usr/bin/bash
# Shared core for the dbox sandbox family (dclaude, dclaude-jen, dshell).
# Sourced, not executed. Functions append to the global ARGS array in the
# order called; each wrapper orchestrates that order so the script reads
# top-to-bottom in the same order bwrap applies the mounts.

BWRAP=$(command -v bwrap)            # 0.12+ at /usr/local/bin; falls back to apt
BLOCK_STUB="$HOME/.local/scripts/bwrap-block"

ARGS=()
dbox_add() { ARGS+=("$@"); }

# State root for this profile+project: persistent home + overlay layers live here.
# Caller sets DBOX_PROFILE first.
dbox_state() {
    local base; base=$(basename "$PWD")
    printf '%s/dbox/%s/%s' "${XDG_STATE_HOME:-$HOME/.local/state}" "$DBOX_PROFILE" "$base"
}

dbox_namespaces() {
    dbox_add \
        --tmpfs /tmp \
        --dev /dev \
        --proc /proc \
        --hostname bubblewrap --unshare-uts \
        --unshare-pid \
        --die-with-parent
    # /tmp is a private tmpfs, but bind the host tmux socket dir back: an agent in
    # one tmux window can then `tmux send-keys` to sibling windows on the same host
    # server (how claude drives the GPU shells). Only this dir is shared; the rest
    # of /tmp stays isolated. -try keeps it harmless when no tmux server is up.
    dbox_add --bind-try "/tmp/tmux-$(id -u)" "/tmp/tmux-$(id -u)"
}

# Read-only host system. -try on anything not guaranteed present so a missing
# path skips instead of aborting the whole sandbox.
dbox_system() {
    dbox_add \
        --ro-bind /bin /bin \
        --ro-bind /lib /lib \
        --ro-bind-try /lib32 /lib32 \
        --ro-bind /lib64 /lib64 \
        --ro-bind /usr/bin /usr/bin \
        --ro-bind /usr/lib /usr/lib \
        --ro-bind-try /usr/libexec /usr/libexec \
        --ro-bind-try /usr/include /usr/include \
        --ro-bind-try /var/lib/dpkg /var/lib/dpkg \
        --ro-bind /usr/local/lib /usr/local/lib \
        --ro-bind-try /etc/alternatives /etc/alternatives \
        --ro-bind-try /etc/resolv.conf /etc/resolv.conf \
        --ro-bind-try /etc/profile.d /etc/profile.d \
        --ro-bind-try /etc/bash_completion.d /etc/bash_completion.d \
        --ro-bind-try /etc/ssl/certs /etc/ssl/certs \
        --ro-bind-try /etc/ld.so.cache /etc/ld.so.cache \
        --ro-bind-try /etc/ld.so.conf /etc/ld.so.conf \
        --ro-bind-try /etc/ld.so.conf.d /etc/ld.so.conf.d \
        --ro-bind-try /etc/localtime /etc/localtime \
        --ro-bind-try /usr/share/terminfo /usr/share/terminfo \
        --ro-bind-try /usr/share/ca-certificates /usr/share/ca-certificates \
        --ro-bind-try /etc/nsswitch.conf /etc/nsswitch.conf \
        --ro-bind-try /etc/hosts /etc/hosts \
        --ro-bind-try /etc/ssl/openssl.cnf /etc/ssl/openssl.cnf \
        --ro-bind-try /usr/share/zoneinfo /usr/share/zoneinfo
}

# Block a set of binaries from the sandbox PATH.
#  - /usr/local/bin is replaced by a tmpfs holding only the non-blocked entries.
#  - Blocked binaries that also live in /usr/bin or /bin (so the wholesale
#    --ro-bind /usr/bin would re-expose them) get a /bwrap-bin stub that shadows
#    them, since /bwrap-bin is first on PATH. The stub set is computed from
#    `command -v`, so it stays in sync with what is actually reachable.
dbox_block() {
    local blocked=("$@") f name b skip args_file lbfd stubfd p
    declare -A is_blocked
    for b in "${blocked[@]}"; do is_blocked[$b]=1; done

    args_file=$(mktemp)
    for f in /usr/local/bin/*; do
        [ -e "$f" ] || continue
        name=$(basename "$f")
        [ -n "${is_blocked[$name]:-}" ] && continue
        printf '%s\0%s\0%s\0' '--ro-bind-try' "$f" "$f"
    done > "$args_file"
    exec {lbfd}<"$args_file"; rm "$args_file"

    dbox_add --tmpfs /usr/local/bin --args "$lbfd" --tmpfs /bwrap-bin

    for b in "${blocked[@]}"; do
        for p in /usr/bin/"$b" /bin/"$b"; do
            if [ -x "$p" ]; then
                exec {stubfd}<"$BLOCK_STUB"
                dbox_add --perms 0755 --ro-bind-data "$stubfd" /bwrap-bin/"$b"
                break
            fi
        done
    done

    dbox_add --setenv PATH "/bwrap-bin:$PATH"
}

# Persistent writable home: stray writes outside the explicit binds land here on
# the host instead of vanishing with the sandbox tmpfs. Inspect with `ls`.
# Must be appended BEFORE the dotfile ro-binds so those layer on top.
dbox_home() {
    local sbox; sbox="$(dbox_state)/home"
    mkdir -p "$sbox"
    dbox_add --bind "$sbox" "$HOME"
}

# Resolve symlinks under $PWD and ~/.claude whose targets live outside both, then
# bind each unique target so the link resolves inside. git_mode = ro|rw for the
# worktree common dir + gitconfig.
#
# Walking whole trees for symlinks is the launch bottleneck: a research repo holds
# tens of thousands of internal dataset links, and ~/.claude is ~15G (plugin npm
# trees, conversation logs). So we don't walk either deeply. The links worth
# binding are enumerated cheaply, no deep traversal:
#   - ~/.claude (depth <= 2): the central config links (CLAUDE.md, skills, ...) that
#     point into ~/dotfiles. Deeper venv pythons under plugins/ resolve via the
#     ~/.asdf and ~/.local toolchain binds, so we needn't hunt them here.
#   - $PWD tracked symlinks: read straight from the git index (mode 120000).
#   - $PWD shallow links (depth <= 2): catches hand-made top-level links git can't
#     see, e.g. a worktree's `.claude` -> the main worktree's central config.
# Deep *gitignored* links (dataset/build trees) are skipped on purpose; their
# targets are internal or belong under --share. Non-git dirs fall back to a walk.
dbox_resolve_links() {
    local git_mode="${1:-ro}" bind="--ro-bind"
    [ "$git_mode" = rw ] && bind="--bind"
    declare -A seen

    if [ -f "$PWD/.git" ]; then
        local common; common=$(git rev-parse --git-common-dir 2>/dev/null)
        if [ -n "$common" ]; then
            common=$(realpath "$common")
            dbox_add "$bind" "$common" "$common"; seen[$common]=1
        fi
        dbox_add "$bind" "$HOME/.gitconfig" "$HOME/.gitconfig"
    fi

    local pwd_norm="${PWD%/}" claude_norm="${HOME%/}/.claude" target
    while IFS= read -r -d '' target; do
        [[ "$target" == "$pwd_norm"/* ]] && continue
        [[ "$target" == "$claude_norm"/* ]] && continue
        [ -z "${seen[$target]:-}" ] || continue
        dbox_add --ro-bind "$target" "$target"; seen[$target]=1
    done < <(
        {
            find "$claude_norm" -maxdepth 2 -type l -print0 2>/dev/null
            if git -C "$pwd_norm" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
                git -C "$pwd_norm" ls-files -s -z 2>/dev/null \
                    | gawk -v RS='\0' -v ORS='\0' -v p="$pwd_norm/" \
                        '$1 == "120000" { sub(/^[^\t]*\t/, ""); print p $0 }'
                find "$pwd_norm" -maxdepth 2 -type l -print0 2>/dev/null
            else
                find "$pwd_norm" -type l -print0 2>/dev/null
            fi
        } | xargs -0 realpath -ez 2>/dev/null)
}

# Always-on shared dropbox at /shared (a stable host dir, empty until used) plus
# any ad-hoc --share paths. A live rw bind: host writes appear instantly inside
# and vice versa, and the same dir bound into two sandboxes is a shared scratch
# for two agents. Treat its contents as untrusted on the host.
dbox_shared() {
    local shared abs s
    shared="${XDG_DATA_HOME:-$HOME/.local/share}/dbox/shared"
    mkdir -p "$shared"
    dbox_add --bind "$shared" /shared
    for s in "$@"; do
        abs=$(realpath "$s") || continue
        dbox_add --bind "$abs" "$abs"
    done
}

# The project tree. live: rw bind, edits hit the real repo (current behaviour).
# scratch: copy-on-write overlay; the agent edits freely but every write lands in
# an inspectable upper dir on the host while the real tree stays untouched.
# Always appended LAST so nothing overmounts it.
dbox_project() {
    local mode="${1:-live}"
    if [ "$mode" = scratch ]; then
        local up work
        up="$(dbox_state)/scratch/upper"
        work="$(dbox_state)/scratch/work"
        rm -rf "$work"; mkdir -p "$up" "$work"   # overlayfs needs a clean workdir each run
        dbox_add --overlay-src "$PWD" --overlay "$up" "$work" "$PWD"
        printf '[dbox] scratch mode: writes captured in %s\n' "$up" >&2
    else
        dbox_add --bind "$PWD" "$PWD"
    fi
}

# Wrap the sandbox in a transient user cgroup scope so an OOM or fork-bomb kills
# the sandbox tree, not the machine. cgroup v2 with delegated cpu/memory/pids
# means no root. DBOX_NOLIMIT=1 skips it.
dbox_exec() {
    if [ -z "${DBOX_NOLIMIT:-}" ] && command -v systemd-run >/dev/null; then
        exec systemd-run --user --scope --quiet \
            -p MemoryMax="${DBOX_MEM:-12G}" -p MemorySwapMax=0 \
            -p CPUQuota="${DBOX_CPU:-600%}" -p TasksMax="${DBOX_TASKS:-8192}" \
            -- "$BWRAP" "${ARGS[@]}" "$@"
    fi
    exec "$BWRAP" "${ARGS[@]}" "$@"
}

# Common leading-flag parser. Sets MODE and SHARES; leaves the rest in DBOX_REST.
DBOX_MODE=live
DBOX_SHARES=()
DBOX_REST=()
dbox_parse() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --scratch) DBOX_MODE=scratch; shift ;;
            --share)   DBOX_SHARES+=("$2"); shift 2 ;;
            --)        shift; break ;;
            *)         break ;;
        esac
    done
    DBOX_REST=("$@")
}
