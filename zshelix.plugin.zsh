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
        echo "Error: Requires exactly 3 arguments, found $*" >&2
        return 1
    fi

    if [[ ! $1 =~ ^-?[0-9]+$ ]] || [[ ! $2 =~ ^-?[0-9]+$ ]]; then
        echo "Error: First two arguments must be integers" >&2
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
        echo "Error: Index $start out of range" >&2
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

function zhm_line_finish() {
    zhm_clear_history
    return 0
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
        echo "Error: Requires exactly 3 arguments, found $*" >&2
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
        echo "Error: Requires exactly 1 argument, found $*" >&2
        return 1
    fi

    local new_pos=$1
    zhm_set_cursor_and_anchor $new_pos $ZHM_ANCHOR $ZHM_MOVEMENT_EXTEND
}

function zhm_set_anchor() {
    if [[ $# -ne 2 ]]; then
        echo "Error: Requires exactly 2 arguments, found $*" >&2
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

function zhm_goto_line_start() {
    zhm_set_cursor_and_anchor 0 0 $ZHM_MOVEMENT_EXTEND
}

function zhm_goto_line_end() {
    zhm_set_cursor_and_anchor $#BUFFER $#BUFFER $ZHM_MOVEMENT_EXTEND
}

### Word operations ###
function zhm_delete_word_backward() {
    local pos=$CURSOR
    # Skip any spaces immediately before cursor
    while ((pos > 0)) && [[ "${BUFFER:$((pos-1)):1}" =~ [[:space:]] ]]; do
        ((pos--))
    done
    # Then skip until we hit a space or start of line
    while ((pos > 0)) && [[ ! "${BUFFER:$((pos-1)):1}" =~ [[:space:]] ]]; do
        ((pos--))
    done
    zhm_update_buffer 1 "${BUFFER:0:$pos}${BUFFER:$CURSOR}"
    zhm_set_cursor $pos
}

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

### Word boundary navigation ###
# TODO:
# - doesn't stop at newlines
# - `b` at first char of word keeps first char highlighted
# - `w` should consume all spaces after a word, only consumes first
function zhm_find_word_boundary() {
    local motion=$1    # next_word | next_end | prev_word
    local word_type=$2 # word | WORD
    local len=$#BUFFER

    local pattern is_match
    if [[ $word_type == "WORD" ]]; then
        pattern="[[:space:]]"
        is_match="! [[ \$char =~ \$pattern ]]"  # Match non-space
    elif [[ $word_type == "word" ]]; then
        pattern="[[:alnum:]_]"
        is_match="[[ \$char =~ \$pattern ]]"    # Match word chars
    else
        echo "Invalid word_type: $word_type" >&2
        return 1
    fi

    local prev_cursor=$CURSOR
    local prev_anchor=$ZHM_ANCHOR
    local pos=$CURSOR

    case $motion in
        "next_word")
            while ((pos < len)); do
                local char="${BUFFER:$pos:1}"
                if ! eval $is_match; then
                    ((pos++))
                else
                    break
                fi
            done

            while ((pos < len)); do
                local char="${BUFFER:$pos:1}"
                if eval $is_match; then
                    ((pos++))
                else
                    break
                fi
            done
            ;;

        "next_end")
            if ((pos < len)); then
                ((pos++))
            fi

            while ((pos < len)); do
                local char="${BUFFER:$pos:1}"
                if ! eval $is_match; then
                    ((pos++))
                else
                    break
                fi
            done

            while ((pos < len)); do
                local char="${BUFFER:$pos:1}"
                if eval $is_match; then
                    ((pos++))
                else
                    break
                fi
            done

            # Move back one to land on last char
            ((pos--))
            ;;

        "prev_word")
            while ((pos > 0)); do
                local char="${BUFFER:$((pos-1)):1}"
                if ! eval $is_match; then
                    ((pos--))
                else
                    break
                fi
            done

            while ((pos > 0)); do
                local char="${BUFFER:$((pos-1)):1}"
                if eval $is_match; then
                    ((pos--))
                else
                    break
                fi
            done
            ;;

        *)
            echo "Invalid motion: $motion" >&2
            return 1
            ;;
    esac

    local new_cursor=$pos

    # If continuing in the same direction, move the anchor in the dir by 1 step
    local prev_dir=$(zhm_sign $((prev_cursor - prev_anchor)))
    local new_dir=$(zhm_sign $((new_cursor - prev_cursor)))
    if [[ $new_dir == $prev_dir ]]; then
        new_anchor=$((prev_cursor+new_dir))
    else
        new_anchor=$prev_cursor
    fi

    zhm_set_cursor_and_anchor $new_cursor $new_anchor $ZHM_MOVEMENT_EXTEND
}

