# Registers, mirroring Helix's register semantics.
#
# Each register holds a list of values (one per selection when yanking). Values
# are stored NUL-separated. Special registers:
#   _   black hole: discards writes, reads nothing
#   +   system clipboard
#   *   primary selection (falls back to the clipboard where unsupported)
#   #   selection indices (read only)
#   .   selection contents (read only)
#   %   current document name (read only)

typeset -gA _zhm_regs
# Values last written to each clipboard register, so that a multi-selection
# yank can be pasted back as multiple values (as Helix does).
typeset -gA _zhm_clip_cache

function _zhm_reg_write() {
    local name=$1
    shift
    case $name in
        (_) return 0 ;;
        ('#'|.|%)
            _zhm_error "register [$name] does not support writing"
            return 1
            ;;
        ('+'|'*')
            local joined=${(pj:\n:)@}
            _zhm_clipboard_copy "$name" "$joined" || {
                _zhm_error "failed to write to the system clipboard"
                return 1
            }
            _zhm_clip_cache[$name]=${(pj:\0:)@}
            ;;
        (*)
            _zhm_regs[$name]=${(pj:\0:)@}
            ;;
    esac
}

# Prepend a value to a register (used for search and prompt history).
function _zhm_reg_push() {
    local name=$1 value=$2
    case $name in
        (_|'#'|.|%|'+'|'*') _zhm_reg_write "$name" "$value" ;;
        (*)
            local -a values=()
            _zhm_reg_read "$name" && values=( "${reply[@]}" )
            values=( "$value" "${(@)values:#$value}" )
            _zhm_regs[$name]=${(pj:\0:)values}
            ;;
    esac
}

# Read a register into $reply. Returns 1 if the register is empty.
function _zhm_reg_read() {
    local name=$1
    reply=()
    case $name in
        (_) return 1 ;;
        ('#')
            local -i i=0
            for (( i = 1; i <= ${#_zhm_sa}; i++ )); do
                reply+=( $i )
            done
            ;;
        (.)
            local -i i=0
            for (( i = 1; i <= ${#_zhm_sa}; i++ )); do
                local -i a=${_zhm_sa[i]} h=${_zhm_sh[i]}
                reply+=( "${_zhm_text:$(( a < h ? a : h )):$(( a < h ? h - a : a - h ))}" )
            done
            ;;
        (%) reply=( zsh ) ;;
        ('+'|'*')
            local content=""
            content=$(_zhm_clipboard_paste "$name"; print -n "x$?")
            local -i code=${content##*x}
            content=${content%x*}
            if (( code != 0 )); then
                _zhm_error "failed to read the system clipboard"
                return 1
            fi
            if (( ${+_zhm_clip_cache[$name]} )); then
                local -a cached=()
                cached=( "${(@ps:\0:)_zhm_clip_cache[$name]}" )
                if [[ ${(pj:\n:)cached} == "$content" ]]; then
                    reply=( "${cached[@]}" )
                    return 0
                fi
            fi
            [[ -n $content ]] || return 1
            reply=( "$content" )
            ;;
        (*)
            (( ${+_zhm_regs[$name]} )) || return 1
            reply=( "${(@ps:\0:)_zhm_regs[$name]}" )
            ;;
    esac
    (( ${#reply} ))
}

function _zhm_reg_first() {
    _zhm_reg_read "$1" || return 1
    REPLY=${reply[1]}
}

function _zhm_default_register() {
    if [[ -n $ZHM_DEFAULT_YANK_REGISTER ]]; then
        REPLY=$ZHM_DEFAULT_YANK_REGISTER
    elif [[ $ZSH_HELIX_SYSTEM_CLIPBOARD == 1 ]]; then
        REPLY=+
    else
        REPLY='"'
    fi
}

### System clipboard ###

typeset -g _zhm_clip_tool=""

function _zhm_clipboard_detect() {
    [[ -n $_zhm_clip_tool ]] && return 0
    if (( ${#ZHM_CLIPBOARD_COPY} && ${#ZHM_CLIPBOARD_PASTE} )); then
        _zhm_clip_tool=custom
    elif [[ -n $ZHM_CLIPBOARD_PROVIDER ]]; then
        _zhm_clip_tool=$ZHM_CLIPBOARD_PROVIDER
    elif [[ $OSTYPE == darwin* ]] && (( $+commands[pbcopy] )); then
        _zhm_clip_tool=pasteboard
    elif [[ -n $WAYLAND_DISPLAY ]] && (( $+commands[wl-copy] && $+commands[wl-paste] )); then
        _zhm_clip_tool=wayland
    elif [[ -n $DISPLAY ]] && (( $+commands[xclip] )); then
        _zhm_clip_tool=xclip
    elif [[ -n $DISPLAY ]] && (( $+commands[xsel] )); then
        _zhm_clip_tool=xsel
    elif (( $+commands[win32yank.exe] )); then
        _zhm_clip_tool=win32yank
    elif [[ -n $TMUX ]] && (( $+commands[tmux] )); then
        _zhm_clip_tool=tmux
    else
        _zhm_clip_tool=termcode
    fi
}

# Copy $2 to the clipboard ($1 is + or *).
function _zhm_clipboard_copy() {
    _zhm_clipboard_detect
    local primary=0
    [[ $1 == '*' ]] && primary=1
    case $_zhm_clip_tool in
        (custom) print -rn -- "$2" | "${ZHM_CLIPBOARD_COPY[@]}" ;;
        (pasteboard) print -rn -- "$2" | pbcopy ;;
        (wayland)
            if (( primary )); then
                print -rn -- "$2" | wl-copy --primary --type text/plain
            else
                print -rn -- "$2" | wl-copy --type text/plain
            fi
            ;;
        (xclip) print -rn -- "$2" | xclip -i -selection ${${primary:#0}:+primary}${${primary:#1}:+clipboard} ;;
        (xsel) print -rn -- "$2" | xsel ${${primary:#0}:+-p}${${primary:#1}:+-b} -i ;;
        (win32yank) print -rn -- "$2" | win32yank.exe -i --crlf ;;
        (tmux) print -rn -- "$2" | tmux load-buffer -w - ;;
        (termcode)
            # OSC 52, which most terminals support for copying.
            local encoded=""
            encoded=$(print -rn -- "$2" | base64 | tr -d '\n') || return 1
            print -rn -- $'\e]52;'${${primary:#0}:+p}${${primary:#1}:+c}';'$encoded$'\a' > /dev/tty
            ;;
        (*) return 1 ;;
    esac
}

# Print the clipboard contents ($1 is + or *).
function _zhm_clipboard_paste() {
    _zhm_clipboard_detect
    local primary=0
    [[ $1 == '*' ]] && primary=1
    case $_zhm_clip_tool in
        (custom) "${ZHM_CLIPBOARD_PASTE[@]}" ;;
        (pasteboard) pbpaste ;;
        (wayland)
            if (( primary )); then
                wl-paste --no-newline --primary
            else
                wl-paste --no-newline
            fi
            ;;
        (xclip) xclip -o -selection ${${primary:#0}:+primary}${${primary:#1}:+clipboard} ;;
        (xsel) xsel ${${primary:#0}:+-p}${${primary:#1}:+-b} -o ;;
        (win32yank) win32yank.exe -o --lf ;;
        (tmux) tmux save-buffer - ;;
        (*)
            # Pasting via OSC 52 isn't supported, so fall back to whatever was
            # last yanked to this register.
            print -rn -- "${(pj:\n:)${(@ps:\0:)_zhm_clip_cache[$1]}}"
            ;;
    esac
}
