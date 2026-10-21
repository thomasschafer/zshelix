# Undo history, modelled on Helix's revision tree.
#
# Each revision stores the full text after the change, the selection from just
# before the change (restored on undo) and the selection at the time it was
# committed (restored on redo). Changes accumulate until they are committed,
# which happens after every command outside insert mode, so a whole insert
# session is a single revision.

typeset -ga _zhm_h_text _zhm_h_before _zhm_h_after
typeset -ga _zhm_h_parent _zhm_h_child
typeset -gi _zhm_h_cur=1
typeset -gi _zhm_dirty=0
typeset -g _zhm_old_sel=""

function _zhm_history_reset() {
    _zhm_h_text=( "$_zhm_text" )
    _zhm_h_before=( "" )
    _zhm_h_after=( "" )
    _zhm_h_parent=( 0 )
    _zhm_h_child=( 0 )
    _zhm_h_cur=1
    _zhm_dirty=0
    _zhm_old_sel=""
}

# Called before the text changes, so the pre-change selection can be restored
# by undo.
function _zhm_history_begin_change() {
    (( _zhm_dirty )) && return
    _zhm_dirty=1
    _zhm_selection_serialize
    _zhm_old_sel=$REPLY
}

function _zhm_history_commit() {
    (( _zhm_dirty )) || return 0
    _zhm_dirty=0
    if [[ $_zhm_text == "${_zhm_h_text[_zhm_h_cur]}" ]]; then
        return 0
    fi
    local -i new=$(( ${#_zhm_h_text} + 1 ))
    _zhm_selection_serialize
    _zhm_h_text[new]=$_zhm_text
    _zhm_h_before[new]=$_zhm_old_sel
    _zhm_h_after[new]=$REPLY
    _zhm_h_parent[new]=$_zhm_h_cur
    _zhm_h_child[new]=0
    _zhm_h_child[_zhm_h_cur]=$new
    _zhm_h_cur=$new
}

function _zhm_history_goto() {
    local -i target=$1
    local sel=$2
    _zhm_set_text_raw "${_zhm_h_text[target]}"
    _zhm_store_text
    _zhm_selection_restore "$sel"
    _zhm_h_cur=$target
}

function _zhm_history_undo() {
    _zhm_history_commit
    local -i parent=${_zhm_h_parent[_zhm_h_cur]}
    if (( parent == 0 )); then
        _zhm_status "Already at oldest change"
        return 1
    fi
    _zhm_history_goto $parent "${_zhm_h_before[_zhm_h_cur]}"
}

function _zhm_history_redo() {
    (( _zhm_dirty )) && return 1
    local -i child=${_zhm_h_child[_zhm_h_cur]}
    if (( child == 0 )); then
        _zhm_status "Already at newest change"
        return 1
    fi
    _zhm_history_goto $child "${_zhm_h_after[child]}"
}

# Jump to revision $1 in chronological order (`earlier`/`later`).
function _zhm_history_jump() {
    local -i target=$1 node
    local -A ancestors
    for (( node = _zhm_h_cur; node; node = _zhm_h_parent[node] )); do
        ancestors[$node]=1
    done
    if (( ${+ancestors[$target]} )); then
        # Moving to an ancestor: the last step is an undo from the child of
        # the target on the path from the current revision.
        local -i child=$_zhm_h_cur
        while (( _zhm_h_parent[child] != target )); do
            child=${_zhm_h_parent[child]}
        done
        _zhm_history_goto $target "${_zhm_h_before[child]}"
    else
        _zhm_history_goto $target "${_zhm_h_after[target]}"
    fi
}

function _zhm_history_earlier() {
    _zhm_history_commit
    local -i target=$(( _zhm_h_cur - $1 ))
    (( target < 1 )) && target=1
    if (( target == _zhm_h_cur )); then
        _zhm_status "Already at oldest change"
        return 1
    fi
    _zhm_history_jump $target
}

function _zhm_history_later() {
    (( _zhm_dirty )) && return 1
    local -i target=$(( _zhm_h_cur + $1 ))
    (( target > ${#_zhm_h_text} )) && target=${#_zhm_h_text}
    if (( target == _zhm_h_cur )); then
        _zhm_status "Already at newest change"
        return 1
    fi
    _zhm_history_jump $target
}