function zhm_move_next_word_start() {
    zhm_find_word_boundary "next_word" "word"
}

function zhm_move_next_long_word_start() {
    zhm_find_word_boundary "next_word" "WORD"
}

function zhm_move_prev_word_start() {
    zhm_find_word_boundary "prev_word" "word"
}

function zhm_move_prev_long_word_start() {
    zhm_find_word_boundary "prev_word" "WORD"
}

function zhm_move_next_word_end() {
    zhm_find_word_boundary "next_end" "word"
}

function zhm_move_next_long_word_end() {
    zhm_find_word_boundary "next_end" "WORD"
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

    zhm_set_cursor_and_anchor $new_cursor $new_anchor $ZHM_MOVEMENT_EXTEND
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

    zhm_set_cursor_and_anchor $new_cursor $new_anchor $ZHM_MOVEMENT_EXTEND
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
            echo "Error: Invalid mode '$ZHM_MODE'" >&2
            return 1
            ;;
    esac

    print -n $cursor
}

function zhm_precmd() {
    zhm_print_cursor
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
        zhm_move_next_word_start
        zhm_move_next_long_word_start
        zhm_move_prev_word_start
        zhm_move_prev_long_word_start
        zhm_move_next_word_end
        zhm_move_next_long_word_end
        zhm_delete_word_forward
        zhm_delete_word_backward
        zhm_delete_char_forward
        zhm_goto_line_start
        zhm_goto_line_end
        zhm_undo
        zhm_redo
        zhm_debug_logs
        zhm_clear_history
        zhm_line_finish
        zhm_extend_line_below
        zhm_extend_to_line_bounds
        zhm_collapse_selection
        zhm_flip_selections
        zhm_select_all
        zhm_move_visual_line_down
        zhm_move_visual_line_up
    )
    for widget in $widgets; do
        zle -N $widget
    done

    bindkey -N helix-normal-mode
    bindkey -M helix-normal-mode 'h' zhm_move_char_left
    bindkey -M helix-normal-mode 'l' zhm_move_char_right
    bindkey -M helix-normal-mode 'k' zhm_move_visual_line_up
    bindkey -M helix-normal-mode 'j' zhm_move_visual_line_down
    bindkey -M helix-normal-mode 'a' zhm_append_mode
    bindkey -M helix-normal-mode 'A' zhm_insert_at_line_end
    bindkey -M helix-normal-mode 'i' zhm_insert_mode
    bindkey -M helix-normal-mode 'I' zhm_insert_at_line_start
    bindkey -M helix-normal-mode 'y' zhm_yank
    bindkey -M helix-normal-mode 'c' zhm_change_selection
    bindkey -M helix-normal-mode 'd' zhm_delete_selection
    bindkey -M helix-normal-mode 'p' zhm_paste_after
    bindkey -M helix-normal-mode 'P' zhm_paste_before
    bindkey -M helix-normal-mode 'w' zhm_move_next_word_start
    bindkey -M helix-normal-mode 'W' zhm_move_next_long_word_start
    bindkey -M helix-normal-mode 'b' zhm_move_prev_word_start
    bindkey -M helix-normal-mode 'B' zhm_move_prev_long_word_start
    bindkey -M helix-normal-mode 'e' zhm_move_next_word_end
    bindkey -M helix-normal-mode 'E' zhm_move_next_long_word_end
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

    # Bind normal mode history search
    bindkey -M helix-normal-mode '^R' history-incremental-search-backward
    bindkey -M helix-normal-mode '^S' history-incremental-search-forward
    bindkey -M helix-normal-mode '^P' up-line-or-history
    bindkey -M helix-normal-mode '^N' down-line-or-history

    # TODO: alt-backspace leaves selection trail, presumably others do too
    # Bind insert mode movement and editing keys
    bindkey -M viins '\e' zhm_normal_mode
    bindkey -M viins '\eb' zhm_move_prev_word_start
    bindkey -M viins '\ef' zhm_move_next_word_start
    bindkey -M viins '\ed' zhm_delete_word_forward
    bindkey -M viins '\e[3~' zhm_delete_char_forward
    bindkey -M viins '\C-a' zhm_goto_line_start
    bindkey -M viins '\C-e' zhm_goto_line_end
    bindkey -M viins '\e\177' zhm_delete_word_backward
    bindkey -M viins '\e^?' zhm_delete_word_backward
    bindkey -M viins '\e[3;3~' zhm_delete_word_forward
    bindkey -M viins '\e\e[3~' zhm_delete_word_forward
    # Bind history search in insert mode
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
