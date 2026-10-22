# Movement and selection commands, ported from `helix_term::commands`.

function _zhm_extend_flag() {
    if [[ $_zhm_mode == select ]]; then REPLY=1; else REPLY=0; fi
}

### Horizontal movement ###

function _zhm_t_move_horizontally() {
    local -i anchor=$1 head=$2 forward=$3 count=$4 extend=$5 pos
    _zhm_cursor $anchor $head; pos=$REPLY
    if (( forward )); then
        (( pos = pos + count > _zhm_len ? _zhm_len : pos + count ))
    else
        (( pos = pos - count < 0 ? 0 : pos - count ))
    fi
    _zhm_put_cursor $anchor $head $pos $extend
}

function _zhm_cmd_move_char_left() { _zhm_count_or_1; _zhm_transform _zhm_t_move_horizontally 0 $REPLY 0 }
function _zhm_cmd_move_char_right() { _zhm_count_or_1; _zhm_transform _zhm_t_move_horizontally 1 $REPLY 0 }
function _zhm_cmd_extend_char_left() { _zhm_count_or_1; _zhm_transform _zhm_t_move_horizontally 0 $REPLY 1 }
function _zhm_cmd_extend_char_right() { _zhm_count_or_1; _zhm_transform _zhm_t_move_horizontally 1 $REPLY 1 }

### Vertical movement ###

