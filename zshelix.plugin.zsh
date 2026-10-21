# zshelix: Helix keybindings for zsh.
#
# Configuration variables must be set before this file is sourced; see the
# README for the full list.

0=${(%):-%N}
typeset -g _ZHM_ROOT=${0:A:h}

() {
    emulate -L zsh
    autoload -Uz is-at-least
    if ! is-at-least 5.3; then
        print -ru2 -- "zshelix requires zsh 5.3 or later (found $ZSH_VERSION)"
        return 1
    fi
    if ! zmodload zsh/pcre 2>/dev/null; then
        print -ru2 -- "zshelix: zsh was built without PCRE support (zsh/pcre); regex commands won't work"
    fi
}

### Configuration defaults ###

typeset -g ZHM_CURSOR_BLOCK=$'\e[2 q'
typeset -g ZHM_CURSOR_BEAM=$'\e[6 q'
typeset -g ZHM_CURSOR_BAR=$'\e[4 q'

: ${ZHM_CURSOR_NORMAL:=$ZHM_CURSOR_BLOCK}
: ${ZHM_CURSOR_INSERT:=$ZHM_CURSOR_BEAM}
: ${ZHM_CURSOR_SELECT:=$ZHM_CURSOR_BAR}

: ${ZHM_STYLE_SELECTION:=bg=238}
: ${ZHM_STYLE_PRIMARY_SELECTION:=bg=240}
: ${ZHM_STYLE_CURSOR:=bg=250,fg=black}

: ${ZHM_INITIAL_MODE:=insert}
: ${ZHM_TAB_WIDTH:=8}
: ${ZHM_INDENT_WIDTH:=2}
: ${ZHM_AUTO_PAIRS:=1}
: ${ZHM_SEARCH_WRAP_AROUND:=1}
: ${ZHM_HISTORY_NAVIGATION:=1}

### Modules ###

() {
    local file
    for file in core history registers movement widgets docs keymap \
        commands/selection commands/edit commands/misc; do
        source "$_ZHM_ROOT/lib/$file.zsh"
    done
}

### Hooks ###

function _zhm_line_init() {
    emulate -L zsh
    setopt extended_glob
    _zhm_load_text
    _zhm_detect_indent
    _zhm_history_reset
    _zhm_jumps_reset
    _zhm_count=0 _zhm_register="" _zhm_restore_cursor=0 _zhm_replaying=0
    _zhm_hl=()
    _zhm_set_single $CURSOR $CURSOR
    _zhm_set_mode $ZHM_INITIAL_MODE
    _zhm_render
}

function _zhm_line_pre_redraw() {
    emulate -L zsh
    setopt extended_glob
    if [[ $BUFFER != "$_zhm_buf" ]] || (( CURSOR != _zhm_cur )); then
        _zhm_sync
        _zhm_render
    fi
}

function _zhm_line_finish() {
    emulate -L zsh
    _zhm_clear_highlight
    [[ -n $ZHM_CURSOR_INSERT ]] && print -n -- "$ZHM_CURSOR_INSERT" > /dev/tty
}

function _zhm_readkey_nop() {}

### Initialisation ###

function _zhm_initialise() {
    emulate -L zsh
    setopt extended_glob

    if is-at-least 5.9; then
        typeset -g _zhm_memo="memo=zshelix"
    fi

    # A widget for every command.
    local name
    for name in ${(k)functions[(I)_zhm_cmd_*]}; do
        zle -N zhm_${name#_zhm_cmd_} _zhm_widget
    done
    zle -N zhm-menu _zhm_menu_widget
    zle -N zhm-readkey-key _zhm_readkey_nop
    zle -N zhm-readkey-utf8 _zhm_readkey_nop

    # Keymap used to read single keys inside commands.
    bindkey -N zhm-readkey
    bindkey -M zhm-readkey -R '^@'-'^?' zhm-readkey-key
    bindkey -M zhm-readkey -R '\M-^@'-'\M-^?' zhm-readkey-utf8
    local key seq
    for key in esc left right up down home end pageup pagedown del S-tab \
        A-backspace A-del A-up A-down A-left A-right; do
        _zhm_key_raw $key
        for seq in "${reply[@]}"; do
            _zhm_bindkey_escape "$seq"
            bindkey -M zhm-readkey -- "$REPLY" zhm-readkey-key
        done
    done
    local -i c
    for (( c = 32; c < 127; c++ )); do
        _zhm_bindkey_escape $'\e'${(#)c}
        bindkey -M zhm-readkey -- "$REPLY" zhm-readkey-key
    done
    for seq in "$_ZHM_KEY_ESC" "$_ZHM_KEY_REPLAY_END"; do
        _zhm_bindkey_escape "$seq"
        bindkey -M zhm-readkey -- "$REPLY" zhm-readkey-key
    done
    _zhm_key_names_init

    # Normal mode, then select mode as a copy of normal mode with overrides.
    bindkey -N zhm-normal
    bindkey -M zhm-normal -R ' '-'~' zhm_noop
    for (( c = 0; c <= 9; c++ )); do
        bindkey -M zhm-normal -- "$c" zhm_count_$c
    done
    _zhm_define_normal_keymap
    _zhm_bindkey_escape "$_ZHM_KEY_REPEAT_INSERT"
    bindkey -M zhm-normal -- "$REPLY" zhm_repeat_insert_once
    bindkey -M zhm-normal '^[[200~' zhm_paste_bracketed_input
    _zhm_bindkey_escape "$_ZHM_KEY_REPLAY_END"
    bindkey -M zhm-normal -- "$REPLY" zhm_replay_end
    bindkey -M viins -- "$REPLY" zhm_replay_end
    bindkey -N zhm-select zhm-normal
    _zhm_define_select_keymap

    # Insert mode uses viins, so that bindings other plugins add there (fzf,
    # atuin, ...) keep working.
    bindkey -M viins -R ' '-'~' zhm_insert_typed
    bindkey -M viins -R '\M-^@'-'\M-^?' zhm_insert_typed
    bindkey -M viins '^[[200~' zhm_paste_bracketed_input
    _zhm_define_insert_keymap
    # Ctrl-r searches history, as the shell user expects, unless something
    # else (fzf, atuin) has already claimed it.
    if [[ $(bindkey -M viins '^R') == *' 'redisplay ]]; then
        bindkey -M viins '^R' history-incremental-search-backward
    fi
    if [[ $(bindkey -M viins '^S') == *' 'undefined-key ]]; then
        bindkey -M viins '^S' history-incremental-search-forward
    fi

    if [[ -z $ZHM_KEYTIMEOUT ]]; then
        KEYTIMEOUT=1
    else
        KEYTIMEOUT=$ZHM_KEYTIMEOUT
    fi

    autoload -Uz add-zle-hook-widget
    add-zle-hook-widget line-init _zhm_line_init
    add-zle-hook-widget line-pre-redraw _zhm_line_pre_redraw
    add-zle-hook-widget line-finish _zhm_line_finish

    # Make viins the main keymap so that widgets which reset the keymap return
    # to insert mode.
    bindkey -v
}

_zhm_initialise
