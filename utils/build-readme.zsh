#!/usr/bin/env zsh
# Generate README.md from utils/README.md.template, filling in the keybinding
# tables from the keymap definitions in lib/keymap.zsh.
emulate -L zsh
setopt err_exit extended_glob

cd "${0:A:h}/.."
readonly TEMPLATE=utils/README.md.template README=README.md

source lib/docs.zsh
source lib/keymap.zsh

typeset -ga bindings menus

# Record bindings instead of binding them.
function zhm_bind() { bindings+=( "$1"$'\t'"$2"$'\t'"$3" ) }
function zhm_menu() { menus+=( "$1"$'\t'"$2"$'\t'"$3"$'\t'"$4" ) }

_zhm_define_normal_keymap
_zhm_define_select_keymap
_zhm_define_insert_keymap

# Display name for a key in Helix notation, as in Helix's documentation.
function key_name() {
    local key=$1 mods=""
    while [[ $key == [ACS]-?* ]]; do
        case ${key[1]} in
            (A) mods+="Alt-" ;;
            (C) mods+="Ctrl-" ;;
            (S) mods+="Shift-" ;;
        esac
        key=${key[3,-1]}
    done
    case $key in
        (esc) key=Esc ;;
        (ret) key=Enter ;;
        (tab) key=Tab ;;
        (space) key=Space ;;
        (backspace) key=Backspace ;;
        (del) key=Delete ;;
        (left) key=Left ;;
        (right) key=Right ;;
        (up) key=Up ;;
        (down) key=Down ;;
        (home) key=Home ;;
        (end) key=End ;;
        (pageup) key=PageUp ;;
        (pagedown) key=PageDown ;;
        (minus) key=- ;;
        (lt) key='<' ;;
        (gt) key='>' ;;
        ('|') key='\|' ;;
    esac
    if [[ $key == *'`'* ]]; then
        # A code span containing a backtick needs double backticks.
        REPLY="\`\` $mods$key \`\`"
    else
        REPLY="\`$mods$key\`"
    fi
}

# Display a key with alternatives (e.g. `h|left`).
function key_display() {
    _zhm_split_alternatives "$1"
    local -a names
    local alt
    for alt in "${reply[@]}"; do
        key_name "$alt"
        names+=( "$REPLY" )
    done
    REPLY=${(j:, :)names}
}

function fields() {
    reply=( "${(@ps:\t:)1}" )
}

# Table of the bindings for mode $1 directly under menu prefix $2 (empty for
# top-level keys), including the menus themselves.
function table() {
    local mode=$1 prefix=$2 entry rest
    local -a f
    print "| Key | Description | Command |"
    print "| --- | --- | --- |"
    for entry in "${bindings[@]}" "${menus[@]}"; do
        fields "$entry"
        f=( "${reply[@]}" )
        [[ ${f[1]} == $mode ]] || continue
        if [[ -n $prefix ]]; then
            [[ ${f[2]} == "$prefix "* ]] || continue
            rest=${f[2]#$prefix }
        else
            rest=${f[2]}
        fi
        [[ $rest == *' '* ]] && continue
        key_display "$rest"
        if (( ${#f} == 3 )); then
            print -r -- "| $REPLY | ${_ZHM_DOCS[${f[3]}]:-${f[3]}} | \`${f[3]}\` |"
        else
            print -r -- "| $REPLY | ${f[3]} menu (see below) | |"
        fi
    done
}

function section() {
    local mode=$1 title=$2 intro=$3 entry keys name fallback part
    local -a shown
    print "### $title"
    print
    [[ -n $intro ]] && { print -r -- "$intro"; print }
    table $mode ""
    for entry in "${menus[@]}"; do
        fields "$entry"
        [[ ${reply[1]} == $mode ]] || continue
        keys=${reply[2]} name=${reply[3]} fallback=${reply[4]}
        shown=()
        for part in ${(s: :)keys}; do
            key_display "$part"
            shown+=( "$REPLY" )
        done
        print
        print "#### $name (${(j: then :)shown})"
        print
        if [[ -n $fallback ]]; then
            print -r -- "Any other character: ${(L)_ZHM_DOCS[$fallback]:0:1}${_ZHM_DOCS[$fallback]:1} (\`$fallback\`)."
            print
        fi
        table $mode "$keys"
    done
    print
}

content=$(
    section normal "Normal mode"
    section select "Select mode" "Select mode has all of the normal mode bindings, except for these, which extend the selection rather than replacing it."
    section insert "Insert mode" "Any other key is inserted as text, as in Helix (so unbound Ctrl and Alt keys insert their letter). Keys with a meaning in the shell, such as Tab for completion and Ctrl-r for history search, keep their shell behaviour."
)

template=$(<$TEMPLATE)
print -r -- "${template/<!-- KEYBINDINGS -->/${content%$'\n'}}" >| $README
