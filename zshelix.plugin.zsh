typeset -g ZSH_HIGHLIGHT_STYLE="bg=240"

typeset -g ZHM_CURSOR_NORMAL='\e[2 q'
typeset -g ZHM_CURSOR_INSERT='\e[6 q'
typeset -g ZHM_MODE_NORMAL="NORMAL"
typeset -g ZHM_MODE_INSERT="INSERT"

typeset -gA ZHM_VALID_MODES=($ZHM_MODE_NORMAL 1 $ZHM_MODE_INSERT 1)
typeset -g ZHM_MODE

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

function zhm_safe_cursor_move() {
    local new_pos=$1
    if ((new_pos >= 0 && new_pos <= $#BUFFER)); then
        CURSOR=$new_pos
        return 0
    fi
    return 1
}

function zhm_safe_anchor_move() {
    local new_pos=$1
    if ((new_pos >= 0 && new_pos <= $#BUFFER)); then
        ZHM_ANCHOR=$new_pos
        return 0
    fi
    return 1
}

### Buffer state ###
ZHM_EMPTY_BUFFER="<ZHM_EMPTY_BUFFER>"

# Usage: zhm_history_append cursor_idx anchor_idx buffer_text
function zhm_history_append() {
    if [[ $# -ne 3 ]]; then
        echo "Error: Requires exactly 3 arguments, found $1 $2 $3" >&2
        return 1
    fi

    if [[ ! $1 =~ ^-?[0-9]+$ ]] || [[ ! $2 =~ ^-?[0-9]+$ ]]; then
        echo "Error: First two arguments must be integers" >&2
        return 1
    fi

    # truncate history at this point
    local cut_at=$(((ZHM_UNDO_INDEX + 1) * 3))
    ZHM_UNDO_STATES=(${(@)ZHM_UNDO_STATES[1,$cut_at]})
    ZHM_UNDO_STATES+=($1 $2 "$3")
    ((ZHM_UNDO_INDEX++))
}

# Outputs "<cursor_idx>\0<anchor_idx>\0<buffer_text>" with null bytes as separators
function zhm_history_get() {
    local start=$((ZHM_UNDO_INDEX * 3 + 1))

    if [[ $start -ge ${#ZHM_UNDO_STATES[@]} ]]; then
        echo "Error: Index $start out of range for $ZHM_UNDO_STATES" >&2
        return 1
    fi

    local buffer_contents="${ZHM_UNDO_STATES[$start+2]}"
    if [[ $buffer_contents == $ZHM_EMPTY_BUFFER ]]; then
        buffer_contents=""
    fi
    printf '%d\0%d\0%s' ${ZHM_UNDO_STATES[$start]} ${ZHM_UNDO_STATES[$start+1]} $buffer_contents
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

    # TODO: if at end of history, save state (zhm_save_state)

    local buffer_start=$BUFFER

    IFS=$'\0' read -r cursor_idx anchor_idx buffer_text <<< $(zhm_history_get)
    zhm_update_buffer 0 $buffer_text
    zhm_set_cursor_and_anchor $cursor_idx $anchor_idx

    ((ZHM_UNDO_INDEX--))

    if [[ $buffer_start == $BUFFER ]]; then
        zhm_undo
    fi
}

function zhm_redo() {
    local history_len=$(( ${#ZHM_UNDO_STATES[@]} / 3 ))
    (( ZHM_UNDO_INDEX >= history_len - 1 )) && return

    ((ZHM_UNDO_INDEX++))

    local buffer_start=$BUFFER
    IFS=$'\0' read -r cursor_idx anchor_idx buffer_text <<< $(zhm_history_get)
    zhm_update_buffer 0 $buffer_text
    zhm_set_cursor_and_anchor $cursor_idx $anchor_idx

    if [[ $buffer_start == $BUFFER ]]; then
        zhm_redo
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
function zhm_reset_anchor() {
    ZHM_ANCHOR=$CURSOR
    zhm_remove_highlight
}

# TODO: don't call `zhm_safe_cursor_move` directly, use the below
function zhm_set_cursor_and_anchor() {
    local cursor=$1
    local anchor=$2
    zhm_safe_cursor_move $cursor
    zhm_safe_anchor_move $anchor

    if ((ZHM_ANCHOR >= 0)); then
        if ((CURSOR >= ZHM_ANCHOR)); then
            region_highlight=("${ZHM_ANCHOR} $((CURSOR + 1)) ${ZSH_HIGHLIGHT_STYLE}")
        else
            region_highlight=("${CURSOR} $((ZHM_ANCHOR + 1)) ${ZSH_HIGHLIGHT_STYLE}")
        fi
    else
        zhm_remove_highlight
    fi
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
    zhm_set_cursor_and_anchor $CURSOR $CURSOR
}

function zhm_flip_selections() {
    zhm_set_cursor_and_anchor $ZHM_ANCHOR $CURSOR
}

### Mode switching ###
function zhm_insert_mode_impl() {
    # TODO: don't lose highlight
    zhm_remove_highlight
    ZHM_MODE=$ZHM_MODE_INSERT
    print -n $ZHM_CURSOR_INSERT
    bindkey -v
    zhm_save_state
}

function zhm_normal_mode() {
    zhm_set_cursor_and_anchor $CURSOR $CURSOR
    ZHM_MODE=$ZHM_MODE_NORMAL
    print -n $ZHM_CURSOR_NORMAL
    bindkey -A helix-normal-mode main
    zhm_save_state
}

### Basic movement and editing ###
function zhm_move_char_left() {
    zhm_safe_cursor_move $((CURSOR - 1))
    zhm_reset_anchor
}

function zhm_move_char_right() {
    zhm_safe_cursor_move $((CURSOR + 1))
    zhm_reset_anchor
}

function zhm_append_mode() {
    # TODO: after exiting to normal mode, move cursor back one
    local new_cursor=$(( $(zhm_max CURSOR ZHM_ANCHOR) + 1))
    zhm_safe_cursor_move $new_cursor
    zhm_insert_mode_impl
    zhm_reset_anchor
}

function zhm_insert_at_line_end() {
    CURSOR=$#BUFFER
    zhm_insert_mode_impl
    zhm_reset_anchor
}

function zhm_insert_at_line_start() {
    CURSOR=0
    zhm_insert_mode_impl
    zhm_reset_anchor
}

function zhm_insert_mode() {
    local new_cursor=$(zhm_min CURSOR ZHM_ANCHOR)
    zhm_safe_cursor_move $new_cursor
    zhm_insert_mode_impl
    zhm_reset_anchor
}


function zhm_delete_char_forward() {
    if ((CURSOR < $#BUFFER)); then
        zhm_update_buffer 1 "${BUFFER:0:$CURSOR}${BUFFER:$((CURSOR+1))}"
    fi
}

function zhm_goto_line_start() {
    CURSOR=0
}

function zhm_goto_line_end() {
    CURSOR=$#BUFFER
}

### Word operations ###
function zhm_move_prev_word_start() {
    local pos=$CURSOR
    # Skip any spaces immediately before cursor
    while ((pos > 0)) && [[ "${BUFFER:$((pos-1)):1}" =~ [[:space:]] ]]; do
        ((pos--))
    done
    # Then skip until we hit a space or start of line
    while ((pos > 0)) && [[ ! "${BUFFER:$((pos-1)):1}" =~ [[:space:]] ]]; do
        ((pos--))
    done
    CURSOR=$pos
}

function zhm_move_next_word_start() {
    local pos=$CURSOR
    # Skip current word if we're in one
    while ((pos < $#BUFFER)) && [[ ! "${BUFFER:$pos:1}" =~ [[:space:]] ]]; do
        ((pos++))
    done
    # Skip spaces
    while ((pos < $#BUFFER)) && [[ "${BUFFER:$pos:1}" =~ [[:space:]] ]]; do
        ((pos++))
    done
    CURSOR=$pos
}

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
    CURSOR=$pos
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
        CURSOR=$start

        case $operation in
            "cut")
                zhm_insert_mode_impl
                ;;
            "delete")
                zhm_reset_anchor
                ;;
        esac
    fi
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
    zhm_set_cursor_and_anchor $cursor $anchor
}

function zhm_paste_after() {
    zhm_paste 0
}

function zhm_paste_before() {
    zhm_paste 1
}

### Word boundary navigation ###
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

    zhm_set_cursor_and_anchor $new_cursor $new_anchor
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
    local temp=$CURSOR
    CURSOR=$ZHM_ANCHOR
    ZHM_ANCHOR=$temp
}

### Line extension commands ###
function zhm_extend_line_below() {
    if ((CURSOR < ZHM_ANCHOR && ZHM_ANCHOR >= 0)); then
        zhm_swap_cursor_anchor
    fi

    ZHM_ANCHOR=$(zhm_find_line_start $ZHM_ANCHOR)

    local current_line_end=$(zhm_find_line_end $CURSOR)

    if ((CURSOR != current_line_end)); then
        CURSOR=$current_line_end
    else {
        if ((CURSOR < $#BUFFER)); then
            ((CURSOR++))
            CURSOR=$(zhm_find_line_end $CURSOR)
        fi
    } fi

    zhm_set_cursor_and_anchor $CURSOR $ZHM_ANCHOR
}

function zhm_extend_to_line_bounds() {
    if ((CURSOR > ZHM_ANCHOR && ZHM_ANCHOR >= 0)); then
        zhm_swap_cursor_anchor
    fi

    ZHM_ANCHOR=$(zhm_find_line_end $ZHM_ANCHOR)

    local current_line_start=$(zhm_find_line_start $CURSOR)

    if ((CURSOR != current_line_start)); then
        CURSOR=$current_line_start
    else {
            # Move down one line and find its end
        if ((CURSOR > 0)); then
            ((CURSOR--))
            CURSOR=$(zhm_find_line_start $CURSOR)
        fi
    } fi

    zhm_set_cursor_and_anchor $CURSOR $ZHM_ANCHOR
}

### Initialisation ###
function zhm_precmd() {
    if [[ $ZHM_MODE == $ZHM_MODE_INSERT ]]; then
        print -n $ZHM_CURSOR_INSERT
    else
        print -n $ZHM_CURSOR_NORMAL
    fi
}

function zhm_initialise() {
    local -a widgets=(
        zhm_normal_mode
        zhm_insert_mode
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
        zhm_move_prev_word_start
        zhm_move_next_word_start
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
    )
    for widget in $widgets; do
        zle -N $widget
    done

    zle -N zle-line-finish zhm_line_finish

    bindkey -N helix-normal-mode
    bindkey -M helix-normal-mode 'h' zhm_move_char_left
    bindkey -M helix-normal-mode 'l' zhm_move_char_right
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
    # Bind normal mode history search
    bindkey -M helix-normal-mode '^R' history-incremental-search-backward
    bindkey -M helix-normal-mode '^S' history-incremental-search-forward
    bindkey -M helix-normal-mode '^P' up-line-or-history
    bindkey -M helix-normal-mode '^N' down-line-or-history

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
