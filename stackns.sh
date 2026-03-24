#!/usr/bin/env bash
# kns - Kubernetes Namespace Stack
# Source this file in your .bashrc / .zshrc:
#   source ~/.kns.sh
#
# Usage:
#   pushns              Push current context namespace onto stack
#   pushns foo          Push 'foo' onto stack and switch to it
#   popns               Pop top namespace, switch to it
#   peekns              Show the stack (a=top, b=top-1, ...)
#   k get pods -n a     Equivalent to: kubectl get pods -n <top of stack>
#   k get pods -n c     Equivalent to: kubectl get pods -n <third on stack>
#   rotatens            Rotate stack: bottom → top
#   rotatens -r         Rotate stack: top → bottom
#   k get pods -n foo   Works normally for non-single-letter args

_KNS_FILE="${KNS_STACK_FILE:-$HOME/.kns_stack}"

# ---------------------------------------------------------------------------
# File-backed stack operations
# ---------------------------------------------------------------------------

_kns_load() {
  _KNS_STACK=()
  if [[ -f "$_KNS_FILE" ]]; then
    while IFS= read -r line; do
      [[ -n "$line" ]] && _KNS_STACK+=("$line")
    done < "$_KNS_FILE"
  fi
}

_kns_save() {
  printf '%s\n' "${_KNS_STACK[@]}" > "$_KNS_FILE"
}

_kns_load

# ---------------------------------------------------------------------------
# Kubeconfig helpers — zero kubectl calls, direct file read/write
# ---------------------------------------------------------------------------

_kns_kubeconfig() {
  # Respect KUBECONFIG but only use the first file if it's a colon-separated list
  local kc="${KUBECONFIG:-$HOME/.kube/config}"
  printf '%s' "${kc%%:*}"
}

_kns_current_context() {
  grep -m1 '^current-context:' "$(_kns_kubeconfig)" 2>/dev/null | awk '{print $2}'
}

