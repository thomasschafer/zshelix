typeset -g ZSH_HIGHLIGHT_STYLE="bg=240"

typeset -g ZHM_CURSOR_NORMAL='\e[2 q'
typeset -g ZHM_CURSOR_INSERT='\e[6 q'
typeset -g ZHM_CURSOR_SELECT='\e[4 q'

# typeset -g ZHM_CURSOR_NORMAL=$'\e[2 q\e]12;#b8c0e0\a'
# typeset -g ZHM_CURSOR_INSERT=$'\e[6 q\e]12;#f4dbd6\a'
# typeset -g ZHM_CURSOR_SELECT=$'\e[2 q\e]12;#f5a97f\a'

typeset -g ZHM_MODE_NORMAL="NORMAL"
typeset -g ZHM_MODE_INSERT="INSERT"
typeset -g ZHM_MODE_SELECT="SELECT"

typeset -g ZHM_MOVEMENT_MOVE="MOVEMENT_MOVE"
typeset -g ZHM_MOVEMENT_EXTEND="MOVEMENT_EXTEND"

typeset -gA ZHM_VALID_MODES=($ZHM_MODE_NORMAL 1 $ZHM_MODE_INSERT 1 $ZHM_MODE_SELECT 1)
typeset -g ZHM_MODE=$ZHM_MODE_INSERT

typeset -ga ZHM_UNDO_STATES=() # cursor_idx, anchor_idx, buffer_text
typeset -g ZHM_UNDO_INDEX=-1

# -1 means no selection
typeset -g ZHM_ANCHOR=-1
typeset -g ZHM_CLIPBOARD=""

### Utility functions ###
function zhm_sign() {
    local num=$1
    echo $(( num > 0 ? 1 : num < 0 ? -1 : 0 ))
}

function zhm_max() {
    echo $(( $1 > $2 ? $1 : $2 ))
}

function zhm_min() {
    echo $(( $1 < $2 ? $1 : $2 ))
}

function zhm_log() {
    echo $1 >> zhm.log
}

function zhm_clamp() {
    local val=$1
    local min=$2
    local max=$3
    if ((val < min)); then
        echo $min
    elif ((val > max)); then
        echo $max
    else
        echo $val
    fi
}

### Buffer state ###
ZHM_EMPTY_BUFFER="<ZHM_EMPTY_BUFFER>"

