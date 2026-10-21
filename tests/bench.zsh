#!/usr/bin/env zsh
# Rough per-keystroke timings for common commands on buffers of various sizes.
#
#     tests/bench.zsh
emulate -L zsh
zmodload zsh/datetime

source ${0:A:h}/../zshelix.plugin.zsh 2>/dev/null

# Outside zle there's no message line.
function zle() { return 0 }

function bench() {
    local name=$1 n=$2
    shift 2
    local -F start=$EPOCHREALTIME
    local -i i
    for (( i = 0; i < n; i++ )); do
        "$@"
    done
    printf '  %-28s %7.2f ms\n' "$name" $(( (EPOCHREALTIME - start) * 1000.0 / n ))
}

function setup() {
    BUFFER=$1
    CURSOR=0
    _zhm_load_text
    _zhm_set_single 0 0
    _zhm_mode=normal
}

for size in 50 200 1000 5000; do
    local line="git commit -m \"some message here\" && "
    local text=""
    while (( ${#text} < size )); do text+=$line; done
    text=${text[1,size]}
    print "buffer of $size characters:"
    setup "$text"
    bench "w (next word)" 50 _zhm_cmd_move_next_word_start
    setup "$text"
    bench "l (move right)" 50 _zhm_cmd_move_char_right
    setup "$text"
    bench "j (move down)" 50 _zhm_cmd_move_visual_line_down
    setup "$text"
    _zhm_mode=insert
    bench "typing a character" 50 _zhm_insert_char x
    setup "$text"
    bench "render" 50 _zhm_render
    setup "$text"
    bench "sync (no change)" 50 _zhm_sync
    setup "$text"
    bench "x then d" 20 eval '_zhm_cmd_extend_line_below; _zhm_cmd_delete_selection; _zhm_history_commit'
done
