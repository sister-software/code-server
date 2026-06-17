# ~/.zshrc for the `operator` user (iSH ARM64 guest).

# Debian-ish default PATH (login/su may set a minimal one; pin it here).
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# Each iPad terminal is a login shell. Spawned terminals (2nd+) are init children
# that don't inherit a cwd, so start them in $HOME. Guarded to login shells so
# nested/non-login subshells keep their directory.
[[ -o login ]] && cd "$HOME" 2>/dev/null

export EDITOR=vim
export PAGER=less
export LANG=${LANG:-C.UTF-8}

# History.
HISTFILE=~/.zsh_history
HISTSIZE=10000
SAVEHIST=10000
setopt SHARE_HISTORY HIST_IGNORE_DUPS HIST_IGNORE_SPACE INC_APPEND_HISTORY

# Completion. -C: trust the pre-baked, zcompiled ~/.zcompdump (built in the
# image) and skip the fpath rebuild + insecure-dir audit — both are very slow
# under the iSH interpreter. zsh auto-uses ~/.zcompdump.zwc and the functions.zwc
# digests (compiled in the image) so completion scripts aren't re-parsed.
autoload -Uz compinit && compinit -C -d ~/.zcompdump
# Cache completion results (apk/git/ssh-hosts/…) to disk so slow first lookups
# aren't repeated. The very first <Tab> in a session still pays a one-time cost
# to load the completion system + hash $PATH — that's interpreter overhead.
[[ -d ~/.cache/zsh ]] || mkdir -p ~/.cache/zsh
zstyle ':completion:*' use-cache on
zstyle ':completion:*' cache-path ~/.cache/zsh
zstyle ':completion:*' completer _complete
setopt AUTO_CD

# Prompt: user@ish:cwd$ (red on non-zero exit).
autoload -Uz colors && colors
setopt PROMPT_SUBST
PROMPT='%F{cyan}%n@ish%f:%F{blue}%~%f %(?.%F{green}.%F{red})%#%f '

# Aliases.
alias ll='ls -alF'
alias la='ls -A'
alias l='ls -CF'
alias grep='grep --color=auto'

# nvm on musl/arm64. nvm (≤0.40.x) only auto-rewrites the download arch x64 →
# x64-musl on Alpine — it never handles arm64, so on this Apple-silicon Alpine it
# fetches glibc arm64 builds that fail to load ("fcntl64: symbol not found").
# Point nvm at the unofficial *musl* builds and force the musl arch. Applied via a
# one-shot precmd hook so it runs AFTER the nvm installer's own block (appended
# below this file by `nvm install`'s setup); if nvm isn't present it stays armed
# until a shell where it is. Native musl node runs fine under the interpreter.
export NVM_NODEJS_ORG_MIRROR=https://unofficial-builds.nodejs.org/download/release
autoload -Uz add-zsh-hook
_ish_fix_nvm_arch() {
  if (( $+functions[nvm_echo] )); then
    nvm_get_arch() { nvm_echo "arm64-musl"; }
    add-zsh-hook -d precmd _ish_fix_nvm_arch
  fi
}
add-zsh-hook precmd _ish_fix_nvm_arch

# Container tooling (podman/crun) needs a writable XDG_RUNTIME_DIR. This guest
# has no elogind, so /run/user/<uid> is never created — point it under $HOME.
export XDG_RUNTIME_DIR="$HOME/.run"
[[ -d $XDG_RUNTIME_DIR ]] || { mkdir -p "$XDG_RUNTIME_DIR" && chmod 700 "$XDG_RUNTIME_DIR"; }
# iSH only has cgroups v1; silence podman's deprecation nag.
export PODMAN_IGNORE_CGROUPSV1_WARNING=1
