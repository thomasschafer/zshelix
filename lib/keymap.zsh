# Keymaps. Bindings are written in Helix's key notation and mirror
# `helix_term::keymap::default`, minus the commands that have no meaning on a
# command line (files, buffers, windows, language servers, tree-sitter and the
# debugger).

# Bindings: "<mode>\x1e<raw key path>" -> "cmd:<command>" or "menu:<title>".
# Raw key paths are the raw key sequences joined with \x1f.
typeset -gA _zhm_km
# Fallback commands for menus that accept any character (e.g. `mi(`).
typeset -gA _zhm_km_fallback
# Entries shown in a menu's info popup: "<mode>\x1e<raw path>" -> lines.
typeset -gA _zhm_km_info
# Top-level keys bound in each zle keymap, to avoid duplicates.
typeset -gA _zhm_km_top

typeset -g _ZHM_NL=$'\n'
# Set once the default keymaps exist (select mode is then a separate keymap).
typeset -gi _zhm_keymaps_ready=0
typeset -g _ZHM_SEP=$'\x1f' _ZHM_MSEP=$'\x1e'

# Raw key sequences (there may be several) for a key in Helix notation.
function _zhm_key_raw() {
    local name=$1
    reply=()
    case $name in
        (esc) reply=( $'\e' ) ;;
        (ret) reply=( $'\r' ) ;;
        (tab) reply=( $'\t' ) ;;
        (S-tab) reply=( $'\e[Z' ) ;;
        (space) reply=( ' ' ) ;;
        (minus) reply=( - ) ;;
        (lt) reply=( '<' ) ;;
        (gt) reply=( '>' ) ;;
        (backspace|S-backspace) reply=( $'\x7f' ) ;;
        (del) reply=( $'\e[3~' ) ;;
        (left) reply=( $'\e[D' $'\eOD' ) ;;
        (right) reply=( $'\e[C' $'\eOC' ) ;;
        (up) reply=( $'\e[A' $'\eOA' ) ;;
        (down) reply=( $'\e[B' $'\eOB' ) ;;
        (home) reply=( $'\e[H' $'\eOH' $'\e[1~' $'\e[7~' ) ;;
        (end) reply=( $'\e[F' $'\eOF' $'\e[4~' $'\e[8~' ) ;;
        (pageup) reply=( $'\e[5~' ) ;;
        (pagedown) reply=( $'\e[6~' ) ;;
        (A-backspace) reply=( $'\e\x7f' $'\e\b' ) ;;
        (A-del) reply=( $'\e[3;3~' $'\e\e[3~' ) ;;
        (A-up) reply=( $'\e[1;3A' $'\e\e[A' ) ;;
        (A-down) reply=( $'\e[1;3B' $'\e\e[B' ) ;;
        (A-left) reply=( $'\e[1;3D' $'\e\e[D' ) ;;
        (A-right) reply=( $'\e[1;3C' $'\e\e[C' ) ;;
        (A-minus) reply=( $'\e-' ) ;;
        (A-?*) reply=( $'\e'${name#A-} ) ;;
        (C-space) reply=( $'\0' ) ;;
        (C-?)
            local ch=${(L)name#C-}
            reply=( ${(#)$(( #ch & 0x1f ))} )
            ;;
        (?) reply=( "$name" ) ;;
        (*) _zhm_bug "unknown key '$name'"; return 1 ;;
    esac
}

# Escape a raw key sequence for bindkey, which interprets `\` and `^`.
function _zhm_bindkey_escape() {
    local raw=$1
    raw=${raw//\\/\\\\}
    REPLY=${raw//\^/\\^}
}

function _zhm_keymap_name() {
    case $1 in
        (normal) REPLY=zhm-normal ;;
        (select) REPLY=zhm-select ;;
        (insert) REPLY=viins ;;
    esac
}

# Split key alternatives separated by `|` into $reply. A `|` at the start of
# an alternative or after a modifier (as in `A-|`) is the pipe key itself.
function _zhm_split_alternatives() {
    local spec=$1 alt="" c
    reply=()
    for c in "${(@s::)spec}"; do
        if [[ $c == '|' && -n $alt && $alt != *- ]]; then
            reply+=( "$alt" )
            alt=""
        else
            alt+=$c
        fi
    done
    [[ -n $alt ]] && reply+=( "$alt" )
}

# Expand a space-separated key path where each key may list alternatives
# separated by `|` into all raw paths, in $reply.
function _zhm_expand_path() {
    local -a paths=( "" ) next alts
    local key alt p r
    for key in ${(s: :)1}; do
        next=()
        _zhm_split_alternatives "$key"
        alts=( "${reply[@]}" )
        for alt in "${alts[@]}"; do
            _zhm_key_raw "$alt" || return 1
            for r in "${reply[@]}"; do
                for p in "${paths[@]}"; do
                    if [[ -z $p ]]; then
                        next+=( "$r" )
                    else
                        next+=( "$p$_ZHM_SEP$r" )
                    fi
                done
            done
        done
        paths=( "${next[@]}" )
    done
    reply=( "${paths[@]}" )
}

# Bind key path $2 (Helix notation) in mode $1 to command $3. Keys before the
# last one are menus; they're created if they don't exist yet. Normal mode
# bindings also apply in select mode unless select mode overrides them.
function zhm_bind() {
    local mode=$1 keys=$2 cmd=$3
    if (( ! ${+functions[_zhm_cmd_$cmd]} )); then
        _zhm_bug "zhm_bind: unknown command '$cmd'"
        return 1
    fi
    _zhm_ensure_menus $mode "$keys" || return 1
    _zhm_expand_path "$keys" || return 1
    local p
    for p in "${reply[@]}"; do
        _zhm_km[$mode$_ZHM_MSEP$p]="cmd:$cmd"
        _zhm_bind_top $mode "$p" zhm_$cmd
        if [[ $mode == normal ]] && (( _zhm_keymaps_ready )) && (( ! ${+_zhm_km[select$_ZHM_MSEP$p]} )); then
            _zhm_bind_top select "$p" zhm_$cmd
        fi
    done
    _zhm_add_info $mode "$keys" "${_ZHM_DOCS[$cmd]:-$cmd}"
}

# Remove the binding for key path $2 in mode $1.
function zhm_unbind() {
    local mode=$1 keys=$2
    _zhm_expand_path "$keys" || return 1
    local p keymap
    _zhm_keymap_name $mode; keymap=$REPLY
    for p in "${reply[@]}"; do
        unset "_zhm_km[$mode$_ZHM_MSEP$p]"
        [[ $p == *$_ZHM_SEP* ]] && continue
        _zhm_bindkey_escape "$p"
        if [[ $mode == insert ]]; then
            bindkey -M viins -r -- "$REPLY"
        else
            bindkey -M $keymap -- "$REPLY" zhm_noop
            if [[ $mode == normal ]] && (( ! ${+_zhm_km[select$_ZHM_MSEP$p]} )); then
                bindkey -M zhm-select -- "$REPLY" zhm_noop
            fi
        fi
    done
    _zhm_add_info $mode "$keys" ""
}

# Create menus for the keys before the last one in path $2, if needed.
function _zhm_ensure_menus() {
    local mode=$1
    local -a parts
    parts=( ${(s: :)2} )
    local -i i
    local prefix p
    for (( i = 1; i < ${#parts}; i++ )); do
        prefix=${(j: :)parts[1,i]}
        _zhm_expand_path "$prefix" || return 1
        for p in "${reply[@]}"; do
            if [[ ${_zhm_km[$mode$_ZHM_MSEP$p]} != menu:* ]] && \
                ! { [[ $mode == select ]] && [[ ${_zhm_km[normal$_ZHM_MSEP$p]} == menu:* ]] }; then
                zhm_menu $mode "$prefix" "$prefix"
                break
            fi
        done
    done
}

# Declare key path $2 in mode $1 as a menu titled $3, optionally with a
# fallback command $4 that receives any other character.
function zhm_menu() {
    local mode=$1 keys=$2 title=$3 fallback=$4
    _zhm_expand_path "$keys" || return 1
    local p
    for p in "${reply[@]}"; do
        _zhm_km[$mode$_ZHM_MSEP$p]="menu:$title"
        [[ -n $fallback ]] && _zhm_km_fallback[$mode$_ZHM_MSEP$p]=$fallback
        _zhm_bind_top $mode "$p" zhm-menu
    done
    _zhm_add_info $mode "$keys" "$title"
}

function _zhm_add_info() {
    local mode=$1 keys=$2 desc=$3
    local -a parts
    parts=( ${(s: :)keys} )
    (( ${#parts} > 1 )) || return 0
    local last=${parts[-1]}
    local parent=${(j: :)parts[1,-2]}
    _zhm_split_alternatives "$last"
    local display=${(j:, :)reply}
    _zhm_expand_path "$parent" || return 1
    local p entry=${(r:10:)display}
    for p in "${reply[@]}"; do
        local k=$mode$_ZHM_MSEP$p
        # Replace any existing entry for the same key; an empty description
        # removes it.
        local -a lines
        lines=( "${(@f)${_zhm_km_info[$k]%$'\n'}}" )
        lines=( "${(@)lines:#${(b)entry} *}" )
        lines=( ${lines:#} )
        [[ -n $desc ]] && lines+=( "$entry $desc" )
        if (( ${#lines} )); then
            _zhm_km_info[$k]=${(pj:\n:)lines}$'\n'
        else
            unset "_zhm_km_info[$k]"
        fi
    done
}

# Bind the first key of raw path $2 in the zle keymap for mode $1.
function _zhm_bind_top() {
    local mode=$1 p=$2 widget=$3
    local first=${p%%$_ZHM_SEP*}
    local keymap
    _zhm_keymap_name $mode; keymap=$REPLY
    # Keys with further keys are menus at the top level.
    [[ $p == *$_ZHM_SEP* ]] && widget=zhm-menu
    _zhm_bindkey_escape "$first"
    bindkey -M $keymap -- "$REPLY" $widget
    if [[ $first == $'\e' ]]; then
        _zhm_bindkey_escape "$_ZHM_KEY_ESC"
        bindkey -M $keymap -- "$REPLY" $widget
    fi
}

# Look up raw path $2 for mode $1, falling back to normal mode bindings in
# select mode as Helix does.
function _zhm_lookup() {
    local mode=$1 p=$2
    REPLY=${_zhm_km[$mode$_ZHM_MSEP$p]}
    if [[ -z $REPLY && $mode == select ]]; then
        REPLY=${_zhm_km[normal$_ZHM_MSEP$p]}
        [[ -n $REPLY ]] && REPLY2=normal
    else
        REPLY2=$mode
    fi
    [[ -n $REPLY ]]
}

function _zhm_menu_info_lines() {
    local mode=$1 p=$2
    local text=${_zhm_km_info[$mode$_ZHM_MSEP$p]}
    if [[ $mode == select ]]; then
        # Merge in the normal mode entries that select mode doesn't override.
        local line
        for line in "${(@f)${_zhm_km_info[normal$_ZHM_MSEP$p]}}"; do
            [[ -n $line ]] || continue
            local key=${line%% *}
            [[ $'\n'$text == *$'\n'"$key "* ]] && continue
            text+=$line$'\n'
        done
    fi
    reply=( "${(@f)${text%$'\n'}}" )
}

# Widget for menu prefixes (g, m, space, ...): shows the menu and reads keys
# until a command is reached.
function _zhm_menu_widget() {
    emulate -L zsh
    setopt extended_glob typeset_silent
    _zhm_sync
    _zhm_record_key "$KEYS"
    local p=$KEYS mode=$_zhm_mode
    while :; do
        if ! _zhm_lookup $mode "$p"; then
            zle -M ""
            _zhm_count=0 _zhm_register=""
            return 0
        fi
        local entry=$REPLY lookup_mode=$REPLY2
        case $entry in
            (cmd:*)
                zle -M ""
                _zhm_run ${entry#cmd:}
                return
                ;;
            (menu:*)
                _zhm_menu_info_lines $mode "$p"
                _zhm_show_info "${entry#menu:}" "${reply[@]}"
                _zhm_read_key
                local key=$REPLY
                # As in Helix, a digit the menu doesn't bind adds to the count
                # while the menu stays open.
                if [[ $key == [0-9] ]] && ! _zhm_lookup $mode "$p$_ZHM_SEP$key" \
                    && [[ $key != 0 || $_zhm_count -gt 0 ]]; then
                    _zhm_count_digit $key
                    continue
                fi
                if ! _zhm_lookup $mode "$p$_ZHM_SEP$key"; then
                    local fallback=${_zhm_km_fallback[$lookup_mode$_ZHM_MSEP$p]}
                    zle -M ""
                    if [[ -n $fallback ]] && _zhm_key_char "$key"; then
                        _zhm_run $fallback "$REPLY"
                    else
                        _zhm_count=0 _zhm_register=""
                        _zhm_render
                    fi
                    return
                fi
                p+=$_ZHM_SEP$key
                ;;
        esac
    done
}

# Normal mode bindings, which are also the base for select mode.
function _zhm_define_normal_keymap() {
    local m=normal
    zhm_bind $m 'h|left' move_char_left
    zhm_bind $m 'j|down' move_visual_line_down
    zhm_bind $m 'k|up' move_visual_line_up
    zhm_bind $m 'l|right' move_char_right

    zhm_bind $m 't' find_till_char
    zhm_bind $m 'f' find_next_char
    zhm_bind $m 'T' till_prev_char
    zhm_bind $m 'F' find_prev_char
    zhm_bind $m 'r' replace
    zhm_bind $m 'R' replace_with_yanked
    zhm_bind $m 'A-.' repeat_last_motion

    zhm_bind $m '~' switch_case
    zhm_bind $m '`' switch_to_lowercase
    zhm_bind $m 'A-`' switch_to_uppercase

    zhm_bind $m 'home' goto_line_start
    zhm_bind $m 'end' goto_line_end

    zhm_bind $m 'w' move_next_word_start
    zhm_bind $m 'b' move_prev_word_start
    zhm_bind $m 'e' move_next_word_end
    zhm_bind $m 'W' move_next_long_word_start
    zhm_bind $m 'B' move_prev_long_word_start
    zhm_bind $m 'E' move_next_long_word_end

    zhm_bind $m 'v' select_mode
    zhm_bind $m 'G' goto_line
    zhm_menu $m 'g' "Goto"
    zhm_bind $m 'g g' goto_file_start
    zhm_bind $m 'g |' goto_column
    zhm_bind $m 'g e' goto_last_line
    zhm_bind $m 'g h' goto_line_start
    zhm_bind $m 'g l' goto_line_end
    zhm_bind $m 'g s' goto_first_nonwhitespace
    zhm_bind $m 'g t' goto_window_top
    zhm_bind $m 'g c' goto_window_center
    zhm_bind $m 'g b' goto_window_bottom
    zhm_bind $m 'g k' move_line_up
    zhm_bind $m 'g j' move_line_down
    zhm_bind $m 'g .' goto_last_modification
    zhm_bind $m 'g w' goto_word
    zhm_bind $m ':' command_mode

    zhm_bind $m 'i' insert_mode
    zhm_bind $m 'I' insert_at_line_start
    zhm_bind $m 'a' append_mode
    zhm_bind $m 'A' insert_at_line_end
    zhm_bind $m 'o' open_below
    zhm_bind $m 'O' open_above

    zhm_bind $m 'd' delete_selection
    zhm_bind $m 'A-d' delete_selection_noyank
    zhm_bind $m 'c' change_selection
    zhm_bind $m 'A-c' change_selection_noyank

    zhm_bind $m 'C' copy_selection_on_next_line
    zhm_bind $m 'A-C' copy_selection_on_prev_line

    zhm_bind $m 's' select_regex
    zhm_bind $m 'A-s' split_selection_on_newline
    zhm_bind $m 'A-minus' merge_selections
    zhm_bind $m 'A-_' merge_consecutive_selections
    zhm_bind $m 'S' split_selection
    zhm_bind $m ';' collapse_selection
    zhm_bind $m 'A-;' flip_selections

    zhm_bind $m '%' select_all
    zhm_bind $m 'x' extend_line_below
    zhm_bind $m 'X' extend_to_line_bounds
    zhm_bind $m 'A-x' shrink_to_line_bounds

    zhm_menu $m 'm' "Match"
    zhm_bind $m 'm m' match_brackets
    zhm_bind $m 'm s' surround_add
    zhm_bind $m 'm r' surround_replace
    zhm_bind $m 'm d' surround_delete
    zhm_menu $m 'm i' "Match inside" select_textobject_inside_surrounding_pair
    zhm_bind $m 'm i w' select_textobject_inside_word
    zhm_bind $m 'm i W' select_textobject_inside_WORD
    zhm_bind $m 'm i p' select_textobject_inside_paragraph
    zhm_bind $m 'm i m' select_textobject_inside_closest_surrounding_pair
    zhm_menu $m 'm a' "Match around" select_textobject_around_surrounding_pair
    zhm_bind $m 'm a w' select_textobject_around_word
    zhm_bind $m 'm a W' select_textobject_around_WORD
    zhm_bind $m 'm a p' select_textobject_around_paragraph
    zhm_bind $m 'm a m' select_textobject_around_closest_surrounding_pair

    zhm_menu $m '[' "Left bracket" select_textobject_inside_prev_pair
    zhm_bind $m '[ p' goto_prev_paragraph
    zhm_bind $m '[ space' add_newline_above
    zhm_menu $m ']' "Right bracket" select_textobject_inside_next_pair
    zhm_bind $m '] p' goto_next_paragraph
    zhm_bind $m '] space' add_newline_below

    zhm_bind $m '/' search
    zhm_bind $m '?' rsearch
    zhm_bind $m 'n' search_next
    zhm_bind $m 'N' search_prev
    zhm_bind $m '*' search_selection_detect_word_boundaries
    zhm_bind $m 'A-*' search_selection

    zhm_bind $m 'u' undo
    zhm_bind $m 'U' redo
    zhm_bind $m 'A-u' earlier
    zhm_bind $m 'A-U' later

    zhm_bind $m 'y' yank
    zhm_bind $m 'p' paste_after
    zhm_bind $m 'P' paste_before

    zhm_bind $m 'Q' record_macro
    zhm_bind $m 'q' replay_macro

    zhm_bind $m '>' indent
    zhm_bind $m '<' unindent
    zhm_bind $m 'J' join_selections
    zhm_bind $m 'A-J' join_selections_space
    zhm_bind $m 'K' keep_selections
    zhm_bind $m 'A-K' remove_selections

    zhm_bind $m ',' keep_primary_selection
    zhm_bind $m 'A-,' remove_primary_selection

    zhm_bind $m '&' align_selections
    zhm_bind $m '_' trim_selections

    zhm_bind $m '(' rotate_selections_backward
    zhm_bind $m ')' rotate_selections_forward
    zhm_bind $m 'A-(' rotate_selection_contents_backward
    zhm_bind $m 'A-)' rotate_selection_contents_forward

    zhm_bind $m 'A-:' ensure_selections_forward

    zhm_bind $m 'esc' normal_mode
    zhm_bind $m 'C-b|pageup' page_up
    zhm_bind $m 'C-f|pagedown' page_down
    zhm_bind $m 'C-u' page_cursor_half_up
    zhm_bind $m 'C-d' eof_or_page_cursor_half_down

    zhm_bind $m 'C-i|tab' jump_forward
    zhm_bind $m 'C-o' jump_backward
    zhm_bind $m 'C-s' save_selection

    zhm_menu $m 'space' "Space"
    zhm_bind $m 'space y' yank_to_clipboard
    zhm_bind $m 'space Y' yank_main_selection_to_clipboard
    zhm_bind $m 'space p' paste_clipboard_after
    zhm_bind $m 'space P' paste_clipboard_before
    zhm_bind $m 'space R' replace_selections_with_clipboard
    zhm_bind $m 'space c' toggle_comments
    zhm_bind $m 'space C' toggle_block_comments
    zhm_bind $m 'space A-c' toggle_line_comments

    zhm_menu $m 'z' "View"
    zhm_bind $m 'z C-b|pageup' page_up
    zhm_bind $m 'z C-f|pagedown' page_down
    zhm_bind $m 'z C-u|backspace' page_cursor_half_up
    zhm_bind $m 'z C-d|space' page_cursor_half_down
    zhm_bind $m 'z /' search
    zhm_bind $m 'z ?' rsearch
    zhm_bind $m 'z n' search_next
    zhm_bind $m 'z N' search_prev

    zhm_bind $m '"' select_register
    zhm_bind $m '|' shell_pipe
    zhm_bind $m 'A-|' shell_pipe_to
    zhm_bind $m '!' shell_insert_output
    zhm_bind $m 'A-!' shell_append_output
    zhm_bind $m '$' shell_keep_pipe

    zhm_bind $m 'C-a' increment
    zhm_bind $m 'C-x' decrement

    zhm_bind $m '.' repeat_last_insert

    # Shell additions, which don't clash with Helix.
    zhm_bind $m 'ret' accept_line
    zhm_bind $m 'C-l' clear_screen
    zhm_bind $m 'C-p' history_prev
    zhm_bind $m 'C-n' history_next
}

# Select mode overrides.
function _zhm_define_select_keymap() {
    local m=select
    zhm_bind $m 'h|left' extend_char_left
    zhm_bind $m 'j|down' extend_visual_line_down
    zhm_bind $m 'k|up' extend_visual_line_up
    zhm_bind $m 'l|right' extend_char_right

    zhm_bind $m 'w' extend_next_word_start
    zhm_bind $m 'b' extend_prev_word_start
    zhm_bind $m 'e' extend_next_word_end
    zhm_bind $m 'W' extend_next_long_word_start
    zhm_bind $m 'B' extend_prev_long_word_start
    zhm_bind $m 'E' extend_next_long_word_end

    zhm_bind $m 'n' extend_search_next
    zhm_bind $m 'N' extend_search_prev

    zhm_bind $m 't' extend_till_char
    zhm_bind $m 'f' extend_next_char
    zhm_bind $m 'T' extend_till_prev_char
    zhm_bind $m 'F' extend_prev_char

    zhm_bind $m 'home' extend_to_line_start
    zhm_bind $m 'end' extend_to_line_end
    zhm_bind $m 'esc' exit_select_mode

    zhm_bind $m 'v' normal_mode
    zhm_menu $m 'g' "Goto"
    zhm_bind $m 'g g' extend_to_file_start
    zhm_bind $m 'g |' extend_to_column
    zhm_bind $m 'g e' extend_to_last_line
    zhm_bind $m 'g k' extend_line_up
    zhm_bind $m 'g j' extend_line_down
    zhm_bind $m 'g w' extend_to_word
}

function _zhm_define_insert_keymap() {
    local m=insert
    zhm_bind $m 'esc' normal_mode
    zhm_bind $m 'C-s' commit_undo_checkpoint
    zhm_bind $m 'C-w|A-backspace' delete_word_backward
    zhm_bind $m 'A-d|A-del' delete_word_forward
    zhm_bind $m 'C-u' kill_to_line_start
    zhm_bind $m 'C-k' kill_to_line_end
    zhm_bind $m 'C-h|backspace' delete_char_backward
    zhm_bind $m 'C-d' eof_or_delete_char_forward
    zhm_bind $m 'del' delete_char_forward
    zhm_bind $m 'C-j' insert_newline
    zhm_bind $m 'S-tab' insert_tab
    zhm_bind $m 'up' move_visual_line_up
    zhm_bind $m 'down' move_visual_line_down
    zhm_bind $m 'left' move_char_left
    zhm_bind $m 'right' move_char_right
    zhm_bind $m 'pageup' page_up
    zhm_bind $m 'pagedown' page_down
    zhm_bind $m 'home' goto_line_start
    zhm_bind $m 'end' goto_line_end_newline

    # Shell additions. Tab, Ctrl-r and the rest of the shell's own insert
    # mode keys are left alone.
    zhm_bind $m 'ret' accept_line
    zhm_bind $m 'C-l' clear_screen
    zhm_bind $m 'C-p' history_prev
    zhm_bind $m 'C-n' history_next
}
