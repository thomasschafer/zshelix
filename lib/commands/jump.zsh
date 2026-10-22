# Jumping to words with two-character labels (`gw`), ported from Helix's
# `jump_to_word` and `jump_to_label`.

# Whether the two characters before $1 (or from $1 if $2 is set) are both
# word characters.
function _zhm_two_word_chars() {
    local -i pos=$1 forward=$2
    if (( forward )); then
        (( pos + 2 <= _zhm_len )) || return 1
        _zhm_is_word_char "${_zhm_chars[pos + 1]}" && _zhm_is_word_char "${_zhm_chars[pos + 2]}"
    else
        (( pos >= 2 )) || return 1
        _zhm_is_word_char "${_zhm_chars[pos]}" && _zhm_is_word_char "${_zhm_chars[pos - 1]}"
    fi
}

# Jump candidates, alternating forwards and backwards from the cursor, as a
# flat list of anchor/head pairs in $reply.
function _zhm_jump_candidates() {
    local -i limit=$(( ${#ZHM_JUMP_LABEL_ALPHABET} * ${#ZHM_JUMP_LABEL_ALPHABET} ))
    local -i cursor fa fh ra rh n=0
    _zhm_primary_cursor; cursor=$REPLY
    fa=$cursor fh=$cursor ra=$cursor rh=$cursor
    if (( cursor < _zhm_len )) && ! _zhm_is_whitespace "${_zhm_chars[cursor + 1]}"; then
        _zhm_word_move next_word_end $fa $fh 1
        (( _zhm_ra == cursor )) && fa=$_zhm_ra fh=$_zhm_rh
        _zhm_word_move prev_word_start $ra $rh 1
        (( _zhm_ra == (cursor < _zhm_len ? cursor + 1 : _zhm_len) )) && ra=$_zhm_ra rh=$_zhm_rh
    fi
    local -a words=()
    while :; do
        local -i changed=0
        while (( fh < _zhm_len )); do
            _zhm_word_move next_word_end $fa $fh 1
            fa=$_zhm_ra fh=$_zhm_rh
            _zhm_two_word_chars $fh 0 || continue
            changed=1
            while (( fa < _zhm_len )) && ! _zhm_is_word_char "${_zhm_chars[fa + 1]}"; do (( fa++ )); done
            words+=( $fa $fh )
            (( ++n == limit )) && break 2
            break
        done
        while (( rh > 0 )); do
            _zhm_word_move prev_word_start $ra $rh 1
            ra=$_zhm_ra rh=$_zhm_rh
            _zhm_two_word_chars $rh 1 || continue
            changed=1
            while (( ra > 0 )) && ! _zhm_is_word_char "${_zhm_chars[ra]}"; do (( ra-- )); done
            words+=( $ra $rh )
            (( ++n == limit )) && break 2
            break
        done
        (( changed )) || break
    done
    reply=( "${words[@]}" )
}

function _zhm_jump_to_word() {
    local -i extend=$1 i
    local alphabet=$ZHM_JUMP_LABEL_ALPHABET
    local -i size=${#alphabet}
    (( size )) || return 0
    _zhm_jump_candidates
    local -a words=()
    words=( "${reply[@]}" )
    local -i count=$(( ${#words} / 2 ))
    (( count )) || return 0

    # Show the labels by temporarily writing them over the start of each
    # word, which keeps the text the same length.
    local saved_buffer=$BUFFER
    local -a saved_hl=()
    saved_hl=( "${region_highlight[@]}" )
    local shown=$BUFFER
    local -a hl=()
    for (( i = 0; i < count; i++ )); do
        local -i from=${words[2 * i + 1]} to=${words[2 * i + 2]}
        (( from = from < to ? from : to ))
        (( from + 2 <= ${#shown} )) || continue
        shown[from+1]=${alphabet[i / size + 1]}
        shown[from+2]=${alphabet[i % size + 1]}
        hl+=( "$from $(( from + 2 )) $ZHM_STYLE_JUMP_LABEL" )
    done
    _zhm_suspend_sync=1
    BUFFER=$shown
    region_highlight+=( "${hl[@]}" )
    zle -R

    local -i outer=-1 inner=-1
    _zhm_read_key
    if [[ $REPLY == ? && $alphabet == *$REPLY* ]]; then
        outer=$(( ${alphabet[(i)$REPLY]} - 1 ))
        if (( outer * size <= count )); then
            _zhm_read_key
            [[ $REPLY == ? && $alphabet == *$REPLY* ]] && inner=$(( ${alphabet[(i)$REPLY]} - 1 ))
        fi
    fi
    BUFFER=$saved_buffer
    region_highlight=( "${saved_hl[@]}" )
    _zhm_suspend_sync=0
    (( outer >= 0 && inner >= 0 )) || return 0
    local -i idx=$(( outer * size + inner ))
    (( idx < count )) || return 0
    local -i a=${words[2 * idx + 1]} h=${words[2 * idx + 2]}
    if (( extend )); then
        local -i pa=${_zhm_sa[_zhm_pi]} ph=${_zhm_sh[_zhm_pi]}
        local -i pf=$(( pa < ph ? pa : ph )) pt=$(( pa < ph ? ph : pa ))
        if (( a < h )); then
            (( a = a < pf ? a : pf ))
        else
            (( a = a > pt ? a : pt ))
        fi
    else
        _zhm_with_direction $a $h 1
        a=$_zhm_ra h=$_zhm_rh
    fi
    _zhm_save_jump
    _zhm_set_single $a $h
}

function _zhm_cmd_goto_word() { _zhm_jump_to_word 0 }
function _zhm_cmd_extend_to_word() { _zhm_jump_to_word 1 }
