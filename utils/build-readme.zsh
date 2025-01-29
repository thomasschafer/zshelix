#!/usr/bin/env zsh

plugin_file="zshelix.plugin.zsh"
template_file="utils/README.md.template"
readme_file="README.md"
temp_file=$(mktemp)

function make_key_readable() {
    local key=$1
    local -A keymap=(
        # Basic special keys
        ['\e[A']='Up'      ['\e[B']='Down'
        ['\e[C']='Right'   ['\e[D']='Left'
        ['\e[1~']='Home'   ['\e[4~']='End'
        ['\e[3~']='Delete'
        ['\e[3;3~']='Alt-Delete'
        ['\e\e[3~']='Alt-Delete'  # Show double escape same as Alt
        # Control keys
        ['^M']='Enter'    ['^L']='Ctrl-l'
        ['^N']='Ctrl-n'   ['^P']='Ctrl-p'
        ['^R']='Ctrl-r'   ['^S']='Ctrl-s'
        ['^?']='Backspace'
        # Alt combinations
        ['\eb']='Alt-b'   ['\ef']='Alt-f'
        ['\ed']='Alt-d'   ['\eB']='Alt-B'
        ['\eF']='Alt-F'   ['\e;']='Alt-;'
        # Compound specials
        ['\e\177']='Alt-Backspace'
        ['\e^?']='Alt-Backspace'
        # Simple escape
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

    grep "$pattern" "$plugin_file" | while read -r line; do
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
} > $temp_file

perl -e '
    local $/;
    open(TEMPLATE, "<", "'$template_file'") or die "Cannot open template: $!";
    open(CONTENT, "<", "'$temp_file'") or die "Cannot open content: $!";
    open(OUTPUT, ">", "'$readme_file'") or die "Cannot open output: $!";
    $template = <TEMPLATE>;
    $content = <CONTENT>;
    $template =~ s/<!-- KEYBINDINGS -->/$content/g;
    print OUTPUT $template;
'

rm $temp_file