function _zhm_move_vertical_impl() {
    local -i forward=$1 extend=$2 count i
    _zhm_count_or_1; count=$REPLY
    local -a sa=() sh=() sc=()
    for (( i = 1; i <= ${#_zhm_sa}; i++ )); do
        _zhm_move_vertically $forward ${_zhm_sa[i]} ${_zhm_sh[i]} ${_zhm_scol[i]:--1} $count $extend
        sa+=( $_zhm_ra ) sh+=( $_zhm_rh ) sc+=( $_zhm_rcol )
    done
    _zhm_sa=( "${sa[@]}" ) _zhm_sh=( "${sh[@]}" )
    _zhm_ensure_invariants
    # Restore sticky columns, which normalisation may have reordered or reset.
    if (( ${#_zhm_sa} == ${#sc} )); then
        _zhm_scol=( "${sc[@]}" )
    fi
}

# Whether the primary cursor is on the first (or last) line, in which case
# moving further up (or down) navigates the shell history instead.
function _zhm_at_history_edge() {
    local -i forward=$1
    (( ${#_zhm_sa} == 1 )) || return 1
    _zhm_primary_cursor
    _zhm_line_of $REPLY
    if (( forward )); then
        (( REPLY >= ${#_zhm_lines} - 2 ))
    else
        (( REPLY == 0 ))
    fi
}

function _zhm_history_navigate() {
    local -i forward=$1 col
    (( ZHM_HISTORY_NAVIGATION )) || return 1
    _zhm_primary_cursor
    _zhm_visual_col $REPLY; col=$REPLY
    (( ${_zhm_scol[_zhm_pi]:--1} >= 0 )) && col=${_zhm_scol[_zhm_pi]}
    local widget=""
    if (( forward )); then
        widget=${ZHM_HISTORY_NEXT_WIDGET:-down-history}
    else
        widget=${ZHM_HISTORY_PREV_WIDGET:-up-history}
    fi
    zle $widget || return 1
    _zhm_load_text
    _zhm_detect_indent
    _zhm_history_reset
    local -i line=0
    if (( forward )); then
        line=0
    else
        line=$(( ${#_zhm_lines} > 1 ? ${#_zhm_lines} - 2 : 0 ))
    fi
    if [[ $_zhm_mode == insert ]]; then
        _zhm_set_single ${#BUFFER} ${#BUFFER}
    else
        _zhm_pos_at_visual_col $line $col
        _zhm_set_single $REPLY $REPLY
        _zhm_scol=( $col )
    fi
    return 0
}

function _zhm_cmd_move_visual_line_up() {
    if _zhm_at_history_edge 0 && _zhm_history_navigate 0; then return; fi
    _zhm_move_vertical_impl 0 0
}
function _zhm_cmd_move_visual_line_down() {
    if _zhm_at_history_edge 1 && _zhm_history_navigate 1; then return; fi
    _zhm_move_vertical_impl 1 0
}
function _zhm_cmd_extend_visual_line_up() { _zhm_move_vertical_impl 0 1 }
function _zhm_cmd_extend_visual_line_down() { _zhm_move_vertical_impl 1 1 }
function _zhm_cmd_move_line_up() { _zhm_move_vertical_impl 0 0 }
function _zhm_cmd_move_line_down() { _zhm_move_vertical_impl 1 0 }
function _zhm_cmd_extend_line_up() { _zhm_move_vertical_impl 0 1 }
function _zhm_cmd_extend_line_down() { _zhm_move_vertical_impl 1 1 }

function _zhm_cmd_history_prev() {
    _zhm_history_navigate 0
}
function _zhm_cmd_history_next() {
    _zhm_history_navigate 1
}

# Page movement. The whole command line is visible, so a "page" is the
# terminal height.
function _zhm_page_impl() {
    local -i forward=$1 divisor=$2 lines
    (( lines = (LINES > 2 ? LINES - 2 : 1) / divisor ))
    (( lines < 1 )) && lines=1
    local -i saved=$_zhm_count
    _zhm_count=$(( lines * (_zhm_count > 0 ? _zhm_count : 1) ))
    _zhm_extend_flag
    _zhm_move_vertical_impl $forward $REPLY
    _zhm_count=$saved
}
function _zhm_cmd_page_up() { _zhm_page_impl 0 1 }
function _zhm_cmd_page_down() { _zhm_page_impl 1 1 }
function _zhm_cmd_page_cursor_half_up() { _zhm_page_impl 0 2 }
function _zhm_cmd_page_cursor_half_down() { _zhm_page_impl 1 2 }

### Line start/end ###

function _zhm_t_goto_line_end() {
    local -i anchor=$1 head=$2 extend=$3 newline=$4 line ls pos
    _zhm_cursor $anchor $head
    _zhm_line_of $REPLY; line=$REPLY
    _zhm_line_start $line; ls=$REPLY
    _zhm_line_end $line; pos=$REPLY
    if (( ! newline )); then
        (( pos = pos - 1 > ls ? pos - 1 : ls ))
    fi
    _zhm_put_cursor $anchor $head $pos $extend
}

function _zhm_t_goto_line_start() {
    local -i anchor=$1 head=$2 extend=$3
    _zhm_cursor $anchor $head
    _zhm_line_of $REPLY
    _zhm_line_start $REPLY
    _zhm_put_cursor $anchor $head $REPLY $extend
}

# Position of the first non-whitespace character on line $1, or fails if the
# line has none.
function _zhm_first_non_whitespace() {
    local -i line=$1 pos end
    _zhm_line_start $line; pos=$REPLY
    _zhm_line_next_start $line; end=$REPLY
    while (( pos < end )); do
        _zhm_is_whitespace "${_zhm_chars[pos + 1]}" || { REPLY=$pos; return 0 }
        (( pos++ ))
    done
    return 1
}

function _zhm_t_goto_first_nonwhitespace() {
    local -i anchor=$1 head=$2 extend=$3
    _zhm_cursor $anchor $head
    _zhm_line_of $REPLY
    if _zhm_first_non_whitespace $REPLY; then
        _zhm_put_cursor $anchor $head $REPLY $extend
    fi
}

function _zhm_cmd_goto_line_end() { _zhm_extend_flag; _zhm_transform _zhm_t_goto_line_end $REPLY 0 }
function _zhm_cmd_extend_to_line_end() { _zhm_transform _zhm_t_goto_line_end 1 0 }
function _zhm_cmd_goto_line_end_newline() { _zhm_extend_flag; _zhm_transform _zhm_t_goto_line_end $REPLY 1 }
function _zhm_cmd_extend_to_line_end_newline() { _zhm_transform _zhm_t_goto_line_end 1 1 }
function _zhm_cmd_goto_line_start() { _zhm_extend_flag; _zhm_transform _zhm_t_goto_line_start $REPLY }
function _zhm_cmd_extend_to_line_start() { _zhm_transform _zhm_t_goto_line_start 1 }
function _zhm_cmd_goto_first_nonwhitespace() { _zhm_extend_flag; _zhm_transform _zhm_t_goto_first_nonwhitespace $REPLY }
function _zhm_cmd_extend_to_first_nonwhitespace() { _zhm_transform _zhm_t_goto_first_nonwhitespace 1 }

### Word movement ###

function _zhm_t_word() {
    _zhm_word_move $3 $1 $2 $4
}

function _zhm_t_extend_word() {
    local -i anchor=$1 head=$2
    _zhm_word_move $3 $anchor $head $4
    _zhm_cursor $_zhm_ra $_zhm_rh
    _zhm_put_cursor $anchor $head $REPLY 1
}

function _zhm_word_cmd() {
    _zhm_count_or_1
    _zhm_transform $1 $2 $REPLY
}

function _zhm_cmd_move_next_word_start() { _zhm_word_cmd _zhm_t_word next_word_start }
function _zhm_cmd_move_prev_word_start() { _zhm_word_cmd _zhm_t_word prev_word_start }
function _zhm_cmd_move_next_word_end() { _zhm_word_cmd _zhm_t_word next_word_end }
function _zhm_cmd_move_prev_word_end() { _zhm_word_cmd _zhm_t_word prev_word_end }
function _zhm_cmd_move_next_long_word_start() { _zhm_word_cmd _zhm_t_word next_long_word_start }
function _zhm_cmd_move_prev_long_word_start() { _zhm_word_cmd _zhm_t_word prev_long_word_start }
function _zhm_cmd_move_next_long_word_end() { _zhm_word_cmd _zhm_t_word next_long_word_end }
function _zhm_cmd_move_prev_long_word_end() { _zhm_word_cmd _zhm_t_word prev_long_word_end }
function _zhm_cmd_move_next_sub_word_start() { _zhm_word_cmd _zhm_t_word next_sub_word_start }
function _zhm_cmd_move_prev_sub_word_start() { _zhm_word_cmd _zhm_t_word prev_sub_word_start }
function _zhm_cmd_move_next_sub_word_end() { _zhm_word_cmd _zhm_t_word next_sub_word_end }
function _zhm_cmd_move_prev_sub_word_end() { _zhm_word_cmd _zhm_t_word prev_sub_word_end }
function _zhm_cmd_extend_next_word_start() { _zhm_word_cmd _zhm_t_extend_word next_word_start }
function _zhm_cmd_extend_prev_word_start() { _zhm_word_cmd _zhm_t_extend_word prev_word_start }
function _zhm_cmd_extend_next_word_end() { _zhm_word_cmd _zhm_t_extend_word next_word_end }
function _zhm_cmd_extend_prev_word_end() { _zhm_word_cmd _zhm_t_extend_word prev_word_end }
function _zhm_cmd_extend_next_long_word_start() { _zhm_word_cmd _zhm_t_extend_word next_long_word_start }
function _zhm_cmd_extend_prev_long_word_start() { _zhm_word_cmd _zhm_t_extend_word prev_long_word_start }
function _zhm_cmd_extend_next_long_word_end() { _zhm_word_cmd _zhm_t_extend_word next_long_word_end }
function _zhm_cmd_extend_prev_long_word_end() { _zhm_word_cmd _zhm_t_extend_word prev_long_word_end }
function _zhm_cmd_extend_next_sub_word_start() { _zhm_word_cmd _zhm_t_extend_word next_sub_word_start }
function _zhm_cmd_extend_prev_sub_word_start() { _zhm_word_cmd _zhm_t_extend_word prev_sub_word_start }
function _zhm_cmd_extend_next_sub_word_end() { _zhm_word_cmd _zhm_t_extend_word next_sub_word_end }
function _zhm_cmd_extend_prev_sub_word_end() { _zhm_word_cmd _zhm_t_extend_word prev_sub_word_end }

### Find character ###

# `find_char_line_ending_motion`.
function _zhm_t_find_line_ending() {
    local -i anchor=$1 head=$2 count=$3 forward=$4 inclusive=$5 extend=$6
    local -i ca ch line pos nlines=${#_zhm_lines}
    _zhm_cursor $anchor $head; ca=$REPLY
    (( ch = ca < _zhm_len ? ca + 1 : _zhm_len ))
    _zhm_line_of $ca; line=$REPLY
    if (( forward )); then
        _zhm_line_end $line
        local -i line_end=$REPLY on_edge
        if (( inclusive )); then
            (( on_edge = line_end == ca ))
        else
            (( on_edge = line_end == ch || line_end == ca ))
        fi
        local -i target=$(( line + count - 1 + on_edge ))
        (( target >= nlines - 1 )) && return 0
        _zhm_line_end $target
        (( pos = REPLY - !inclusive ))
    else
        if (( inclusive )); then
            local -i target=$(( line - count ))
            (( target < 0 )) && return 0
            _zhm_line_end $target; pos=$REPLY
        else
            _zhm_line_start $line
            local -i on_edge=$(( REPLY == ca ))
            local -i target=$(( line - count + 1 - on_edge ))
            (( target <= 0 )) && return 0
            _zhm_line_start $target; pos=$REPLY
        fi
    fi
    if (( extend )); then
        _zhm_put_cursor $anchor $head $pos 1
    else
        _zhm_put_cursor $ca $ca $pos 1
    fi
}

function _zhm_t_find_char() {
    local -i anchor=$1 head=$2 count=$4 forward=$5 inclusive=$6 extend=$7
    local ch=$3
    local -i ca=0 chd=0 start=0 pos=0
    _zhm_cursor $anchor $head; ca=$REPLY
    (( chd = ca < _zhm_len ? ca + 1 : _zhm_len ))
    if (( inclusive && forward )); then
        start=$chd
    elif (( inclusive )); then
        start=$ca
    elif (( forward )); then
        start=$(( chd + 1 ))
    else
        start=$(( ca > 0 ? ca - 1 : 0 ))
    fi
    (( start > _zhm_len )) && return 0
    _zhm_find_nth_char $count "$ch" $start $forward || return 0
    pos=$REPLY
    if (( ! inclusive )); then
        (( pos = forward ? pos - 1 : pos + 1 ))
    fi
    if (( extend )); then
        _zhm_put_cursor $anchor $head $pos 1
    else
        _zhm_put_cursor $ca $ca $pos 1
    fi
}

# Applies a find motion. $1: character, $2: count, $3: forward, $4: inclusive,
# $5: extend.
function _zhm_find_char_apply() {
    if [[ $1 == $'\n' ]]; then
        _zhm_transform _zhm_t_find_line_ending $2 $3 $4 $5
    else
        _zhm_transform _zhm_t_find_char "$1" $2 $3 $4 $5
    fi
}

function _zhm_find_char() {
    local -i forward=$1 inclusive=$2 extend=$3 count
    _zhm_count_or_1; count=$REPLY
    _zhm_read_char || return 0
    _zhm_apply_motion "_zhm_find_char_apply ${(q)REPLY} $count $forward $inclusive $extend"
}

function _zhm_cmd_find_till_char() { _zhm_extend_flag; _zhm_find_char 1 0 $REPLY }
function _zhm_cmd_find_next_char() { _zhm_extend_flag; _zhm_find_char 1 1 $REPLY }
function _zhm_cmd_till_prev_char() { _zhm_extend_flag; _zhm_find_char 0 0 $REPLY }
function _zhm_cmd_find_prev_char() { _zhm_extend_flag; _zhm_find_char 0 1 $REPLY }
function _zhm_cmd_extend_till_char() { _zhm_find_char 1 0 1 }
function _zhm_cmd_extend_next_char() { _zhm_find_char 1 1 1 }
function _zhm_cmd_extend_till_prev_char() { _zhm_find_char 0 0 1 }
function _zhm_cmd_extend_prev_char() { _zhm_find_char 0 1 1 }

# Repeat the last find motion (with its original count) `count` times.
function _zhm_cmd_repeat_last_motion() {
    [[ -n $_zhm_last_motion ]] || return 0
    local -i count=0 i=0
    _zhm_count_or_1; count=$REPLY
    for (( i = 0; i < count; i++ )); do
        eval "$_zhm_last_motion"
    done
}

### Goto ###

function _zhm_t_put() {
    _zhm_put_cursor $1 $2 $3 $4
}

function _zhm_goto_line_impl() {
    local -i extend=$1 line max
    (( _zhm_count > 0 )) || return 0
    _zhm_save_jump
    # Don't jump to the empty line after the final newline.
    (( max = ${#_zhm_lines} - 2 ))
    (( max < 0 )) && max=0
    (( line = _zhm_count - 1 < max ? _zhm_count - 1 : max ))
    _zhm_line_start $line
    _zhm_transform _zhm_t_put $REPLY $extend
}

function _zhm_cmd_goto_line() { _zhm_goto_line_impl 0 }
function _zhm_cmd_extend_to_line() { _zhm_goto_line_impl 1 }

function _zhm_goto_file_start_impl() {
    local -i extend=$1
    if (( _zhm_count > 0 )); then
        _zhm_goto_line_impl $extend
        return
    fi
    _zhm_save_jump
    _zhm_transform _zhm_t_put 0 $extend
}

function _zhm_cmd_goto_file_start() { _zhm_goto_file_start_impl 0 }
function _zhm_cmd_extend_to_file_start() { _zhm_goto_file_start_impl 1 }

function _zhm_goto_last_line_impl() {
    local -i extend=$1 line=$(( ${#_zhm_lines} - 2 ))
    (( line < 0 )) && line=0
    _zhm_line_start $line
    _zhm_save_jump
    _zhm_transform _zhm_t_put $REPLY $extend
}

function _zhm_cmd_goto_last_line() { _zhm_goto_last_line_impl 0 }
function _zhm_cmd_extend_to_last_line() { _zhm_goto_last_line_impl 1 }

function _zhm_cmd_goto_file_end() { _zhm_save_jump; _zhm_transform _zhm_t_put $_zhm_len 0 }
function _zhm_cmd_extend_to_file_end() { _zhm_save_jump; _zhm_transform _zhm_t_put $_zhm_len 1 }

function _zhm_t_goto_column() {
    local -i anchor=$1 head=$2 count=$3 extend=$4 line ls le pos
    _zhm_cursor $anchor $head
    _zhm_line_of $REPLY; line=$REPLY
    _zhm_line_start $line; ls=$REPLY
    _zhm_line_end $line; le=$REPLY
    (( pos = ls + count - 1 ))
    (( pos > _zhm_len )) && pos=$_zhm_len
    (( pos > le )) && pos=$le
    _zhm_put_cursor $anchor $head $pos $extend
}

function _zhm_cmd_goto_column() { _zhm_count_or_1; _zhm_save_jump; _zhm_transform _zhm_t_goto_column $REPLY 0 }
function _zhm_cmd_extend_to_column() { _zhm_count_or_1; _zhm_save_jump; _zhm_transform _zhm_t_goto_column $REPLY 1 }

# The whole buffer is always on screen, so the window is the whole buffer.
function _zhm_goto_window_impl() {
    local align=$1 line last=$(( ${#_zhm_lines} - 2 ))
    (( last < 0 )) && last=0
    local -i offset=$(( _zhm_count > 0 ? _zhm_count - 1 : 0 ))
    case $align in
        (top) line=$(( offset < last ? offset : last )) ;;
        (center) line=$(( last / 2 )) ;;
        (bottom) line=$(( last - offset > 0 ? last - offset : 0 )) ;;
    esac
    _zhm_line_start $line
    local -i pos=$REPLY
    _zhm_extend_flag
    _zhm_transform _zhm_t_put $pos $REPLY
}
function _zhm_cmd_goto_window_top() { _zhm_goto_window_impl top }
function _zhm_cmd_goto_window_center() { _zhm_goto_window_impl center }
function _zhm_cmd_goto_window_bottom() { _zhm_goto_window_impl bottom }

function _zhm_cmd_goto_last_modification() {
    (( _zhm_last_edit >= 0 )) || return 0
    local -i pos=$(( _zhm_last_edit > _zhm_len ? _zhm_len : _zhm_last_edit ))
    _zhm_extend_flag
    _zhm_save_jump
    _zhm_transform _zhm_t_put $pos $REPLY
}

### Paragraphs ###

function _zhm_t_next_paragraph() { _zhm_move_next_paragraph $1 $2 $3 $4 }
function _zhm_t_prev_paragraph() { _zhm_move_prev_paragraph $1 $2 $3 $4 }

# Applies a paragraph motion ($1 is next or prev). Whether to extend is
# decided when the motion is applied, so repeating it with `A-.` follows the
# current mode as in Helix.
function _zhm_paragraph_apply() {
    local dir=$1
    local -i count=$2
    _zhm_extend_flag
    _zhm_save_jump
    _zhm_transform _zhm_t_${dir}_paragraph $count $REPLY
}

# Runs motion $1 (an eval-able command) and records it for `A-.`.
function _zhm_apply_motion() {
    _zhm_last_motion=$1
    eval "$1"
}

function _zhm_cmd_goto_next_paragraph() {
    _zhm_count_or_1
    _zhm_apply_motion "_zhm_paragraph_apply next $REPLY"
}

function _zhm_cmd_goto_prev_paragraph() {
    _zhm_count_or_1
    _zhm_apply_motion "_zhm_paragraph_apply prev $REPLY"
}

### Modes ###

function _zhm_cmd_normal_mode() {
    if [[ $_zhm_mode == insert ]]; then
        _zhm_set_mode normal
        _zhm_try_restore_indent
        if (( _zhm_restore_cursor )); then
            local -i i=0
            for (( i = 1; i <= ${#_zhm_sa}; i++ )); do
                local -i a=${_zhm_sa[i]} h=${_zhm_sh[i]} from to
                (( from = a < h ? a : h, to = a < h ? h : a ))
                (( h > a )) && (( to = to > 0 ? to - 1 : 0 ))
                _zhm_sa[i]=$from _zhm_sh[i]=$to
            done
            _zhm_ensure_invariants
            _zhm_restore_cursor=0
        fi
    else
        _zhm_set_mode normal
    fi
}

function _zhm_cmd_select_mode() {
    local -i i=0
    for (( i = 1; i <= ${#_zhm_sa}; i++ )); do
        if (( _zhm_sa[i] == _zhm_sh[i] && _zhm_sh[i] == _zhm_len )); then
            (( _zhm_sa[i] = _zhm_sa[i] > 0 ? _zhm_sa[i] - 1 : 0 ))
        fi
    done
    _zhm_ensure_invariants
    _zhm_set_mode select
}

function _zhm_exit_select_mode() {
    [[ $_zhm_mode == select ]] && _zhm_set_mode normal
    return 0
}

function _zhm_cmd_exit_select_mode() {
    _zhm_exit_select_mode
}

### Selection manipulation ###

function _zhm_t_collapse() {
    _zhm_cursor $1 $2
    _zhm_ra=$REPLY _zhm_rh=$REPLY
}
function _zhm_cmd_collapse_selection() { _zhm_transform _zhm_t_collapse }

function _zhm_t_flip() { _zhm_ra=$2 _zhm_rh=$1 }
function _zhm_cmd_flip_selections() { _zhm_transform _zhm_t_flip }

function _zhm_t_forward() { _zhm_with_direction $1 $2 1 }
function _zhm_cmd_ensure_selections_forward() { _zhm_transform _zhm_t_forward }

function _zhm_cmd_select_all() {
    _zhm_save_jump
    _zhm_set_single 0 $_zhm_len
}

function _zhm_t_extend_line() {
    local -i anchor=$1 head=$2 below=$3 count=$4 start end sl el nlines=${#_zhm_lines}
    _zhm_line_range $anchor $head
    sl=$_zhm_ra el=$_zhm_rh
    _zhm_line_start $sl; start=$REPLY
    if (( el + 1 >= nlines )); then end=$_zhm_len; else _zhm_line_start $(( el + 1 )); end=$REPLY; fi
    local -i from=$(( anchor < head ? anchor : head )) to=$(( anchor < head ? head : anchor ))
    local -i na=0 nh=0 target=0
    if (( from == start && to == end )); then
        if (( below )); then
            target=$(( el + count + 1 ))
            na=$start
        else
            target=$(( sl - count < 0 ? 0 : sl - count ))
            na=$end
        fi
    else
        if (( below )); then
            target=$(( el + count ))
            na=$start
        else
            target=$(( sl - count + 1 < 0 ? 0 : sl - count + 1 ))
            na=$end
        fi
    fi
    if (( target >= nlines )); then
        nh=$_zhm_len
    else
        _zhm_line_start $target; nh=$REPLY
    fi
    _zhm_ra=$na _zhm_rh=$nh
}

function _zhm_cmd_extend_line_below() { _zhm_count_or_1; _zhm_transform _zhm_t_extend_line 1 $REPLY }
function _zhm_cmd_extend_line_above() { _zhm_count_or_1; _zhm_transform _zhm_t_extend_line 0 $REPLY }
function _zhm_cmd_extend_line() {
    local -i a=${_zhm_sa[_zhm_pi]} h=${_zhm_sh[_zhm_pi]}
    _zhm_count_or_1
    _zhm_transform _zhm_t_extend_line $(( h >= a )) $REPLY
}

# Start of line $1, or the end of the text past the last line.
function _zhm_line_to_char_sat() {
    if (( $1 >= ${#_zhm_lines} )); then REPLY=$_zhm_len; else _zhm_line_start $1; fi
}

function _zhm_t_select_line() {
    local -i anchor=$1 head=$2 below=$3 count=$4 sl el start end nlines=${#_zhm_lines}
    _zhm_line_range $anchor $head
    sl=$_zhm_ra el=$_zhm_rh
    _zhm_line_start $sl; start=$REPLY
    _zhm_line_next_start $el; end=$REPLY
    local -i from=$(( anchor < head ? anchor : head )) to=$(( anchor < head ? head : anchor ))
    local -i forward=$(( head >= anchor ))
    (( from != start || to != end )) && (( count = count > 0 ? count - 1 : 0 ))
    local -i al=0 hl=0
    if (( !below && forward )); then
        (( al = sl, hl = el - count < 0 ? 0 : el - count ))
    elif (( !below )); then
        (( al = el, hl = sl - count < 0 ? 0 : sl - count ))
    elif (( forward )); then
        (( al = sl, hl = el + count > nlines ? nlines : el + count ))
    else
        (( al = el, hl = sl + count > nlines ? nlines : sl + count ))
    fi
    local -i plus_a=$(( al + 1 > nlines ? nlines : al + 1 )) plus_h=$(( hl + 1 > nlines ? nlines : hl + 1 ))
    if (( al < hl )); then
        _zhm_line_to_char_sat $al; _zhm_ra=$REPLY
        _zhm_line_to_char_sat $plus_h; _zhm_rh=$REPLY
    elif (( al == hl )); then
        if (( below )); then
            _zhm_line_to_char_sat $hl; _zhm_ra=$REPLY
            _zhm_line_to_char_sat $plus_a; _zhm_rh=$REPLY
        else
            _zhm_line_to_char_sat $plus_a; _zhm_ra=$REPLY
            _zhm_line_to_char_sat $hl; _zhm_rh=$REPLY
        fi
    else
        _zhm_line_to_char_sat $plus_a; _zhm_ra=$REPLY
        _zhm_line_to_char_sat $hl; _zhm_rh=$REPLY
    fi
}

function _zhm_cmd_select_line_below() { _zhm_count_or_1; _zhm_transform _zhm_t_select_line 1 $REPLY }
function _zhm_cmd_select_line_above() { _zhm_count_or_1; _zhm_transform _zhm_t_select_line 0 $REPLY }

function _zhm_t_extend_to_line_bounds() {
    local -i anchor=$1 head=$2 start end
    _zhm_line_range $anchor $head
    local -i el=$_zhm_rh
    _zhm_line_start $_zhm_ra; start=$REPLY
    _zhm_line_next_start $el; end=$REPLY
    _zhm_with_direction $start $end $(( head >= anchor ))
}
function _zhm_cmd_extend_to_line_bounds() { _zhm_transform _zhm_t_extend_to_line_bounds }

function _zhm_t_shrink_to_line_bounds() {
    local -i anchor=$1 head=$2 sl el start end
    _zhm_line_range $anchor $head
    sl=$_zhm_ra el=$_zhm_rh
    if (( sl == el )); then
        _zhm_ra=$anchor _zhm_rh=$head
        return
    fi
    local -i from=$(( anchor < head ? anchor : head )) to=$(( anchor < head ? head : anchor ))
    _zhm_line_start $sl; start=$REPLY
    _zhm_line_next_start $el; end=$REPLY
    if (( start != from )); then
        _zhm_line_next_start $sl; start=$REPLY
    fi
    if (( end != to )); then
        _zhm_line_start $el; end=$REPLY
    fi
    _zhm_with_direction $start $end $(( head >= anchor ))
}
function _zhm_cmd_shrink_to_line_bounds() { _zhm_transform _zhm_t_shrink_to_line_bounds }

function _zhm_cmd_keep_primary_selection() {
    _zhm_set_single ${_zhm_sa[_zhm_pi]} ${_zhm_sh[_zhm_pi]}
}

function _zhm_cmd_remove_primary_selection() {
    if (( ${#_zhm_sa} == 1 )); then
        _zhm_error "no selections remaining"
        return 1
    fi
    local -i i=$_zhm_pi
    _zhm_sa[i]=() _zhm_sh[i]=() _zhm_scol[i]=()
    if (( i > ${#_zhm_sa} )); then
        _zhm_pi=$(( i - 1 ))
    fi
    _zhm_ensure_invariants
}

function _zhm_rotate_selections() {
    local -i forward=$1 count len=${#_zhm_sa}
    _zhm_count_or_1; count=$REPLY
    local -i idx=$(( _zhm_pi - 1 ))
    if (( forward )); then
        (( idx = (idx + count) % len ))
    else
        (( idx = (idx + ((len - count > 0 ? len - count : 0) % len)) % len ))
    fi
    _zhm_pi=$(( idx + 1 ))
}
function _zhm_cmd_rotate_selections_forward() { _zhm_rotate_selections 1 }
function _zhm_cmd_rotate_selections_backward() { _zhm_rotate_selections 0 }
function _zhm_cmd_rotate_selections_first() { _zhm_pi=1 }
function _zhm_cmd_rotate_selections_last() { _zhm_pi=${#_zhm_sa} }

function _zhm_cmd_merge_selections() {
    local -i fa=${_zhm_sa[1]} fh=${_zhm_sh[1]} la=${_zhm_sa[-1]} lh=${_zhm_sh[-1]}
    local -i ff=$(( fa < fh ? fa : fh )) lt=$(( la < lh ? lh : la ))
    if (( la > lh && fa > fh )); then
        _zhm_set_single $(( fa > la ? fa : la )) $(( fh < lh ? fh : lh ))
    else
        local -i lf=$(( la < lh ? la : lh )) ft=$(( fa < fh ? fh : fa ))
        _zhm_set_single $(( lf < ff ? lf : ff )) $(( ft > lt ? ft : lt ))
    fi
}

function _zhm_cmd_merge_consecutive_selections() {
    local -i i pa=${_zhm_sa[_zhm_pi]} ph=${_zhm_sh[_zhm_pi]}
    local -a sa=() sh=()
    for (( i = 1; i <= ${#_zhm_sa}; i++ )); do
        local -i ca=${_zhm_sa[i]} ch=${_zhm_sh[i]}
        if (( ${#sa} )); then
            local -i pa2=${sa[-1]} ph2=${sh[-1]}
            local -i pt=$(( pa2 < ph2 ? ph2 : pa2 )) cf=$(( ca < ch ? ca : ch ))
            if (( pt == cf )); then
                local -i ma=0 mh=0
                if (( ca > ch && pa2 > ph2 )); then
                    (( ma = ca > pa2 ? ca : pa2, mh = ch < ph2 ? ch : ph2 ))
                else
                    local -i pf=$(( pa2 < ph2 ? pa2 : ph2 )) ct=$(( ca < ch ? ch : ca ))
                    (( ma = cf < pf ? cf : pf, mh = ct > pt ? ct : pt ))
                fi
                if (( (pa2 == pa && ph2 == ph) || (ca == pa && ch == ph) )); then
                    pa=$ma ph=$mh
                fi
                sa[-1]=$ma sh[-1]=$mh
                continue
            fi
        fi
        sa+=( $ca ) sh+=( $ch )
    done
    _zhm_sa=( "${sa[@]}" ) _zhm_sh=( "${sh[@]}" )
    _zhm_scol=( "${(@)_zhm_sa/*/-1}" )
    for (( i = 1; i <= ${#_zhm_sa}; i++ )); do
        (( _zhm_sa[i] == pa && _zhm_sh[i] == ph )) && _zhm_pi=$i
    done
    _zhm_ensure_invariants
}

function _zhm_cmd_split_selection_on_newline() {
    local -i i pi=1
    local -a ranges=()
    for (( i = 1; i <= ${#_zhm_sa}; i++ )); do
        local -i a=${_zhm_sa[i]} h=${_zhm_sh[i]}
        local -i from=$(( a < h ? a : h )) to=$(( a < h ? h : a ))
        if (( from == to )); then
            ranges+=( $a $h )
            continue
        fi
        local -i start=$from p
        for (( p = from; p < to; p++ )); do
            if [[ ${_zhm_chars[p + 1]} == $'\n' ]]; then
                ranges+=( $start $p )
                start=$(( p + 1 ))
            fi
        done
        (( start < to )) && ranges+=( $start $to )
    done
    _zhm_set_selection 1 "${ranges[@]}"
}

# Adds a selection on the line below or above each selection.
function _zhm_copy_selection_on_line() {
    local -i forward=$1 count i nlines=${#_zhm_lines}
    _zhm_count_or_1; count=$REPLY
    local -a ranges=()
    local -i primary=0
    for (( i = 1; i <= ${#_zhm_sa}; i++ )); do
        ranges+=( ${_zhm_sa[i]} ${_zhm_sh[i]} )
    done
    for (( i = 1; i <= ${#_zhm_sa}; i++ )); do
        local -i a=${_zhm_sa[i]} h=${_zhm_sh[i]} head anchor
        if (( a < h )); then
            (( head = h - 1, anchor = a ))
        else
            (( head = h, anchor = a > 0 ? a - 1 : 0 ))
        fi
        local -i hrow=0 arow=0 hcol=0 acol=0
        _zhm_line_of $head; hrow=$REPLY
        _zhm_line_of $anchor; arow=$REPLY
        _zhm_visual_col $head; hcol=$REPLY
        _zhm_visual_col $anchor; acol=$REPLY
        local -i height=$(( (hrow > arow ? hrow - arow : arow - hrow) + 1 ))
        (( i == _zhm_pi )) && primary=$(( ${#ranges} / 2 + 1 ))
        ranges+=( $a $h )
        local -i sels=0 k=0
        while (( sels < count )); do
            local -i offset=$(( (k + 1) * height )) ar hr
            if (( forward )); then
                (( ar = arow + offset, hr = hrow + offset ))
            else
                (( ar = arow - offset < 0 ? 0 : arow - offset, hr = hrow - offset < 0 ? 0 : hrow - offset ))
            fi
            (( ar >= nlines || hr >= nlines )) && break
            local -i na=0 nh=0
            _zhm_pos_at_visual_col $ar $acol; na=$REPLY
            _zhm_pos_at_visual_col $hr $hcol; nh=$REPLY
            _zhm_visual_col $na; local -i nac=$REPLY
            _zhm_visual_col $nh; local -i nhc=$REPLY
            if (( nac == acol && nhc == hcol )); then
                (( i == _zhm_pi )) && primary=$(( ${#ranges} / 2 + 1 ))
                _zhm_put_cursor $na $na $nh 1
                ranges+=( $_zhm_ra $_zhm_rh )
                (( sels++ ))
            fi
            (( ar == 0 && hr == 0 )) && break
            (( k++ ))
        done
    done
    # The original ranges were added twice; normalisation merges duplicates.
    _zhm_set_selection $primary "${ranges[@]}"
}

function _zhm_cmd_copy_selection_on_next_line() { _zhm_copy_selection_on_line 1 }
function _zhm_cmd_copy_selection_on_prev_line() { _zhm_copy_selection_on_line 0 }

function _zhm_cmd_trim_selections() {
    local -a ranges=()
    local -i i pi=0 n=0
    local -i pa=${_zhm_sa[_zhm_pi]} ph=${_zhm_sh[_zhm_pi]}
    local -i pf=$(( pa < ph ? pa : ph )) pt=$(( pa < ph ? ph : pa ))
    for (( i = 1; i <= ${#_zhm_sa}; i++ )); do
        local -i a=${_zhm_sa[i]} h=${_zhm_sh[i]}
        local -i from=$(( a < h ? a : h )) to=$(( a < h ? h : a ))
        (( from == to )) && continue
        local frag=${_zhm_text:$from:$(( to - from ))}
        [[ $frag == [[:space:]]# ]] && continue
        while (( from < _zhm_len )) && _zhm_is_whitespace "${_zhm_chars[from + 1]}"; do (( from++ )); done
        while (( to > 0 )) && _zhm_is_whitespace "${_zhm_chars[to]}"; do (( to-- )); done
        _zhm_with_direction $from $to $(( h >= a ))
        ranges+=( $_zhm_ra $_zhm_rh )
        (( n++ ))
        if (( ! pi )); then
            if (( from == pf || (to > pf && pt > from) )); then
                pi=$n
            fi
        fi
    done
    if (( n )); then
        (( pi )) || pi=$n
        _zhm_set_selection $pi "${ranges[@]}"
    else
        _zhm_cmd_collapse_selection
        _zhm_cmd_keep_primary_selection
    fi
}

function _zhm_cmd_align_selections() {
    local -i i n=${#_zhm_sa} prev_line=-1 col_idx=0 running=0
    local -a widths=() rows=() cols=()
    for (( i = 1; i <= n; i++ )); do
        local -i h=${_zhm_sh[i]} a=${_zhm_sa[i]} hr ar hc
        _zhm_line_of $h; hr=$REPLY
        _zhm_line_of $a; ar=$REPLY
        if (( hr != ar )); then
            _zhm_error "align cannot work with multi line selections"
            return 1
        fi
        _zhm_visual_col $h; hc=$REPLY
        if (( hr != prev_line )); then
            col_idx=0 running=0 prev_line=$hr
        fi
        local -i width=$(( hc - running ))
        if (( col_idx < ${#widths} )); then
            (( widths[col_idx + 1] = widths[col_idx + 1] > width ? widths[col_idx + 1] : width ))
        else
            widths+=( $width )
        fi
        rows+=( $hr ) cols+=( $hc )
        (( running += width, col_idx++ ))
    done
    local -a positions=()
    local -i sum=0 w
    for w in "${widths[@]}"; do
        (( sum += w ))
        positions+=( $sum )
    done
    _zhm_changes_reset
    prev_line=-1
    for (( i = 1; i <= n; i++ )); do
        if (( rows[i] != prev_line )); then
            col_idx=0 running=0 prev_line=${rows[i]}
        fi
        local -i inserts=$(( positions[col_idx + 1] - cols[i] - running ))
        local -i a=${_zhm_sa[i]} h=${_zhm_sh[i]}
        local -i pos=$(( a < h ? a : h ))
        (( col_idx++, running += inserts ))
        _zhm_change $pos $pos "${(l:$inserts:: :)}"
    done
    _zhm_apply_changes
    _zhm_exit_select_mode
}

### Text objects ###

function _zhm_t_textobject_word() {
    _zhm_textobject_word $1 $2 $3 $4
}

function _zhm_t_textobject_paragraph() {
    _zhm_textobject_paragraph $1 $2 $3 $4
}

function _zhm_t_textobject_pair() {
    local -i anchor=$1 head=$2 count=$6
    local kind=$3 ch=$4 find_type=$5
    local -i found=1
    if [[ $ch == closest ]]; then
        _zhm_find_nth_closest_pairs $anchor $head $count || found=0
    else
        _zhm_find_nth_pairs_pos "$ch" $anchor $head $find_type $count || found=0
    fi
    if (( found )); then
        _zhm_pair_textobject $_zhm_ra $_zhm_rh $kind
    else
        _zhm_ra=$anchor _zhm_rh=$head
    fi
    # Helix sets the direction for next/prev pairs even if none was found.
    if [[ $find_type == next ]]; then
        _zhm_with_direction $_zhm_ra $_zhm_rh 1
    elif [[ $find_type == prev ]]; then
        _zhm_with_direction $_zhm_ra $_zhm_rh 0
    fi
}

function _zhm_textobject_cmd() {
    local kind=$1 object=$2 ch=$3
    [[ $object == *pair && $ch == [[:alnum:]] ]] && return 0
    _zhm_count_or_1
    _zhm_apply_motion "_zhm_textobject_apply $kind $object ${(q)ch} $REPLY"
}

function _zhm_textobject_apply() {
    local kind=$1 object=$2 ch=$3
    local -i count=$4
    case $object in
        (word) _zhm_transform _zhm_t_textobject_word $kind 0 ;;
        (WORD) _zhm_transform _zhm_t_textobject_word $kind 1 ;;
        (paragraph) _zhm_transform _zhm_t_textobject_paragraph $kind $count ;;
        (closest) _zhm_transform _zhm_t_textobject_pair $kind closest surround $count ;;
        (pair|next_pair|prev_pair)
            local find_type=surround
            [[ $object == next_pair ]] && find_type=next
            [[ $object == prev_pair ]] && find_type=prev
            _zhm_transform _zhm_t_textobject_pair $kind "$ch" $find_type $count
            ;;
    esac
}

function _zhm_cmd_select_textobject_inside_word() { _zhm_textobject_cmd inside word }
function _zhm_cmd_select_textobject_around_word() { _zhm_textobject_cmd around word }
function _zhm_cmd_select_textobject_inside_WORD() { _zhm_textobject_cmd inside WORD }
function _zhm_cmd_select_textobject_around_WORD() { _zhm_textobject_cmd around WORD }
function _zhm_cmd_select_textobject_inside_paragraph() { _zhm_textobject_cmd inside paragraph }
function _zhm_cmd_select_textobject_around_paragraph() { _zhm_textobject_cmd around paragraph }
function _zhm_cmd_select_textobject_inside_closest_surrounding_pair() { _zhm_textobject_cmd inside closest }
function _zhm_cmd_select_textobject_around_closest_surrounding_pair() { _zhm_textobject_cmd around closest }
function _zhm_cmd_select_textobject_inside_surrounding_pair() { _zhm_textobject_cmd inside pair "$1" }
function _zhm_cmd_select_textobject_around_surrounding_pair() { _zhm_textobject_cmd around pair "$1" }
function _zhm_cmd_select_textobject_inside_prev_pair() { _zhm_textobject_cmd inside prev_pair "$1" }
function _zhm_cmd_select_textobject_inside_next_pair() { _zhm_textobject_cmd inside next_pair "$1" }

function _zhm_t_match_brackets() {
    local -i anchor=$1 head=$2 extend=$3
    _zhm_cursor $anchor $head
    if _zhm_match_bracket_plain $REPLY; then
        _zhm_put_cursor $anchor $head $REPLY $extend
    fi
}

function _zhm_cmd_match_brackets() {
    _zhm_extend_flag
    local -i extend=$REPLY
    _zhm_save_jump
    _zhm_transform _zhm_t_match_brackets $extend
}

### Jumplist ###

typeset -ga _zhm_jumps
typeset -gi _zhm_jump_idx=0

function _zhm_jumps_reset() {
    _zhm_jumps=()
    _zhm_jump_idx=0
}

# Save the current selection to the jumplist (Helix's `push_jump`).
function _zhm_save_jump() {
    local REPLY=""
    _zhm_selection_serialize
    local sel=$REPLY
    # Drop any jumps after the current position, as Helix does.
    if (( _zhm_jump_idx < ${#_zhm_jumps} )); then
        _zhm_jumps=( "${(@)_zhm_jumps[1,_zhm_jump_idx]}" )
    fi
    if (( ${#_zhm_jumps} )) && [[ ${_zhm_jumps[-1]} == "$sel" ]]; then
        return 0
    fi
    _zhm_jumps+=( "$sel" )
    _zhm_jump_idx=${#_zhm_jumps}
}

function _zhm_cmd_jump_backward() {
    local -i count=0
    _zhm_count_or_1; count=$REPLY
    (( _zhm_jump_idx > 0 )) || return 0
    if (( _zhm_jump_idx == ${#_zhm_jumps} )); then
        # Save the current position so jump_forward can return to it.
        _zhm_selection_serialize
        if [[ ${_zhm_jumps[-1]} != "$REPLY" ]]; then
            _zhm_jumps+=( "$REPLY" )
        fi
    fi
    local -i target=$(( _zhm_jump_idx - count + 1 ))
    _zhm_selection_serialize
    [[ ${_zhm_jumps[_zhm_jump_idx]} == "$REPLY" ]] && (( target-- ))
    (( target < 1 )) && target=1
    _zhm_jump_idx=$target
    _zhm_selection_restore "${_zhm_jumps[target]}"
}

function _zhm_cmd_jump_forward() {
    local -i count=0
    _zhm_count_or_1; count=$REPLY
    local -i target=$(( _zhm_jump_idx + count ))
    (( target > ${#_zhm_jumps} )) && return 0
    _zhm_jump_idx=$target
    _zhm_selection_restore "${_zhm_jumps[target]}"
}

function _zhm_cmd_save_selection() {
    _zhm_save_jump
    _zhm_status "Selection saved to jumplist"
}
