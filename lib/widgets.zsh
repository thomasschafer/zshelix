# ZLE integration: dispatching commands, keeping our model in sync with the
# zle buffer, rendering selections, reading keys and prompting.

# Pending count and register for the next command.
typeset -gi _zhm_count=0
typeset -g _zhm_register=""

# The buffer and cursor as we last left them, used to detect changes made by
# other widgets (completion, history, other plugins).
typeset -g _zhm_buf=""
typeset -gi _zhm_cur=0

# Set while a command temporarily changes the buffer for display (jump
# labels), so the change isn't mistaken for an edit.
typeset -gi _zhm_suspend_sync=0

# Our entries in region_highlight.
typeset -ga _zhm_hl

# Macro recording: register being recorded to (empty if not recording) and the
# recorded key events.
typeset -g _zhm_macro_reg=""
typeset -ga _zhm_macro_keys

# Last insert session for `.`: the command that entered insert mode and the
# keys typed while in insert mode.
typeset -g _zhm_last_insert_cmd=""
typeset -ga _zhm_last_insert_keys

# Non-zero while replayed keys (macros, `.`) are being processed, so that they
# aren't recorded again.
typeset -gi _zhm_replaying=0

# Last find motion for `A-.`.
typeset -g _zhm_last_motion=""

# Private key sequences used when replaying keys with `zle -U`, so that a
# standalone Escape can't be merged with the following key into an Alt
# combination.
typeset -g _ZHM_KEY_ESC=$'\e[9999~'
typeset -g _ZHM_KEY_REPEAT_INSERT=$'\e[9998~'
typeset -g _ZHM_KEY_REPLAY_END=$'\e[9997~'

### Messages ###

function _zhm_status() {
    zle -M -- "$1"
}

function _zhm_error() {
    zle -M -- "$1"
}

### Count and register ###

function _zhm_count_or_1() {
    REPLY=$(( _zhm_count > 0 ? _zhm_count : 1 ))
}

function _zhm_register_or_default() {
    if [[ -n $_zhm_register ]]; then
        REPLY=$_zhm_register
    else
        _zhm_default_register
    fi
}

### Modes ###

function _zhm_keymap_for_mode() {
    case $1 in
        (normal) REPLY=zhm-normal ;;
        (select) REPLY=zhm-select ;;
        (insert) REPLY=viins ;;
        (*) _zhm_bug "unknown mode '$1'"; return 1 ;;
    esac
}

function _zhm_set_mode() {
    local mode=$1
    _zhm_keymap_for_mode $mode || return
    local keymap=$REPLY
    local old=$_zhm_mode
    _zhm_mode=$mode
    typeset -g ZHM_MODE=$mode
    zle -K $keymap
    _zhm_print_cursor
    if [[ $old != $mode ]] && (( ${+functions[zhm_mode_changed]} )); then
        zhm_mode_changed $old $mode
    fi
}

function _zhm_print_cursor() {
    local seq
    case $_zhm_mode in
        (normal) seq=$ZHM_CURSOR_NORMAL ;;
        (select) seq=$ZHM_CURSOR_SELECT ;;
        (insert) seq=$ZHM_CURSOR_INSERT ;;
    esac
    [[ -n $seq ]] && print -n -- "$seq" > /dev/tty
}

### Rendering ###

