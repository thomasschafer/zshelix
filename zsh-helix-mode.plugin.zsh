# Define the widget function
function helix-mode-handler() {
    case $HELIX_MODE in
        "NORMAL")
            case $KEYS in
                "i")
                    HELIX_MODE="INSERT"
                    print -n '\e[6 q'  # Bar cursor
                    ;;
                "h")
                    if ((CURSOR > 0)); then
                        ((CURSOR--))
                    fi
                    ;;
                "l")
                    if ((CURSOR < $#BUFFER)); then
                        ((CURSOR++))
                    fi
                    ;;
            esac
            ;;
        "INSERT")
            if [[ $KEYS == $'\e' ]]; then  # Escape
                HELIX_MODE="NORMAL"
                print -n '\e[2 q'  # Block cursor
            elif [[ $KEYS == $'\177' ]]; then  # Backspace
                if ((CURSOR > 0)); then
                    ((CURSOR--))
                    BUFFER="${BUFFER:0:$CURSOR}${BUFFER:$((CURSOR+1))}"
                fi
            else
                BUFFER="${BUFFER:0:$CURSOR}$KEYS${BUFFER:$CURSOR}"
                ((CURSOR++))
            fi
            ;;
    esac
    
    zle redisplay
}
# Register with ZLE
zle -N helix-mode-handler

# Initialize state
typeset -g HELIX_MODE="NORMAL"
print -n '\e[2 q'  # Start with block cursor

# Create new keymap
bindkey -N helix-mode

# Bind normal mode keys
bindkey -M helix-mode "h" helix-mode-handler
bindkey -M helix-mode "i" helix-mode-handler
bindkey -M helix-mode "j" helix-mode-handler
bindkey -M helix-mode "k" helix-mode-handler
bindkey -M helix-mode "l" helix-mode-handler

# Bind all printable ASCII characters
## Letters
for ascii in {97..122}; do  # a-z
    char=$(printf \\$(printf '%03o' $ascii))
    bindkey -M helix-mode "$char" helix-mode-handler
done
for ascii in {65..90}; do  # A-Z
    char=$(printf \\$(printf '%03o' $ascii))
    bindkey -M helix-mode "$char" helix-mode-handler
done

## Numbers
for ascii in {48..57}; do  # 0-9
    char=$(printf \\$(printf '%03o' $ascii))
    bindkey -M helix-mode "$char" helix-mode-handler
done

## Symbols and punctuation
# Space through #
for ascii in {32..35}; do
    char=$(printf \\$(printf '%03o' $ascii))
    bindkey -M helix-mode "$char" helix-mode-handler
done

# $ through )
for ascii in {36..41}; do
    char=$(printf \\$(printf '%03o' $ascii))
    bindkey -M helix-mode "$char" helix-mode-handler
done

# Individual bindings for special characters
bindkey -M helix-mode "*" helix-mode-handler
bindkey -M helix-mode "+" helix-mode-handler
bindkey -M helix-mode "," helix-mode-handler
bindkey -M helix-mode -- "-" helix-mode-handler
bindkey -M helix-mode "." helix-mode-handler
bindkey -M helix-mode "/" helix-mode-handler

# : through @
for ascii in {58..64}; do
    char=$(printf \\$(printf '%03o' $ascii))
    bindkey -M helix-mode "$char" helix-mode-handler
done

# [ through `
for ascii in {91..96}; do
    char=$(printf \\$(printf '%03o' $ascii))
    bindkey -M helix-mode "$char" helix-mode-handler
done

# { through ~
for ascii in {123..126}; do
    char=$(printf \\$(printf '%03o' $ascii))
    bindkey -M helix-mode "$char" helix-mode-handler
done

# Special keys
bindkey -M helix-mode $'\e' helix-mode-handler     # Escape
bindkey -M helix-mode '^M' helix-mode-handler      # Enter
bindkey -M helix-mode '^I' helix-mode-handler      # Tab
bindkey -M helix-mode '^H' helix-mode-handler      # Backspace
bindkey -M helix-mode '^?' helix-mode-handler      # Delete
bindkey -M helix-mode '^[[A' helix-mode-handler    # Up arrow
bindkey -M helix-mode '^[[B' helix-mode-handler    # Down arrow
bindkey -M helix-mode '^[[C' helix-mode-handler    # Right arrow
bindkey -M helix-mode '^[[D' helix-mode-handler    # Left arrow

# Switch to our keymap
bindkey -A helix-mode main
