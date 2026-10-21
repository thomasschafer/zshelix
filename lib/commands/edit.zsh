# Editing commands, ported from `helix_term::commands`.

# Set by append mode so that leaving insert mode moves the cursor back.
typeset -gi _zhm_restore_cursor=0

### Entering insert mode ###

function _zhm_enter_insert_mode() {
    _zhm_set_mode insert
}

function _zhm_cmd_insert_mode() {
    _zhm_enter_insert_mode
    local -i i
    for (( i = 1; i <= ${#_zhm_sa}; i++ )); do
        local -i a=${_zhm_sa[i]} h=${_zhm_sh[i]}
        _zhm_sa[i]=$(( a < h ? h : a )) _zhm_sh[i]=$(( a < h ? a : h ))
    done
    _zhm_ensure_invariants
}

function _zhm_cmd_append_mode() {
    _zhm_enter_insert_mode
    _zhm_restore_cursor=1
    local -i la=${_zhm_sa[-1]} lh=${_zhm_sh[-1]}
    if (( la != lh && (la > lh ? la : lh) == _zhm_len )); then
        _zhm_changes_reset
        _zhm_change $_zhm_len $_zhm_len $'\n'
        _zhm_apply_changes
    fi
    local -i i
    for (( i = 1; i <= ${#_zhm_sa}; i++ )); do
        local -i a=${_zhm_sa[i]} h=${_zhm_sh[i]}
        local -i from=$(( a < h ? a : h )) to=$(( a < h ? h : a ))
        _zhm_sa[i]=$from _zhm_sh[i]=$(( to < _zhm_len ? to + 1 : _zhm_len ))
    done
    _zhm_ensure_invariants
}

# Indentation for a new line after line $1. Without syntax information Helix
# measures the line's leading whitespace in whole indent units
# (`indent_level_for_line`) and repeats the indent unit that many times.
function _zhm_newline_indent() {
    local -i line=$1 pos width=0 iw
    _zhm_line_start $line; pos=$REPLY
    while (( pos < _zhm_len )); do
        case ${_zhm_chars[pos + 1]} in
            ($'\t') (( width += ZHM_TAB_WIDTH - width % ZHM_TAB_WIDTH )) ;;
            (' ') (( width++ )) ;;
            (*) break ;;
        esac
        (( pos++ ))
    done
    (( iw = _zhm_indent_width > 0 ? _zhm_indent_width : ZHM_TAB_WIDTH ))
    _zhm_indent_unit
    local unit=$REPLY out="" k
    for (( k = 0; k < width / iw; k++ )); do out+=$unit; done
    REPLY=$out
}

# `insert_with_indent`: $1 is "start" or "end".
function _zhm_insert_with_indent() {
    local fallback=$1
    local -i was_select=0 i offs=0
    [[ $_zhm_mode == select ]] && was_select=1
    _zhm_enter_insert_mode
    local -a ranges
    _zhm_changes_reset
    for (( i = 1; i <= ${#_zhm_sa}; i++ )); do
        local -i a=${_zhm_sa[i]} h=${_zhm_sh[i]} line ls pos
        _zhm_cursor $a $h
        _zhm_line_of $REPLY; line=$REPLY
        _zhm_line_start $line; ls=$REPLY
        _zhm_line_end $line
        if (( REPLY == ls )); then
            # Empty line: indent it.
            _zhm_newline_indent $line
            local indent=$REPLY
            ranges+=( $(( offs + ls + ${#indent} )) $(( offs + ls + ${#indent} )) )
            (( offs += ${#indent} ))
            _zhm_change $ls $ls "$indent"
        else
            if [[ $fallback == start ]]; then
                if _zhm_first_non_whitespace $line; then
                    pos=$REPLY
                else
                    pos=$ls
                fi
            else
                _zhm_line_end $line; pos=$REPLY
            fi
            _zhm_put_cursor $a $h $(( pos + offs )) $was_select
            ranges+=( $_zhm_ra $_zhm_rh )
        fi
    done
    local -i pi=$_zhm_pi
    _zhm_apply_changes
    _zhm_set_selection $pi "${ranges[@]}"
}

function _zhm_cmd_insert_at_line_start() { _zhm_insert_with_indent start }
function _zhm_cmd_insert_at_line_end() { _zhm_insert_with_indent end }

# `open`: $1 is "below" or "above".
function _zhm_open() {
    local dir=$1
    local -i count i offs=0
    _zhm_count_or_1; count=$REPLY
    _zhm_enter_insert_mode
    local -a ranges
    _zhm_changes_reset
    for (( i = 1; i <= ${#_zhm_sa}; i++ )); do
        local -i a=${_zhm_sa[i]} h=${_zhm_sh[i]} curr next pos_line_end pos_width
        local -i from=$(( a < h ? a : h )) to=$(( a < h ? h : a ))
        if [[ $dir == below ]]; then
            _zhm_line_of $(( to > 0 ? to - 1 : 0 )); curr=$REPLY
            next=$(( curr + 1 ))
        else
            _zhm_line_of $from; curr=$REPLY
            next=$curr
        fi
        local -i above=$(( next > 0 ? next - 1 : 0 ))
        if (( next == 0 )); then
            pos_line_end=0 pos_width=0
        else
            _zhm_line_end $above; pos_line_end=$REPLY
            pos_width=1
        fi
        _zhm_newline_indent $curr
        local indent=$REPLY text=""
        if [[ $dir == above ]] && (( next == 0 )); then
            text=$indent$'\n'
        else
            text=$'\n'$indent
        fi
        local repeated=""
        local -i k
        for (( k = 0; k < count; k++ )); do repeated+=$text; done
        local -i pos=$(( offs + pos_line_end + pos_width ))
        for (( k = 0; k < count; k++ )); do
            local -i p=$(( pos + k * (1 + ${#indent}) + ${#indent} ))
            ranges+=( $p $p )
        done
        (( offs += ${#repeated} ))
        _zhm_change $pos_line_end $pos_line_end "$repeated"
    done
    local -i pi=$_zhm_pi
    _zhm_apply_changes
    _zhm_set_selection $pi "${ranges[@]}"
}

function _zhm_cmd_open_below() { _zhm_open below }
function _zhm_cmd_open_above() { _zhm_open above }

# Remove the indentation of a newly inserted line if insert mode is left
# without typing anything on it (Helix's `try_restore_indent`). Only the
# primary selection is considered, as in Helix.
function _zhm_try_restore_indent() {
    (( _zhm_dirty && _zhm_indent_insert_end >= 0 )) || return 0
    local -i pos line ls le
    _zhm_primary_cursor; pos=$REPLY
    _zhm_line_of $pos; line=$REPLY
    _zhm_line_start $line; ls=$REPLY
    _zhm_line_end $line; le=$REPLY
    (( pos == _zhm_indent_insert_end && pos == le )) || return 0
    _zhm_changes_reset
    _zhm_change $ls $pos ""
    _zhm_apply_changes
}

### Deleting and changing ###

function _zhm_selection_is_linewise() {
    local -i i
    for (( i = 1; i <= ${#_zhm_sa}; i++ )); do
        local -i a=${_zhm_sa[i]} h=${_zhm_sh[i]}
        local -i from=$(( a < h ? a : h )) to=$(( a < h ? h : a ))
        local frag=${_zhm_text:$from:$(( to - from ))}
        [[ $frag == *$'\n'* ]] || return 1
        _zhm_line_range $a $h
        local -i el=$_zhm_rh
        _zhm_line_start $_zhm_ra
        (( REPLY == from )) || return 1
        _zhm_line_next_start $el
        (( REPLY == to )) || return 1
    done
    return 0
}

function _zhm_selection_fragments() {
    reply=()
    local -i i
    for (( i = 1; i <= ${#_zhm_sa}; i++ )); do
        local -i a=${_zhm_sa[i]} h=${_zhm_sh[i]}
        local -i from=$(( a < h ? a : h )) to=$(( a < h ? h : a ))
        reply+=( "${_zhm_text:$from:$(( to - from ))}" )
    done
}

function _zhm_delete_selection_impl() {
    local op=$1
    local -i yank=$2 linewise=0
    _zhm_selection_is_linewise && linewise=1
    if (( yank )) && [[ $_zhm_register != _ ]]; then
        _zhm_register_or_default
        local reg=$REPLY
        _zhm_selection_fragments
        _zhm_reg_write "$reg" "${reply[@]}" || return 1
    fi
    _zhm_changes_reset
    local -i i last=0
    for (( i = 1; i <= ${#_zhm_sa}; i++ )); do
        local -i a=${_zhm_sa[i]} h=${_zhm_sh[i]}
        local -i from=$(( a < h ? a : h )) to=$(( a < h ? h : a ))
        (( from < last )) && from=$last
        (( to < from )) && continue
        _zhm_change $from $to ""
        last=$to
    done
    _zhm_apply_changes
    if [[ $op == delete ]]; then
        _zhm_exit_select_mode
    elif (( linewise )); then
        _zhm_open above
    else
        _zhm_enter_insert_mode
    fi
}

function _zhm_cmd_delete_selection() { _zhm_delete_selection_impl delete 1 }
function _zhm_cmd_delete_selection_noyank() { _zhm_delete_selection_impl delete 0 }
function _zhm_cmd_change_selection() { _zhm_delete_selection_impl change 1 }
function _zhm_cmd_change_selection_noyank() { _zhm_delete_selection_impl change 0 }

### Replace ###

function _zhm_cmd_replace() {
    _zhm_read_char || return 0
    local ch=$REPLY
    _zhm_changes_reset
    local -i i
    for (( i = 1; i <= ${#_zhm_sa}; i++ )); do
        local -i a=${_zhm_sa[i]} h=${_zhm_sh[i]}
        local -i from=$(( a < h ? a : h )) to=$(( a < h ? h : a ))
        (( from == to )) && continue
        _zhm_change $from $to "${(pl:$(( to - from ))::$ch:)}"
    done
    _zhm_apply_changes
    _zhm_exit_select_mode
}

### Case ###

function _zhm_switch_case_impl() {
    local mode=$1
    _zhm_changes_reset
    local -i i
    for (( i = 1; i <= ${#_zhm_sa}; i++ )); do
        local -i a=${_zhm_sa[i]} h=${_zhm_sh[i]}
        local -i from=$(( a < h ? a : h )) to=$(( a < h ? h : a ))
        local frag=${_zhm_text:$from:$(( to - from ))} out=""
        case $mode in
            (upper) out=${(U)frag} ;;
            (lower) out=${(L)frag} ;;
            (switch)
                local c
                for c in "${(@s::)frag}"; do
                    if [[ $c == [[:lower:]] ]]; then
                        out+=${(U)c}
                    elif [[ $c == [[:upper:]] ]]; then
                        out+=${(L)c}
                    else
                        out+=$c
                    fi
                done
                ;;
        esac
        _zhm_change $from $to "$out"
    done
    _zhm_apply_changes
    _zhm_exit_select_mode
}

function _zhm_cmd_switch_case() { _zhm_switch_case_impl switch }
function _zhm_cmd_switch_to_uppercase() { _zhm_switch_case_impl upper }
function _zhm_cmd_switch_to_lowercase() { _zhm_switch_case_impl lower }

### Yank and paste ###

function _zhm_yank_impl() {
    local reg=$1
    _zhm_selection_fragments
    local -i n=${#reply}
    _zhm_reg_write "$reg" "${reply[@]}" || return 1
    local s=s
    (( n == 1 )) && s=""
    _zhm_status "yanked $n selection$s to register $reg"
}

function _zhm_cmd_yank() {
    _zhm_register_or_default
    _zhm_yank_impl "$REPLY"
    _zhm_exit_select_mode
}

function _zhm_cmd_yank_to_clipboard() { _zhm_yank_impl +; _zhm_exit_select_mode }
function _zhm_cmd_yank_to_primary_clipboard() { _zhm_yank_impl '*'; _zhm_exit_select_mode }

function _zhm_yank_joined_impl() {
    local reg=$1 sep=$2
    _zhm_selection_fragments
    local -i n=${#reply}
    _zhm_reg_write "$reg" "${(pj:$sep:)reply}" || return 1
    local s=s
    (( n == 1 )) && s=""
    _zhm_status "joined and yanked $n selection$s to register $reg"
}

function _zhm_cmd_yank_joined() {
    _zhm_register_or_default
    _zhm_yank_joined_impl "$REPLY" $'\n'
    _zhm_exit_select_mode
}
function _zhm_cmd_yank_joined_to_clipboard() { _zhm_yank_joined_impl + $'\n'; _zhm_exit_select_mode }

function _zhm_yank_main_impl() {
    local reg=$1
    local -i a=${_zhm_sa[_zhm_pi]} h=${_zhm_sh[_zhm_pi]}
    local -i from=$(( a < h ? a : h )) to=$(( a < h ? h : a ))
    _zhm_reg_write "$reg" "${_zhm_text:$from:$(( to - from ))}" || return 1
    _zhm_status "yanked primary selection to register $reg"
}
function _zhm_cmd_yank_main_selection_to_clipboard() { _zhm_yank_main_impl +; _zhm_exit_select_mode }
function _zhm_cmd_yank_main_selection_to_primary_clipboard() { _zhm_yank_main_impl '*'; _zhm_exit_select_mode }

# `paste_impl`. $1: before, after or cursor. The values are in $reply.
function _zhm_paste_values() {
    local action=$1
    local -i count=$2 i linewise=0
    local -a values
    values=( "${reply[@]}" )
    (( ${#values} )) || return 0
    local v
    for v in "${values[@]}"; do
        [[ $v == *$'\n' ]] && linewise=1
    done
    local -a mapped
    for v in "${values[@]}"; do
        v=${v//$'\r\n'/$'\n'}
        v=${v//$'\r'/$'\n'}
        local out="" k
        for (( k = 0; k < count; k++ )); do out+=$v; done
        mapped+=( "$out" )
    done
    _zhm_changes_reset
    local -a ranges
    local -i offset=0
    for (( i = 1; i <= ${#_zhm_sa}; i++ )); do
        local -i a=${_zhm_sa[i]} h=${_zhm_sh[i]} pos
        local -i from=$(( a < h ? a : h )) to=$(( a < h ? h : a ))
        case $action:$linewise in
            (before:1)
                _zhm_line_of $from
                _zhm_line_start $REPLY; pos=$REPLY
                ;;
            (after:1)
                _zhm_line_range $a $h
                local -i line=$(( _zhm_rh + 1 ))
                if (( line >= ${#_zhm_lines} )); then pos=$_zhm_len; else _zhm_line_start $line; pos=$REPLY; fi
                ;;
            (before:0) pos=$from ;;
            (after:0) pos=$to ;;
            (cursor:*) _zhm_cursor $a $h; pos=$REPLY ;;
        esac
        local value
        if (( i <= ${#mapped} )); then
            value=${mapped[i]}
        else
            value=${mapped[-1]}
        fi
        local -i anchor=$(( offset + pos ))
        _zhm_with_direction $anchor $(( anchor + ${#value} )) $(( h >= a ))
        ranges+=( $_zhm_ra $_zhm_rh )
        (( offset += ${#value} ))
        _zhm_change $pos $pos "$value"
    done
    local -i pi=$_zhm_pi
    # Helix sorts nothing here: positions follow the (sorted) selection.
    _zhm_apply_changes
    if [[ $_zhm_mode == normal ]]; then
        _zhm_set_selection $pi "${ranges[@]}"
    fi
}

function _zhm_paste_from_register() {
    local reg=$1 action=$2
    local -i count
    _zhm_count_or_1; count=$REPLY
    _zhm_reg_read "$reg" || return 0
    _zhm_paste_values $action $count
}

function _zhm_cmd_paste_after() {
    _zhm_register_or_default
    _zhm_paste_from_register "$REPLY" after
    _zhm_exit_select_mode
}

function _zhm_cmd_paste_before() {
    _zhm_register_or_default
    _zhm_paste_from_register "$REPLY" before
    _zhm_exit_select_mode
}

function _zhm_cmd_paste_clipboard_after() { _zhm_paste_from_register + after; _zhm_exit_select_mode }
function _zhm_cmd_paste_clipboard_before() { _zhm_paste_from_register + before; _zhm_exit_select_mode }
function _zhm_cmd_paste_primary_clipboard_after() { _zhm_paste_from_register '*' after; _zhm_exit_select_mode }
function _zhm_cmd_paste_primary_clipboard_before() { _zhm_paste_from_register '*' before; _zhm_exit_select_mode }

function _zhm_replace_with_register() {
    local reg=$1
    local -i count i
    _zhm_count_or_1; count=$REPLY
    _zhm_reg_read "$reg" || return 0
    local -a values
    local v
    for v in "${reply[@]}"; do
        v=${v//$'\r\n'/$'\n'}
        local out="" k
        for (( k = 0; k < count; k++ )); do out+=$v; done
        values+=( "$out" )
    done
    _zhm_changes_reset
    local -i vi=1
    for (( i = 1; i <= ${#_zhm_sa}; i++ )); do
        local -i a=${_zhm_sa[i]} h=${_zhm_sh[i]}
        local -i from=$(( a < h ? a : h )) to=$(( a < h ? h : a ))
        (( from == to )) && continue
        local value
        if (( vi <= ${#values} )); then value=${values[vi]}; else value=${values[-1]}; fi
        (( vi++ ))
        _zhm_change $from $to "$value"
    done
    _zhm_apply_changes
}

function _zhm_cmd_replace_with_yanked() {
    _zhm_register_or_default
    _zhm_replace_with_register "$REPLY"
    _zhm_exit_select_mode
}
function _zhm_cmd_replace_selections_with_clipboard() { _zhm_replace_with_register +; _zhm_exit_select_mode }
function _zhm_cmd_replace_selections_with_primary_clipboard() { _zhm_replace_with_register '*'; _zhm_exit_select_mode }

# Bracketed paste: paste at the cursor in insert and select mode, before the
# selection in normal mode.
function _zhm_paste_bracketed() {
    local content=$1
    local action=before
    [[ $_zhm_mode == normal ]] || action=cursor
    reply=( "$content" )
    local -i count
    _zhm_count_or_1; count=$REPLY
    if [[ $_zhm_mode == insert ]]; then
        _zhm_history_commit
    fi
    _zhm_paste_values $action $count
    _zhm_exit_select_mode
}

# Widget for the terminal's bracketed paste: let zsh read the pasted text into
# an empty scratch buffer, then paste it Helix-style.
function _zhm_cmd_paste_bracketed_input() {
    local saved_buffer=$BUFFER
    local -i saved_cursor=$CURSOR
    BUFFER="" CURSOR=0
    zle bracketed-paste
    local content=$BUFFER
    BUFFER=$saved_buffer CURSOR=$saved_cursor
    [[ -n $content ]] || return 0
    _zhm_paste_bracketed "$content"
}

function _zhm_cmd_insert_register() {
    local -i count
    _zhm_count_or_1; count=$REPLY
    _zhm_read_char || return 0
    _zhm_reg_read "$REPLY" || return 0
    _zhm_paste_values cursor $count
}

### Undo ###

function _zhm_cmd_undo() {
    local -i count i
    _zhm_count_or_1; count=$REPLY
    for (( i = 0; i < count; i++ )); do
        _zhm_history_undo || break
    done
}

function _zhm_cmd_redo() {
    local -i count i
    _zhm_count_or_1; count=$REPLY
    for (( i = 0; i < count; i++ )); do
        _zhm_history_redo || break
    done
}

function _zhm_cmd_earlier() {
    local -i count i
    _zhm_count_or_1; count=$REPLY
    for (( i = 0; i < count; i++ )); do
        _zhm_history_earlier 1 || break
    done
}

function _zhm_cmd_later() {
    local -i count i
    _zhm_count_or_1; count=$REPLY
    for (( i = 0; i < count; i++ )); do
        _zhm_history_later 1 || break
    done
}

function _zhm_cmd_commit_undo_checkpoint() {
    _zhm_history_commit
}

### Indentation ###

# Distinct line numbers covered by the selection.
function _zhm_selected_lines() {
    local -A seen
    reply=()
    local -i i l
    for (( i = 1; i <= ${#_zhm_sa}; i++ )); do
        _zhm_line_range ${_zhm_sa[i]} ${_zhm_sh[i]}
        for (( l = _zhm_ra; l <= _zhm_rh; l++ )); do
            if (( ! ${+seen[$l]} )); then
                seen[$l]=1
                reply+=( $l )
            fi
        done
    done
    reply=( ${(on)reply} )
}

function _zhm_indent_unit() {
    if (( _zhm_indent_width == 0 )); then
        REPLY=$'\t'
    else
        REPLY=${(l:$_zhm_indent_width:: :)}
    fi
}

function _zhm_cmd_indent() {
    local -i count l
    _zhm_count_or_1; count=$REPLY
    _zhm_indent_unit
    local unit=$REPLY indent="" k
    for (( k = 0; k < count; k++ )); do indent+=$unit; done
    _zhm_selected_lines
    _zhm_changes_reset
    for l in "${reply[@]}"; do
        local -i ls le
        _zhm_line_start $l; ls=$REPLY
        _zhm_line_next_start $l; le=$REPLY
        local content=${_zhm_text:$ls:$(( le - ls ))}
        [[ $content == [[:space:]]# ]] && continue
        local this=$indent
        if (( _zhm_indent_width > 0 )); then
            _zhm_first_non_whitespace $l
            local -i offset=$(( (REPLY - ls) % _zhm_indent_width ))
            this=${indent:$offset}
        fi
        _zhm_change $ls $ls "$this"
    done
    _zhm_apply_changes
    _zhm_exit_select_mode
}

function _zhm_cmd_unindent() {
    local -i count l width
    _zhm_count_or_1; count=$REPLY
    local -i iw=$(( _zhm_indent_width > 0 ? _zhm_indent_width : ZHM_TAB_WIDTH ))
    local -i target=$(( count * iw ))
    _zhm_selected_lines
    _zhm_changes_reset
    for l in "${reply[@]}"; do
        local -i ls pos=0
        _zhm_line_start $l; ls=$REPLY
        width=0
        while (( ls + pos < _zhm_len )); do
            local c=${_zhm_chars[ls + pos + 1]}
            if [[ $c == ' ' ]]; then
                (( width++ ))
            elif [[ $c == $'\t' ]]; then
                (( width = (width / ZHM_TAB_WIDTH + 1) * ZHM_TAB_WIDTH ))
            else
                break
            fi
            (( pos++ ))
            (( width >= target )) && break
        done
        (( pos > 0 )) && _zhm_change $ls $(( ls + pos )) ""
    done
    _zhm_apply_changes
    _zhm_exit_select_mode
}

### Joining lines ###

function _zhm_join_selections_impl() {
    local -i select_space=$1 i
    local -a cf ct cx
    local -A seen
    for (( i = 1; i <= ${#_zhm_sa}; i++ )); do
        _zhm_line_range ${_zhm_sa[i]} ${_zhm_sh[i]}
        local -i sl=$_zhm_ra el=$_zhm_rh l
        if (( sl == el )); then
            (( el = el + 1 < ${#_zhm_lines} - 1 ? el + 1 : ${#_zhm_lines} - 1 ))
        fi
        for (( l = sl; l < el; l++ )); do
            local -i start end
            _zhm_line_end $l; start=$REPLY
            _zhm_line_start $(( l + 1 )); end=$REPLY
            while (( end < _zhm_len )) && [[ ${_zhm_chars[end + 1]} == (' '|$'\t') ]]; do (( end++ )); done
            local sep=" "
            _zhm_line_end $(( l + 1 ))
            (( end == REPLY )) && sep=""
            local key="$start $end"
            (( ${+seen[$key]} )) && continue
            seen[$key]=1
            cf+=( $start ) ct+=( $end ) cx+=( "$sep" )
        done
    done
    (( ${#cf} )) || return 0
    # Sort the changes by start position.
    local -a order
    for (( i = 1; i <= ${#cf}; i++ )); do order+=( "${cf[i]} $i" ); done
    order=( ${(on)order} )
    _zhm_changes_reset
    local entry
    local -a ranges
    local -i offset=0
    for entry in "${order[@]}"; do
        local -i idx=${entry#* }
        _zhm_change ${cf[idx]} ${ct[idx]} "${cx[idx]}"
        if [[ -n ${cx[idx]} ]]; then
            ranges+=( $(( cf[idx] - offset )) $(( cf[idx] - offset )) )
            (( offset += ct[idx] - cf[idx] - 1 ))
        else
            (( offset += ct[idx] - cf[idx] ))
        fi
    done
    _zhm_apply_changes
    if (( select_space && ${#ranges} )); then
        _zhm_set_selection 1 "${ranges[@]}"
    fi
}

function _zhm_cmd_join_selections() { _zhm_join_selections_impl 0 }
function _zhm_cmd_join_selections_space() { _zhm_join_selections_impl 1 }

### Newlines ###

function _zhm_add_newline_impl() {
    local dir=$1
    local -i count i
    _zhm_count_or_1; count=$REPLY
    local nl=${(pl:$count::\n:)}
    _zhm_changes_reset
    local -A seen
    local -a positions
    for (( i = 1; i <= ${#_zhm_sa}; i++ )); do
        _zhm_line_range ${_zhm_sa[i]} ${_zhm_sh[i]}
        local -i line pos
        if [[ $dir == above ]]; then line=$_zhm_ra; else line=$(( _zhm_rh + 1 )); fi
        if (( line >= ${#_zhm_lines} )); then pos=$_zhm_len; else _zhm_line_start $line; pos=$REPLY; fi
        (( ${+seen[$pos]} )) && continue
        seen[$pos]=1
        _zhm_change $pos $pos "$nl"
    done
    _zhm_apply_changes
}

function _zhm_cmd_add_newline_above() { _zhm_add_newline_impl above }
function _zhm_cmd_add_newline_below() { _zhm_add_newline_impl below }

### Rotating selection contents ###

function _zhm_reorder_contents() {
    local strategy=$1
    local -i n=${#_zhm_sa} by i
    _zhm_selection_fragments
    local -a frags
    frags=( "${reply[@]}" )
    by=$(( _zhm_count > 0 ? (_zhm_count < n ? _zhm_count : n) : 1 ))
    local -a reordered
    local -i pi
    case $strategy in
        (forward)
            reordered=( "${(@)frags[n-by+1,n]}" "${(@)frags[1,n-by]}" )
            (( pi = (_zhm_pi - 1 + n + by) % n + 1 ))
            ;;
        (backward)
            reordered=( "${(@)frags[by+1,n]}" "${(@)frags[1,by]}" )
            (( pi = (_zhm_pi - 1 + n - by) % n + 1 ))
            ;;
        (reverse)
            (( by % 2 == 0 )) && return 0
            reordered=( "${(@Oa)frags}" )
            (( pi = n - _zhm_pi + 1 ))
            ;;
    esac
    _zhm_changes_reset
    for (( i = 1; i <= n; i++ )); do
        local -i a=${_zhm_sa[i]} h=${_zhm_sh[i]}
        _zhm_change $(( a < h ? a : h )) $(( a < h ? h : a )) "${reordered[i]}"
    done
    _zhm_pi=$pi
    _zhm_apply_changes
}

function _zhm_cmd_rotate_selection_contents_forward() { _zhm_reorder_contents forward }
function _zhm_cmd_rotate_selection_contents_backward() { _zhm_reorder_contents backward }
function _zhm_cmd_reverse_selection_contents() { _zhm_reorder_contents reverse }

### Surround ###

function _zhm_cmd_surround_add() {
    _zhm_show_info "Surround selections with" "( or )  Parentheses" "{ or }  Curly braces" "< or >  Angled brackets" "[ or ]  Square brackets" "        ... or any character"
    _zhm_read_char
    local -i ok=$?
    zle -M ""
    (( ok == 0 )) || return 0
    local open close
    if [[ $REPLY == $'\n' ]]; then
        open=$'\n' close=$'\n'
    else
        _zhm_get_pair "$REPLY"
        open=$REPLY close=$REPLY2
    fi
    _zhm_changes_reset
    local -a ranges
    local -i i offs=0
    for (( i = 1; i <= ${#_zhm_sa}; i++ )); do
        local -i a=${_zhm_sa[i]} h=${_zhm_sh[i]}
        local -i from=$(( a < h ? a : h )) to=$(( a < h ? h : a ))
        _zhm_change $from $from "$open"
        _zhm_change $to $to "$close"
        _zhm_with_direction $(( offs + from )) $(( offs + to + 2 )) $(( h >= a ))
        ranges+=( $_zhm_ra $_zhm_rh )
        (( offs += 2 ))
    done
    local -i pi=$_zhm_pi
    _zhm_apply_changes
    _zhm_set_selection $pi "${ranges[@]}"
    _zhm_exit_select_mode
}

# `get_surround_pos`: sets reply to a flat list of open/close positions.
function _zhm_get_surround_pos() {
    local ch=$1
    local -i skip=$2 i
    reply=()
    local -A used
    for (( i = 1; i <= ${#_zhm_sa}; i++ )); do
        local -i a=${_zhm_sa[i]} h=${_zhm_sh[i]}
        if [[ -z $ch ]]; then
            _zhm_find_nth_closest_pairs $a $h $skip || { _zhm_error $_zhm_surround_error; return 1 }
        else
            _zhm_find_nth_pairs_pos "$ch" $a $h surround $skip || { _zhm_error $_zhm_surround_error; return 1 }
        fi
        local -i op=$(( _zhm_ra < _zhm_rh ? _zhm_ra : _zhm_rh )) cp=$(( _zhm_ra < _zhm_rh ? _zhm_rh : _zhm_ra ))
        if (( ${+used[$op]} || ${+used[$cp]} )); then
            _zhm_error "Cursors overlap for a single surround pair range"
            return 1
        fi
        used[$op]=1 used[$cp]=1
        reply+=( $op $cp )
    done
}

function _zhm_surround_read_target() {
    _zhm_read_key
    zle -M ""
    # Enter isn't a character here, unlike for `r` and `ms`.
    [[ $REPLY == $'\r' ]] && return 1
    _zhm_key_char "$REPLY" || return 1
    [[ $REPLY == m ]] && REPLY=""
    return 0
}

function _zhm_cmd_surround_delete() {
    local -i count
    _zhm_count_or_1; count=$REPLY
    _zhm_show_info "Delete surrounding pair of" "m       Nearest matching pair" "( or )  Parentheses" "{ or }  Curly braces" "< or >  Angled brackets" "[ or ]  Square brackets" "        ... or any character"
    _zhm_surround_read_target || return 0
    _zhm_get_surround_pos "$REPLY" $count || return 1
    local -a positions
    positions=( ${(on)reply} )
    _zhm_changes_reset
    local p
    for p in "${positions[@]}"; do
        _zhm_change $p $(( p + 1 )) ""
    done
    _zhm_apply_changes
    _zhm_exit_select_mode
}

function _zhm_cmd_surround_replace() {
    local -i count
    _zhm_count_or_1; count=$REPLY
    _zhm_show_info "Replace surrounding pair of" "m       Nearest matching pair" "( or )  Parentheses" "{ or }  Curly braces" "< or >  Angled brackets" "[ or ]  Square brackets" "        ... or any character"
    _zhm_surround_read_target || return 0
    _zhm_get_surround_pos "$REPLY" $count || return 1
    local -a positions
    positions=( "${reply[@]}" )
    _zhm_selection_serialize
    local saved=$REPLY
    # Show the pair being replaced while waiting for the replacement.
    local -a points
    local p
    for p in "${positions[@]}"; do points+=( $p $p ); done
    _zhm_set_selection $(( (_zhm_pi - 1) * 2 + 1 )) "${points[@]}"
    _zhm_render
    _zhm_show_info "Replace with a pair of" "( or )  Parentheses" "{ or }  Curly braces" "< or >  Angled brackets" "[ or ]  Square brackets" "        ... or any character"
    _zhm_read_key
    zle -M ""
    local key=$REPLY
    _zhm_selection_restore "$saved"
    [[ $key == $'\r' ]] && return 0
    _zhm_key_char "$key" || return 0
    _zhm_get_pair "$REPLY"
    local open=$REPLY close=$REPLY2
    local -a sorted
    local -i i
    for (( i = 1; i <= ${#positions}; i += 2 )); do
        sorted+=( "${positions[i]} o" "${positions[i + 1]} c" )
    done
    sorted=( ${(on)sorted} )
    _zhm_changes_reset
    local entry
    for entry in "${sorted[@]}"; do
        local -i pos=${entry% *}
        if [[ ${entry#* } == o ]]; then
            _zhm_change $pos $(( pos + 1 )) "$open"
        else
            _zhm_change $pos $(( pos + 1 )) "$close"
        fi
    done
    _zhm_apply_changes
    _zhm_exit_select_mode
}

### Comments ###

# Toggle line comments with the shell comment token, as Helix's
# `toggle_line_comments` does.
function _zhm_cmd_toggle_comments() {
    local token=${ZHM_COMMENT_TOKEN:-#}
    local -i tlen=${#token} i l min=-1 margin=1 commented=1 min_next=0
    local -a lines to_change
    local -i nlines=${#_zhm_lines}
    for (( i = 1; i <= ${#_zhm_sa}; i++ )); do
        _zhm_line_range ${_zhm_sa[i]} ${_zhm_sh[i]}
        local -i start=$_zhm_ra end=$(( _zhm_rh + 1 < nlines ? _zhm_rh + 1 : nlines ))
        (( start < min_next )) && start=$min_next
        for (( l = start; l < end; l++ )); do lines+=( $l ); done
        min_next=$end
    done
    for l in "${lines[@]}"; do
        _zhm_first_non_whitespace $l || continue
        local -i ls pos=$REPLY
        _zhm_line_start $l; ls=$REPLY
        (( pos -= ls ))
        (( min < 0 || pos < min )) && min=$pos
        [[ ${_zhm_text:$(( ls + pos )):$tlen} == "$token" ]] || commented=0
        [[ ${_zhm_chars[ls + pos + tlen + 1]} == ' ' ]] || margin=0
        to_change+=( $l )
    done
    _zhm_changes_reset
    for l in "${to_change[@]}"; do
        _zhm_line_start $l
        local -i pos=$(( REPLY + min ))
        if (( commented )); then
            _zhm_change $pos $(( pos + tlen + margin )) ""
        else
            _zhm_change $pos $pos "$token "
        fi
    done
    _zhm_apply_changes
    _zhm_exit_select_mode
}

function _zhm_cmd_toggle_line_comments() { _zhm_cmd_toggle_comments }
function _zhm_cmd_toggle_block_comments() { _zhm_cmd_toggle_comments }

### Increment ###

# `helix_core::increment::integer`. Sets REPLY to the new text.
function _zhm_increment_integer() {
    local text=$1
    local -i amount=$2
    [[ -n $text && $text != _* && $text != *_ ]] || return 1
    local -i radix=10
    case $text in
        (0x*) radix=16 ;;
        (0o*) radix=8 ;;
        (0b*) radix=2 ;;
    esac
    # Separator positions counted from the right.
    local -a seps
    local -i i n=${#text}
    for (( i = 0; i < n; i++ )); do
        [[ ${text[n-i]} == _ ]] && seps+=( $i )
    done
    local word=${text//_/}
    local out
    if (( radix == 10 )); then
        [[ $word == (-|)<-> ]] || return 1
        # Check the value fits in a 64-bit integer.
        local digits=${word#-}
        digits=${digits##0#}
        (( ${#digits} <= 18 )) || return 1
        local -i value=$(( 10#${word#-} ))
        [[ $word == -* ]] && (( value = -value ))
        local -i new=$(( value + amount ))
        local -i len=${#word}
        if (( value < 0 && new >= 0 )); then
            (( len-- ))
        elif (( value >= 0 && new < 0 )); then
            (( len++ ))
        fi
        (( len -= ${#seps} ))
        if [[ $word == 0* || $word == -0* ]]; then
            if (( new < 0 )); then
                out=-${(l:$(( len - 1 ))::0:)$(( -new ))}
            else
                out=${(l:$len::0:)new}
            fi
            # Zero padding only pads, it never truncates.
            local plain=$new
            (( ${#out} < ${#plain} )) && out=$plain
        else
            out=$new
        fi
    else
        local number=${word:2}
        case $radix in
            (16) [[ $number == [[:xdigit:]]## ]] || return 1 ;;
            (8) [[ $number == [0-7]## ]] || return 1 ;;
            (2) [[ $number == [01]## ]] || return 1 ;;
        esac
        (( ${#number} <= 15 )) || return 1
        local -i value=$(( $radix#$number ))
        local -i new=$(( value + amount ))
        (( new < 0 )) && new=0
        local -i len=$(( ${#text} - 2 - ${#seps} ))
        local digits
        case $radix in
            (16)
                local lower=${number//[^a-f]/} upper=${number//[^A-F]/}
                digits=$(( [#16] new ))
                digits=${digits#16\#}
                if (( ${#upper} > ${#lower} )); then digits=${(U)digits}; else digits=${(L)digits}; fi
                out=0x
                ;;
            (8) digits=$(( [#8] new )); digits=${digits#8\#}; out=0o ;;
            (2) digits=$(( [#2] new )); digits=${digits#2\#}; out=0b ;;
        esac
        (( ${#digits} < len )) && digits=${(l:$len::0:)digits}
        out+=$digits
    fi
    # Reinsert separators.
    local idx
    for idx in "${seps[@]}"; do
        if (( idx < ${#out} )); then
            local -i at=$(( ${#out} - idx ))
            (( at > 0 )) && out=${out[1,at]}_${out[at+1,-1]}
        fi
    done
    if (( ${#out} > ${#text} && ${#seps} )); then
        local -i spacing
        if (( ${#seps} >= 2 )); then
            (( spacing = seps[-1] - seps[-2] - 1 ))
        else
            spacing=${seps[1]}
        fi
        local -i prefix=$(( radix == 10 ? 0 : 2 ))
        local first=${out%%_*}
        if [[ $first != $out ]]; then
            local -i index=${#first}
            while (( index - prefix > spacing )); do
                (( index -= spacing ))
                out=${out[1,index]}_${out[index+1,-1]}
            done
        fi
    fi
    REPLY=$out
}

# Dates and times (`helix_core::increment::date_time`), for the common
# numeric formats.
function _zhm_increment_date() {
    local text=$1
    local -i amount=$2
    zmodload -F zsh/datetime b:strftime 2>/dev/null || return 1
    local fmt unit
    case $text in
        ([0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' '[0-9][0-9]:[0-9][0-9]:[0-9][0-9]) fmt='%Y-%m-%d %H:%M:%S' unit=60 ;;
        ([0-9][0-9][0-9][0-9]/[0-9][0-9]/[0-9][0-9]' '[0-9][0-9]:[0-9][0-9]:[0-9][0-9]) fmt='%Y/%m/%d %H:%M:%S' unit=60 ;;
        ([0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' '[0-9][0-9]:[0-9][0-9]) fmt='%Y-%m-%d %H:%M' unit=60 ;;
        ([0-9][0-9][0-9][0-9]/[0-9][0-9]/[0-9][0-9]' '[0-9][0-9]:[0-9][0-9]) fmt='%Y/%m/%d %H:%M' unit=60 ;;
        ([0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) fmt='%Y-%m-%d' unit=86400 ;;
        ([0-9][0-9][0-9][0-9]/[0-9][0-9]/[0-9][0-9]) fmt='%Y/%m/%d' unit=86400 ;;
        ([0-9][0-9]:[0-9][0-9]:[0-9][0-9]) fmt='%H:%M:%S' unit=time ;;
        ([0-9][0-9]:[0-9][0-9]) fmt='%H:%M' unit=time ;;
        (*) return 1 ;;
    esac
    local -i epoch
    if [[ $unit == time ]]; then
        local -i h=${text[1,2]} m=${text[4,5]} s=0
        [[ $fmt == *%S ]] && s=${text[7,8]}
        (( h < 24 && m < 60 && s < 60 )) || return 1
        local -i secs=$(( ((h * 60 + m) * 60 + s + amount * 60) % 86400 ))
        (( secs < 0 )) && (( secs += 86400 ))
        if [[ $fmt == *%S ]]; then
            REPLY=$(printf '%02d:%02d:%02d' $(( secs / 3600 )) $(( secs / 60 % 60 )) $(( secs % 60 )))
        else
            REPLY=$(printf '%02d:%02d' $(( secs / 3600 )) $(( secs / 60 % 60 )))
        fi
        return 0
    fi
    TZ=UTC strftime -r -s epoch "$fmt" "$text" 2>/dev/null || return 1
    # Reject dates that don't round-trip (e.g. 2021-02-30).
    local check
    TZ=UTC strftime -s check "$fmt" $epoch
    [[ $check == "$text" ]] || return 1
    (( epoch += amount * unit ))
    TZ=UTC strftime -s REPLY "$fmt" $epoch
}

function _zhm_increment_impl() {
    local -i sign=$1 amount i by=0
    _zhm_count_or_1
    (( amount = sign * REPLY ))
    [[ $_zhm_register == '#' ]] && by=$sign
    _zhm_changes_reset
    local -a ranges
    local -i diff=0 changed=0
    for (( i = 1; i <= ${#_zhm_sa}; i++ )); do
        local -i a=${_zhm_sa[i]} h=${_zhm_sh[i]}
        local -i from=$(( a < h ? a : h )) to=$(( a < h ? h : a ))
        local frag=${_zhm_text:$from:$(( to - from ))}
        local -i nf=$(( from + diff ))
        if _zhm_increment_integer "$frag" $amount || _zhm_increment_date "$frag" $amount; then
            ranges+=( $nf $(( nf + ${#REPLY} )) )
            (( diff += ${#REPLY} - ${#frag}, changed = 1 ))
            _zhm_change $from $to "$REPLY"
        else
            ranges+=( $nf $(( to + diff )) )
        fi
        (( amount += by ))
    done
    (( changed )) || return 0
    local -i pi=$_zhm_pi
    _zhm_apply_changes
    _zhm_set_selection $pi "${ranges[@]}"
    _zhm_exit_select_mode
}

function _zhm_cmd_increment() { _zhm_increment_impl 1 }
function _zhm_cmd_decrement() { _zhm_increment_impl -1 }

### Shell ###

function _zhm_shell_impl() {
    local cmd=$1 behaviour=$2
    local -i pipe=0 i offset=0
    [[ $behaviour == (replace|ignore) ]] && pipe=1
    local -a changes_from changes_to outputs ranges
    local shared="" have_shared=0
    for (( i = 1; i <= ${#_zhm_sa}; i++ )); do
        local -i a=${_zhm_sa[i]} h=${_zhm_sh[i]}
        local -i from=$(( a < h ? a : h )) to=$(( a < h ? h : a ))
        local input=${_zhm_text:$from:$(( to - from ))} output
        if (( have_shared )); then
            output=$shared
        else
            if ! _zhm_shell_run "$cmd" "$input" $pipe; then
                _zhm_error "$REPLY"
                return 1
            fi
            output=$REPLY
            if [[ $input != *$'\n' && $output == *$'\n' ]]; then
                output=${output%$'\n'}
                output=${output%$'\r'}
            fi
            (( pipe )) || { shared=$output have_shared=1 }
        fi
        local -i cf ct deleted
        case $behaviour in
            (replace) cf=$from ct=$to deleted=$(( to - from )) ;;
            (insert) cf=$from ct=$from deleted=0 ;;
            (append) cf=$to ct=$to deleted=0 ;;
            (*) cf=$from ct=$from deleted=0 ;;
        esac
        local -i anchor=$(( ct + offset - deleted ))
        _zhm_with_direction $anchor $(( anchor + ${#output} )) $(( h >= a ))
        ranges+=( $_zhm_ra $_zhm_rh )
        (( offset += ${#output} - deleted ))
        changes_from+=( $cf ) changes_to+=( $ct ) outputs+=( "$output" )
    done
    [[ $behaviour == ignore ]] && return 0
    _zhm_changes_reset
    for (( i = 1; i <= ${#changes_from}; i++ )); do
        _zhm_change ${changes_from[i]} ${changes_to[i]} "${outputs[i]}"
    done
    local -i pi=$_zhm_pi
    _zhm_apply_changes
    _zhm_set_selection $pi "${ranges[@]}"
}

function _zhm_shell_prompt() {
    local prompt=$1 behaviour=$2
    _zhm_prompt "$prompt" '|' || return 0
    [[ -n $REPLY ]] || return 0
    _zhm_shell_impl "$REPLY" $behaviour
}

function _zhm_cmd_shell_pipe() { _zhm_shell_prompt "pipe:" replace }
function _zhm_cmd_shell_pipe_to() { _zhm_shell_prompt "pipe-to:" ignore }
function _zhm_cmd_shell_insert_output() { _zhm_shell_prompt "insert-output:" insert }
function _zhm_cmd_shell_append_output() { _zhm_shell_prompt "append-output:" append }

function _zhm_cmd_shell_keep_pipe() {
    _zhm_prompt "keep-pipe:" '|' || return 0
    local cmd=$REPLY
    [[ -n $cmd ]] || return 0
    local -a ranges
    local -i i index=0
    for (( i = 1; i <= ${#_zhm_sa}; i++ )); do
        local -i a=${_zhm_sa[i]} h=${_zhm_sh[i]}
        local -i from=$(( a < h ? a : h )) to=$(( a < h ? h : a ))
        if _zhm_shell_run "$cmd" "${_zhm_text:$from:$(( to - from ))}" 1; then
            ranges+=( $a $h )
            (( i >= _zhm_pi && index == 0 )) && index=$(( ${#ranges} / 2 ))
        fi
    done
    if (( ! ${#ranges} )); then
        _zhm_error "No selections remaining"
        return 1
    fi
    (( index )) || index=$(( ${#ranges} / 2 ))
    _zhm_set_selection $index "${ranges[@]}"
}

### Insert mode editing ###

# Auto-pairs, as in `helix_core::auto_pairs` with the default pairs.
typeset -gA _ZHM_AUTO_PAIRS=( '(' ')' '{' '}' '[' ']' "'" "'" '"' '"' '`' '`' )

# Sets REPLY to the open character of the auto pair containing $1, and
# REPLY2 to the close character. Fails if $1 isn't part of a pair.
function _zhm_auto_pair() {
    local ch=$1 open
    (( ZHM_AUTO_PAIRS )) || return 1
    for open in "${(@k)_ZHM_AUTO_PAIRS}"; do
        if [[ $open == "$ch" || ${_ZHM_AUTO_PAIRS[$open]} == "$ch" ]]; then
            REPLY=$open REPLY2=${_ZHM_AUTO_PAIRS[$open]}
            return 0
        fi
    done
    return 1
}

function _zhm_range_is_single_grapheme() {
    local -i a=$1 h=$2
    (( (a > h ? a - h : h - a) == 1 ))
}

# `get_next_range` from auto_pairs.
function _zhm_autopair_next_range() {
    local -i a=$1 h=$2 inserted=$3 single=0
    if (( h == _zhm_len && a == _zhm_len )); then
        _zhm_ra=$(( a + 1 )) _zhm_rh=$(( h + 1 ))
        return
    fi
    _zhm_range_is_single_grapheme $a $h && single=1
    if (( inserted == 0 )); then
        local -i ea
        if (( single )); then
            (( ea = a < _zhm_len ? a + 1 : _zhm_len ))
        else
            ea=$a
        fi
        _zhm_ra=$ea
        (( _zhm_rh = h < _zhm_len ? h + 1 : _zhm_len ))
        return
    fi
    if (( inserted == 1 )); then
        if (( single || h < a )); then
            _zhm_ra=$(( a + 1 ))
        else
            _zhm_ra=$a
        fi
        _zhm_rh=$(( h + 1 ))
        return
    fi
    local -i eh
    if (( h == 0 || h < a )); then
        eh=$(( h + 1 ))
    else
        eh=$(( (h > 0 ? h - 1 : 0) + inserted ))
    fi
    local -i len=$(( a > h ? a - h : h - a )) ea
    if (( len == 0 )); then
        ea=$eh
    elif (( len == 1 && h >= a )); then
        ea=$(( eh - 1 ))
    elif (( len == 1 )); then
        ea=$(( eh + 1 ))
    elif (( h >= a )); then
        if (( single )); then ea=$(( h - 1 + 1 )); else ea=$a; fi
    else
        if (( single )); then ea=$(( a - 1 + inserted )); else ea=$(( a + inserted )); fi
    fi
    _zhm_ra=$ea _zhm_rh=$eh
}

# Auto-pair hook for inserting $3 into range ($1, $2). On success sets
# _zhm_hook_from/_zhm_hook_to/_zhm_hook_text to the change and
# _zhm_ra/_zhm_rh to the new range.
typeset -gi _zhm_hook_from _zhm_hook_to
typeset -g _zhm_hook_text
function _zhm_autopair_insert_hook() {
    local -i a=$1 h=$2 cursor
    local ch=$3
    _zhm_cursor $a $h; cursor=$REPLY
    local next=${_zhm_chars[cursor + 1]}
    (( cursor >= _zhm_len )) && next=""
    local prev=""
    (( cursor > 0 )) && prev=${_zhm_chars[cursor]}
    if _zhm_auto_pair "$ch"; then
        local open=$REPLY close=$REPLY2
        if [[ $open == "$close" ]]; then
            # Same open and close character (quotes).
            if [[ -n $next && $next == "$open" ]]; then
                _zhm_hook_from=$cursor _zhm_hook_to=$cursor _zhm_hook_text=""
                _zhm_autopair_next_range $a $h 0
                return 0
            fi
            [[ -n $next && $next == [[:alnum:]] ]] && return 1
            [[ -n $prev && $prev == [[:alnum:]] ]] && return 1
            _zhm_hook_from=$cursor _zhm_hook_to=$cursor _zhm_hook_text=$open$close
            _zhm_autopair_next_range $a $h 2
            return 0
        elif [[ $ch == "$open" ]]; then
            [[ -n $next && $next == [[:alnum:]] ]] && return 1
            _zhm_hook_from=$cursor _zhm_hook_to=$cursor _zhm_hook_text=$open$close
            _zhm_autopair_next_range $a $h 2
            return 0
        else
            [[ $next == "$close" ]] || return 1
            _zhm_hook_from=$cursor _zhm_hook_to=$cursor _zhm_hook_text=""
            _zhm_autopair_next_range $a $h 0
            return 0
        fi
    elif [[ $ch == [[:space:]] ]] && (( ZHM_AUTO_PAIRS )); then
        # Inserting whitespace between a pair inserts it on both sides.
        [[ -n $next && -n $prev ]] || return 1
        _zhm_auto_pair "$next" || return 1
        [[ $REPLY == "$prev" && $REPLY2 == "$next" ]] || return 1
        [[ $next == "$ch" ]] && return 1
        _zhm_hook_from=$cursor _zhm_hook_to=$cursor _zhm_hook_text=$ch$ch
        _zhm_autopair_next_range $a $h 2
        return 0
    fi
    return 1
}

# `insert::insert_char` for character $1 (`change_by_and_with_selection`).
function _zhm_insert_char() {
    local ch=$1
    local -i i offset=0
    local -a ranges
    _zhm_changes_reset
    for (( i = 1; i <= ${#_zhm_sa}; i++ )); do
        local -i a=${_zhm_sa[i]} h=${_zhm_sh[i]} from to
        local text
        if _zhm_autopair_insert_hook $a $h "$ch"; then
            from=$_zhm_hook_from to=$_zhm_hook_to text=$_zhm_hook_text
        else
            _zhm_cursor $a $h
            from=$REPLY to=$REPLY text=$ch
            # Map the range through this single change.
            local -a saved_cf saved_ct saved_cx
            saved_cf=( "${_zhm_cf[@]}" ) saved_ct=( "${_zhm_ct[@]}" ) saved_cx=( "${_zhm_cx[@]}" )
            _zhm_cf=( $from ) _zhm_ct=( $to ) _zhm_cx=( "$text" )
            _zhm_map_range $a $h
            _zhm_cf=( "${saved_cf[@]}" ) _zhm_ct=( "${saved_ct[@]}" ) _zhm_cx=( "${saved_cx[@]}" )
        fi
        ranges+=( $(( _zhm_ra + offset )) $(( _zhm_rh + offset )) )
        (( offset += ${#text} - (to - from) ))
        _zhm_change $from $to "$text"
    done
    local -i pi=$_zhm_pi
    _zhm_apply_changes
    _zhm_set_selection $pi "${ranges[@]}"
}

# Self-insert: work out what was typed by letting zsh insert it into an empty
# scratch buffer (which handles multi-byte input), then insert it at every
# selection.
function _zhm_cmd_insert_typed() {
    local saved_buffer=$BUFFER
    local -i saved_cursor=$CURSOR
    BUFFER="" CURSOR=0
    zle .self-insert
    local typed=$BUFFER
    BUFFER=$saved_buffer CURSOR=$saved_cursor
    local c
    for c in "${(@s::)typed}"; do
        _zhm_insert_char "$c"
    done
}

# Helix inserts the character of unbound Ctrl and Alt keys in insert mode
# (Ctrl-a and Alt-a both insert `a`).
function _zhm_cmd_insert_key_char() {
    _zhm_key_char "$KEYS" || return 0
    _zhm_insert_char "$REPLY"
}

function _zhm_cmd_insert_tab() {
    _zhm_changes_reset
    local -i i
    for (( i = 1; i <= ${#_zhm_sa}; i++ )); do
        _zhm_cursor ${_zhm_sa[i]} ${_zhm_sh[i]}
        local -i cursor=$REPLY
        local indent
        if (( _zhm_indent_width == 0 )); then
            indent=$'\t'
        else
            _zhm_line_of $cursor
            _zhm_line_start $REPLY
            local -i offset=$(( (cursor - REPLY) % _zhm_indent_width ))
            indent=${(l:$(( _zhm_indent_width - offset )):: :)}
        fi
        _zhm_change $cursor $cursor "$indent"
    done
    _zhm_apply_changes
}

function _zhm_cmd_insert_newline() {
    local -a ranges
    local -i i global=0 last=0
    _zhm_changes_reset
    for (( i = 1; i <= ${#_zhm_sa}; i++ )); do
        local -i a=${_zhm_sa[i]} h=${_zhm_sh[i]} pos line ls deleted=0
        _zhm_cursor $a $h; pos=$REPLY
        local prev=" " curr=" "
        (( pos > 0 )) && prev=${_zhm_chars[pos]}
        (( pos < _zhm_len )) && curr=${_zhm_chars[pos + 1]}
        _zhm_line_of $pos; line=$REPLY
        _zhm_line_start $line; ls=$REPLY
        local before=${_zhm_text:$ls:$(( pos - ls ))}
        local -i from to local_offs
        local new_text
        if [[ $before == *[^[:space:]]* ]]; then
            local trimmed=${before%%[[:space:]]#}
            local -i first_trailing=$(( ls + ${#trimmed} ))
            (( first_trailing < last )) && first_trailing=$last
            (( first_trailing > pos )) && first_trailing=$pos
            last=$pos
            _zhm_newline_indent $line
            local indent=$REPLY
            local on_pair=0
            if (( ZHM_AUTO_PAIRS )) && _zhm_auto_pair "$prev" && [[ $REPLY == "$prev" && $REPLY2 == "$curr" ]]; then
                on_pair=1
            fi
            if (( on_pair )); then
                _zhm_indent_unit
                local inner=$indent$REPLY
                new_text=$'\n'$inner
                local_offs=${#new_text}
                new_text+=$'\n'$indent
            else
                new_text=$'\n'$indent
                local_offs=${#new_text}
            fi
            deleted=$(( pos - first_trailing ))
            from=$first_trailing to=$pos
            (( local_offs -= deleted ))
        else
            new_text=$'\n'
            from=$ls to=$ls
            local_offs=1
        fi
        _zhm_cursor $a $h
        if (( REPLY > a )); then
            ranges+=( $(( a + global )) $(( h + local_offs + global )) )
        else
            ranges+=( $(( a + local_offs + global )) $(( h + local_offs + global )) )
        fi
        (( global += ${#new_text} - deleted ))
        _zhm_change $from $to "$new_text"
    done
    local -i pi=$_zhm_pi
    _zhm_apply_changes
    _zhm_set_selection $pi "${ranges[@]}"
}

# `delete_by_selection_insert_mode`: the function $1 is called with each
# range and must set _zhm_ra/_zhm_rh to the deletion range. $2 is the
# direction (1 = forward).
function _zhm_delete_insert_mode() {
    local fn=$1
    local -i forward=$2 i last=0 eof=0
    local -a ranges
    _zhm_changes_reset
    for (( i = 1; i <= ${#_zhm_sa}; i++ )); do
        local -i a=${_zhm_sa[i]} h=${_zhm_sh[i]}
        $fn $a $h
        local -i start=$_zhm_ra end=$_zhm_rh
        if (( forward )); then
            if (( h > a )); then
                (( end == _zhm_len )) && eof=1
                (( h++ ))
            fi
            ranges+=( $a $h )
        fi
        (( last > end )) && continue
        (( last > start )) && start=$last
        _zhm_change $start $end ""
        last=$end
    done
    if (( eof )); then
        _zhm_change $_zhm_len $_zhm_len $'\n'
    fi
    if (( forward )); then
        local -i pi=$_zhm_pi
        _zhm_sa=() _zhm_sh=()
        for (( i = 1; i <= ${#ranges}; i += 2 )); do
            _zhm_sa+=( ${ranges[i]} ) _zhm_sh+=( ${ranges[i + 1]} )
        done
        _zhm_scol=( "${(@)_zhm_sa/*/-1}" )
        _zhm_pi=$pi
    fi
    _zhm_apply_changes
}

function _zhm_d_char_forward() {
    local -i count
    _zhm_count_or_1; count=$REPLY
    _zhm_cursor $1 $2
    _zhm_ra=$REPLY
    (( _zhm_rh = REPLY + count > _zhm_len ? _zhm_len : REPLY + count ))
}

function _zhm_cmd_delete_char_forward() {
    _zhm_delete_insert_mode _zhm_d_char_forward 1
}

function _zhm_d_word_backward() {
    local -i a=$1 h=$2 count cursor
    _zhm_count_or_1; count=$REPLY
    _zhm_word_move prev_word_start $a $h $count
    local -i anchor=$(( _zhm_ra < _zhm_rh ? _zhm_ra : _zhm_rh ))
    _zhm_cursor $a $h; cursor=$REPLY
    # `exclude_cursor`
    local -i na=$anchor nh=$cursor
    local -i rto=$(( na > nh ? na : nh )) cto=$(( a > h ? a : h ))
    if (( rto == cto && _zhm_len != cto )); then
        local -i rfrom=$(( na < nh ? na : nh ))
        na=$rfrom nh=$(( cto > 0 ? cto - 1 : 0 ))
    fi
    _zhm_ra=$(( na < nh ? na : nh )) _zhm_rh=$(( na < nh ? nh : na ))
}

function _zhm_cmd_delete_word_backward() {
    _zhm_delete_insert_mode _zhm_d_word_backward 0
}

function _zhm_d_word_forward() {
    local -i a=$1 h=$2 count cursor
    _zhm_count_or_1; count=$REPLY
    _zhm_word_move next_word_end $a $h $count
    local -i to=$(( _zhm_ra > _zhm_rh ? _zhm_ra : _zhm_rh ))
    _zhm_cursor $a $h; cursor=$REPLY
    _zhm_ra=$cursor _zhm_rh=$to
}

function _zhm_cmd_delete_word_forward() {
    _zhm_delete_insert_mode _zhm_d_word_forward 1
}

function _zhm_d_kill_to_line_start() {
    local -i a=$1 h=$2 line first anchor head
    _zhm_cursor $a $h; anchor=$REPLY
    _zhm_line_of $anchor; line=$REPLY
    _zhm_line_start $line; first=$REPLY
    if (( anchor == first && line != 0 )); then
        _zhm_line_end $(( line - 1 )); head=$REPLY
    elif _zhm_first_non_whitespace $line && (( REPLY < anchor )); then
        head=$REPLY
    else
        head=$first
    fi
    _zhm_ra=$(( head < anchor ? head : anchor )) _zhm_rh=$(( head < anchor ? anchor : head ))
}

function _zhm_cmd_kill_to_line_start() {
    _zhm_delete_insert_mode _zhm_d_kill_to_line_start 0
}

function _zhm_d_kill_to_line_end() {
    local -i a=$1 h=$2 line le pos
    _zhm_cursor $a $h; pos=$REPLY
    _zhm_line_of $pos; line=$REPLY
    _zhm_line_end $line; le=$REPLY
    if (( pos == le )); then
        _zhm_line_next_start $line
        _zhm_ra=$pos _zhm_rh=$REPLY
    else
        _zhm_ra=$pos _zhm_rh=$le
    fi
}

function _zhm_cmd_kill_to_line_end() {
    _zhm_delete_insert_mode _zhm_d_kill_to_line_end 1
}

# `dedent` from `delete_char_backward`.
function _zhm_dedent() {
    local -i a=$1 h=$2 pos ls
    _zhm_cursor $a $h; pos=$REPLY
    _zhm_line_of $pos
    _zhm_line_start $REPLY; ls=$REPLY
    local frag=${_zhm_text:$ls:$(( pos - ls ))}
    [[ -n $frag && $frag == [\ $'\t']## ]] || return 1
    if [[ ${_zhm_chars[pos]} == $'\t' ]]; then
        _zhm_ra=$(( pos - 1 )) _zhm_rh=$pos
        return 0
    fi
    local -i width=0 iw=$(( _zhm_indent_width > 0 ? _zhm_indent_width : ZHM_TAB_WIDTH ))
    local c
    for c in "${(@s::)frag}"; do
        if [[ $c == $'\t' ]]; then (( width += ZHM_TAB_WIDTH )); else (( width++ )); fi
    done
    local -i drop=$(( width % iw ))
    (( drop == 0 )) && drop=$iw
    local -i start=$pos k
    for (( k = 0; k < drop; k++ )); do
        [[ ${_zhm_chars[start]} == ' ' ]] || break
        (( start-- ))
    done
    _zhm_ra=$start _zhm_rh=$pos
}

# Auto-pair delete hook: sets the deletion and the new range.
typeset -gi _zhm_del_ra _zhm_del_rh
function _zhm_autopair_delete_hook() {
    local -i a=$1 h=$2 cursor
    (( ZHM_AUTO_PAIRS )) || return 1
    _zhm_cursor $a $h; cursor=$REPLY
    (( cursor < _zhm_len && cursor > 0 )) || return 1
    local cur=${_zhm_chars[cursor + 1]} prev=${_zhm_chars[cursor]}
    local -i matched=0
    if (( _zhm_len >= 4 )) && [[ $prev == [[:space:]] && $cur == [[:space:]] ]] && (( cursor >= 2 && cursor + 1 < _zhm_len )); then
        local sp=${_zhm_chars[cursor - 1]} sn=${_zhm_chars[cursor + 2]}
        if _zhm_auto_pair "$sp" && [[ $REPLY == "$sp" && $REPLY2 == "$sn" ]]; then
            matched=1
        fi
    fi
    if (( ! matched )); then
        _zhm_auto_pair "$cur" || return 1
        [[ $REPLY == "$prev" && $REPLY2 == "$cur" ]] || return 1
    fi
    # `handle_delete`
    local -i end_next=$(( cursor + 1 )) end_prev=$(( cursor - 1 ))
    local -i size=$(( end_next - end_prev ))
    local -i next_head=$(( (h < _zhm_len ? h + 1 : _zhm_len) - size ))
    local -i next_anchor single=0
    _zhm_range_is_single_grapheme $a $h && single=1
    if (( h >= a && single )); then
        next_anchor=$(( a - (end_next - cursor) ))
    elif (( single )); then
        next_anchor=$(( a - (cursor - end_prev) ))
    elif (( h >= a )); then
        next_anchor=$a
    else
        next_anchor=$(( a - size ))
    fi
    _zhm_ra=$end_prev _zhm_rh=$end_next
    _zhm_del_ra=$next_anchor _zhm_del_rh=$next_head
    return 0
}

function _zhm_cmd_delete_char_backward() {
    local -i count i offset=0 last=0
    _zhm_count_or_1; count=$REPLY
    local -a ranges
    _zhm_changes_reset
    for (( i = 1; i <= ${#_zhm_sa}; i++ )); do
        local -i a=${_zhm_sa[i]} h=${_zhm_sh[i]} pos from to have_range=0
        _zhm_cursor $a $h; pos=$REPLY
        if (( pos == 0 )); then
            from=0 to=0
        elif _zhm_dedent $a $h; then
            from=$_zhm_ra to=$_zhm_rh
        elif _zhm_autopair_delete_hook $a $h; then
            from=$_zhm_ra to=$_zhm_rh have_range=1
        else
            (( from = pos - count < 0 ? 0 : pos - count, to = pos ))
        fi
        local -i size
        if (( last > from )); then (( size = to - last )); else (( size = to - from )); fi
        if (( have_range )); then
            _zhm_ra=$_zhm_del_ra _zhm_rh=$_zhm_del_rh
        else
            local -a scf sct scx
            scf=( "${_zhm_cf[@]}" ) sct=( "${_zhm_ct[@]}" ) scx=( "${_zhm_cx[@]}" )
            _zhm_cf=( $from ) _zhm_ct=( $to ) _zhm_cx=( "" )
            _zhm_map_range $a $h
            _zhm_cf=( "${scf[@]}" ) _zhm_ct=( "${sct[@]}" ) _zhm_cx=( "${scx[@]}" )
        fi
        ranges+=( $(( _zhm_ra - offset < 0 ? 0 : _zhm_ra - offset )) $(( _zhm_rh - offset < 0 ? 0 : _zhm_rh - offset )) )
        (( offset += size ))
        if (( last > from )); then
            (( to > last )) && _zhm_change $last $to ""
        else
            _zhm_change $from $to ""
        fi
        (( to > last )) && last=$to
    done
    local -i pi=$_zhm_pi
    _zhm_apply_changes
    _zhm_set_selection $pi "${ranges[@]}"
}
