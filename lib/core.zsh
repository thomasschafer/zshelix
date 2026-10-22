# Core data model: text, lines, characters, ranges and selections.
#
# The editable text is modelled on a Helix document. A command line is treated
# like a file that ends with a newline, so the text starts out as `$BUFFER`
# plus a trailing "\n". That newline is never part of `$BUFFER`, but it gives
# the cursor somewhere to sit at the end of the line, exactly as in Helix.
# Edits can remove it (just as they can in Helix), in which case `$BUFFER` is
# the whole text.
#
# All positions are 0-based character offsets into that text and, as in Helix,
# refer to the gaps between characters. A range is a pair of positions (anchor,
# head). Selections are stored as parallel arrays of anchors and heads, plus the
# 1-based index of the primary range.

typeset -g _zhm_text=$'\n'
typeset -gi _zhm_len=1
typeset -ga _zhm_chars=( $'\n' )
typeset -ga _zhm_lines=( 0 1 )

typeset -ga _zhm_sa=( 0 ) _zhm_sh=( 1 )
# Sticky visual column for vertical movement (-1 when unset), one per range.
typeset -ga _zhm_scol=( -1 )
typeset -gi _zhm_pi=1

# Scratch range used to return results from range functions.
typeset -gi _zhm_ra=0 _zhm_rh=0

typeset -g _zhm_mode=insert

# Position of the most recent edit, for `g.`.
typeset -gi _zhm_last_edit=-1
# When all uncommitted changes compose to a single insertion (as when typing),
# its start and text; _zhm_ins_from is -1 otherwise. Used to emulate Helix's
# `try_restore_indent`, which looks at the composed changes.
typeset -gi _zhm_ins_from=-1
typeset -g _zhm_ins_text=""

### Errors ###

# Fail loudly: invariant violations are programming errors and should be
# visible rather than silently ignored.
function _zhm_bug() {
    local msg="zshelix internal error: $*"
    if zle; then
        zle -M -- "$msg"
    else
        print -ru2 -- "$msg"
    fi
    return 1
}

### Text ###

function _zhm_load_text() {
    _zhm_set_text_raw "$BUFFER"$'\n'
}

