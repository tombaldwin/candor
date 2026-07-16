# bash completion for the candor umbrella dispatcher.
# Install: source this file from ~/.bashrc, or drop it in a bash-completion.d directory
# (Homebrew installs it to $(brew --prefix)/etc/bash_completion.d/).

_candor() {
  local cur prev actions effects engines
  COMPREPLY=()
  cur="${COMP_WORDS[COMP_CWORD]}"
  prev="${COMP_WORDS[COMP_CWORD-1]}"
  actions="init hook scan effects doctor engines update outdated config mcp lsp where path callers tour blindspots gains fix fix-gate show map containment diff reachable impact whatif unverified rewire parsepolicy agents"
  effects="Net Fs Db Llm Exec Env Clock Ipc Log Rand Clipboard Unknown"
  engines="jvm rust ts swift"

  # flags anywhere
  case "$cur" in
    --*) COMPREPLY=( $(compgen -W "--report --policy --json --gate-json --help --version" -- "$cur") ); return 0;;
  esac
  case "$prev" in
    --report|--policy|--gate-json) COMPREPLY=( $(compgen -f -- "$cur") ); return 0;;
  esac

  if [ "$COMP_CWORD" -eq 1 ]; then
    COMPREPLY=( $(compgen -W "$actions" -- "$cur") ); return 0
  fi

  case "${COMP_WORDS[1]}" in
    init|scan)               COMPREPLY=( $(compgen -d -- "$cur") );;
    hook)                    if [ "$COMP_CWORD" -eq 2 ]; then COMPREPLY=( $(compgen -W "install uninstall" -- "$cur") ); else COMPREPLY=( $(compgen -d -- "$cur") ); fi;;
    mcp)                     if [ "$COMP_CWORD" -eq 2 ]; then COMPREPLY=( $(compgen -W "install" -- "$cur") ); else COMPREPLY=( $(compgen -d -- "$cur") ); fi;;
    update|install|upgrade)  COMPREPLY=( $(compgen -W "$engines" -- "$cur") );;
    config)                  COMPREPLY=( $(compgen -W "update-check" -- "$cur") );;
    where)                   COMPREPLY=( $(compgen -W "$effects" -- "$cur") );;
    path|fix)                # <fn> then <Effect>
      if [ "$COMP_CWORD" -eq 3 ]; then COMPREPLY=( $(compgen -W "$effects" -- "$cur") ); fi;;
    *)                       COMPREPLY=( $(compgen -f -- "$cur") );;
  esac
  return 0
}
complete -F _candor candor
