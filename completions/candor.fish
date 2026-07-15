# fish completion for the candor umbrella dispatcher.
# Install: copy (or symlink) into ~/.config/fish/completions/candor.fish
# (Homebrew installs it to $(brew --prefix)/share/fish/vendor_completions.d/).

set -l actions init scan doctor engines update outdated config where path callers tour blindspots gains fix fix-gate show map containment diff reachable impact whatif unverified rewire parsepolicy agents
set -l effects Net Fs Db Llm Exec Env Clock Ipc Log Rand Clipboard Unknown

complete -c candor -f

complete -c candor -n "not __fish_seen_subcommand_from $actions" -a init      -d 'stand up the gate (every language present)'
complete -c candor -n "not __fish_seen_subcommand_from $actions" -a scan      -d 'analyse a project (engine picked by its manifest)'
complete -c candor -n "not __fish_seen_subcommand_from $actions" -a doctor    -d 'check every engine is installed and compatible'
complete -c candor -n "not __fish_seen_subcommand_from $actions" -a engines   -d 'list the engines, their source and status'
complete -c candor -n "not __fish_seen_subcommand_from $actions" -a update    -d 'fetch / refresh the engines'
complete -c candor -n "not __fish_seen_subcommand_from $actions" -a outdated  -d 'check release channels for newer versions'
complete -c candor -n "not __fish_seen_subcommand_from $actions" -a config    -d 'view or set settings'
complete -c candor -n "not __fish_seen_subcommand_from $actions" -a where     -d 'the functions that perform an effect'
complete -c candor -n "not __fish_seen_subcommand_from $actions" -a path      -d 'the call path by which a function reaches an effect'
complete -c candor -n "not __fish_seen_subcommand_from $actions" -a callers   -d 'who calls a function, direct and transitive'
complete -c candor -n "not __fish_seen_subcommand_from $actions" -a tour      -d 'the most surprising transitive reaches'
complete -c candor -n "not __fish_seen_subcommand_from $actions" -a blindspots -d 'the Unknown sources worth resolving'
complete -c candor -n "not __fish_seen_subcommand_from $actions" -a gains     -d 'what a new version newly reaches'
complete -c candor -n "not __fish_seen_subcommand_from $actions" -a fix       -d 'the boundary hoist that would clear a violation'
complete -c candor -n "not __fish_seen_subcommand_from $actions" -a fix-gate  -d 'every policy crossing and its remedy'
complete -c candor -n "not __fish_seen_subcommand_from $actions" -a "show map containment diff reachable impact whatif unverified rewire parsepolicy agents"

complete -c candor -n "__fish_seen_subcommand_from update install upgrade" -a "jvm rust ts swift"
complete -c candor -n "__fish_seen_subcommand_from config" -a "update-check"
complete -c candor -n "__fish_seen_subcommand_from where" -a "$effects"
complete -c candor -n "__fish_seen_subcommand_from init scan" -a "(__fish_complete_directories)"
complete -c candor -l report -d 'use this report instead of discovering .candor/' -r
complete -c candor -l policy -d 'evaluate a policy file' -r
complete -c candor -l json -d 'machine-readable output'
complete -c candor -s h -l help -d 'show help'
complete -c candor -s V -l version -d 'version details for every installed engine'
