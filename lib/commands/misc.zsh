# Search, regex selection, registers, macros, counts and shell integration.

### Search ###

typeset -g _zhm_last_search_register=/

# `search_impl`: the regex must already be compiled. $1: extend (1/0),
# $2: forward (1/0), $3: show warnings.
function _zhm_search_impl() {
    local -i extend=$1 forward=$2 warn=$3
    local -i pa=${_zhm_sa[_zhm_pi]} ph=${_zhm_sh[_zhm_pi]}
    local -i from=$(( pa < ph ? pa : ph )) to=$(( pa < ph ? ph : pa ))
    local -i ms=-1 me=-1 wrapped=0
    if (( forward )); then
        _zhm_search_forward_from $to && { ms=${reply[1]} me=${reply[2]} }
        if (( ms < 0 )) && (( ZHM_SEARCH_WRAP_AROUND )); then
            _zhm_search_forward_from 0 && { ms=${reply[1]} me=${reply[2]} wrapped=1 }
        fi
    else
        _zhm_regex_matches 0 $from
        if (( ${#reply} )); then
            ms=${reply[-2]} me=${reply[-1]}
        elif (( ZHM_SEARCH_WRAP_AROUND )); then
            _zhm_regex_matches $from $_zhm_len
            (( ${#reply} )) && { ms=${reply[-2]} me=${reply[-1]} wrapped=1 }
        fi
    fi
    if (( warn )); then
        if (( wrapped )); then
            _zhm_status "Wrapped around document"
        elif (( ms < 0 )); then
            _zhm_error "No more matches"
        fi
    fi
    (( ms >= 0 )) || return 1
    (( me == 0 )) && return 1
    _zhm_with_direction $ms $me $(( ph >= pa ))
    if (( extend )); then
        _zhm_sa+=( $_zhm_ra ) _zhm_sh+=( $_zhm_rh ) _zhm_scol+=( -1 )
        _zhm_pi=${#_zhm_sa}
    else
        _zhm_sa[_zhm_pi]=$_zhm_ra _zhm_sh[_zhm_pi]=$_zhm_rh
    fi
    _zhm_ensure_invariants
    return 0
}

# First match starting at or after position $1, searching the whole text so
# that anchors see the surrounding context. Sets reply to the start and end.
function _zhm_search_forward_from() {
    local -i start=$1 bs be
    _zhm_chars_to_bytes $start
    local ZPCRE_OP MATCH
    local -a match
    pcre_match -b -n $REPLY -- "$_zhm_text" || return 1
    bs=${ZPCRE_OP% *} be=${ZPCRE_OP#* }
    local -i cs ce
    _zhm_bytes_to_chars "$_zhm_text" $bs; cs=$REPLY
    _zhm_bytes_to_chars "$_zhm_text" $be; ce=$REPLY
    reply=( $cs $ce )
}

typeset -g _zhm_prompt_snapshot=""
typeset -gi _zhm_search_extend=0 _zhm_search_forward=1

function _zhm_search_update() {
    local input=$1
    _zhm_selection_restore "$_zhm_prompt_snapshot"
    [[ -n $input ]] || return 0
    _zhm_regex_compile "$input" || return 0
    _zhm_search_impl $_zhm_search_extend $_zhm_search_forward 0
}

function _zhm_searcher() {
    local -i forward=$1
    local reg=${_zhm_register:-/}
    _zhm_extend_flag
    _zhm_search_extend=$REPLY _zhm_search_forward=$forward
    _zhm_selection_serialize
    _zhm_prompt_snapshot=$REPLY
    local prompt="search:"
    (( forward )) || prompt="rsearch:"
    if ! _zhm_prompt "$prompt" "$reg" _zhm_search_update; then
        _zhm_selection_restore "$_zhm_prompt_snapshot"
        return 0
    fi
    _zhm_last_search_register=$reg
    local input=$REPLY
    _zhm_selection_restore "$_zhm_prompt_snapshot"
    [[ -n $input ]] || return 0
    if ! _zhm_regex_compile "$input"; then
        _zhm_error "Invalid regex: $input"
        return 1
    fi
    _zhm_save_jump
    _zhm_search_impl $_zhm_search_extend $forward 0
}

function _zhm_cmd_search() { _zhm_searcher 1 }
function _zhm_cmd_rsearch() { _zhm_searcher 0 }

function _zhm_search_next_or_prev() {
    local -i extend=$1 forward=$2 count i
    _zhm_count_or_1; count=$REPLY
    local reg=${_zhm_register:-$_zhm_last_search_register}
    _zhm_reg_first "$reg" || return 0
    local query=$REPLY
    if ! _zhm_regex_compile "$query"; then
        _zhm_error "Invalid regex: $query"
        return 1
    fi
    for (( i = 0; i < count; i++ )); do
        _zhm_search_impl $extend $forward 1
    done
    _zhm_save_jump
}

function _zhm_cmd_search_next() { _zhm_search_next_or_prev 0 1 }
function _zhm_cmd_search_prev() { _zhm_search_next_or_prev 0 0 }
function _zhm_cmd_extend_search_next() { _zhm_search_next_or_prev 1 1 }
function _zhm_cmd_extend_search_prev() { _zhm_search_next_or_prev 1 0 }

# Escape regex metacharacters like Rust's `regex::escape`.
function _zhm_regex_escape() {
    REPLY=${1//(#b)([\\.+*?()|\[\]\{\}^\$#&~-])/\\$match[1]}
}

function _zhm_search_selection_impl() {
    local -i detect=$1 i
    local reg=${_zhm_register:-/}
    local -A seen
    local -a parts
    for (( i = 1; i <= ${#_zhm_sa}; i++ )); do
        local -i a=${_zhm_sa[i]} h=${_zhm_sh[i]}
        local -i from=$(( a < h ? a : h )) to=$(( a < h ? h : a ))
        local prefix="" suffix=""
        if (( detect )); then
            if (( from < _zhm_len )) && _zhm_is_word_char "${_zhm_chars[from + 1]}"; then
                if (( from == 0 )) || ! _zhm_is_word_char "${_zhm_chars[from]}"; then
                    prefix='\b'
                fi
            fi
            if (( to > 0 && to < _zhm_len )) && _zhm_is_word_char "${_zhm_chars[to]}" && ! _zhm_is_word_char "${_zhm_chars[to + 1]}"; then
                suffix='\b'
            fi
        fi
        _zhm_regex_escape "${_zhm_text:$from:$(( to - from ))}"
        local part=$prefix$REPLY$suffix
        (( ${+seen[$part]} )) && continue
        seen[$part]=1
        parts+=( "$part" )
    done
    local regex=${(j:|:)parts}
    _zhm_reg_push "$reg" "$regex"
    _zhm_last_search_register=$reg
    _zhm_status "register '$reg' set to '$regex'"
}

function _zhm_cmd_search_selection() { _zhm_search_selection_impl 0 }
function _zhm_cmd_search_selection_detect_word_boundaries() { _zhm_search_selection_impl 1 }

function _zhm_cmd_make_search_word_bounded() {
    local reg=${_zhm_register:-$_zhm_last_search_register}
    _zhm_reg_first "$reg" || return 0
    local regex=$REPLY
    local -i starts=0 ends=0
    [[ $regex == '\b'* ]] && starts=1
    [[ $regex == *'\b' ]] && ends=1
    (( starts && ends )) && return 0
    (( starts )) || regex='\b'$regex
    (( ends )) || regex+='\b'
    _zhm_reg_push "$reg" "$regex"
    _zhm_last_search_register=$reg
    _zhm_status "register '$reg' set to '$regex'"
}

### Regex selection ###

typeset -g _zhm_regex_op=""

function _zhm_select_on_matches() {
    local -i i
    local -a ranges
    for (( i = 1; i <= ${#_zhm_sa}; i++ )); do
        local -i a=${_zhm_sa[i]} h=${_zhm_sh[i]}
        local -i from=$(( a < h ? a : h )) to=$(( a < h ? h : a )) k
        _zhm_regex_matches $from $to
        for (( k = 1; k <= ${#reply}; k += 2 )); do
            local -i s=${reply[k]} e=${reply[k + 1]}
            (( s == to && e == to )) && continue
            ranges+=( $s $e )
        done
    done
    (( ${#ranges} )) || return 1
    _zhm_set_selection 1 "${ranges[@]}"
}

function _zhm_split_on_matches() {
    local -i i
    local -a ranges
    for (( i = 1; i <= ${#_zhm_sa}; i++ )); do
        local -i a=${_zhm_sa[i]} h=${_zhm_sh[i]}
        local -i from=$(( a < h ? a : h )) to=$(( a < h ? h : a )) k
        if (( from == to )); then
            ranges+=( $a $h )
            continue
        fi
        local -i start=$from
        _zhm_regex_matches $from $to
        for (( k = 1; k <= ${#reply}; k += 2 )); do
            ranges+=( $start ${reply[k]} )
            start=${reply[k + 1]}
        done
        (( start < to )) && ranges+=( $start $to )
    done
    _zhm_set_selection 1 "${ranges[@]}"
}

function _zhm_keep_or_remove_matches() {
    local -i remove=$1 i
    local -a ranges
    for (( i = 1; i <= ${#_zhm_sa}; i++ )); do
        local -i a=${_zhm_sa[i]} h=${_zhm_sh[i]}
        local -i from=$(( a < h ? a : h )) to=$(( a < h ? h : a )) matched=0
        _zhm_regex_matches $from $to 1
        (( ${#reply} )) && matched=1
        (( matched != remove )) && ranges+=( $a $h )
    done
    (( ${#ranges} )) || return 1
    _zhm_set_selection 1 "${ranges[@]}"
}

function _zhm_regex_op_apply() {
    case $_zhm_regex_op in
        (select) _zhm_select_on_matches ;;
        (split) _zhm_split_on_matches ;;
        (keep) _zhm_keep_or_remove_matches 0 ;;
        (remove) _zhm_keep_or_remove_matches 1 ;;
    esac
}

function _zhm_regex_op_update() {
    _zhm_selection_restore "$_zhm_prompt_snapshot"
    [[ -n $1 ]] || return 0
    _zhm_regex_compile "$1" || return 0
    _zhm_regex_op_apply
}

function _zhm_regex_prompt_cmd() {
    local op=$1 prompt=$2 error=$3
    local reg=${_zhm_register:-/}
    _zhm_regex_op=$op
    _zhm_selection_serialize
    _zhm_prompt_snapshot=$REPLY
    if ! _zhm_prompt "$prompt" "$reg" _zhm_regex_op_update; then
        _zhm_selection_restore "$_zhm_prompt_snapshot"
        return 0
    fi
    local input=$REPLY
    _zhm_selection_restore "$_zhm_prompt_snapshot"
    [[ -n $input ]] || return 0
    if ! _zhm_regex_compile "$input"; then
        _zhm_error "Invalid regex: $input"
        return 1
    fi
    _zhm_save_jump
    if ! _zhm_regex_op_apply && [[ -n $error ]]; then
        _zhm_error "$error"
    fi
}

function _zhm_cmd_select_regex() { _zhm_regex_prompt_cmd select "select:" "nothing selected" }
function _zhm_cmd_split_selection() { _zhm_regex_prompt_cmd split "split:" "" }
function _zhm_cmd_keep_selections() { _zhm_regex_prompt_cmd keep "keep:" "no selections remaining" }
function _zhm_cmd_remove_selections() { _zhm_regex_prompt_cmd remove "remove:" "no selections remaining" }

### Registers ###

function _zhm_cmd_select_register() {
    local -a lines
    local name
    for name in ${(ok)_zhm_regs}; do
        local preview=${${(ps:\0:)_zhm_regs[$name]}[1]}
        preview=${preview//$'\n'/⏎}
        lines+=( "$name  ${preview[1,40]}" )
    done
    _zhm_show_info "Select register" "${lines[@]}"
    _zhm_read_char
    local -i ok=$?
    zle -M ""
    (( ok == 0 )) && _zhm_register=$REPLY
    return 0
}

### Macros ###

function _zhm_cmd_record_macro() {
    if [[ -n $_zhm_macro_reg ]]; then
        local reg=$_zhm_macro_reg
        # Drop the key that ended the recording.
        _zhm_keys_encode "${(@)_zhm_macro_keys[1,-2]}"
        local macro=$REPLY
        _zhm_macro_reg=""
        _zhm_macro_keys=()
        _zhm_reg_write "$reg" "$macro" || return 1
        _zhm_status "Recorded to register [$reg]"
    else
        _zhm_macro_reg=${_zhm_register:-@}
        _zhm_macro_keys=()
        _zhm_status "Recording to register [$_zhm_macro_reg]"
    fi
}

function _zhm_cmd_replay_macro() {
    local reg=${_zhm_register:-@}
    local -i count i
    _zhm_count_or_1; count=$REPLY
    if (( _zhm_replaying )); then
        _zhm_error "Cannot replay from register [$reg] because already replaying"
        return 1
    fi
    if ! _zhm_reg_read "$reg" || (( ${#reply} != 1 )); then
        _zhm_error "Register [$reg] empty"
        return 1
    fi
    if ! _zhm_keys_decode "${reply[1]}"; then
        _zhm_error "Invalid macro: ${reply[1]}"
        return 1
    fi
    local -a keys all
    keys=( "${reply[@]}" )
    for (( i = 0; i < count; i++ )); do all+=( "${keys[@]}" ); done
    _zhm_replay_input "${all[@]}"
}

### Repeat last insert ###

function _zhm_cmd_repeat_last_insert() {
    [[ -n $_zhm_last_insert_cmd ]] || return 0
    local -i count i
    _zhm_count_or_1; count=$REPLY
    local -a events
    events=( "${_zhm_last_insert_keys[@]}" )
    for (( i = 1; i < count; i++ )); do
        events+=( "$_ZHM_KEY_REPEAT_INSERT" "${_zhm_last_insert_keys[@]}" )
    done
    _zhm_replay_input "${events[@]}"
    _zhm_replay_insert_cmd
}

function _zhm_replay_insert_cmd() {
    local -a words
    words=( ${(z)_zhm_last_insert_cmd} )
    local cmd=${words[1]}
    local -a args
    args=( "${(@Q)words[2,-1]}" )
    _zhm_cmd_$cmd "${args[@]}"
}

function _zhm_cmd_repeat_insert_once() {
    _zhm_replay_insert_cmd
}

function _zhm_cmd_replay_end() {
    _zhm_replay_end
}

### Counts ###

function _zhm_count_digit() {
    local -i digit=$1
    if (( _zhm_count == 0 && digit == 0 )); then
        return 0
    fi
    local -i next=$(( _zhm_count * 10 + digit ))
    (( next > 100000000 )) && return 0
    _zhm_count=$next
}

function _zhm_cmd_count_0() { _zhm_count_digit 0 }
function _zhm_cmd_count_1() { _zhm_count_digit 1 }
function _zhm_cmd_count_2() { _zhm_count_digit 2 }
function _zhm_cmd_count_3() { _zhm_count_digit 3 }
function _zhm_cmd_count_4() { _zhm_count_digit 4 }
function _zhm_cmd_count_5() { _zhm_count_digit 5 }
function _zhm_cmd_count_6() { _zhm_count_digit 6 }
function _zhm_cmd_count_7() { _zhm_count_digit 7 }
function _zhm_cmd_count_8() { _zhm_count_digit 8 }
function _zhm_cmd_count_9() { _zhm_count_digit 9 }

### Shell line integration ###

function _zhm_cmd_accept_line() {
    _zhm_clear_highlight
    zle ${ZHM_ACCEPT_LINE_WIDGET:-accept-line}
}

function _zhm_cmd_clear_screen() {
    zle clear-screen
}

# Ctrl-d: end of file on an empty line, as in zsh.
function _zhm_cmd_eof_or_delete_char_forward() {
    if [[ -z $BUFFER ]]; then
        _zhm_eof
        return
    fi
    _zhm_cmd_delete_char_forward
}

function _zhm_cmd_eof_or_page_cursor_half_down() {
    if [[ -z $BUFFER ]]; then
        _zhm_eof
        return
    fi
    _zhm_cmd_page_cursor_half_down
}

function _zhm_eof() {
    # Mirror zsh's behaviour for Ctrl-d on an empty line.
    if [[ -o ignore_eof ]]; then
        _zhm_status "zsh: use 'exit' to exit."
        return 0
    fi
    _zhm_clear_highlight
    BUFFER=exit
    zle .accept-line
}

function _zhm_cmd_noop() {
    return 0
}

### Command mode ###

typeset -gA _ZHM_TYPABLE=(
    sort sort
    rsort rsort
    reverse-selection-contents reverse
    pipe pipe
    pipe-to pipe-to
    insert-output insert-output
    append-output append-output
    run-shell-command run-shell-command
    sh run-shell-command
    yank-join yank-join
    clipboard-yank clipboard-yank
    clipboard-yank-join clipboard-yank-join
    primary-clipboard-yank primary-clipboard-yank
    primary-clipboard-yank-join primary-clipboard-yank-join
    clipboard-paste-after clipboard-paste-after
    clipboard-paste-before clipboard-paste-before
    clipboard-paste-replace clipboard-paste-replace
    primary-clipboard-paste-after primary-clipboard-paste-after
    primary-clipboard-paste-before primary-clipboard-paste-before
    primary-clipboard-paste-replace primary-clipboard-paste-replace
    clear-register clear-register
    echo echo
    goto goto
    g goto
    earlier earlier
    ear earlier
    later later
    lat later
    write write
    w write
    x write
    wq write
    quit quit
    q quit
    q! quit
    set-option set
    set set
)

function _zhm_cmd_command_mode() {
    _zhm_prompt ":" ":" || return 0
    local input=$REPLY
    [[ -n $input ]] || return 0
    local -a words
    words=( ${(z)input} )
    local name=${words[1]}
    local -a args
    args=( "${(@Q)words[2,-1]}" )
    local rest=${input#*[[:space:]]}
    [[ $rest == $input ]] && rest=""
    if [[ $name == <-> ]]; then
        _zhm_count=$name
        _zhm_goto_line_impl 0
        return
    fi
    local op=${_ZHM_TYPABLE[$name]}
    case $op in
        (sort|rsort)
            _zhm_selection_fragments
            local -a frags sorted
            frags=( "${reply[@]}" )
            if [[ $op == sort ]]; then sorted=( "${(@o)frags}" ); else sorted=( "${(@O)frags}" ); fi
            _zhm_changes_reset
            local -i i
            for (( i = 1; i <= ${#_zhm_sa}; i++ )); do
                local -i a=${_zhm_sa[i]} h=${_zhm_sh[i]}
                _zhm_change $(( a < h ? a : h )) $(( a < h ? h : a )) "${sorted[i]}"
            done
            _zhm_apply_changes
            ;;
        (reverse) _zhm_count=1; _zhm_reorder_contents reverse ;;
        (pipe) _zhm_shell_impl "$rest" replace ;;
        (pipe-to) _zhm_shell_impl "$rest" ignore ;;
        (insert-output) _zhm_shell_impl "$rest" insert ;;
        (append-output) _zhm_shell_impl "$rest" append ;;
        (run-shell-command)
            if _zhm_shell_run "$rest" "" 0; then
                _zhm_status "${REPLY%$'\n'}"
            else
                _zhm_error "$REPLY"
            fi
            ;;
        (yank-join)
            _zhm_register_or_default
            _zhm_yank_joined_impl "$REPLY" "${rest:-$'\n'}"
            ;;
        (clipboard-yank) _zhm_yank_main_impl + ;;
        (clipboard-yank-join) _zhm_yank_joined_impl + "${rest:-$'\n'}" ;;
        (primary-clipboard-yank) _zhm_yank_main_impl '*' ;;
        (primary-clipboard-yank-join) _zhm_yank_joined_impl '*' "${rest:-$'\n'}" ;;
        (clipboard-paste-after) _zhm_paste_from_register + after ;;
        (clipboard-paste-before) _zhm_paste_from_register + before ;;
        (clipboard-paste-replace) _zhm_replace_with_register + ;;
        (primary-clipboard-paste-after) _zhm_paste_from_register '*' after ;;
        (primary-clipboard-paste-before) _zhm_paste_from_register '*' before ;;
        (primary-clipboard-paste-replace) _zhm_replace_with_register '*' ;;
        (clear-register)
            if [[ -z ${args[1]} ]]; then
                _zhm_regs=()
                _zhm_status "All registers cleared"
            else
                unset "_zhm_regs[${args[1]}]"
                _zhm_status "Register ${args[1]} cleared"
            fi
            ;;
        (echo) _zhm_status "$rest" ;;
        (goto)
            [[ ${args[1]} == <-> ]] || { _zhm_error "invalid line number"; return 1 }
            _zhm_count=${args[1]}
            _zhm_goto_line_impl 0
            ;;
        (earlier) _zhm_count=${args[1]:-1}; _zhm_cmd_earlier ;;
        (later) _zhm_count=${args[1]:-1}; _zhm_cmd_later ;;
        (write)
            # There's no file to write: run the command line instead.
            _zhm_cmd_accept_line
            ;;
        (quit)
            # Quitting abandons the command line.
            BUFFER=""
            _zhm_load_text
            _zhm_set_single 0 0
            _zhm_clear_highlight
            zle .send-break
            ;;
        (set)
            _zhm_status "Options are set with ZHM_* variables in your .zshrc"
            ;;
        (*)
            _zhm_error "no such command: '$name'"
            return 1
            ;;
    esac
}