_kns_current() {
  local kubeconfig ctx
  kubeconfig=$(_kns_kubeconfig)
  ctx=$(_kns_current_context)
  [[ -z "$ctx" ]] && return 1

  # Walk the contexts array, find the matching name, return its namespace
  awk -v target="$ctx" '
    /^contexts:/ { in_ctx=1; next }
    in_ctx && /^[^ ]/ { exit }
    in_ctx && /- context:/ { ns=""; next }
    in_ctx && /namespace:/ { sub(/.*namespace: */, ""); gsub(/"/, ""); ns=$0; next }
    in_ctx && /name: / && ns != "" {
      sub(/.*name: */, ""); gsub(/"/, "")
      if ($0 == target) { print ns; exit }
    }
    in_ctx && /name: / && ns == "" {
      sub(/.*name: */, ""); gsub(/"/, "")
      if ($0 == target) { print "default"; exit }
    }
  ' "$kubeconfig"
}

_kns_switch() {
  local ns="$1"
  local kubeconfig ctx
  kubeconfig=$(_kns_kubeconfig)
  ctx=$(_kns_current_context)
  [[ -z "$ctx" ]] && return 1

  # Modify lines in place — no rebuilding, no index drift
  python3 -c "
import sys

kc_path, target, ns = sys.argv[1], sys.argv[2], sys.argv[3]

with open(kc_path, 'r') as f:
    lines = f.read().split('\n')

in_contexts = False
i = 0
while i < len(lines):
    if lines[i].rstrip() == 'contexts:':
        in_contexts = True
        i += 1
        continue
    if in_contexts and lines[i] and not lines[i][0].isspace():
        break
    if in_contexts and lines[i].strip().startswith('- context:'):
        block_start = i
        i += 1
        while i < len(lines) and lines[i] and lines[i][0].isspace() and not lines[i].lstrip().startswith('- '):
            i += 1

        is_target = False
        ns_idx = -1
        for bi in range(block_start, i):
            s = lines[bi].strip()
            if s.startswith('name:') and not s.startswith('namespace:'):
                if s.split(':', 1)[1].strip().strip('\"').strip(\"'\") == target:
                    is_target = True
            if s.startswith('namespace:'):
                ns_idx = bi

        if is_target:
            if ns_idx >= 0:
                old = lines[ns_idx]
                indent = old[:len(old) - len(old.lstrip())]
                lines[ns_idx] = indent + 'namespace: ' + ns
            else:
                # Detect indent from sibling properties (cluster/user)
                prop_indent = ''
                for bi in range(block_start + 1, i):
                    s = lines[bi].strip()
                    if s and not s.startswith('name:'):
                        prop_indent = lines[bi][:len(lines[bi]) - len(lines[bi].lstrip())]
                        break
                if not prop_indent:
                    prop_indent = '    '
                lines.insert(block_start + 1, prop_indent + 'namespace: ' + ns)
            break
        continue
    i += 1

with open(kc_path, 'w') as f:
    f.write('\n'.join(lines))
" "$kubeconfig" "$ctx" "$ns"
}

# ---------------------------------------------------------------------------
# Resolve single-letter namespace references
# ---------------------------------------------------------------------------

_kns_letter_to_index() {
  printf '%d' "$(( $(printf '%d' "'$1") - 97 ))"
}

_kns_resolve() {
  local arg="$1"
  if [[ "$arg" =~ ^@[a-z]$ ]]; then
    _kns_load
    local letter="${arg:1:1}"
    local idx
    idx=$(_kns_letter_to_index "$letter")
    local top=$(( ${#_KNS_STACK[@]} - 1 ))
    local actual=$(( top - idx ))
    if (( actual < 0 || actual >= ${#_KNS_STACK[@]} )); then
      echo "kns: '$arg' is out of range (stack depth: ${#_KNS_STACK[@]})" >&2
      return 1
    fi
    printf '%s' "${_KNS_STACK[$actual]}"
  else
    printf '%s' "$arg"
  fi
}

# ---------------------------------------------------------------------------
# Stack operations
# ---------------------------------------------------------------------------

pushns() {
  _kns_load
  if [[ -z "$1" ]]; then
    local cur
    cur=$(_kns_current)
    if [[ -z "$cur" ]]; then
      echo "kns: no namespace set in current context" >&2
      return 1
    fi
    _KNS_STACK+=("$cur")
    _kns_save
    echo "pushed '$cur'  (stack depth: ${#_KNS_STACK[@]})"
  else
    _KNS_STACK+=("$1")
    _kns_save
    _kns_switch "$1"
    echo "pushed '$1'  (stack depth: ${#_KNS_STACK[@]})"
  fi
}

popns() {
  _kns_load
  if (( ${#_KNS_STACK[@]} == 0 )); then
    echo "kns: stack is empty" >&2
    return 1
  fi
  local top=$(( ${#_KNS_STACK[@]} - 1 ))
  local ns="${_KNS_STACK[$top]}"
  unset '_KNS_STACK[$top]'
  _KNS_STACK=("${_KNS_STACK[@]}")
  _kns_save
  _kns_switch "$ns"
  echo "popped '$ns'  (stack depth: ${#_KNS_STACK[@]})"
}

peekns() {
  _kns_load
  if (( ${#_KNS_STACK[@]} == 0 )); then
    echo "(empty)"
    return
  fi
  local top=$(( ${#_KNS_STACK[@]} - 1 ))
  local letter=97
  for (( i = top; i >= 0; i-- )); do
    local tag
    tag=$(printf '%b' "\\x$(printf '%02x' "$letter")")
    printf '%s = %s' "$tag" "${_KNS_STACK[$i]}"
    if (( i == top )); then
      printf '  ← top'
    fi
    printf '\n'
    (( letter++ ))
  done
}

# ---------------------------------------------------------------------------
# Swap: pop top, switch to it, push current namespace so you can swap back
# ---------------------------------------------------------------------------

swapns() {
  _kns_load
  if (( ${#_KNS_STACK[@]} == 0 )); then
    echo "kns: stack is empty, nothing to swap with" >&2
    return 1
  fi
  local cur
  cur=$(_kns_current)
  if [[ -z "$cur" ]]; then
    echo "kns: no namespace set in current context" >&2
    return 1
  fi
  local top=$(( ${#_KNS_STACK[@]} - 1 ))
  local target="${_KNS_STACK[$top]}"
  unset '_KNS_STACK[$top]'
  _KNS_STACK=("${_KNS_STACK[@]}")
  _KNS_STACK+=("$cur")
  _kns_save
  _kns_switch "$target"
  echo "swapped: now in '$target', pushed '$cur'  (stack depth: ${#_KNS_STACK[@]})"
}

# ---------------------------------------------------------------------------
# Switch: jump to a stack letter's namespace without modifying the stack
# ---------------------------------------------------------------------------

switchns() {
  if [[ -z "$1" ]]; then
    echo "usage: switchns <letter>  (e.g. switchns b)" >&2
    return 1
  fi
  local arg="$1"
  # Accept a bare letter (a-z) and resolve it via the stack
  if [[ "$arg" =~ ^[a-z]$ ]]; then
    arg="@$arg"
  fi
  local ns
  ns=$(_kns_resolve "$arg") || return 1
  _kns_switch "$ns"
  echo "switched to '$ns'  (stack unchanged)"
}

# ---------------------------------------------------------------------------
# Move: swap two stack entries by letter without changing the current ns
# ---------------------------------------------------------------------------

movens() {
  if [[ -z "$1" || -z "$2" ]]; then
    echo "usage: movens <letter> <letter>  (e.g. movens a c)" >&2
    return 1
  fi
  _kns_load
  local top=$(( ${#_KNS_STACK[@]} - 1 ))

  _movens_resolve() {
    local letter="$1"
    if [[ ! "$letter" =~ ^[a-z]$ ]]; then
      echo "kns: '$letter' is not a valid stack letter" >&2
      return 1
    fi
    local offset
    offset=$(_kns_letter_to_index "$letter")
    local idx=$(( top - offset ))
    if (( idx < 0 || idx > top )); then
      echo "kns: '$letter' is out of range (stack depth: ${#_KNS_STACK[@]})" >&2
      return 1
    fi
    printf '%d' "$idx"
  }

  local idx1 idx2
  idx1=$(_movens_resolve "$1") || return 1
  idx2=$(_movens_resolve "$2") || return 1

  local tmp="${_KNS_STACK[$idx1]}"
  _KNS_STACK[$idx1]="${_KNS_STACK[$idx2]}"
  _KNS_STACK[$idx2]="$tmp"
  _kns_save
  echo "swapped $1 (${_KNS_STACK[$idx1]}) ↔ $2 (${_KNS_STACK[$idx2]})"
}

# ---------------------------------------------------------------------------
# Rotate: move bottom to top (default), or top to bottom with -r
# ---------------------------------------------------------------------------

rotatens() {
  _kns_load
  if (( ${#_KNS_STACK[@]} < 2 )); then
    echo "kns: need at least 2 entries to rotate" >&2
    return 1
  fi
  if [[ "$1" == "-r" ]]; then
    # Reverse: move top to bottom
    local top=$(( ${#_KNS_STACK[@]} - 1 ))
    local val="${_KNS_STACK[$top]}"
    unset '_KNS_STACK[$top]'
    _KNS_STACK=("$val" "${_KNS_STACK[@]}")
  else
    # Default: move bottom to top
    local val="${_KNS_STACK[0]}"
    _KNS_STACK=("${_KNS_STACK[@]:1}")
    _KNS_STACK+=("$val")
  fi
  _kns_save
  echo "rotated stack:"
  peekns
}

# ---------------------------------------------------------------------------
# Clear the stack
# ---------------------------------------------------------------------------

clearns() {
  _KNS_STACK=()
  _kns_save
  echo "kns: stack cleared"
}

currentns() {
  local ns
  ns=$(_kns_current)
  if [[ -z "$ns" ]]; then
    echo "kns: no namespace set in current context" >&2
    return 1
  fi
  echo "$ns"
}

# ---------------------------------------------------------------------------
# kubectl wrapper: intercepts -n <letter> and resolves it
# Captures any existing 'k' alias (e.g. kubecolor) before overriding
# ---------------------------------------------------------------------------

_KNS_K_CMD="kubectl"
if _kns_alias_out=$(alias k 2>/dev/null); then
  # alias output is like: alias k='kubecolor'
  _KNS_K_CMD="${_kns_alias_out#*=\'}"
  _KNS_K_CMD="${_KNS_K_CMD%\'}"
  unalias k 2>/dev/null
fi

k() {
  local args=()
  local resolved
  while (( $# )); do
    case "$1" in
      -n|--namespace)
        shift
        if [[ -z "$1" ]]; then
          echo "kns: -n requires an argument" >&2
          return 1
        fi
        resolved=$(_kns_resolve "$1") || return 1
        args+=(-n "$resolved")
        ;;
      -n=*|--namespace=*)
        local val="${1#*=}"
        resolved=$(_kns_resolve "$val") || return 1
        args+=(--namespace="$resolved")
        ;;
      -n?*)
        local val="${1:2}"
        resolved=$(_kns_resolve "$val") || return 1
        args+=(-n "$resolved")
        ;;
      *)
        args+=("$1")
        ;;
    esac
    shift
  done
  $_KNS_K_CMD "${args[@]}"
}

# ---------------------------------------------------------------------------
# Tab completion: complete single letters from the stack for -n
# ---------------------------------------------------------------------------

_kns_complete_namespace() {
  local cur="${COMP_WORDS[$COMP_CWORD]}"
  local prev="${COMP_WORDS[$((COMP_CWORD - 1))]}"

  if [[ "$prev" == "-n" || "$prev" == "--namespace" ]]; then
    _kns_load
    local depth=${#_KNS_STACK[@]}
    local letters=()
    for (( i = 0; i < depth && i < 26; i++ )); do
      local idx=$(( depth - 1 - i ))
      local letter
      letter=$(printf '%b' "\\x$(printf '%02x' $(( 97 + i )))")
      letters+=("@$letter")
    done
    local real_ns
    mapfile -t real_ns < <(kubectl get namespaces -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n')
    COMPREPLY=( $(compgen -W "${letters[*]} ${real_ns[*]}" -- "$cur") )
    return
  fi

  if type __start_kubectl &>/dev/null; then
    __start_kubectl
  fi
}

complete -o default -F _kns_complete_namespace k
