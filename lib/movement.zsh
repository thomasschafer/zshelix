# Movement and text object primitives, ported from `helix_core::movement`,
# `helix_core::textobject`, `helix_core::surround` and
# `helix_core::match_brackets`.

### Word motions ###

# Whether the motion target $1 is reached between characters $2 and $3, as in
# `helix_core::movement::reached_target`. Targets are named
# {next,prev}_{word,long_word,sub_word}_{start,end}.
function _zhm_reached_target() {
    local target=$1 p=$2 n=$3
    local -i pc nc
    _zhm_cat "$p"; pc=$REPLY
    _zhm_cat "$n"; nc=$REPLY
    local boundary=0
    case $target in
        (*_long_word_*)
            if (( pc != nc )) && ! (( (pc == _ZHM_WORD && nc == _ZHM_PUNCT) || (pc == _ZHM_PUNCT && nc == _ZHM_WORD) )); then
                boundary=1
            fi
            ;;
        (*_sub_word_*)
            if (( pc == _ZHM_WORD && nc == _ZHM_WORD )); then
                local -i pu=0 nu=0
                [[ $p == _ ]] && pu=1
                [[ $n == _ ]] && nu=1
                if (( pu != nu )); then
                    boundary=1
                elif [[ $target == next_* ]]; then
                    [[ $p == [[:lower:]] && $n == [[:upper:]] ]] && boundary=1
                else
                    [[ $p == [[:upper:]] && $n == [[:lower:]] ]] && boundary=1
                fi
            elif (( pc != nc )); then
                boundary=1
            fi
            ;;
        (*)
            (( pc != nc )) && boundary=1
            ;;
    esac
    (( boundary )) || return 1
    local p_ws=0 n_ws=0
    (( pc == _ZHM_WS || pc == _ZHM_EOL )) && p_ws=1
    (( nc == _ZHM_WS || nc == _ZHM_EOL )) && n_ws=1
    if [[ $target == *_sub_word_* ]]; then
        [[ $p == _ ]] && p_ws=1
        [[ $n == _ ]] && n_ws=1
    fi
    case $target in
        (next_*_start|prev_*_end)
            (( nc == _ZHM_EOL || ! n_ws ))
            ;;
        (*)
            (( ! p_ws || nc == _ZHM_EOL ))
            ;;
    esac
}

# `CharHelpers::range_to_target` for range ($1, $2): sets _zhm_ra/_zhm_rh.
function _zhm_range_to_target() {
    local target=$1
    local -i anchor=$2 head=$3 it=$3 prev=0
    [[ $target == prev_* ]] && prev=1
    local prev_ch="" has_prev=0 ch

    # Character before the head in the direction of motion.
    if (( prev )); then
        if (( it < _zhm_len )); then
            prev_ch=${_zhm_chars[it + 1]} has_prev=1
        fi
    else
        if (( it > 0 )); then
            prev_ch=${_zhm_chars[it]} has_prev=1
        fi
    fi

    # Skip any initial newline characters.
    while :; do
        if (( prev )); then
            (( it > 0 )) || break
            ch=${_zhm_chars[it]}
        else
            (( it < _zhm_len )) || break
            ch=${_zhm_chars[it + 1]}
        fi
        _zhm_is_line_ending "$ch" || break
        prev_ch=$ch has_prev=1
        if (( prev )); then
            (( it--, head = head > 0 ? head - 1 : 0 ))
        else
            (( it++, head++ ))
        fi
    done
    if (( has_prev )) && _zhm_is_line_ending "$prev_ch"; then
        anchor=$head
    fi

    local -i head_start=$head
    while :; do
        if (( prev )); then
            (( it > 0 )) || break
            ch=${_zhm_chars[it]}
            (( it-- ))
        else
            (( it < _zhm_len )) || break
            ch=${_zhm_chars[it + 1]}
            (( it++ ))
        fi
        if (( ! has_prev )) || _zhm_reached_target $target "$prev_ch" "$ch"; then
            if (( head == head_start )); then
                anchor=$head
            else
                break
            fi
        fi
        prev_ch=$ch has_prev=1
        if (( prev )); then
            (( head = head > 0 ? head - 1 : 0 ))
        else
            (( head++ ))
        fi
    done
    _zhm_ra=$anchor _zhm_rh=$head
}

