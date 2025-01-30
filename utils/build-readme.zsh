#!/usr/bin/env zsh
set -eo pipefail
set -e

readonly PLUGIN="zshelix.plugin.zsh"
readonly TEMPLATE="utils/README.md.template"
readonly README="README.md"

[[ -f $PLUGIN ]] || { echo "Error: $PLUGIN not found"; exit 1; }
[[ -f $TEMPLATE ]] || { echo "Error: $TEMPLATE not found"; exit 1; }

temp_file=$(mktemp) || { echo "Error: Failed to create temp file"; exit 1; }
trap "rm -f '$temp_file'" EXIT

function make_key_readable() {
    local key=$1
    local -A keymap=(
        ['\e[A']='Up'
        ['\e[B']='Down'
        ['\e[C']='Right'
        ['\e[D']='Left'
        ['\e[1~']='Home'
        ['\e[4~']='End'
        ['\e[3~']='Delete'
        ['\e[3;3~']='Alt-Delete'
        ['\e\e[3~']='Alt-Delete'
        ['^M']='Enter'
        ['^L']='Ctrl-l'
        ['^N']='Ctrl-n'
        ['^P']='Ctrl-p'
        ['^R']='Ctrl-r'
        ['^S']='Ctrl-s'
        ['^?']='Backspace'
        ['\eb']='Alt-b'
        ['\ef']='Alt-f'
        ['\ed']='Alt-d'
        ['\eB']='Alt-B'
        ['\eF']='Alt-F'
        ['\e;']='Alt-;'
        ['\e\177']='Alt-Backspace'
        ['\e^?']='Alt-Backspace'
        ['\e']='Esc'
    )

    [[ -n "${keymap[$key]}" ]] && echo "${keymap[$key]}" || echo "$key"
}

function print_mappings() {
    local mode=$1
    local pattern=$2
    typeset -A seen

    echo "| Key | Description | Function |"
    echo "|-----|-------------|----------|"

    grep "$pattern" "$PLUGIN" | while read -r line; do
        [[ $line =~ "#.*HIDDEN" ]] && continue
        
        if [[ $line =~ "$pattern'([^']+)' ([^ ]+)(.*)# DESC: (.*)" ]]; then
            key=$(make_key_readable "${match[1]}")
            func="${match[2]#zhm_}"
            desc="${match[4]}"
            entry="| \`$key\` | $desc | $func |"
        elif [[ $line =~ "$pattern'([^']+)' ([^ ]+)" ]]; then
            key=$(make_key_readable "${match[1]}")
            func="${match[2]#zhm_}"
            entry="| \`$key\` | | $func |"
        else
            continue
        fi

        combo="${key}${func}"
        [[ -z ${seen[$combo]} ]] && echo $entry
        seen[$combo]=1
    done
}

# Generate keybindings documentation
{
    echo "### Normal Mode"
    echo
    print_mappings "normal" "bindkey -M helix-normal-mode "
    echo
    echo "### Insert Mode"
    echo
    print_mappings "insert" "bindkey -M viins "
} > "$temp_file" || { echo "Error: Failed to write to temp file"; exit 1; }

perl -e '
    local $/;
    open(TEMPLATE, "<", "'"$TEMPLATE"'") or die "Cannot open template: $!";
    open(CONTENT, "<", "'"$temp_file"'") or die "Cannot open content: $!";
    open(OUTPUT, ">", "'"$README"'") or die "Cannot open output: $!";
    $template = <TEMPLATE>;
    $content = <CONTENT>;
    $template =~ s/<!-- KEYBINDINGS -->/$content/g;
    print OUTPUT $template;
' || { echo "Error: Failed to generate $README"; exit 1; }