function zhm_history_append() {
    if [[ $# -ne 3 ]]; then
        echo "Error (zhm_history_append): Requires exactly 3 arguments, found $*" >&2
        return 1
    fi

    if [[ ! $1 =~ ^-?[0-9]+$ ]] || [[ ! $2 =~ ^-?[0-9]+$ ]]; then
        echo "Error (zhm_history_append): First two arguments must be integers" >&2
        return 1
    fi

    # Only base64 encode non-empty buffer content
    local encoded_buffer
    if [[ -n $3 && $3 != $ZHM_EMPTY_BUFFER ]]; then
        encoded_buffer=$(print -n "$3" | base64)
    else
        encoded_buffer=$ZHM_EMPTY_BUFFER
    fi

    # truncate history at this point
    local cut_at=$(((ZHM_UNDO_INDEX + 1) * 3))
    ZHM_UNDO_STATES=(${(@)ZHM_UNDO_STATES[1,$cut_at]})
    ZHM_UNDO_STATES+=($1 $2 $encoded_buffer)
    ((ZHM_UNDO_INDEX++))
}

function zhm_history_get_state() {
    local start=$((ZHM_UNDO_INDEX * 3 + 1))
    if [[ $start -ge ${#ZHM_UNDO_STATES[@]} ]]; then
        echo "Error (zhm_history_get_state): Index $start out of range" >&2
        return 1
    fi

    typeset -g _zhm_state_cursor=${ZHM_UNDO_STATES[$start]}
    typeset -g _zhm_state_anchor=${ZHM_UNDO_STATES[$start+1]}
    local encoded_buffer=${ZHM_UNDO_STATES[$start+2]}

    if [[ $encoded_buffer == $ZHM_EMPTY_BUFFER ]]; then
        typeset -g _zhm_state_buffer=""
    else
        typeset -g _zhm_state_buffer=$(base64 -d <<< $encoded_buffer)
    fi
    return 0
}

function zhm_debug_logs() {}

function zhm_update_buffer() {
    local save_state=$1
    local new_buffer=${2:-""}
    if [[ $new_buffer == $ZHM_EMPTY_BUFFER ]]; then
        new_buffer=""
    fi

    if [[ $save_state == 1 && ($BUFFER != $new_buffer) ]]; then
        zhm_save_state
    fi
    BUFFER=$new_buffer
}

function zhm_save_state() {
    # Only save if buffer content changed
    if [[ ${#ZHM_UNDO_STATES} -eq 0 ]] || [[ "$ZHM_UNDO_STATES[-1]" != "$BUFFER" ]]; then
        zhm_history_append ${CURSOR:-0} $ZHM_ANCHOR ${BUFFER:-$ZHM_EMPTY_BUFFER}
    fi
}

function zhm_undo() {
    (( ZHM_UNDO_INDEX <= 0 )) && return

    local buffer_start=$BUFFER

    if zhm_history_get_state; then
        zhm_update_buffer 0 "$_zhm_state_buffer"
        zhm_set_cursor_and_anchor $_zhm_state_cursor $_zhm_state_anchor $ZHM_MOVEMENT_MOVE
        ((ZHM_UNDO_INDEX--))

        if [[ $buffer_start == $BUFFER ]]; then
            zhm_undo
        fi
    fi
}

function zhm_redo() {
    local history_len=$(( ${#ZHM_UNDO_STATES[@]} / 3 ))
    (( ZHM_UNDO_INDEX >= history_len - 1 )) && return

    ((ZHM_UNDO_INDEX++))

    local buffer_start=$BUFFER

    if zhm_history_get_state; then
        zhm_update_buffer 0 "$_zhm_state_buffer"
        zhm_set_cursor_and_anchor $_zhm_state_cursor $_zhm_state_anchor $ZHM_MOVEMENT_MOVE

        if [[ $buffer_start == $BUFFER ]]; then
            zhm_redo
        fi
    fi
}

function zhm_clear_history() {
    ZHM_UNDO_STATES=()
    ZHM_UNDO_INDEX=-1
    zhm_history_append 0 0 $ZHM_EMPTY_BUFFER
}

function zhm_accept_and_clear() {
    zhm_clear_history
    zhm_remove_highlight
    zle accept-line
}

### Selection and highlighting ###
function zhm_set_cursor_and_anchor() {
    function zhm_safe_cursor_move() {
        local new_pos=$1
        CURSOR=$(zhm_clamp $new_pos 0 $#BUFFER)
    }

    function zhm_safe_anchor_move() {
        local new_pos=$1
        local upper_bound=$#BUFFER
        if ((CURSOR < upper_bound)); then
            ((upper_bound--))
        fi
        ZHM_ANCHOR=$(zhm_clamp $new_pos 0 $upper_bound)
    }

    if [[ $# -ne 3 ]]; then
        echo "Error (zhm_set_cursor_and_anchor): Requires exactly 3 arguments, found $*" >&2
        return 1
    fi

    local cursor=$1
    local anchor=$2
    local movement_type=$3

    zhm_safe_cursor_move $cursor

    case $movement_type in
        $ZHM_MOVEMENT_MOVE)
            zhm_safe_anchor_move $anchor
            ;;
        $ZHM_MOVEMENT_EXTEND)
            case $ZHM_MODE in
                $ZHM_MODE_NORMAL)
                    zhm_safe_anchor_move $anchor
                    ;;
                $ZHM_MODE_INSERT)
                    # TODO: don't do this if we can retain selection in insert mode
                    zhm_safe_anchor_move $CURSOR
                    ;;
                $ZHM_MODE_SELECT)
                    # No-op, extend selection
                    ;;
                *)
                    echo "Invalid mode: $ZHM_MODE" >&2
                    return 1
                    ;;
            esac
            ;;
        *)
            echo "Invalid movement type: $movement_type" >&2
            return 1
            ;;
    esac

    # TODO: remove MODE != INSERT if we can retain selection in insert mode
    if [[ "$ZHM_MODE" != "$ZHM_MODE_INSERT" ]] && (( ZHM_ANCHOR >= 0 )); then
        if ((CURSOR >= ZHM_ANCHOR)); then
            region_highlight=("${ZHM_ANCHOR} $((CURSOR + 1)) ${ZSH_HIGHLIGHT_STYLE}")
        else
            region_highlight=("${CURSOR} $((ZHM_ANCHOR + 1)) ${ZSH_HIGHLIGHT_STYLE}")
        fi
    else
        zhm_remove_highlight
    fi
}

function zhm_set_cursor() {
    if [[ $# -ne 1 ]]; then
        echo "Error (zhm_set_cursor): Requires exactly 1 argument, found $*" >&2
        return 1
    fi

    local new_pos=$1
    zhm_set_cursor_and_anchor $new_pos $ZHM_ANCHOR $ZHM_MOVEMENT_EXTEND
}

function zhm_set_anchor() {
    if [[ $# -ne 2 ]]; then
        echo "Error (zhm_set_anchor): Requires exactly 2 arguments, found $*" >&2
        return 1
    fi

    local new_pos=$1
    local movement_type=$2
    zhm_set_cursor_and_anchor $CURSOR $new_pos $movement_type
}

function zhm_remove_highlight() {
    region_highlight=()
}

function zhm_get_selection_bounds() {
    if ((ZHM_ANCHOR < 0)); then
        return 1
    fi
    if ((CURSOR >= ZHM_ANCHOR)); then
        echo $ZHM_ANCHOR $((CURSOR + 1))
    else
        echo $CURSOR $((ZHM_ANCHOR + 1))
    fi
}

function zhm_collapse_selection() {
    zhm_set_cursor_and_anchor $CURSOR $CURSOR $ZHM_MOVEMENT_MOVE
}

function zhm_flip_selections() {
    zhm_set_cursor_and_anchor $ZHM_ANCHOR $CURSOR $ZHM_MOVEMENT_MOVE
}

### Mode switching ###
function zhm_insert_mode_impl() {
    # TODO: don't lose highlight
    zhm_remove_highlight
    ZHM_MODE=$ZHM_MODE_INSERT
    zhm_print_cursor
    bindkey -v
    zhm_save_state
}

function zhm_normal_mode() {
    if [[ "$ZHM_MODE" == "$ZHM_MODE_INSERT" ]]; then
        # TODO: we won't need this if we can keep highlight in insert mode
        zhm_set_anchor $CURSOR $ZHM_MOVEMENT_EXTEND
    fi
    ZHM_MODE=$ZHM_MODE_NORMAL
    zhm_print_cursor
    bindkey -A helix-normal-mode main
    zhm_save_state
}

function zhm_select_mode_flip() {
    if [[ "$ZHM_MODE" == "$ZHM_MODE_SELECT" ]]; then
        ZHM_MODE=$ZHM_MODE_NORMAL
    else
        ZHM_MODE=$ZHM_MODE_SELECT
    fi
    zhm_print_cursor
    # TODO: do we need a helix-select-mode?
    bindkey -A helix-normal-mode main
    zhm_save_state
}

### Basic movement and editing ###
function zhm_move_char_left() {
    local pos=$((CURSOR - 1))
    zhm_set_cursor_and_anchor $pos $pos $ZHM_MOVEMENT_EXTEND
}

function zhm_move_char_right() {
    local pos=$((CURSOR + 1))
    zhm_set_cursor_and_anchor $pos $pos $ZHM_MOVEMENT_EXTEND
}

function zhm_move_visual_line_down() {
    zle down-line-or-history
    zhm_set_anchor $CURSOR $ZHM_MOVEMENT_EXTEND
}

function zhm_move_visual_line_up() {
    zle up-line-or-history
    zhm_set_anchor $CURSOR $ZHM_MOVEMENT_EXTEND
}

function zhm_append_mode() {
    # TODO: after exiting to normal mode, move cursor back one. Also don't lose highlight
    local pos=$(( $(zhm_max CURSOR ZHM_ANCHOR) + 1))
    zhm_set_cursor_and_anchor $pos $pos $ZHM_MOVEMENT_EXTEND
    zhm_insert_mode_impl

}

function zhm_insert_mode() {
    local pos=$(zhm_min CURSOR ZHM_ANCHOR)
    zhm_set_cursor_and_anchor $pos $pos $ZHM_MOVEMENT_EXTEND
    zhm_insert_mode_impl
}

function zhm_find_line_first_non_blank() {
    local pos=$1
    local line_start=$(zhm_find_line_start $pos)
    local line_end=$(zhm_find_line_end $pos)
    local current=$line_start

    while ((current < line_end)) && [[ "${BUFFER:$current:1}" =~ [[:space:]] ]]; do
        ((current++))
    done

    echo $current
}

function zhm_insert_at_line_end() {
    local pos=$(zhm_find_line_end $CURSOR)
    zhm_set_cursor_and_anchor $pos $pos $ZHM_MOVEMENT_MOVE
    zhm_insert_mode_impl
}

function zhm_insert_at_line_start() {
    local pos=$(zhm_find_line_first_non_blank $CURSOR)
    zhm_set_cursor_and_anchor $pos $pos $ZHM_MOVEMENT_MOVE
    zhm_insert_mode_impl
}

function zhm_delete_char_forward() {
    if ((CURSOR < $#BUFFER)); then
        zhm_update_buffer 1 "${BUFFER:0:$CURSOR}${BUFFER:$((CURSOR+1))}"
    fi
}

### Word operations ###
# TODO: these should stop at punctuation etc. matching e.g. zhm_move_prev_word_start. Maybe just replace with built-in C-w?
function zhm_delete_word_forward() {
    local pos=$CURSOR
    # Skip current word if we're in one
    while ((pos < $#BUFFER)) && [[ ! "${BUFFER:$pos:1}" =~ [[:space:]] ]]; do
        ((pos++))
    done
    # Skip spaces
    while ((pos < $#BUFFER)) && [[ "${BUFFER:$pos:1}" =~ [[:space:]] ]]; do
        ((pos++))
    done
    zhm_update_buffer 1 "${BUFFER:0:$CURSOR}${BUFFER:$pos}"
}

### Selection operations ###
function zhm_operate_on_selection() {
    local operation=$1  # "yank", "cut", or "delete"

    local bounds=($(zhm_get_selection_bounds))
    if ((${#bounds} != 2)); then
        return 1
    fi
    local start=$bounds[1]
    local end=$bounds[2]

    ZHM_CUT_BUFFER="${BUFFER:$start:$((end-start))}"

    if [[ $operation != "yank" ]]; then
        zhm_update_buffer 1 "${BUFFER:0:$start}${BUFFER:$end}"
        zhm_set_cursor_and_anchor $start $start $ZHM_MOVEMENT_MOVE
    fi

    case $operation in
        "cut")
            zhm_insert_mode_impl
            ;;
        "delete")
            zhm_normal_mode
            ;;
        "yank")
            zhm_normal_mode
            ;;
        *)
            echo "Invalid operation: $operation" >&2
            return 1
            ;;
    esac

    return 0
}

function zhm_yank() {
    zhm_operate_on_selection "yank"
}

function zhm_change_selection() {
    zhm_operate_on_selection "cut"
}

function zhm_delete_selection() {
    zhm_operate_on_selection "delete"
}

function zhm_paste() {
    local before=$1  # 1 for paste before, 0 for paste after

    if [[ -z "$ZHM_CUT_BUFFER" ]]; then
        return
    fi
    local bounds=($(zhm_get_selection_bounds))
    if ((${#bounds} != 2)); then
        return 1
    fi

    local paste_pos=$((before ? bounds[1] : bounds[2]))
    if ((paste_pos > ${#BUFFER})); then
        ((paste_pos--))
    fi

    zhm_update_buffer 1 "${BUFFER:0:$paste_pos}${ZHM_CUT_BUFFER}${BUFFER:$paste_pos}"

    local pos1=$paste_pos
    local pos2=$((paste_pos + ${#ZHM_CUT_BUFFER} - 1))

    # Select pasted contents
    local ordering=$(zhm_sign $((CURSOR - ZHM_ANCHOR)))
    local cursor= anchor=
    if [[ $ordering == 1 ]]; then
        cursor=$pos2
        anchor=$pos1
    else
        cursor=$pos1
        anchor=$pos2
    fi
    zhm_set_cursor_and_anchor $cursor $anchor $ZHM_MOVEMENT_MOVE

    zhm_normal_mode
}

function zhm_paste_after() {
    zhm_paste 0
}

function zhm_paste_before() {
    zhm_paste 1
}

function zhm_replace() {
    local bounds=($(zhm_get_selection_bounds))
    if ((${#bounds} != 2)); then
        return 1
    fi
    local start=$bounds[1]
    local end=$bounds[2]
    local len=$((end - start))

    read -k 1 char
    if [[ $? != 0 ]] || [[ $char == $'\e' ]]; then
        zhm_normal_mode
        return 0
    fi

    # Create string of repeated characters
    local replacement=""
    for ((i = 0; i < len; i++)); do
        replacement+="$char"
    done

    zhm_update_buffer 1 "${BUFFER:0:$start}${replacement}${BUFFER:$end}"
    zhm_normal_mode
}

function zhm_replace_with_yanked() {
    local bounds=($(zhm_get_selection_bounds))
    if ((${#bounds} != 2)) || [[ -z "$ZHM_CUT_BUFFER" ]]; then
        return 1
    fi
    local start=$bounds[1]
    local end=$bounds[2]

    zhm_update_buffer 1 "${BUFFER:0:$start}${ZHM_CUT_BUFFER}${BUFFER:$end}"

    # Select pasted contents
    local new_cursor=$((start + ${#ZHM_CUT_BUFFER} - 1))
    zhm_set_cursor_and_anchor $new_cursor $start $ZHM_MOVEMENT_MOVE

    zhm_normal_mode
}

### Word boundary navigation ###
# TODO: this has some issues with single letter words, e.g. when moving back and forth in "a b c"
function zhm_move_word_impl() {
    ## Helper functions ##
    function is_word_char() {
        local char="${BUFFER:$1:1}"
        [[ $char =~ [a-zA-Z0-9_] ]]
    }

    function is_whitespace() {
        local char="${BUFFER:$1:1}"
        [[ $char =~ [[:space:]] ]]
    }

    function is_not_whitespace() {
        ! is_whitespace "$1"
    }

    function is_symbol() {
        ! is_word_char "$1" && ! is_whitespace "$1"
    }

    function char_type() {
        local pos=$1
        if is_word_char $pos; then
            echo 1
        elif is_symbol $pos; then
            echo 2
        else
            echo 3
        fi
    }

    function within_bounds() {
        local num=$1
        if [[ ! $num =~ ^-?[0-9]+$ ]]; then
            echo "Error (zhm_move_word_impl): argument must be a number" >&2
            return 1
        fi
        (( num >= 0 && num <= len - 1 ))
    }

    function consume_word_chars() {
        if ((whitespace_first)) && within_bounds $((pos + step)) && is_whitespace $pos; then
            # TODO: this is hacky
            ((pos += step))
        fi
        local word_matcher=
        case $word_type in
            "word")
                if is_word_char $pos; then
                    word_matcher="is_word_char"
                elif is_symbol $pos; then
                    word_matcher="is_symbol"
                fi
                ;;
            "long_word")
                word_matcher="is_not_whitespace"
                ;;
            *)
                echo "Error (zhm_move_word_impl): Invalid word_type '$word_type'" >&2
                return 1
                ;;
        esac

        if [ -n "$word_matcher" ]; then
            while within_bounds $((pos + step)) && $word_matcher $((pos + step)); do
                ((pos += step))
            done
        fi
    }
    function consume_whitespace() {
        if ((whitespace_first)) && is_not_whitespace $pos; then
            # TODO: this is hacky
            return 0
        fi
        while within_bounds $((pos + step)) && is_whitespace $((pos + step)); do
            ((pos += step))
        done
    }

    ## Argument parsing ##
    if [[ $# -ne 3 ]]; then
        echo "Error (zhm_move_word_impl): Requires exactly 3 arguments, found '$*'" >&2
        return 1
    fi

    local direction=$1  # next | prev
    local position=$2   # start | end
    local word_type=$3  # word | long_word

    local step=
    case $direction in
        "next")
            step=1
            ;;
        "prev")
            step=-1
            ;;
        *)
            echo "Error (zhm_move_word_impl): Invalid direction '$direction'" >&2
            return 1
            ;;
    esac

    local whitespace_first=
    case $position in
        "start")
            case $direction in
                "next")
                    whitespace_first=0
                    ;;
                "prev")
                    whitespace_first=1
                    ;;
                *)
                    echo "Error (zhm_move_word_impl): Invalid direction '$direction'" >&2
                    return 1
                    ;;
            esac
            ;;
        "end")
            whitespace_first=1
            ;;
        *)
            echo "Error (zhm_move_word_impl): Invalid position '$position'" >&2
            return 1
            ;;
    esac

    ## Logic ##
    local len=$#BUFFER

    local prev_cursor=$CURSOR
    local prev_anchor=$ZHM_ANCHOR
    local pos=$CURSOR

    local prev_step=$(zhm_sign $((prev_cursor - prev_anchor)))
    if (( prev_step != (-step) )) && [[ $(char_type $pos) != $(char_type $((pos + step))) ]]; then
        ((pos += step))
    fi
    local new_anchor=$pos

   if ((whitespace_first)); then
        consume_whitespace
        consume_word_chars
    else
        consume_word_chars
        consume_whitespace
    fi


    local new_cursor=$pos

    zhm_set_cursor_and_anchor $new_cursor $new_anchor $ZHM_MOVEMENT_EXTEND
}

function zhm_move_next_word_start() {
    zhm_move_word_impl "next" "start" "word"
}

function zhm_move_next_long_word_start() {
    zhm_move_word_impl "next" "start" "long_word"
}

function zhm_move_prev_word_start() {
    zhm_move_word_impl "prev" "start" "word"
}

function zhm_move_prev_long_word_start() {
    zhm_move_word_impl "prev" "start" "long_word"
}

function zhm_move_next_word_end() {
    zhm_move_word_impl "next" "end" "word"
}

function zhm_move_next_long_word_end() {
    zhm_move_word_impl "next" "end" "long_word"
}

### Line movement helpers ###
function zhm_find_line_start() {
    local pos=$1
    local start=$pos

    while ((start > 0)) && [[ ${BUFFER:$((start-1)):1} != $'\n' ]]; do
        ((start--))
    done
    echo $start
}

function zhm_find_line_end() {
    local pos=$1
    local buffer_len=$#BUFFER
    local end=$pos

    while ((end < buffer_len)) && [[ ${BUFFER:$end:1} != $'\n' ]]; do
        ((end++))
    done
    echo $end
}

function zhm_swap_cursor_anchor() {
    zhm_set_cursor_and_anchor $ZHM_ANCHOR $CURSOR $ZHM_MOVEMENT_MOVE
}

function zhm_goto_line_start() {
    local line_start=$(zhm_find_line_start $CURSOR)
    zhm_set_cursor_and_anchor $line_start $line_start $ZHM_MOVEMENT_EXTEND
}

function zhm_goto_line_end() {
    local line_end=$(zhm_find_line_end $CURSOR)
    zhm_set_cursor_and_anchor $line_end $line_end $ZHM_MOVEMENT_EXTEND
}


function zhm_goto_first_nonwhitespace() {
    local first_char=$(zhm_find_line_first_non_blank $CURSOR)
    zhm_set_cursor_and_anchor $first_char $first_char $ZHM_MOVEMENT_EXTEND
}

function zhm_goto_file_start() {
    zhm_set_cursor_and_anchor 0 0 $ZHM_MOVEMENT_EXTEND
}

function zhm_goto_last_line() {
    zhm_set_cursor_and_anchor $#BUFFER $#BUFFER $ZHM_MOVEMENT_EXTEND
}

### Line extension commands ###
function zhm_extend_line_below() {
    if ((CURSOR < ZHM_ANCHOR && ZHM_ANCHOR >= 0)); then
        zhm_swap_cursor_anchor
    fi

    local new_anchor=$(zhm_find_line_start $ZHM_ANCHOR)

    local current_line_end=$(zhm_find_line_end $CURSOR)

    local new_cursor=$CURSOR
    if ((new_cursor != current_line_end)); then
        new_cursor=$current_line_end
    else
        if ((new_cursor < $#BUFFER)); then
            ((new_cursor++))
            new_cursor=$(zhm_find_line_end $new_cursor)
        fi
    fi

    zhm_set_cursor_and_anchor $new_cursor $new_anchor $ZHM_MOVEMENT_MOVE
}

function zhm_extend_to_line_bounds() {
    if ((CURSOR > ZHM_ANCHOR && ZHM_ANCHOR >= 0)); then
        zhm_swap_cursor_anchor
    fi

    local new_anchor=$(zhm_find_line_end $ZHM_ANCHOR)

    local current_line_start=$(zhm_find_line_start $CURSOR)

    local new_cursor=$CURSOR
    if ((new_cursor != current_line_start)); then
        new_cursor=$current_line_start
    else
        if ((new_cursor > 0)); then
            ((new_cursor--))
            new_cursor=$(zhm_find_line_start $new_cursor)
        fi
    fi

    zhm_set_cursor_and_anchor $new_cursor $new_anchor $ZHM_MOVEMENT_MOVE
}

function zhm_select_all() {
    zhm_set_cursor_and_anchor $#BUFFER 0 $ZHM_MOVEMENT_EXTEND
}

### Initialisation ###
function zhm_print_cursor() {
    local cursor=
    case $ZHM_MODE in
        $ZHM_MODE_INSERT)
            cursor=$ZHM_CURSOR_INSERT
            ;;
        $ZHM_MODE_NORMAL)
            cursor=$ZHM_CURSOR_NORMAL
            ;;
        $ZHM_MODE_SELECT)
            cursor=$ZHM_CURSOR_SELECT
            ;;
        *)
            echo "Error (zhm_print_cursor): Invalid mode '$ZHM_MODE'" >&2
            return 1
            ;;
    esac

    print -n $cursor
}

function zhm_initialise() {
    local -a widgets=(
        zhm_normal_mode
        zhm_insert_mode
        zhm_select_mode_flip
        zhm_move_char_left
        zhm_move_char_right
        zhm_append_mode
        zhm_insert_at_line_end
        zhm_insert_mode_impl
        zhm_insert_at_line_start
        zhm_yank
        zhm_change_selection
        zhm_delete_selection
        zhm_paste_after
        zhm_paste_before
        zhm_replace
        zhm_replace_with_yanked
        zhm_move_next_word_start
        zhm_move_next_long_word_start
        zhm_move_prev_word_start
        zhm_move_prev_long_word_start
        zhm_move_next_word_end
        zhm_move_next_long_word_end
        zhm_goto_line_start
        zhm_goto_line_end
        zhm_goto_first_nonwhitespace
        zhm_goto_file_start
        zhm_goto_last_line
        zhm_delete_word_forward
        zhm_delete_char_forward
        zhm_undo
        zhm_redo
        zhm_debug_logs
        zhm_extend_line_below
        zhm_extend_to_line_bounds
        zhm_collapse_selection
        zhm_flip_selections
        zhm_select_all
        zhm_move_visual_line_down
        zhm_move_visual_line_up
        zhm_accept_and_clear
    )
    for widget in $widgets; do
        zle -N $widget
    done

    # Normal mode
    bindkey -N helix-normal-mode
    bindkey -M helix-normal-mode 'h' zhm_move_char_left
    bindkey -M helix-normal-mode 'j' zhm_move_visual_line_down
    bindkey -M helix-normal-mode 'k' zhm_move_visual_line_up
    bindkey -M helix-normal-mode 'l' zhm_move_char_right
    bindkey -M helix-normal-mode '\e[D' zhm_move_char_left
    bindkey -M helix-normal-mode '\e[B' zhm_move_visual_line_down
    bindkey -M helix-normal-mode '\e[A' zhm_move_visual_line_up
    bindkey -M helix-normal-mode '\e[C' zhm_move_char_right
    bindkey -M helix-normal-mode 'a' zhm_append_mode
    bindkey -M helix-normal-mode 'A' zhm_insert_at_line_end
    bindkey -M helix-normal-mode 'i' zhm_insert_mode
    bindkey -M helix-normal-mode 'I' zhm_insert_at_line_start
    bindkey -M helix-normal-mode 'y' zhm_yank
    bindkey -M helix-normal-mode 'c' zhm_change_selection
    bindkey -M helix-normal-mode 'd' zhm_delete_selection
    bindkey -M helix-normal-mode 'p' zhm_paste_after
    bindkey -M helix-normal-mode 'P' zhm_paste_before
    bindkey -M helix-normal-mode 'r' zhm_replace
    bindkey -M helix-normal-mode 'R' zhm_replace_with_yanked
    bindkey -M helix-normal-mode 'w' zhm_move_next_word_start
    bindkey -M helix-normal-mode 'W' zhm_move_next_long_word_start
    bindkey -M helix-normal-mode 'b' zhm_move_prev_word_start
    bindkey -M helix-normal-mode 'B' zhm_move_prev_long_word_start
    bindkey -M helix-normal-mode 'e' zhm_move_next_word_end
    bindkey -M helix-normal-mode 'E' zhm_move_next_long_word_end
    bindkey -M helix-normal-mode 'gh' zhm_goto_line_start
    bindkey -M helix-normal-mode 'gl' zhm_goto_line_end
    bindkey -M helix-normal-mode 'gs' zhm_goto_first_nonwhitespace
    bindkey -M helix-normal-mode 'gg' zhm_goto_file_start
    bindkey -M helix-normal-mode 'ge' zhm_goto_last_line
    bindkey -M helix-normal-mode 'u' zhm_undo
    bindkey -M helix-normal-mode 'U' zhm_redo
    bindkey -M helix-normal-mode 'D' zhm_debug_logs
    bindkey -M helix-normal-mode 'x' zhm_extend_line_below
    # TODO: the below should default to `extend_to_line_bounds` - override with config
    bindkey -M helix-normal-mode 'X' zhm_extend_to_line_bounds
    bindkey -M helix-normal-mode ';' zhm_collapse_selection
    bindkey -M helix-normal-mode '\e;' zhm_flip_selections
    bindkey -M helix-normal-mode '%' zhm_select_all
    bindkey -M helix-normal-mode 'v' zhm_select_mode_flip
    bindkey -M helix-normal-mode '\e' zhm_normal_mode
    bindkey -M helix-normal-mode '^M' zhm_accept_and_clear
    bindkey -M helix-normal-mode '^L' clear-screen
    # History search
    bindkey -M helix-normal-mode '^P' up-line-or-history
    bindkey -M helix-normal-mode '^N' down-line-or-history

    # Insert mode
    bindkey -M viins '\e' zhm_normal_mode
    bindkey -M viins '\eb' zhm_move_prev_word_start
    bindkey -M viins '\ef' zhm_move_next_word_start
    bindkey -M viins '\ed' zhm_delete_word_forward
    bindkey -M viins '\e[3~' zhm_delete_char_forward
    bindkey -M viins '\e\177' backward-kill-word
    bindkey -M viins '\e^?' backward-kill-word
    bindkey -M viins '\e[3;3~' zhm_delete_word_forward
    bindkey -M viins '\e\e[3~' zhm_delete_word_forward
    bindkey -M viins '^M' zhm_accept_and_clear
    bindkey -M viins '\eB' zhm_move_prev_word_start
    bindkey -M viins '\eF' zhm_move_next_word_start
    bindkey -M viins '\e[1~' zhm_goto_line_start
    bindkey -M viins '\e[4~' zhm_goto_line_end
    bindkey -M viins '\e[D' backward-char
    bindkey -M viins '\e[C' forward-char
    bindkey -M viins '^?' backward-delete-char
    # History search
    bindkey -M viins '^R' history-incremental-search-backward
    bindkey -M viins '^S' history-incremental-search-forward
    bindkey -M viins '^P' up-line-or-history
    bindkey -M viins '^N' down-line-or-history

    # Set short timeout for escape key
    KEYTIMEOUT=1

    # Start in insert mode with default Zsh behavior
    bindkey -v
    zhm_insert_mode_impl

    # TODO (hacky): we shouldn't need this
    zhm_history_append 0 0 $ZHM_EMPTY_BUFFER
}

zhm_initialise

# TODO:
# - ADD TESTS!
# - Integrate with system clipboard and add options for delete without yanking