# `helix_core::movement::word_move`: sets _zhm_ra/_zhm_rh.
function _zhm_word_move() {
    local target=$1
    local -i anchor=$2 head=$3 count=$4 prev=0 i
    [[ $target == prev_* ]] && prev=1
    if (( (prev && head == 0) || (!prev && head == _zhm_len) )); then
        _zhm_ra=$anchor _zhm_rh=$head
        return
    fi
    local -i ra rh
    if (( prev )); then
        if (( anchor < head )); then
            (( ra = head, rh = head > 0 ? head - 1 : 0 ))
        else
            (( ra = head < _zhm_len ? head + 1 : _zhm_len, rh = head ))
        fi
    else
        if (( anchor < head )); then
            (( ra = head > 0 ? head - 1 : 0, rh = head ))
        else
            (( ra = head, rh = head < _zhm_len ? head + 1 : _zhm_len ))
        fi
    fi
    for (( i = 0; i < count; i++ )); do
        _zhm_range_to_target $target $ra $rh
        (( _zhm_ra == ra && _zhm_rh == rh )) && break
        ra=$_zhm_ra rh=$_zhm_rh
    done
    _zhm_ra=$ra _zhm_rh=$rh
}

### Find character ###

# `helix_core::search::find_nth_char`: position of the $1th occurrence of
# character $2 starting from gap $3 in direction $4 (1 = forward).
function _zhm_find_nth_char() {
    local -i n=$1 pos=$3 forward=$4
    local ch=$2
    (( n > 0 )) || return 1
    if (( forward )); then
        while (( pos < _zhm_len )); do
            if [[ ${_zhm_chars[pos + 1]} == "$ch" ]]; then
                (( --n == 0 )) && { REPLY=$pos; return 0 }
            fi
            (( pos++ ))
        done
    else
        while (( pos > 0 )); do
            (( pos-- ))
            if [[ ${_zhm_chars[pos + 1]} == "$ch" ]]; then
                (( --n == 0 )) && { REPLY=$pos; return 0 }
            fi
        done
    fi
    return 1
}

### Vertical movement ###

# Visual column of position $1 within its line.
function _zhm_visual_col() {
    local -i pos=$1 i col=0
    _zhm_line_of $pos
    _zhm_line_start $REPLY
    for (( i = REPLY; i < pos; i++ )); do
        if [[ ${_zhm_chars[i + 1]} == $'\t' ]]; then
            (( col += ZHM_TAB_WIDTH - col % ZHM_TAB_WIDTH ))
        else
            _zhm_char_width "${_zhm_chars[i + 1]}"
            (( col += REPLY ))
        fi
    done
    REPLY=$col
}

# Position at visual column $2 on line $1, stopping at the end of the line.
function _zhm_pos_at_visual_col() {
    local -i line=$1 target=$2 col=0 pos end
    _zhm_line_start $line; pos=$REPLY
    _zhm_line_end $line; end=$REPLY
    while (( pos < end )); do
        local -i w
        if [[ ${_zhm_chars[pos + 1]} == $'\t' ]]; then
            (( w = ZHM_TAB_WIDTH - col % ZHM_TAB_WIDTH ))
        else
            _zhm_char_width "${_zhm_chars[pos + 1]}"
            w=$REPLY
        fi
        (( col + w > target )) && break
        (( col += w, pos++ ))
    done
    REPLY=$pos
}

