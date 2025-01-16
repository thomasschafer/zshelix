typeset -g ZSH_HIGHLIGHT_STYLE="bg=240"
typeset -g ZHM_CURSOR_NORMAL='\e[2 q'
typeset -g ZHM_CURSOR_INSERT='\e[6 q'
typeset -g ZHM_MODE_NORMAL="NORMAL"
typeset -g ZHM_MODE_INSERT="INSERT"

typeset -gA ZHM_VALID_MODES=($ZHM_MODE_NORMAL 1 $ZHM_MODE_INSERT 1)
typeset -g ZHM_MODE

# -1 means no selection
typeset -g ZHM_ANCHOR=-1  # -1 means selection is just cursor

typeset -g ZHM_CLIPBOARD=""

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
        BUFFER="${BUFFER:0:$start}${BUFFER:$end}"
        CURSOR=$start

        case $operation in
            "cut")
                zhm_switch_to_insert_mode
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

function zhm_cut() {
    zhm_operate_on_selection "cut"
}

function zhm_delete() {
    zhm_operate_on_selection "delete"
}

function zhm_get_selection_bounds() {
    if ((ZHM_ANCHOR < 0)); then
        # If no selection, return false
        return 1
    fi
    if ((CURSOR >= ZHM_ANCHOR)); then
        # Forward selection
        print -- "$ZHM_ANCHOR $((CURSOR + 1))"
    else
        # Backward selection
        print -- "$CURSOR $((ZHM_ANCHOR + 1))"
    fi
    return 0
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

    BUFFER="${BUFFER:0:$paste_pos}${ZHM_CUT_BUFFER}${BUFFER:$paste_pos}"

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

# TODO: combine the two below
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

function zhm_switch_to_insert_mode() {
    zhm_remove_highlight
    ZHM_MODE=$ZHM_MODE_INSERT
    print -n $ZHM_CURSOR_INSERT
}

function zhm_switch_to_normal_mode() {
    zhm_set_cursor_and_anchor $CURSOR $CURSOR
    ZHM_MODE=$ZHM_MODE_NORMAL
    print -n $ZHM_CURSOR_NORMAL
}

function zhm_insert_character() {
    if [[ $KEYS =~ [[:print:]] ]]; then
        BUFFER="${BUFFER:0:$CURSOR}$KEYS${BUFFER:$CURSOR}"
        ((CURSOR++))
    fi
}

function zhm_handle_backspace() {
    if ((CURSOR > 0)); then
        ((CURSOR--))
        BUFFER="${BUFFER:0:$CURSOR}${BUFFER:$((CURSOR+1))}"
    fi
}

function zhm_backward_kill_word() {
    local pos=$CURSOR
    # Skip any spaces immediately before cursor
    while ((pos > 0)) && [[ "${BUFFER:$((pos-1)):1}" =~ [[:space:]] ]]; do
        ((pos--))
    done
    # Then skip until we hit a space or start of line
    while ((pos > 0)) && [[ ! "${BUFFER:$((pos-1)):1}" =~ [[:space:]] ]]; do
        ((pos--))
    done
    BUFFER="${BUFFER:0:$pos}${BUFFER:$CURSOR}"
    CURSOR=$pos
}

function zhm_forward_kill_word() {
    local pos=$CURSOR
    # Skip current word if we're in one
    while ((pos < $#BUFFER)) && [[ ! "${BUFFER:$pos:1}" =~ [[:space:]] ]]; do
        ((pos++))
    done
    # Skip spaces
    while ((pos < $#BUFFER)) && [[ "${BUFFER:$pos:1}" =~ [[:space:]] ]]; do
        ((pos++))
    done
    BUFFER="${BUFFER:0:$CURSOR}${BUFFER:$pos}"
}


function zhm_backward_word_insert() {
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

function zhm_forward_word_insert() {
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

function zhm_sign() {
  local num=$1
  echo $(( num > 0 ? 1 : num < 0 ? -1 : 0 ))
}

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

function zhm_handle_normal_mode() {
    local clear_selection=0;
    case $KEYS in
        "i")
            zhm_switch_to_insert_mode
            clear_selection=1  # TODO: keep selection, in the same way as Helix
            ;;
        "a")
            zhm_safe_cursor_move $((CURSOR + 1))
            zhm_switch_to_insert_mode
            clear_selection=1  # TODO: keep selection, in the same way as Helix
            ;;
        "A")
            CURSOR=$#BUFFER
            zhm_switch_to_insert_mode
            clear_selection=1
            ;;
        "I")
            CURSOR=0
            zhm_switch_to_insert_mode
            clear_selection=1
            ;;
        "h")
            zhm_safe_cursor_move $((CURSOR - 1))
            clear_selection=1
            ;;
        "l")
            zhm_safe_cursor_move $((CURSOR + 1))
            clear_selection=1
            ;;
        "y")
            zhm_yank
            ;;
        "c")
            zhm_cut
            clear_selection=1
            ;;
        "d")
            zhm_delete
            clear_selection=1
            ;;
        "p")
            zhm_paste 0
            ;;
        "P")
            zhm_paste 1
            ;;
        "w")
            zhm_find_word_boundary "next_word" "word"
            ;;
        "W")
            zhm_find_word_boundary "next_word" "WORD"
            ;;
        "b")
            zhm_find_word_boundary "prev_word" "word"
            ;;
        "B")
            zhm_find_word_boundary "prev_word" "WORD"
            ;;
        "e")
            zhm_find_word_boundary "next_end" "word"
            ;;
        "E")
            zhm_find_word_boundary "next_end" "WORD"
            ;;
    esac

    if ((clear_selection)); then
        zhm_reset_anchor
    fi
}