# Set the text and update all derived state.
function _zhm_set_text_raw() {
    _zhm_text=$1
    _zhm_len=${#_zhm_text}
    _zhm_chars=( "${(@s::)_zhm_text}" )
    local -a parts=()
    parts=( "${(@ps:\n:)_zhm_text}" )
    _zhm_lines=()
    local -i p=0
    local part=""
    for part in "${parts[@]}"; do
        _zhm_lines+=( $p )
        (( p += ${#part} + 1 ))
    done
}

# Write the text back to the zle buffer.
function _zhm_store_text() {
    BUFFER=${_zhm_text%$'\n'}
}

# Line index (0-based) containing position $1.
function _zhm_line_of() {
    local -i pos=$1 i
    for (( i = ${#_zhm_lines}; i > 1; i-- )); do
        (( _zhm_lines[i] <= pos )) && break
    done
    REPLY=$(( i - 1 ))
}

function _zhm_line_start() {
    REPLY=${_zhm_lines[$1 + 1]}
}

# Position of the line ending of line $1 (or the end of the text for the last
# line), i.e. Helix's `line_end_char_index`.
function _zhm_line_end() {
    local -i line=$1
    if (( line + 2 <= ${#_zhm_lines} )); then
        REPLY=$(( _zhm_lines[line + 2] - 1 ))
    else
        REPLY=$_zhm_len
    fi
}

# Start of the line after $1, clamped to the end of the text.
function _zhm_line_next_start() {
    local -i line=$1
    if (( line + 2 <= ${#_zhm_lines} )); then
        REPLY=${_zhm_lines[line + 2]}
    else
        REPLY=$_zhm_len
    fi
}

### Characters ###

# Character categories, mirroring `helix_core::chars::CharCategory`.
typeset -gi _ZHM_EOL=0 _ZHM_WS=1 _ZHM_WORD=2 _ZHM_PUNCT=3 _ZHM_UNKNOWN=4

function _zhm_cat() {
    case $1 in
        ($'\n'|$'\r'|$'\v'|$'\f') REPLY=$_ZHM_EOL ;;
        ([[:space:]]) REPLY=$_ZHM_WS ;;
        ([[:alnum:]_]) REPLY=$_ZHM_WORD ;;
        ([[:punct:]]) REPLY=$_ZHM_PUNCT ;;
        (*) REPLY=$_ZHM_UNKNOWN ;;
    esac
}

function _zhm_is_word_char() {
    [[ $1 == [[:alnum:]_] ]]
}

# Rust's `char::is_whitespace`, which includes line endings.
function _zhm_is_whitespace() {
    [[ $1 == [[:space:]] ]]
}

function _zhm_is_line_ending() {
    [[ $1 == ($'\n'|$'\r'|$'\v'|$'\f') ]]
}

# Display width of a single character.
function _zhm_char_width() {
    if [[ $1 == $'\t' ]]; then
        REPLY=$ZHM_TAB_WIDTH
    else
        REPLY=${(m)#1}
        (( REPLY < 1 )) && REPLY=1
    fi
}

### Ranges ###

function _zhm_prev_boundary() {
    REPLY=$(( $1 > 0 ? $1 - 1 : 0 ))
}

# Block cursor position of range ($1, $2).
function _zhm_cursor() {
    if (( $2 > $1 )); then
        REPLY=$(( $2 - 1 ))
    else
        REPLY=$2
    fi
}

# `Range::put_cursor`: sets _zhm_ra/_zhm_rh.
function _zhm_put_cursor() {
    local -i anchor=$1 head=$2 pos=$3 extend=$4
    if (( extend )); then
        if (( head >= anchor && pos < anchor )); then
            (( anchor = anchor < _zhm_len ? anchor + 1 : _zhm_len ))
        elif (( head < anchor && pos >= anchor )); then
            (( anchor = anchor > 0 ? anchor - 1 : 0 ))
        fi
        if (( anchor <= pos )); then
            _zhm_ra=$anchor
            (( _zhm_rh = pos < _zhm_len ? pos + 1 : _zhm_len ))
        else
            _zhm_ra=$anchor
            _zhm_rh=$pos
        fi
    else
        _zhm_ra=$pos
        _zhm_rh=$pos
    fi
}

# `Range::line_range`: sets _zhm_ra (start line) and _zhm_rh (end line).
function _zhm_line_range() {
    local -i from=$(( $1 < $2 ? $1 : $2 )) to=$(( $1 < $2 ? $2 : $1 ))
    if (( from != to )); then
        (( to = to - 1 > from ? to - 1 : from ))
    fi
    _zhm_line_of $from
    _zhm_ra=$REPLY
    _zhm_line_of $to
    _zhm_rh=$REPLY
}

# Sets _zhm_ra/_zhm_rh to range ($1, $2) with direction $3 (1 = forward,
# 0 = backward).
function _zhm_with_direction() {
    local -i a=$1 h=$2 forward=$3
    if (( (h >= a) == forward )); then
        _zhm_ra=$a _zhm_rh=$h
    else
        _zhm_ra=$h _zhm_rh=$a
    fi
}

### Selections ###

function _zhm_primary_cursor() {
    _zhm_cursor ${_zhm_sa[_zhm_pi]} ${_zhm_sh[_zhm_pi]}
}

# Replace the selection. Arguments: primary index, then anchor/head pairs.
function _zhm_set_selection() {
    local -i pi=$1
    shift
    (( $# >= 2 && $# % 2 == 0 )) || { _zhm_bug "invalid selection: $*"; return 1 }
    _zhm_sa=() _zhm_sh=() _zhm_scol=()
    while (( $# )); do
        _zhm_sa+=( $1 ) _zhm_sh+=( $2 ) _zhm_scol+=( -1 )
        shift 2
    done
    (( pi >= 1 && pi <= ${#_zhm_sa} )) || { _zhm_bug "invalid primary index $pi"; return 1 }
    _zhm_pi=$pi
    _zhm_ensure_invariants
}

function _zhm_set_single() {
    _zhm_set_selection 1 $1 $2
}

function _zhm_selection_serialize() {
    local -a parts=()
    local -i i=0
    for (( i = 1; i <= ${#_zhm_sa}; i++ )); do
        parts+=( ${_zhm_sa[i]} ${_zhm_sh[i]} )
    done
    REPLY="$_zhm_pi ${parts[*]}"
}

function _zhm_selection_restore() {
    _zhm_set_selection ${=1}
}

# `Selection::normalize`: sort ranges by start and merge overlapping ones.
function _zhm_normalize() {
    local -i n=${#_zhm_sa}
    (( n < 2 )) && return 0
    local -i pa=${_zhm_sa[_zhm_pi]} ph=${_zhm_sh[_zhm_pi]} i
    local -a keyed=()
    for (( i = 1; i <= n; i++ )); do
        local -i a=${_zhm_sa[i]} h=${_zhm_sh[i]}
        keyed+=( "$(( a < h ? a : h )) $i" )
    done
    keyed=( ${(on)keyed} )
    local -a sa=() sh=() sc=()
    local entry=""
    for entry in "${keyed[@]}"; do
        local -i idx=${entry#* }
        local -i ca=${_zhm_sa[idx]} ch=${_zhm_sh[idx]} cs=${_zhm_scol[idx]:--1}
        if (( ${#sa} )); then
            local -i pa2=${sa[-1]} ph2=${sh[-1]}
            local -i pf=$(( pa2 < ph2 ? pa2 : ph2 )) pt=$(( pa2 < ph2 ? ph2 : pa2 ))
            local -i cf=$(( ca < ch ? ca : ch )) ct=$(( ca < ch ? ch : ca ))
            if (( pf == cf || (pt > cf && ct > pf) )); then
                local -i ma=0 mh=0
                if (( ca > ch && pa2 > ph2 )); then
                    (( ma = ca > pa2 ? ca : pa2, mh = ch < ph2 ? ch : ph2 ))
                else
                    (( ma = cf < pf ? cf : pf, mh = ct > pt ? ct : pt ))
                fi
                if (( (pa2 == pa && ph2 == ph) || (ca == pa && ch == ph) )); then
                    pa=$ma ph=$mh
                fi
                sa[-1]=$ma sh[-1]=$mh sc[-1]=-1
                continue
            fi
        fi
        sa+=( $ca ) sh+=( $ch ) sc+=( $cs )
    done
    _zhm_sa=( "${sa[@]}" ) _zhm_sh=( "${sh[@]}" ) _zhm_scol=( "${sc[@]}" )
    for (( i = 1; i <= ${#_zhm_sa}; i++ )); do
        if (( _zhm_sa[i] == pa && _zhm_sh[i] == ph )); then
            _zhm_pi=$i
            return 0
        fi
    done
    _zhm_bug "primary range lost during normalisation"
}

# `Selection::ensure_invariants`: ranges are at least one character wide
# (except at the very end of the text), sorted and non-overlapping.
function _zhm_ensure_invariants() {
    local -i i=0
    for (( i = 1; i <= ${#_zhm_sa}; i++ )); do
        (( _zhm_sa[i] > _zhm_len )) && _zhm_sa[i]=$_zhm_len
        (( _zhm_sh[i] > _zhm_len )) && _zhm_sh[i]=$_zhm_len
        (( _zhm_sa[i] < 0 )) && _zhm_sa[i]=0
        (( _zhm_sh[i] < 0 )) && _zhm_sh[i]=0
        if (( _zhm_sa[i] == _zhm_sh[i] && _zhm_sh[i] < _zhm_len )); then
            (( _zhm_sh[i]++ ))
        fi
    done
    _zhm_normalize
}

# Apply function $1 to every range. The function receives the anchor and head
# (followed by any extra arguments) and must set _zhm_ra/_zhm_rh.
function _zhm_transform() {
    local fn=$1
    shift
    local -i i=0
    local -a sa=() sh=()
    for (( i = 1; i <= ${#_zhm_sa}; i++ )); do
        _zhm_ra=${_zhm_sa[i]} _zhm_rh=${_zhm_sh[i]}
        $fn ${_zhm_sa[i]} ${_zhm_sh[i]} "$@" || return
        sa+=( $_zhm_ra ) sh+=( $_zhm_rh )
    done
    _zhm_sa=( "${sa[@]}" ) _zhm_sh=( "${sh[@]}" )
    _zhm_scol=( "${(@)_zhm_sa/*/-1}" )
    _zhm_ensure_invariants
}

### Changes ###
#
# A change set is a list of (from, to, replacement) triples which must be
# sorted and non-overlapping, like the changes in a Helix `Transaction`.

typeset -ga _zhm_cf _zhm_ct _zhm_cx

function _zhm_changes_reset() {
    _zhm_cf=() _zhm_ct=() _zhm_cx=()
}

function _zhm_change() {
    _zhm_cf+=( $1 ) _zhm_ct+=( $2 ) _zhm_cx+=( "$3" )
}

# Mapping state, so that mapping positions in increasing order is a single
# pass over the changes: the index of the first change not yet passed, the
# offset accumulated before it, and the last position mapped.
typeset -gi _zhm_mi=1 _zhm_md=0 _zhm_mlast=0

function _zhm_map_reset() {
    _zhm_mi=1 _zhm_md=0 _zhm_mlast=0
}

# Map position $1 through the pending changes. $2 is the association: one of
# before, after, before_sticky or after_sticky (see `helix_core::Assoc`).
# Call `_zhm_map_reset` before mapping a new set of positions.
function _zhm_map_pos() {
    local -i pos=$1 i from to ins delta
    local assoc=$2
    (( pos < _zhm_mlast )) && _zhm_map_reset
    _zhm_mlast=$pos
    delta=$_zhm_md
    for (( i = _zhm_mi; i <= ${#_zhm_cf}; i++ )); do
        from=${_zhm_cf[i]} to=${_zhm_ct[i]} ins=${#_zhm_cx[i]}
        _zhm_mi=$i _zhm_md=$delta
        (( pos < from )) && break
        if (( from == to )); then
            if (( pos == from )); then
                if [[ $assoc == after* ]]; then
                    REPLY=$(( from + delta + ins ))
                else
                    REPLY=$(( from + delta ))
                fi
                return
            fi
        elif (( pos < to )); then
            if (( ins == 0 || pos == from )); then
                REPLY=$(( from + delta ))
            elif [[ $assoc == *_sticky ]] && (( to - from == ins )); then
                REPLY=$(( from + delta + pos - from ))
            elif [[ $assoc == after* ]]; then
                REPLY=$(( from + delta + ins ))
            else
                REPLY=$(( from + delta ))
            fi
            return
        fi
        (( delta += ins - (to - from) ))
    done
    if (( i > ${#_zhm_cf} )); then
        _zhm_mi=$i _zhm_md=$delta
    fi
    REPLY=$(( pos + delta ))
}

# Map range ($1, $2) through the single change ($3, $4, $5).
function _zhm_map_range_one() {
    local -a _zhm_cf=( $3 ) _zhm_ct=( $4 ) _zhm_cx=( "$5" )
    _zhm_map_reset
    _zhm_map_range $1 $2
}

# Map a range through the pending changes (`Range::map`). The start of the
# range sticks after insertions and the end sticks before them.
function _zhm_map_range() {
    local -i a=$1 h=$2
    if (( a == h )); then
        _zhm_map_pos $a after_sticky
        _zhm_ra=$REPLY _zhm_rh=$REPLY
    elif (( a < h )); then
        _zhm_map_pos $a after_sticky
        _zhm_ra=$REPLY
        _zhm_map_pos $h before_sticky
        _zhm_rh=$REPLY
    else
        _zhm_map_pos $h after_sticky
        _zhm_rh=$REPLY
        _zhm_map_pos $a before_sticky
        _zhm_ra=$REPLY
    fi
}

# Apply the pending changes to the text, mapping the selection through them.
# Returns 1 (without touching anything) if there are no effective changes.
function _zhm_apply_changes() {
    local -i n=${#_zhm_cf} i last=0
    local new=""
    local -a cf=() ct=() cx=()
    for (( i = 1; i <= n; i++ )); do
        local -i from=${_zhm_cf[i]} to=${_zhm_ct[i]}
        (( from < last || to < from || to > _zhm_len )) && {
            _zhm_bug "unsorted or invalid change ($from, $to) after $last"
            _zhm_changes_reset
            return 2
        }
        (( from == to )) && [[ -z ${_zhm_cx[i]} ]] && continue
        new+=${_zhm_text:$last:$(( from - last ))}${_zhm_cx[i]}
        if (( ${#cf} && from == ct[-1] )); then
            # Adjacent changes merge into one, as in a Helix ChangeSet.
            ct[-1]=$to
            cx[-1]+=${_zhm_cx[i]}
        else
            cf+=( $from ) ct+=( $to ) cx+=( "${_zhm_cx[i]}" )
        fi
        last=$to
    done
    _zhm_cf=( "${cf[@]}" ) _zhm_ct=( "${ct[@]}" ) _zhm_cx=( "${cx[@]}" )
    if (( ! ${#_zhm_cf} )); then
        return 1
    fi
    new+=${_zhm_text:$last}
    _zhm_compose_insert
    local -i was_dirty=$_zhm_dirty
    _zhm_history_begin_change
    local -a sa=() sh=()
    _zhm_map_reset
    for (( i = 1; i <= ${#_zhm_sa}; i++ )); do
        _zhm_map_range ${_zhm_sa[i]} ${_zhm_sh[i]}
        sa+=( $_zhm_ra ) sh+=( $_zhm_rh )
    done
    # Position for `g.` (Helix's `last_edit_pos`): the end of the change
    # overlapping the primary selection (or the first change) in a revision,
    # mapped through later changes in the same revision.
    if (( ! was_dirty )); then
        local -i pa=${_zhm_sa[_zhm_pi]} ph=${_zhm_sh[_zhm_pi]} k pick=1 delta=0
        local -i pf=$(( pa < ph ? pa : ph )) pt=$(( pa < ph ? ph : pa ))
        for (( k = 1; k <= ${#_zhm_cf}; k++ )); do
            local -i f=${_zhm_cf[k]} t=${_zhm_ct[k]}
            if (( f == pf || (t > pf && pt > f) )); then
                pick=$k
                break
            fi
        done
        for (( k = 1; k < pick; k++ )); do
            (( delta += ${#_zhm_cx[k]} - (_zhm_ct[k] - _zhm_cf[k]) ))
        done
        _zhm_last_edit=$(( _zhm_cf[pick] + delta + ${#_zhm_cx[pick]} ))
    else
        _zhm_map_reset
        _zhm_map_pos $_zhm_last_edit after
        _zhm_last_edit=$REPLY
    fi
    _zhm_set_text_raw "$new"
    _zhm_sa=( "${sa[@]}" ) _zhm_sh=( "${sh[@]}" )
    _zhm_scol=( "${(@)_zhm_sa/*/-1}" )
    _zhm_ensure_invariants
    _zhm_store_text
    _zhm_changes_reset
    return 0
}

# Update the composed insertion (see _zhm_ins_from) with the pending changes.
function _zhm_compose_insert() {
    local -i from=${_zhm_cf[1]} to=${_zhm_ct[1]}
    local text=${_zhm_cx[1]}
    if (( ${#_zhm_cf} != 1 )); then
        _zhm_ins_from=-1
    elif (( ! _zhm_dirty )); then
        if (( from == to )); then
            _zhm_ins_from=$from _zhm_ins_text=$text
        else
            _zhm_ins_from=-1
        fi
    elif (( _zhm_ins_from >= 0 )); then
        local -i end=$(( _zhm_ins_from + ${#_zhm_ins_text} ))
        if (( from >= _zhm_ins_from && to <= end )); then
            local -i rel_from=$(( from - _zhm_ins_from )) rel_to=$(( to - _zhm_ins_from ))
            _zhm_ins_text=${_zhm_ins_text:0:$rel_from}$text${_zhm_ins_text:$rel_to}
            [[ -n $_zhm_ins_text ]] || _zhm_ins_from=-1
        else
            _zhm_ins_from=-1
        fi
    fi
}

### Indentation ###

# Effective indent width (0 for tabs): ZHM_INDENT_WIDTH unless the text's own
# indentation style was detected.
typeset -gi _zhm_indent_width=2

# Helix's `auto_detect_indent_style`: a histogram of indentation increases
# between consecutive lines. Sets _zhm_indent_width.
function _zhm_detect_indent() {
    _zhm_indent_width=$ZHM_INDENT_WIDTH
    local -a hist=()
    hist=( 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 )
    local -i prev_tabs=0 prev_count=0 n=0
    local line=""
    for line in "${(@f)_zhm_text}"; do
        (( ++n > 1000 )) && break
        local first=${line[1]}
        local -i is_tabs=0
        if [[ $first == $'\t' ]]; then
            is_tabs=1
        elif [[ $first == ' ' ]]; then
            is_tabs=0
        elif [[ -z $first ]]; then
            continue
        else
            prev_tabs=0 prev_count=0
            continue
        fi
        local lead=""
        if (( is_tabs )); then
            lead=${(M)line##$'\t'#}
        else
            lead=${(M)line## #}
        fi
        local -i count=${#lead}
        local rest=${line:$count}
        # Lines of only whitespace are blank.
        [[ $rest == [[:space:]]# ]] && continue
        (( count > 256 )) && continue
        if (( (prev_tabs == is_tabs || prev_count == 0) && prev_count < count )); then
            if (( is_tabs )); then
                (( hist[1]++ ))
            else
                local -i amount=$(( count - prev_count ))
                (( amount <= 16 )) && (( hist[amount + 1]++ ))
            fi
        fi
        prev_tabs=$is_tabs prev_count=$count
    done
    (( hist[1] *= 2 ))
    (( hist[2] > 1 )) && (( hist[2] /= 2 ))
    local -i best=1 i second=0
    for (( i = 2; i <= 17; i++ )); do
        (( hist[i] > hist[best] )) && best=$i
    done
    for (( i = 1; i <= 17; i++ )); do
        (( i != best && hist[i] > second )) && second=${hist[i]}
    done
    if (( hist[best] >= 1 && second * 100 < 66 * hist[best] )); then
        _zhm_indent_width=$(( best - 1 ))
    fi
}