function _zhm_render() {
    local -i n=${#BUFFER} i from to c
    _zhm_primary_cursor
    CURSOR=$(( REPLY > n ? n : REPLY ))
    if (( ${#_zhm_hl} )); then
        region_highlight=( "${(@)region_highlight:|_zhm_hl}" )
    fi
    _zhm_hl=()
    local style memo
    [[ -n $_zhm_memo ]] && memo=" $_zhm_memo"
    for (( i = 1; i <= ${#_zhm_sa}; i++ )); do
        local -i a=${_zhm_sa[i]} h=${_zhm_sh[i]}
        (( from = a < h ? a : h, to = a < h ? h : a ))
        (( to > n )) && to=$n
        if (( i == _zhm_pi )); then
            style=$ZHM_STYLE_PRIMARY_SELECTION
        else
            style=$ZHM_STYLE_SELECTION
        fi
        (( to > from )) && [[ -n $style ]] && _zhm_hl+=( "$from $to $style$memo" )
        if (( i != _zhm_pi )); then
            _zhm_cursor $a $h; c=$REPLY
            if (( c < n )); then
                _zhm_hl+=( "$c $(( c + 1 )) $ZHM_STYLE_CURSOR$memo" )
            elif (( n > 0 )); then
                # A cursor at the end of the text can't be highlighted, so
                # mark the last character instead.
                _zhm_hl+=( "$(( n - 1 )) $n $ZHM_STYLE_CURSOR$memo" )
            fi
        fi
    done
    region_highlight+=( "${_zhm_hl[@]}" )
    _zhm_buf=$BUFFER
    _zhm_cur=$CURSOR
}

function _zhm_clear_highlight() {
    if (( ${#_zhm_hl} )); then
        region_highlight=( "${(@)region_highlight:|_zhm_hl}" )
    fi
    _zhm_hl=()
}

### Synchronisation ###

# Bring our model up to date with any changes made outside zshelix.
function _zhm_sync() {
    if [[ $BUFFER != "$_zhm_buf" ]]; then
        _zhm_history_begin_change
        _zhm_load_text
        _zhm_set_single $CURSOR $CURSOR
        [[ $_zhm_mode == insert ]] || _zhm_history_commit
        _zhm_buf=$BUFFER
        _zhm_cur=$CURSOR
    elif (( CURSOR != _zhm_cur )); then
        _zhm_set_single $CURSOR $CURSOR
        _zhm_cur=$CURSOR
    fi
}

### Dispatch ###

# Entry point for every zshelix command widget (named zhm_<command>).
function _zhm_widget() {
    emulate -L zsh
    setopt extended_glob typeset_silent
    _zhm_sync
    _zhm_record_key "$KEYS"
    _zhm_run ${WIDGET#zhm_}
}

function _zhm_run() {
    local cmd=$1
    shift
    if (( ! ${+functions[_zhm_cmd_$cmd]} )); then
        _zhm_bug "unknown command '$cmd'"
        return 1
    fi
    local old_mode=$_zhm_mode
    local saved_text=$_zhm_text saved_sel
    _zhm_selection_serialize
    saved_sel=$REPLY
    local -i ret=0
    {
        _zhm_cmd_$cmd "$@"
        ret=$?
    } always {
        if (( TRY_BLOCK_ERROR )); then
            # A bug in a command shouldn't throw away the command line:
            # restore the state from before the command and report it.
            TRY_BLOCK_ERROR=0
            ret=1
            _zhm_set_text_raw "$saved_text"
            _zhm_store_text
            _zhm_selection_restore "$saved_sel"
            _zhm_bug "command '$cmd' failed"
        fi
    }
    case $cmd in
        (count_*|select_register) ;;
        (*) _zhm_count=0 _zhm_register="" ;;
    esac
    if [[ $old_mode != insert && $_zhm_mode == insert ]] && (( ! _zhm_replaying )); then
        _zhm_last_insert_cmd="$cmd ${(q)@}"
        _zhm_last_insert_keys=()
    fi
    [[ $_zhm_mode == insert ]] || _zhm_history_commit
    _zhm_render
    return $ret
}

### Key recording ###

# Record a key event for macros and for repeating the last insert.
function _zhm_record_key() {
    local key=$1
    (( _zhm_replaying )) && return 0
    if [[ -n $_zhm_macro_reg ]]; then
        _zhm_macro_keys+=( "$key" )
    fi
    if [[ $_zhm_mode == insert ]]; then
        _zhm_last_insert_keys+=( "$key" )
    fi
}

# Replay key events $@ as if typed, followed by a marker that ends the replay.
function _zhm_replay_input() {
    _zhm_keys_to_input "$@"
    (( _zhm_replaying++ ))
    zle -U -- "$REPLY$_ZHM_KEY_REPLAY_END"
}

function _zhm_replay_end() {
    (( _zhm_replaying > 0 && _zhm_replaying-- ))
    return 0
}

# Key names for raw key sequences, used to write macros in Helix's key
# notation.
typeset -gA _zhm_key_names

function _zhm_key_names_init() {
    local name seq
    for name in esc ret tab S-tab backspace del left right up down home end \
        pageup pagedown A-backspace A-del A-up A-down A-left A-right; do
        _zhm_key_raw $name
        for seq in "${reply[@]}"; do
            (( ${+_zhm_key_names[$seq]} )) || _zhm_key_names[$seq]=$name
        done
    done
    local -i c
    for (( c = 1; c < 27; c++ )); do
        seq=${(#)c}
        (( ${+_zhm_key_names[$seq]} )) || _zhm_key_names[$seq]=C-${(#)$(( c + 96 ))}
    done
    _zhm_key_names+=( $'\0' C-space '<' lt '>' gt $'\e<' A-lt $'\e>' A-gt )
}

# Encode key events as Helix key notation (e.g. `wd<esc>`).
function _zhm_keys_encode() {
    local out="" key
    for key in "$@"; do
        if (( ${+_zhm_key_names[$key]} )); then
            out+="<${_zhm_key_names[$key]}>"
        elif [[ $key == $'\e'? ]]; then
            out+="<A-${key[2]}>"
        else
            out+=$key
        fi
    done
    REPLY=$out
}

# Decode Helix key notation into key events in $reply.
function _zhm_keys_decode() {
    local spec=$1
    local -a events
    while [[ -n $spec ]]; do
        if [[ $spec == '<'[^\>]##'>'* ]]; then
            local name=${${spec#<}%%>*}
            spec=${spec#<$name>}
            case $name in
                (lt) events+=( '<' ) ;;
                (gt) events+=( '>' ) ;;
                (A-lt) events+=( $'\e<' ) ;;
                (A-gt) events+=( $'\e>' ) ;;
                (*)
                    _zhm_key_raw "$name" 2>/dev/null || return 1
                    events+=( "${reply[1]}" )
                    ;;
            esac
        else
            events+=( "${spec[1]}" )
            spec=${spec[2,-1]}
        fi
    done
    reply=( "${events[@]}" )
}

# Convert recorded key events into a string suitable for `zle -U`.
function _zhm_keys_to_input() {
    local out="" key
    for key in "$@"; do
        if [[ $key == $'\e' ]]; then
            out+=$_ZHM_KEY_ESC
        else
            out+=$key
        fi
    done
    REPLY=$out
}

### Reading keys ###

# Read a single key (which may be a multi-byte character or an escape
# sequence) into REPLY, going through zle so that pushed input (macros) is
# honoured.
function _zhm_read_key() {
    local keymap=$KEYMAP
    zle -K zhm-readkey
    zle read-command
    local key=$KEYS
    if [[ $REPLY == zhm-readkey-utf8 ]]; then
        # Lead byte of a multi-byte UTF-8 character: read the continuation
        # bytes as well.
        local -i lead extra i
        () {
            setopt localoptions no_multibyte
            lead=$(( #key ))
        }
        if (( lead >= 0xF0 )); then
            extra=3
        elif (( lead >= 0xE0 )); then
            extra=2
        else
            extra=1
        fi
        for (( i = 0; i < extra; i++ )); do
            zle read-command
            key+=$KEYS
        done
    fi
    zle -K $keymap
    [[ $key == $_ZHM_KEY_ESC ]] && key=$'\e'
    if [[ $key == $_ZHM_KEY_REPLAY_END ]]; then
        # Replayed keys ran out while a command was waiting for a key.
        _zhm_replay_end
        _zhm_read_key
        return
    fi
    _zhm_record_key "$key"
    REPLY=$key
}

# The character of key $1, ignoring Ctrl and Alt as Helix does for keys that
# take a character argument (f, t, r, ...): Ctrl-o and Alt-o both give `o`.
# Enter gives a newline. Returns 1 for keys without a character, such as
# Escape and the cursor keys.
function _zhm_key_char() {
    local key=$1
    case $key in
        ($'\r') REPLY=$'\n' ;;
        ($'\t') REPLY=$key ;;
        ($'\e'?) REPLY=${key[2]} ;;
        ($'\0') REPLY=' ' ;;
        ([$'\x01'-$'\x1a'])
            [[ $key == ($'\b'|$'\e') ]] && return 1
            REPLY=${(#)$(( #key + 96 ))}
            ;;
        ($'\e'*|[[:cntrl:]]) return 1 ;;
        (*) REPLY=$key ;;
    esac
    return 0
}

# Read a key and convert it to a character with `_zhm_key_char`.
function _zhm_read_char() {
    _zhm_read_key
    _zhm_key_char "$REPLY"
}

### Info popups ###

function _zhm_show_info() {
    local title=$1
    shift
    local -a lines
    lines=( "$title" "$@" )
    zle -M -- "${(pj:\n:)lines}"
    zle -R
}

### Prompt ###

# Minibuffer prompt. $1 is the prompt text, $2 the history register (may be
# empty) and $3 an optional function called with the input on every change
# (for live previews). Returns 0 with the input in REPLY when confirmed, or 1
# if cancelled.
function _zhm_prompt() {
    local prompt=$1 reg=$2 update=$3
    local input="" key
    local -i pos=0 hist=0
    local -a history
    [[ -n $reg ]] && _zhm_reg_read "$reg" && history=( "${reply[@]}" )
    while :; do
        zle -M -- "$prompt${input[1,pos]}▏${input[pos+1,-1]}"
        zle -R
        _zhm_read_key
        key=$REPLY
        case $key in
            ($'\r'|$'\n')
                zle -M ""
                if [[ -z $input ]]; then
                    input=${history[1]}
                elif [[ -n $reg && $input != "${history[1]}" ]]; then
                    _zhm_reg_push "$reg" "$input"
                fi
                REPLY=$input
                return 0
                ;;
            ($'\e'|$'\a')
                zle -M ""
                return 1
                ;;
            ($'\x7f'|$'\b')
                if [[ -z $input ]]; then
                    zle -M ""
                    return 1
                fi
                if (( pos > 0 )); then
                    input=${input[1,pos-1]}${input[pos+1,-1]}
                    (( pos-- ))
                fi
                ;;
            ($'\e[3~'|$'\x04')
                input=${input[1,pos]}${input[pos+2,-1]}
                ;;
            ($'\x17'|$'\e\x7f')
                local left=${input[1,pos]}
                local stripped=${left%%[[:alnum:]_]##[^[:alnum:]_]#}
                [[ $stripped == $left ]] && stripped=${left%?}
                input=$stripped${input[pos+1,-1]}
                pos=${#stripped}
                ;;
            ($'\x15') input=${input[pos+1,-1]} pos=0 ;;
            ($'\x0b') input=${input[1,pos]} ;;
            ($'\e[D'|$'\eOD'|$'\x02') (( pos > 0 && pos-- )) ;;
            ($'\e[C'|$'\eOC'|$'\x06') (( pos < ${#input} && pos++ )) ;;
            ($'\e[H'|$'\eOH'|$'\e[1~'|$'\x01') pos=0 ;;
            ($'\e[F'|$'\eOF'|$'\e[4~'|$'\x05') pos=${#input} ;;
            ($'\e[A'|$'\eOA'|$'\x10')
                if (( hist < ${#history} )); then
                    (( hist++ ))
                    input=${history[hist]} pos=${#input}
                fi
                ;;
            ($'\e[B'|$'\eOB'|$'\x0e')
                if (( hist > 1 )); then
                    (( hist-- ))
                    input=${history[hist]} pos=${#input}
                elif (( hist == 1 )); then
                    hist=0 input="" pos=0
                fi
                ;;
            ($'\x12')
                # Ctrl-r: insert the contents of a register.
                _zhm_read_char || continue
                if _zhm_reg_first "$REPLY"; then
                    input=${input[1,pos]}$REPLY${input[pos+1,-1]}
                    (( pos += ${#REPLY} ))
                fi
                ;;
            ($'\e'*|[[:cntrl:]]) continue ;;
            (*)
                input=${input[1,pos]}$key${input[pos+1,-1]}
                (( pos += ${#key} ))
                ;;
        esac
        if [[ -n $update ]]; then
            $update "$input"
            _zhm_render
        fi
    done
}

### Regular expressions ###

# Compile $1 with Helix's regex prompt settings: multi-line, Unicode-aware and
# smart case.
function _zhm_regex_compile() {
    local pattern=$1 flags="(*UCP)(?m)"
    [[ $pattern == *[[:upper:]]* ]] || flags+="(?i)"
    pcre_compile -- "$flags$pattern" 2>/dev/null
}

# Number of characters in the first $2 bytes of $1.
function _zhm_bytes_to_chars() {
    local pre
    () {
        setopt localoptions no_multibyte
        pre=${1[1,$2]}
    } "$1" $2
    REPLY=${#pre}
}

# Byte offset of character position $1.
function _zhm_chars_to_bytes() {
    local pre=${_zhm_text:0:$1}
    () {
        setopt localoptions no_multibyte
        REPLY=${#pre}
    }
}

# Byte length of the first character of $1.
function _zhm_char_bytes() {
    local ch=${1[1]}
    () {
        setopt localoptions no_multibyte
        REPLY=${#ch}
    }
}

# Whether the compiled regex matches the empty string, used for matches at the
# very end of the text, where zsh's pcre_match can't start a search.
function _zhm_regex_matches_empty() {
    local ZPCRE_OP MATCH
    local -a match
    pcre_match -b -- "" && [[ $ZPCRE_OP == "0 0" ]]
}

# All matches of the compiled regex within text [$1, $2): sets reply to a flat
# list of start/end character positions. If $3 is set, stops after the first
# match. As with Helix's `regex_input_at`, anchors and look-around see the
# whole text, but matches can't extend past the end of the range.
function _zhm_regex_matches() {
    local -i from=$1 to=$2 first=${3:-0}
    reply=()
    local -i off limit total bs be cs ce last_end=-1
    _zhm_chars_to_bytes $from; off=$REPLY
    _zhm_chars_to_bytes $to; limit=$REPLY
    _zhm_chars_to_bytes $_zhm_len; total=$REPLY
    local prefix=${_zhm_text:0:$to}
    local ZPCRE_OP MATCH
    local -a match
    while (( off <= limit )); do
        if (( off >= total )); then
            if (( last_end != total )) && _zhm_regex_matches_empty; then
                reply+=( $_zhm_len $_zhm_len )
            fi
            break
        fi
        pcre_match -b -n $off -- "$_zhm_text" || break
        bs=${ZPCRE_OP% *} be=${ZPCRE_OP#* }
        (( bs > limit )) && break
        if (( be > limit )); then
            # The match runs past the end of the range: match within it.
            if (( off >= limit )); then
                break
            fi
            pcre_match -b -n $off -- "$prefix" || break
            bs=${ZPCRE_OP% *} be=${ZPCRE_OP#* }
        fi
        _zhm_bytes_to_chars "$_zhm_text" $bs; cs=$REPLY
        _zhm_bytes_to_chars "$_zhm_text" $be; ce=$REPLY
        # Like Rust's regex, an empty match directly after the previous
        # match isn't reported.
        if (( bs != be || bs != last_end )); then
            reply+=( $cs $ce )
            (( first )) && return 0
        fi
        last_end=$be
        if (( be == bs )); then
            (( ce >= to )) && break
            _zhm_char_bytes "${_zhm_chars[ce + 1]}"
            (( off = be + REPLY ))
        else
            off=$be
        fi
    done
    return 0
}

### Shell commands ###

# Run shell command $1 with optional input $2 (only when $3 is 1). Sets REPLY
# to the output; returns non-zero with the error in REPLY on failure.
function _zhm_shell_run() {
    local cmd=$1 input=$2
    local -i pipe=$3
    local -a shell
    if (( ${#ZHM_SHELL} )); then
        shell=( "${ZHM_SHELL[@]}" )
    else
        shell=( sh -c )
    fi
    local errfile=${TMPDIR:-/tmp}/zshelix-$$-stderr
    local out
    if (( pipe )); then
        out=$(print -rn -- "$input" | "${shell[@]}" "$cmd" 2>$errfile; print -n "x$?")
    else
        out=$("${shell[@]}" "$cmd" </dev/null 2>$errfile; print -n "x$?")
    fi
    local -i code=${out##*x}
    out=${out%x*}
    local err=""
    [[ -s $errfile ]] && err=$(<$errfile)
    rm -f -- $errfile
    if (( code != 0 )); then
        REPLY=${err:-"Shell command failed: status $code"}
        return 1
    fi
    if [[ -n $err ]]; then
        REPLY=$err
    else
        REPLY=$out
    fi
    return 0
}