function zhm_handle_insert_mode() {
    case $KEYS in
        $'\e')  # Escape
            zhm_switch_to_normal_mode
            ;;
        $'\177')  # Backspace
            zhm_handle_backspace
            ;;
        $'\r')  # Enter
            zle accept-line
            ;;
        $'\C-u')  # Ctrl-u
            BUFFER="${BUFFER:$CURSOR}"
            CURSOR=0
            ;;
        $'\C-w')  # Ctrl-w
            zhm_backward_kill_word
            ;;
        $'\eb')  # Alt-b
            zhm_backward_word_insert
            ;;
        $'\ef')  # Alt-f
            zhm_forward_word_insert
            ;;
        $'\ed')  # Alt-d
            zhm_forward_kill_word
            ;;
        $'\e[3~')  # Delete key
            if ((CURSOR < $#BUFFER)); then
                BUFFER="${BUFFER:0:$CURSOR}${BUFFER:$((CURSOR+1))}"
            fi
            ;;
        $'\C-a')  # Ctrl-a
            CURSOR=0
            ;;
        $'\C-e')  # Ctrl-e
            CURSOR=$#BUFFER
            ;;
        $'\e\177'|$'\e^?') # Alt-backspace (two common variants)
            zhm_backward_kill_word
            ;;
        $'\e[3;3~'|$'\e\e[3~') # Alt-delete (two common variants)
            zhm_forward_kill_word
            ;;
        *)
            zhm_insert_character
            ;;
    esac
}

function zhm_mode_handler() {
    if [[ -z "${ZHM_VALID_MODES[$ZHM_MODE]}" ]]; then
        ZHM_MODE=$ZHM_MODE_NORMAL
        print -n $ZHM_CURSOR_NORMAL
    fi

    case $ZHM_MODE in
        $ZHM_MODE_NORMAL)
            zhm_handle_normal_mode
            ;;
        $ZHM_MODE_INSERT)
            zhm_handle_insert_mode
            ;;
    esac
    zle redisplay
}

function zhm_precmd() {
    if [[ $ZHM_MODE == $ZHM_MODE_INSERT ]]; then
        print -n $ZHM_CURSOR_INSERT
    else
        print -n $ZHM_CURSOR_NORMAL
    fi
}

function zhm_bind_ascii_range() {
    local start=$1
    local end=$2
    local char

    for ascii in {$start..$end}; do
        char=$(printf \\$(printf '%03o' $ascii))
        bindkey -M helix-mode "$char" zhm_mode_handler
    done
}


function zhm_initialize() {
    # Register with ZLE
    zle -N zhm_mode_handler
    zle_highlight=(region:standout)

    # Start in insert mode
    zhm_switch_to_insert_mode

    # Create new keymap
    bindkey -N helix-mode

    local -a normal_mode_keys=(
        h j k l
        w W b B e E
        a A i I
        c d
    )

    for key in $normal_mode_keys; do
        bindkey -M helix-mode $key zhm_mode_handler
    done

    local -A insert_mode_special_keys=(
        ['\e']='Escape'
        ['^M']='Enter'
        ['^I']='Tab'
        ['^H']='Backspace'
        ['^?']='Delete'
        ['^[[A']='Up arrow'
        ['^[[B']='Down arrow'
        ['^[[C']='Right arrow'
        ['^[[D']='Left arrow'
        ['^U']='Ctrl-u'
        ['^W']='Ctrl-w'
        ['\eb']='Alt-b'
        ['\ef']='Alt-f'
        ['\ed']='Alt-d'
        ['^A']='Ctrl-a'
        ['^E']='Ctrl-e'
        ['^[[3~']='Delete key'
        ['\e\177']='Alt-backspace'
        ['\e^?']='Alt-backspace (alternate)'
        ['\e[3;3~']='Alt-delete'
        ['\e\e[3~']='Alt-delete (alternate)'
    )

    for key comment in ${(kv)insert_mode_special_keys}; do
        bindkey -M helix-mode $key zhm_mode_handler
    done

    # Bind history search
    bindkey -M helix-mode '^R' history-incremental-search-backward
    bindkey -M helix-mode '^S' history-incremental-search-forward
    bindkey -M helix-mode '^P' up-line-or-history
    bindkey -M helix-mode '^N' down-line-or-history

    bindkey -M isearch '^?' backward-delete-char
    bindkey -M isearch '^H' backward-delete-char
    bindkey -M isearch '^W' backward-kill-word

    # Bind all printable ASCII characters (32-126)
    local char
    for ascii in {32..44} {46..126}; do
        char=$(printf \\$(printf '%03o' $ascii))
        bindkey -M helix-mode "$char" zhm_mode_handler
        bindkey -M isearch "$char" self-insert
    done
    # Special handling for hyphen
    bindkey -M helix-mode -- "-" zhm_mode_handler
    bindkey -M isearch -- "-" self-insert

    KEYTIMEOUT=1  # Set timeout to 10ms instead of default 400ms

    # Switch to our keymap
    bindkey -A helix-mode main

    # Add our precmd hook
    autoload -Uz add-zsh-hook
    add-zsh-hook precmd zhm_precmd
}

zhm_initialize