# `helix_core::movement::move_vertically` for range $1 ($2, $3) with sticky
# column $4: sets _zhm_ra/_zhm_rh and _zhm_rcol (the new sticky column).
typeset -gi _zhm_rcol=-1
function _zhm_move_vertically() {
    local -i forward=$1 anchor=$2 head=$3 scol=$4 count=$5 extend=$6
    local -i pos line col nlines new_line
    _zhm_cursor $anchor $head; pos=$REPLY
    _zhm_line_of $pos; line=$REPLY
    if (( scol >= 0 )); then
        col=$scol
    else
        _zhm_visual_col $pos; col=$REPLY
    fi
    nlines=${#_zhm_lines}
    if (( forward )); then
        new_line=$(( line + count ))
    else
        new_line=$(( line - count < 0 ? 0 : line - count ))
    fi
    (( new_line > nlines - 1 )) && new_line=$(( nlines - 1 ))
    _zhm_pos_at_visual_col $new_line $col
    local -i new_pos=$REPLY
    if (( extend )); then
        _zhm_line_start $new_line
        local -i ls=$REPLY
        _zhm_line_next_start $new_line
        if (( REPLY - ls == 0 )); then
            _zhm_ra=$anchor _zhm_rh=$head _zhm_rcol=$scol
            return
        fi
    fi
    _zhm_put_cursor $anchor $head $new_pos $extend
    _zhm_rcol=$col
}

### Paragraphs ###

# Helix's `rope_is_line_ending(slice.line(n))`: true when the line consists of
# only a line ending, or is the empty last line after the final newline.
function _zhm_line_is_blank() {
    local -i line=$1
    _zhm_line_start $line
    local -i s=$REPLY
    (( s >= _zhm_len )) && return 0
    _zhm_line_next_start $line
    (( REPLY - s == 1 )) && [[ ${_zhm_chars[s + 1]} == $'\n' ]]
}

function _zhm_move_next_paragraph() {
    local -i anchor=$1 head=$2 count=$3 extend=$4
    local -i cursor line nlines last_char curr_empty next_empty i last_line
    _zhm_cursor $anchor $head; cursor=$REPLY
    _zhm_line_of $cursor; line=$REPLY
    nlines=${#_zhm_lines}
    _zhm_line_next_start $line
    _zhm_prev_boundary $REPLY
    (( last_char = REPLY == cursor ))
    _zhm_line_is_blank $line && curr_empty=1 || curr_empty=0
    local -i nl=$(( line + 1 < nlines - 1 ? line + 1 : nlines - 1 ))
    _zhm_line_is_blank $nl && next_empty=1 || next_empty=0
    local -i curr_empty_to_line=$(( curr_empty && !next_empty ))
    (( curr_empty_to_line && last_char )) && (( line++ ))
    last_line=$line
    for (( i = 0; i < count; i++ )); do
        while (( line < nlines )) && ! _zhm_line_is_blank $line; do (( line++ )); done
        while (( line < nlines )) && _zhm_line_is_blank $line; do (( line++ )); done
        (( line == last_line )) && break
        last_line=$line
    done
    local -i new_head
    if (( line >= nlines )); then
        new_head=$_zhm_len
    else
        _zhm_line_start $line; new_head=$REPLY
    fi
    local -i new_anchor
    if (( ! extend )); then
        if (( curr_empty_to_line && last_char )); then
            new_anchor=$head
        else
            new_anchor=$cursor
        fi
    else
        _zhm_put_cursor $anchor $head $new_head 1
        new_anchor=$_zhm_ra
    fi
    _zhm_ra=$new_anchor _zhm_rh=$new_head
}

function _zhm_move_prev_paragraph() {
    local -i anchor=$1 head=$2 count=$3 extend=$4
    local -i cursor line first_char prev_empty curr_empty i last_line
    _zhm_cursor $anchor $head; cursor=$REPLY
    _zhm_line_of $cursor; line=$REPLY
    _zhm_line_start $line
    (( first_char = REPLY == cursor ))
    _zhm_line_is_blank $(( line > 0 ? line - 1 : 0 )) && prev_empty=1 || prev_empty=0
    _zhm_line_is_blank $line && curr_empty=1 || curr_empty=0
    local -i prev_empty_to_line=$(( prev_empty && !curr_empty ))
    (( prev_empty_to_line && !first_char )) && (( line++ ))
    last_line=$line
    for (( i = 0; i < count; i++ )); do
        while (( line > 0 )) && _zhm_line_is_blank $(( line - 1 )); do (( line-- )); done
        while (( line > 0 )) && ! _zhm_line_is_blank $(( line - 1 )); do (( line-- )); done
        (( line == last_line )) && break
        last_line=$line
    done
    _zhm_line_start $line
    local -i new_head=$REPLY new_anchor
    if (( ! extend )); then
        if (( prev_empty_to_line && first_char )); then
            new_anchor=$cursor
        else
            new_anchor=$head
        fi
    else
        _zhm_put_cursor $anchor $head $new_head 1
        new_anchor=$_zhm_ra
    fi
    _zhm_ra=$new_anchor _zhm_rh=$new_head
}

### Text objects ###

# `find_word_boundary` from `helix_core::textobject`.
function _zhm_find_word_boundary() {
    local -i pos=$1 forward=$2 long=$3 prev_cat cat
    if (( forward )); then
        if (( pos == 0 )); then
            prev_cat=$_ZHM_WS
        else
            _zhm_cat "${_zhm_chars[pos]}"; prev_cat=$REPLY
        fi
    else
        if (( pos == _zhm_len )); then
            prev_cat=$_ZHM_WS
        else
            _zhm_cat "${_zhm_chars[pos + 1]}"; prev_cat=$REPLY
        fi
    fi
    local -i it=$pos
    while :; do
        local ch
        if (( forward )); then
            (( it < _zhm_len )) || break
            ch=${_zhm_chars[it + 1]}
            (( it++ ))
        else
            (( it > 0 )) || break
            ch=${_zhm_chars[it]}
            (( it-- ))
        fi
        _zhm_cat "$ch"; cat=$REPLY
        if (( cat == _ZHM_EOL || cat == _ZHM_WS )); then
            REPLY=$pos
            return
        fi
        if (( !long && cat != prev_cat && pos != 0 && pos != _zhm_len )); then
            REPLY=$pos
            return
        fi
        if (( forward )); then
            (( pos++ ))
        else
            (( pos = pos > 0 ? pos - 1 : 0 ))
        fi
        prev_cat=$cat
    done
    REPLY=$pos
}

# `textobject_word`: $3 is "inside" or "around", $4 is 1 for WORD.
function _zhm_textobject_word() {
    local -i anchor=$1 head=$2 long=$4 pos start end
    local kind=$3
    _zhm_cursor $anchor $head; pos=$REPLY
    _zhm_find_word_boundary $pos 0 $long; start=$REPLY
    if (( pos >= _zhm_len )); then
        end=$pos
    else
        _zhm_cat "${_zhm_chars[pos + 1]}"
        if (( REPLY == _ZHM_WS || REPLY == _ZHM_EOL )); then
            end=$pos
        else
            _zhm_find_word_boundary $(( pos + 1 )) 1 $long; end=$REPLY
        fi
    fi
    if (( start == end )); then
        _zhm_ra=$start _zhm_rh=$end
        return
    fi
    if [[ $kind == inside ]]; then
        _zhm_ra=$start _zhm_rh=$end
        return
    fi
    local -i right=0 left=0
    while (( end + right < _zhm_len )) && [[ ${_zhm_chars[end + right + 1]} == ($'\t'|' '|[[:blank:]]) ]]; do
        (( right++ ))
    done
    if (( right > 0 )); then
        _zhm_ra=$start _zhm_rh=$(( end + right ))
    else
        while (( start - left > 0 )) && [[ ${_zhm_chars[start - left]} == ($'\t'|' '|[[:blank:]]) ]]; do
            (( left++ ))
        done
        _zhm_ra=$(( start - left )) _zhm_rh=$end
    fi
}

function _zhm_textobject_paragraph() {
    local -i anchor=$1 head=$2 count=$4 line nlines
    local kind=$3
    nlines=${#_zhm_lines}
    _zhm_cursor $anchor $head
    local -i cursor=$REPLY
    _zhm_line_of $cursor; line=$REPLY
    local -i prev_empty curr_empty next_empty last_char
    _zhm_line_is_blank $(( line > 0 ? line - 1 : 0 )) && prev_empty=1 || prev_empty=0
    _zhm_line_is_blank $line && curr_empty=1 || curr_empty=0
    if (( line + 1 >= nlines )); then
        next_empty=1
    else
        _zhm_line_is_blank $(( line + 1 )) && next_empty=1 || next_empty=0
    fi
    _zhm_line_next_start $line
    _zhm_prev_boundary $REPLY
    (( last_char = REPLY == cursor ))
    local -i prev_empty_to_line=$(( prev_empty && !curr_empty ))
    local -i curr_empty_to_line=$(( curr_empty && !next_empty ))

    local -i line_back=$line
    (( prev_empty_to_line || curr_empty_to_line )) && (( line_back++ ))
    if ! (( curr_empty_to_line && last_char )); then
        while (( line_back > 0 )) && _zhm_line_is_blank $(( line_back - 1 )); do (( line_back-- )); done
        while (( line_back > 0 )) && ! _zhm_line_is_blank $(( line_back - 1 )); do (( line_back-- )); done
    fi
    (( curr_empty_to_line && last_char )) && (( line++ ))
    local -i i count_done=0 done
    for (( i = 0; i < count; i++ )); do
        done=0
        while (( line < nlines )) && ! _zhm_line_is_blank $line; do (( line++ )); done=1; done
        while (( line < nlines )) && _zhm_line_is_blank $line; do (( line++ )); done
        (( count_done += done ))
    done
    if (( count_done != count && line >= nlines )); then
        while (( line_back > 0 )) && _zhm_line_is_blank $(( line_back - 1 )); do (( line_back-- )); done
        while (( line_back > 0 )) && ! _zhm_line_is_blank $(( line_back - 1 )); do (( line_back-- )); done
    fi
    if [[ $kind == inside ]]; then
        while (( line > 0 )) && _zhm_line_is_blank $(( line - 1 )); do (( line-- )); done
    fi
    _zhm_line_start $line_back
    _zhm_ra=$REPLY
    if (( line >= nlines )); then
        _zhm_rh=$_zhm_len
    else
        _zhm_line_start $line
        _zhm_rh=$REPLY
    fi
}

### Brackets and pairs ###

typeset -ga _ZHM_BRACKETS=( '(' ')' '{' '}' '[' ']' '<' '>' '‘' '’' '“' '”' '«' '»' '「' '」' '（' '）' )
typeset -ga _ZHM_PAIRS=( "${_ZHM_BRACKETS[@]}" '"' '"' "'" "'" '`' '`' '|' '|' )

# `get_pair`: sets REPLY to the open character and REPLY2 to the close one.
typeset -g REPLY2
function _zhm_get_pair() {
    local ch=$1
    local -i i
    for (( i = 1; i <= ${#_ZHM_PAIRS}; i += 2 )); do
        if [[ ${_ZHM_PAIRS[i]} == "$ch" || ${_ZHM_PAIRS[i + 1]} == "$ch" ]]; then
            REPLY=${_ZHM_PAIRS[i]} REPLY2=${_ZHM_PAIRS[i + 1]}
            return
        fi
    done
    REPLY=$ch REPLY2=$ch
}

function _zhm_is_open_bracket() {
    local -i i
    for (( i = 1; i <= ${#_ZHM_BRACKETS}; i += 2 )); do
        [[ ${_ZHM_BRACKETS[i]} == "$1" ]] && return 0
    done
    return 1
}

function _zhm_is_close_bracket() {
    local -i i
    for (( i = 2; i <= ${#_ZHM_BRACKETS}; i += 2 )); do
        [[ ${_ZHM_BRACKETS[i]} == "$1" ]] && return 0
    done
    return 1
}

# `find_matching_bracket_plaintext`.
function _zhm_match_bracket_plain() {
    local -i pos=$1
    (( pos < _zhm_len )) || return 1
    local bracket=${_zhm_chars[pos + 1]} matching
    _zhm_is_open_bracket "$bracket" || _zhm_is_close_bracket "$bracket" || return 1
    _zhm_get_pair "$bracket"
    if [[ $REPLY == "$bracket" ]]; then
        matching=$REPLY2
    else
        matching=$REPLY
    fi
    local -i fwd=0 count=1 i
    _zhm_is_open_bracket "$bracket" && fwd=1
    if (( fwd )); then
        for (( i = pos + 1; i < _zhm_len && i <= pos + 10000; i++ )); do
            if [[ ${_zhm_chars[i + 1]} == "$bracket" ]]; then
                (( count++ ))
            elif [[ ${_zhm_chars[i + 1]} == "$matching" ]]; then
                (( count == 1 )) && { REPLY=$i; return 0 }
                (( count-- ))
            fi
        done
    else
        for (( i = pos - 1; i >= 0 && i >= pos - 10000; i-- )); do
            if [[ ${_zhm_chars[i + 1]} == "$bracket" ]]; then
                (( count++ ))
            elif [[ ${_zhm_chars[i + 1]} == "$matching" ]]; then
                (( count == 1 )) && { REPLY=$i; return 0 }
                (( count-- ))
            fi
        done
    fi
    return 1
}

function _zhm_find_nth_open_pair() {
    local open=$1 close=$2
    local -i pos=$3 n=$4 i step
    (( pos < _zhm_len )) || return 1
    [[ ${_zhm_chars[pos + 1]} == "$open" ]] && { REPLY=$pos; return 0 }
    local -i it=$pos
    for (( i = 0; i < n; i++ )); do
        step=0
        while :; do
            (( it > 0 )) || return 1
            (( it-- ))
            local c=${_zhm_chars[it + 1]}
            if [[ $c == "$close" ]]; then
                (( step++ ))
            elif [[ $c == "$open" ]]; then
                (( step == 0 )) && break
                (( step = step > 0 ? step - 1 : 0 ))
            fi
        done
    done
    REPLY=$it
}

function _zhm_find_nth_close_pair() {
    local open=$1 close=$2
    local -i pos=$3 n=$4 i step
    (( pos < _zhm_len )) || return 1
    [[ ${_zhm_chars[pos + 1]} == "$close" ]] && { REPLY=$pos; return 0 }
    local -i it=$pos
    for (( i = 0; i < n; i++ )); do
        step=0
        while :; do
            (( it + 1 < _zhm_len )) || return 1
            (( it++ ))
            local c=${_zhm_chars[it + 1]}
            if [[ $c == "$open" ]]; then
                (( step++ ))
            elif [[ $c == "$close" ]]; then
                (( step == 0 )) && break
                (( step = step > 0 ? step - 1 : 0 ))
            fi
        done
    done
    REPLY=$it
}

# `find_nth_pairs_pos`: sets _zhm_ra/_zhm_rh to the pair positions (in the
# direction of the range). $4 is the find type: surround, next or prev.
typeset -g _zhm_surround_error=""
function _zhm_find_nth_pairs_pos() {
    local ch=$1 find_type=$4
    local -i anchor=$2 head=$3 n=$5 pos
    _zhm_surround_error="Surround pair not found around all cursors"
    (( _zhm_len >= 2 )) || return 1
    local -i to=$(( anchor > head ? anchor : head ))
    (( to <= _zhm_len )) || { _zhm_surround_error="Cursor range exceeds text length"; return 1 }
    _zhm_get_pair "$ch"
    local open=$REPLY close=$REPLY2
    _zhm_cursor $anchor $head; pos=$REPLY
    case $find_type in
        (next)
            _zhm_find_nth_char $n "$open" $pos 1 || return 1
            (( pos = REPLY + 1, n = 1 ))
            ;;
        (prev)
            _zhm_find_nth_char $n "$close" $pos 0 || return 1
            (( pos = REPLY - 1, n = 1 ))
            ;;
    esac
    local -i op cp
    if [[ $open == "$close" ]]; then
        if [[ ${_zhm_chars[pos + 1]} == "$open" ]]; then
            if _zhm_match_bracket_plain $pos; then
                if (( REPLY > pos )); then
                    op=$pos cp=$REPLY
                else
                    op=$REPLY cp=$pos
                fi
            else
                _zhm_surround_error="Cursor on ambiguous surround pair"
                return 1
            fi
        else
            _zhm_find_nth_char $n "$open" $pos 0 || return 1
            op=$REPLY
            _zhm_find_nth_char $n "$close" $pos 1 || return 1
            cp=$REPLY
        fi
    else
        _zhm_find_nth_open_pair "$open" "$close" $pos $n || return 1
        op=$REPLY
        _zhm_find_nth_close_pair "$open" "$close" $pos $n || return 1
        cp=$REPLY
    fi
    if (( head >= anchor )); then
        _zhm_ra=$op _zhm_rh=$cp
    else
        _zhm_ra=$cp _zhm_rh=$op
    fi
}

# `find_nth_closest_pairs_plain`.
function _zhm_find_nth_closest_pairs() {
    local -i anchor=$1 head=$2 skip=$3
    _zhm_surround_error="Surround pair not found around all cursors"
    local -i from=$(( anchor < head ? anchor : head )) to=$(( anchor < head ? head : anchor ))
    local -a stack
    local -i close_pos=$(( from > 0 ? from - 1 : 0 )) i
    for (( i = from; i < _zhm_len; i++ )); do
        (( close_pos++ ))
        local ch=${_zhm_chars[i + 1]}
        if _zhm_is_open_bracket "$ch"; then
            stack+=( "$ch" )
            continue
        fi
        _zhm_is_close_bracket "$ch" || continue
        _zhm_get_pair "$ch"
        local open=$REPLY close=$REPLY2
        if (( ${#stack} )) && [[ ${stack[-1]} == "$open" ]]; then
            stack[-1]=()
            continue
        fi
        if _zhm_find_nth_open_pair "$open" "$close" $close_pos 1; then
            local -i open_pos=$REPLY
            if (( open_pos <= from + 1 && close_pos >= (to > 0 ? to - 1 : 0) )); then
                if (( skip > 1 )); then
                    (( skip-- ))
                    continue
                fi
                if (( head >= anchor )); then
                    _zhm_ra=$open_pos _zhm_rh=$close_pos
                else
                    _zhm_ra=$close_pos _zhm_rh=$open_pos
                fi
                return 0
            fi
        fi
    done
    return 1
}

# Converts a pair position range from the functions above into an inside or
# around text object range.
function _zhm_pair_textobject() {
    local -i a=$1 h=$2
    local kind=$3
    if [[ $kind == inside ]]; then
        if (( a < h )); then
            _zhm_ra=$(( a + 1 )) _zhm_rh=$h
        else
            _zhm_ra=$a _zhm_rh=$(( h + 1 ))
        fi
    else
        if (( a < h )); then
            _zhm_ra=$a _zhm_rh=$(( h + 1 ))
        else
            _zhm_ra=$(( a + 1 )) _zhm_rh=$h
        fi
    fi
}
