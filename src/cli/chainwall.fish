# Generated integration: command metadata and Registry suggestions come from
# the installed binary, so this file stays valid across CLI upgrades.
function __chainwall_complete
    set -l words (commandline -opc)
    set -l current (commandline -ct)
    set -l suggestions (command chainwall __complete -- $words[2..] "$current" 2>/dev/null)
    for suggestion in $suggestions
        set -l fields (string split \t -- "$suggestion")
        switch $fields[1]
            case __chainwall_files__
                for candidate in (__fish_complete_path "$fields[3]")
                    printf '%s%s\n' "$fields[2]" "$candidate"
                end
            case __chainwall_directories__
                for candidate in (__fish_complete_directories "$fields[3]")
                    printf '%s%s\n' "$fields[2]" "$candidate"
                end
            case '*'
                printf '%s\n' "$suggestion"
        end
    end
end

complete -c chainwall -f -a '(__chainwall_complete)'
