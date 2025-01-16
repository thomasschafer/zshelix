# Configuration
typeset -g ZHM_CURSOR_NORMAL='\e[2 q'
typeset -g ZHM_CURSOR_INSERT='\e[6 q'
typeset -g ZHM_MODE_NORMAL="NORMAL"
typeset -g ZHM_MODE_INSERT="INSERT"

# State tracking
typeset -gA ZHM_VALID_MODES=($ZHM_MODE_NORMAL 1 $ZHM_MODE_INSERT 1)
typeset -g ZHM_MODE

# Core functions
function zhm_safe_cursor_move() {
    local new_pos=$1
    if ((new_pos >= 0 && new_pos <= $#BUFFER)); then
        CURSOR=$new_pos
        return 0
    fi
    return 1
}

function zhm_switch_to_insert_mode() {
    ZHM_MODE=$ZHM_MODE_INSERT
    print -n $ZHM_CURSOR_INSERT
}

function zhm_switch_to_normal_mode() {
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

function zhm_find_word_boundary() {
    local direction=$1
    local boundary=$2
    local word_type=$3
    local pos=$CURSOR
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

    if [[ $direction == "next" ]]; then
        if [[ $boundary == "start" ]]; then
            # Skip current word
            while ((pos < len)); do
                local char="${BUFFER:$pos:1}"
                if eval $is_match; then
                    ((pos++))
                else
                    break
                fi
            done
            # Skip non-word chars
            while ((pos < len)); do
                local char="${BUFFER:$pos:1}"
                if ! eval $is_match; then
                    ((pos++))
                else
                    break
                fi
            done
        elif [[ $boundary == "end" ]]; then
            # Move at least one position forward if we're at the end of a word
            if ((pos < len)); then
                local char="${BUFFER:$pos:1}"
                if eval $is_match; then
                    ((pos++))
                fi
            fi
            # Skip non-word chars
            while ((pos < len)); do
                local char="${BUFFER:$pos:1}"
                if ! eval $is_match; then
                    ((pos++))
                else
                    break
                fi
            done
            # Skip to end of word
            while ((pos < len)); do
                local char="${BUFFER:$pos:1}"
                if eval $is_match; then
                    ((pos++))
                else
                    break
                fi
            done
            # Move back one to land on last char
            if ((pos > CURSOR)); then
                ((pos--))
            fi
        else
            echo "Invalid boundary: $boundary" >&2
            return 1
        fi
    elif [[ $direction == "prev" ]]; then
        if [[ $boundary == "start" ]]; then
            # If on word char, move back one
            if ((pos > 0)); then
                local char="${BUFFER:$((pos-1)):1}"
                if eval $is_match; then
                    ((pos--))
                fi
            fi
            # Skip non-word chars
            while ((pos > 0)); do
                local char="${BUFFER:$((pos-1)):1}"
                if ! eval $is_match; then
                    ((pos--))
                else
                    break
                fi
            done
            # Skip word chars
            while ((pos > 0)); do
                local char="${BUFFER:$((pos-1)):1}"
                if eval $is_match; then
                    ((pos--))
                else
                    break
                fi
            done
        elif [[ $boundary == "end" ]]; then
            echo "Backward end motion not implemented" >&2
            return 1
        else
            echo "Invalid boundary: $boundary" >&2
            return 1
        fi
    else
        echo "Invalid direction: $direction" >&2
        return 1
    fi

    zhm_safe_cursor_move $pos
}

function zhm_handle_normal_mode() {
    case $KEYS in
        "i")
            zhm_switch_to_insert_mode
            ;;
        "h")
            zhm_safe_cursor_move $((CURSOR - 1))
            ;;
        "l")
            zhm_safe_cursor_move $((CURSOR + 1))
            ;;
        "w")
            zhm_find_word_boundary "next" "start" "word"
            ;;
        "W")
            zhm_find_word_boundary "next" "start" "WORD"
            ;;
        "b")
            zhm_find_word_boundary "prev" "start" "word"
            ;;
        "B")
            zhm_find_word_boundary "prev" "start" "WORD"
            ;;
        "e")
            zhm_find_word_boundary "next" "end" "word"
            ;;
        "E")
            zhm_find_word_boundary "next" "end" "WORD"
            ;;
    esac
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
            ;;
        *)
            zhm_insert_character
            ;;
    esac
}

function zhm_mode_handler() {
    # Validate current mode
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

    # Set initial cursor
    zhm_switch_to_insert_mode

    # Create new keymap
    bindkey -N helix-mode

    # Bind normal mode keys
    bindkey -M helix-mode "h" zhm_mode_handler
    bindkey -M helix-mode "i" zhm_mode_handler
    bindkey -M helix-mode "j" zhm_mode_handler
    bindkey -M helix-mode "k" zhm_mode_handler
    bindkey -M helix-mode "l" zhm_mode_handler

    # Bind all printable ASCII characters
    zhm_bind_ascii_range 32 44   # space through comma
    zhm_bind_ascii_range 46 126  # period through tilde
    bindkey -M helix-mode -- "-" zhm_mode_handler  # Special handling for hyphen

    # Bind special keys
    bindkey -M helix-mode $'\e' zhm_mode_handler      # Escape
    bindkey -M helix-mode '^M' zhm_mode_handler       # Enter
    bindkey -M helix-mode '^I' zhm_mode_handler       # Tab
    bindkey -M helix-mode '^H' zhm_mode_handler       # Backspace
    bindkey -M helix-mode '^?' zhm_mode_handler       # Delete
    bindkey -M helix-mode '^[[A' zhm_mode_handler     # Up arrow
    bindkey -M helix-mode '^[[B' zhm_mode_handler     # Down arrow
    bindkey -M helix-mode '^[[C' zhm_mode_handler     # Right arrow
    bindkey -M helix-mode '^[[D' zhm_mode_handler     # Left arrow
    bindkey -M helix-mode '^U' zhm_mode_handler       # Ctrl-u
    bindkey -M helix-mode '^W' zhm_mode_handler       # Ctrl-w

    # Switch to our keymap
    bindkey -A helix-mode main

    # Add our precmd hook
    autoload -Uz add-zsh-hook
    add-zsh-hook precmd zhm_precmd
}

# Initialize the plugin
zhm_initialize
