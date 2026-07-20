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
    # The claude-bus mailbox: bind the host bus root into the box at the same path
    # so an agent in one box can message an agent in another (file mailbox; see the
    # claude-bus skill). Default matches claude-bus (~/.cache/claude-bus), which the
    # dev profile already binds rw via dbox_dotfiles; this bind is what carries a
    # $CLAUDE_BUS_ROOT that points elsewhere (e.g. a /tmp path) into the box too.
    # -try keeps it harmless until a host `claude-bus init` creates the dir; the
    # grant is strictly weaker than the tmux send-keys bind in dbox_tmux.
    local bus="${CLAUDE_BUS_ROOT:-${XDG_CACHE_HOME:-$HOME/.cache}/claude-bus}"
    dbox_add --bind-try "$bus" "$bus"
}

# Whitelist individual host /usr/local/bin tools into the box by binding just
# those binaries (resolved through any symlink). The default profile rebuilds
# /usr/local/bin via dbox_block and re-exposes every non-blocked entry, but
# jen/rem don't mount /usr/local/bin at all, so user-installed tools there go
# missing. Bind each named tool explicitly rather than mounting the whole dir, to
# keep the exposed surface an audited whitelist. Unknown names are skipped.
dbox_localbin() {
    local name bin
    for name in "$@"; do
        bin=$(command -v "$name" 2>/dev/null) || continue
        bin=$(realpath "$bin" 2>/dev/null) || continue
        dbox_add --ro-bind-try "$bin" "/usr/local/bin/$name"
    done
}

# Bind the host tmux socket dir back into the private /tmp so a tmux client inside
# the box talks to the host's tmux server. That shared server is what lets one
# session `tmux send-keys` to any other session or window, including ones living
# in a different box or on the host (how claude drives the GPU shells). Only this
# dir is shared; the rest of /tmp stays isolated. Call after dbox_namespaces,
# which tmpfs's /tmp. -try keeps it harmless when no tmux server is up. The tmux
# binary is whitelisted via dbox_localbin so jen/rem get the host's ghr build
# rather than the older apt /usr/bin/tmux (a version mismatch the server rejects).
dbox_tmux() {
    dbox_add --bind-try "/tmp/tmux-$(id -u)" "/tmp/tmux-$(id -u)"
    dbox_localbin tmux
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
        --ro-bind /usr/share/vim /usr/share/vim \
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
        --ro-bind-try /usr/share/zoneinfo /usr/share/zoneinfo \
        --ro-bind-try /etc/R /etc/R \
        --ro-bind-try /usr/share/R /usr/share/R
        # /usr/lib/R already comes in with the wholesale /usr/lib bind above.
}

# Block a set of binaries from the sandbox PATH.
#  - /usr/local/bin is replaced by a tmpfs holding only the non-blocked entries.
#  - Blocked binaries that also live in /usr/bin or /bin (so the wholesale
#    --ro-bind /usr/bin would re-expose them) get a /bwrap-bin stub that shadows
#    them, since /bwrap-bin is first on PATH. The stub set is computed from
#    `command -v`, so it stays in sync with what is actually reachable.
dbox_block() {
    [ $# -eq 0 ] && return 0          # nothing to block (e.g. the jen profile)
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

# ---- Profile building blocks -------------------------------------------------
# Composed by the wrappers after dbox_home. Each does one thing and appends in
# call order, same contract as the core functions above.

# Shared read-only dotfiles plus the writable cargo/cache trees. Layered on top
# of the persistent home, so append after dbox_home.
dbox_dotfiles() {
    dbox_add \
        --ro-bind "$HOME/.bashrc" "$HOME/.bashrc" \
        --ro-bind "$HOME/.profile" "$HOME/.profile" \
        --ro-bind "$HOME/.local" "$HOME/.local" \
        --ro-bind-try "$HOME/go/bin" "$HOME/go/bin" \
        --ro-bind-try "$HOME/Downloads" "$HOME/Downloads" \
        --ro-bind-try "$HOME/.asdf" "$HOME/.asdf" \
        --ro-bind-try "$HOME/.tool-versions" "$HOME/.tool-versions" \
        --ro-bind-try "$HOME/.config/eatracker" "$HOME/.config/eatracker" \
        --ro-bind-try "$HOME/.circleci" "$HOME/.circleci" \
        --bind "$HOME/.cargo" "$HOME/.cargo" \
        --bind "$HOME/.cache" "$HOME/.cache" \
        --bind-try "$HOME/.R" "$HOME/.R"
}

# Claude config and credentials. Sources default to the standard layout; pass
# alternates for a separate identity (the -rem profile's ~/.claude-rem). The
# destinations inside the box are always the standard paths, so claude finds
# them where it expects regardless of which host identity backs them.
#
# Three identity files are overlaid per profile: the token (.credentials.json)
# and two account-metadata copies, the top-level ~/.claude.json (the statusline
# reads this one's oauthAccount) and the nested ~/.claude/.claude.json. The
# nested one lives inside the shared rw ~/.claude, so without this overlay it
# carries whichever identity last wrote it and bleeds across profiles. Both
# metadata copies come from the same source; the token is never derived from it.
dbox_claude() {
    local json_src="${1:-$HOME/.claude.json}"
    local creds_src="${2:-$HOME/.claude/.credentials.json}"
    local jfd jfd2
    [ -r "$json_src" ]  || { echo "dbox: missing claude config $json_src" >&2; exit 1; }
    [ -r "$creds_src" ] || { echo "dbox: missing claude credentials $creds_src" >&2; exit 1; }
    exec {jfd}<"$json_src"
    exec {jfd2}<"$json_src"
    # The token (.credentials.json) is bound READ-ONLY, NOT via --file. `--file` runs
    # creat(O_TRUNC) on the destination, and because ~/.claude is bound rw to the
    # host that truncated the real ~/.claude/.credentials.json to 0 bytes on every
    # launch (and for the -rem profile clobbered the dungngo creds with the rem
    # identity). A read-only bind never writes the host file, so an in-box claude can
    # neither empty nor clobber it. Safe because the tokens are long-lived (setup-
    # token, no in-box refresh needed); a refreshable /login token would EROFS on
    # expiry. The two account-metadata copies (see the header note) stay as --file:
    # they are not secrets, and the nested ~/.claude/.claude.json must be writable
    # for the statusline.
    dbox_add \
        --bind "$HOME/.claude" "$HOME/.claude" \
        --ro-bind "$creds_src" "$HOME/.claude/.credentials.json" \
        --file "$jfd" "$HOME/.claude.json" \
        --file "$jfd2" "$HOME/.claude/.claude.json"

    # Pin the account across idle. Billing follows the bearer token server-side, so
    # for a long-lived setup-token (expiresAt 0, no refresh) we export it as
    # CLAUDE_CODE_OAUTH_TOKEN. That holds the account even when claude re-hydrates
    # oauthAccount to the default on idle -- and unlike CLAUDE_CONFIG_DIR it keeps
    # the single shared ~/.claude/projects. bwrap inherits the launcher env (no
    # --clearenv), so export keeps the token out of argv (no ps / proc-cmdline leak,
    # unlike --setenv). A refreshable token can't be pinned statically, so there we
    # UNSET the var: the box falls back to the bound creds file, and a stray value
    # from the launcher env can never leak in and mis-bill. No jq -> treat as unknown.
    local ctok="" cexp="" cref=""
    if command -v jq >/dev/null 2>&1; then
        ctok=$(jq -r '.claudeAiOauth.accessToken  // empty' "$creds_src" 2>/dev/null)
        cexp=$(jq -r '.claudeAiOauth.expiresAt    // 0'     "$creds_src" 2>/dev/null)
        cref=$(jq -r '.claudeAiOauth.refreshToken // ""'    "$creds_src" 2>/dev/null)
    fi
    if [ -n "$ctok" ] && [ "$cexp" = 0 ] && [ -z "$cref" ]; then
        export CLAUDE_CODE_OAUTH_TOKEN="$ctok"
    else
        unset CLAUDE_CODE_OAUTH_TOKEN
    fi
}

# Host git identity for pushing as the user: gitconfig, a gh credential helper,
# and a GH_TOKEN. A PAT at ~/.config/dclaude-jen/gh-token wins when present,
# else gh's own token. The github.com insteadOf rewrite lets git@ remotes push
# over https. Pair with `dbox_resolve_links rw` so the gitconfig/common-dir
# binds are writable.
dbox_feat_git_push() {
    local token gh_cfg
    gh_cfg=(--ro-bind-try "$HOME/.config/gh" "$HOME/.config/gh")
    if [ -r "$HOME/.config/dclaude-jen/gh-token" ]; then
        token=$(cat "$HOME/.config/dclaude-jen/gh-token"); gh_cfg=()
    else
        token=$(gh auth token)
    fi
    dbox_add \
        --ro-bind-try "$HOME/.gitconfig" "$HOME/.gitconfig" \
        "${gh_cfg[@]}" \
        --setenv GH_TOKEN "$token" \
        --setenv GIT_CONFIG_COUNT 2 \
        --setenv GIT_CONFIG_KEY_0 "credential.https://github.com.helper" \
        --setenv GIT_CONFIG_VALUE_0 "!gh auth git-credential" \
        --setenv GIT_CONFIG_KEY_1 "url.https://github.com/.insteadOf" \
        --setenv GIT_CONFIG_VALUE_1 "git@github.com:"
}

# Rootless podman socket, presented as the docker/podman host.
dbox_feat_podman() {
    local sock="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/podman/podman.sock"
    dbox_add \
        --setenv DOCKER_HOST "unix://$sock" \
        --setenv CONTAINER_HOST "unix://$sock" \
        --bind-try "$sock" "$sock"
}

# Bind the parent of $PWD too, for sibling worktrees or a shared package root.
dbox_feat_bind_parent() {
    dbox_add --bind "$PWD/.." "$PWD/.."
}

# Resolve symlinks under $PWD, ~/.claude and ~/.local whose targets live outside,
# then bind each unique target so the link resolves inside. git_mode = ro|rw for
# the worktree common dir + gitconfig.
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
#   - ~/.local (depth 1): top-level dir-symlinks like `scripts` -> ~/dotfiles, so
#     the user's helper scripts (e.g. `ea`) resolve and run inside the box. The
#     wrappers ro-bind ~/.local whole, which carries that symlink in but not its
#     target; binding the target here is what makes it non-dangling.
# Deep *gitignored* links (dataset/build trees) are skipped on purpose; their
# targets are internal or belong under --share. Non-git dirs fall back to a walk.
dbox_resolve_links() {
    local git_mode="${1:-ro}" bind="--ro-bind"
    [ "$git_mode" = rw ] && bind="--bind"
    declare -A seen

    # ~/.gitconfig carries git identity AND filter configs like git-lfs
    # (filter.lfs.*). Bind it read-only for ANY git work tree -- not just worktrees
    # -- so the LFS smudge/clean filters are configured (otherwise checkouts leave
    # pointer files) and the box never rewrites the user's global config.
    if git -C "$PWD" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        dbox_add --ro-bind-try "$HOME/.gitconfig" "$HOME/.gitconfig"
    fi
    # Worktree (.git is a file): its common dir lives outside $PWD, so bind it too,
    # honouring git_mode so jen/rem can commit/push.
    if [ -f "$PWD/.git" ]; then
        local common; common=$(git rev-parse --git-common-dir 2>/dev/null)
        if [ -n "$common" ]; then
            common=$(realpath "$common")
            dbox_add "$bind" "$common" "$common"; seen[$common]=1
        fi
    fi

    local pwd_norm="${PWD%/}" claude_norm="${HOME%/}/.claude" local_norm="${HOME%/}/.local" target
    while IFS= read -r -d '' target; do
        [[ "$target" == "$pwd_norm"/* ]] && continue
        [[ "$target" == "$claude_norm"/* ]] && continue
        [[ "$target" == "$local_norm"/* ]] && continue
        [ -z "${seen[$target]:-}" ] || continue
        dbox_add --ro-bind "$target" "$target"; seen[$target]=1
    done < <(
        {
            find "$claude_norm" -maxdepth 2 -type l -print0 2>/dev/null
            find "$local_norm" -maxdepth 1 -type l -print0 2>/dev/null
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
# True inside a dbox sandbox (it sets its UTS hostname to "bubblewrap"). A sandbox
# can't enter a host coat (its pid ns is unshared, the pod runs on the host), so
# coat-launch is skipped there. Factored out so should_enter_coat is unit-testable.
_dbox_in_sandbox() {
    [ "$(cat /proc/sys/kernel/hostname 2>/dev/null)" = bubblewrap ]
}

# Decide whether this launch should enter the worktree's coat. On yes: echo the
# coat name on stdout and return 0. On no: return non-zero. Precedence:
#   - inside a sandbox, or --no-coat / DBOX_NO_COAT   -> never
#   - --coat / DBOX_COAT_FORCE                        -> yes (create+enter) if local
#   - else auto: only when DBOX_COAT=auto (default) AND a coat already exists
# Depends only on _dbox_in_sandbox / workit / podman, so tests can inject stubs.
should_enter_coat() {
    _dbox_in_sandbox && return 1
    [ -z "${DBOX_NO_COAT:-}" ] || return 1
    command -v workit >/dev/null 2>&1 && command -v podman >/dev/null 2>&1 || return 1
    local cn
    cn=$(workit name 2>/dev/null) || return 1
    local existed=0
    if podman pod exists "$cn" 2>/dev/null; then existed=1; fi
    if [ "${DBOX_COAT_FORCE:-}" != 1 ]; then
        # Not forced: honour the mode, and only auto-enter a coat that already
        # exists. Opt-out is `off` (plus common falsey synonyms); default is auto;
        # anything else warns and is treated as auto, rather than silently doing
        # the opposite of a mistyped opt-out (e.g. DBOX_COAT=disabled).
        case "${DBOX_COAT:-auto}" in
            off | false | no | none | 0 | disabled) return 1 ;;
            auto | on | true | yes | 1) ;;
            *) printf 'dbox: unrecognized DBOX_COAT=%s; using auto\n' "${DBOX_COAT}" >&2 ;;
        esac
        [ "$existed" = 1 ] || return 1
    fi
    # ensure it's up (creates it under --coat; just starts an existing one)
    workit up >/dev/null 2>&1 || {
        printf 'dbox: could not start coat %s; launching without it\n' "$cn" >&2
        return 1
    }
    # the infra pid must live in THIS pid ns for `workit run` to nsenter it
    local pid
    pid=$(workit pid 2>/dev/null) || return 1
    [ -n "$pid" ] && [ -e "/proc/$pid" ] || return 1
    # name a coat that --coat just provisioned, so an accidental --coat in the
    # wrong directory is visible rather than a pod created out of nowhere
    if [ "$existed" = 0 ]; then
        printf 'dbox: created coat %s (--coat)\n' "$cn" >&2
    fi
    printf '%s\n' "$cn"
}

dbox_exec() {
    # If this launch should enter the worktree's coat, wrap the bwrap exec in
    # `workit run` so the sandbox starts inside the coat's netns (bwrap does not
    # --unshare-net, so it inherits it), and give it what it needs there: IS_SANDBOX
    # (nsenter --user makes it uid 0 in the coat's rootless userns, which claude
    # refuses --dangerously-skip-permissions under) and the coat's own resolv.conf
    # (the host's 127.0.0.53 stub is unreachable inside the coat, so DNS would die).
    # Forward the claude-bus identity the spawner set, so the in-box SessionStart hook
    # can self-register this session. Applies to coat AND plain dbox: the box's own
    # cgroup scope (systemd-run --scope; bwrap does not unshare the cgroup ns) is what
    # the monitor probes, so no host-side cgroup handling is needed. `[ -z ] ||` keeps
    # it errexit-safe when a var is unset.
    [ -z "${CLAUDE_BUS_NAME:-}" ]       || dbox_add --setenv CLAUDE_BUS_NAME "$CLAUDE_BUS_NAME"
    [ -z "${CLAUDE_BUS_SUPERVISOR:-}" ] || dbox_add --setenv CLAUDE_BUS_SUPERVISOR "$CLAUDE_BUS_SUPERVISOR"
    [ -z "${CLAUDE_BUS_ROLE:-}" ]       || dbox_add --setenv CLAUDE_BUS_ROLE "$CLAUDE_BUS_ROLE"

    local -a coat=()
    local cn
    if cn=$(should_enter_coat); then
        coat=(workit run --)
        dbox_add --setenv IS_SANDBOX 1
        # Bind the pod's OWN resolv.conf (podman writes the right nameserver for the
        # active backend — slirp's 10.0.2.3, pasta's, ... — plus host resolvers and
        # search domains), so a podman upgrade to pasta doesn't break coat DNS. Fall
        # back to slirp's forwarder (override DBOX_COAT_DNS). Appended last so it
        # overrides dbox_system's earlier /etc/resolv.conf bind.
        local infra_id rcpath rcfd rcfile
        infra_id=$(podman pod inspect "$cn" --format '{{.InfraContainerID}}' 2>/dev/null) || infra_id=""
        rcpath=$(podman container inspect "$infra_id" --format '{{.ResolvConfPath}}' 2>/dev/null) || rcpath=""
        # The opens are the LAST term of each if-condition on purpose: a bare
        # `exec {fd}<path` whose redirection fails aborts the whole launch under
        # `set -euo pipefail` (the wrappers run it), so the mktemp fallback would be
        # unreachable and a torn-down / unreadable ResolvConfPath would kill the
        # sandbox instead of just losing coat DNS. In a tested context set -e is
        # suspended, so a failed open falls through to the fallback (or to no bind).
        if [ -n "$rcpath" ] && [ -r "$rcpath" ] && [ -s "$rcpath" ] && exec {rcfd}<"$rcpath"; then
            dbox_add --ro-bind-data "$rcfd" /etc/resolv.conf
        elif rcfile=$(mktemp 2>/dev/null) &&
            printf 'nameserver %s\n' "${DBOX_COAT_DNS:-10.0.2.3}" >"$rcfile" &&
            exec {rcfd}<"$rcfile"; then
            rm -f "$rcfile"
            dbox_add --ro-bind-data "$rcfd" /etc/resolv.conf
        fi
        printf 'dbox: launching inside coat %s\n' "$cn" >&2
    fi
    if [ -z "${DBOX_NOLIMIT:-}" ] && command -v systemd-run >/dev/null; then
        exec systemd-run --user --scope --quiet \
            -p MemoryMax="${DBOX_MEM:-12G}" -p MemorySwapMax=0 \
            -p CPUQuota="${DBOX_CPU:-600%}" -p TasksMax="${DBOX_TASKS:-8192}" \
            -- ${coat[@]+"${coat[@]}"} "$BWRAP" "${ARGS[@]}" "$@"
    fi
    exec ${coat[@]+"${coat[@]}"} "$BWRAP" "${ARGS[@]}" "$@"
}

# Common leading-flag parser. Sets MODE and SHARES; leaves the rest in DBOX_REST.
DBOX_MODE=live
# Coat launch mode: "auto" (default) enters the worktree's coat automatically when
# one already exists; "off" (or a falsey synonym: false/no/none/0/disabled) needs
# an explicit --coat; an unrecognized value warns and is treated as auto. Per-launch
# flags --coat (force on) and --no-coat (force off) override the mode.
DBOX_COAT="${DBOX_COAT:-auto}"
DBOX_COAT_FORCE="${DBOX_COAT_FORCE:-}"
DBOX_NO_COAT="${DBOX_NO_COAT:-}"
DBOX_SHARES=()
DBOX_REST=()
dbox_parse() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --scratch) DBOX_MODE=scratch; shift ;;
            --coat)    DBOX_COAT_FORCE=1; shift ;;
            --no-coat) DBOX_NO_COAT=1; shift ;;
            --share)   DBOX_SHARES+=("$2"); shift 2 ;;
            --)        shift; break ;;
            *)         break ;;
        esac
    done
    DBOX_REST=("$@")
}
