# kns - Kubernetes Namespace Stack

A shell utility that gives you a namespace stack and shorthand references for quick namespace switching with `kubectl` (or whatever you have `k` aliased to, like `kubecolor`).

## Possible dangers
### This tool does direct read and writes to your kube config it may brick it. I currently have solved all of the situations i have found in which it does this but there may be more. So be careful.

## Setup

Source the script in your `.bashrc` or `.zshrc` **after** any existing `alias k=...`:

```bash
source /path/to/stackns.sh
```

## Stack Commands

### `pushns [namespace]`
- `pushns` — pushes your current context namespace onto the stack
- `pushns foo` — pushes `foo` onto the stack and switches to it

### `popns`
Pops the top namespace off the stack and switches to it.

### `swapns`
Pops the top, switches to it, and pushes your current namespace in its place. Run it again to flip back. Useful for bouncing between two namespaces.

### `peekns`
Prints the stack with letter labels (`a` = top, `b` = second, etc.).

### `switchns <letter>`
Switches to the namespace at the given stack letter without modifying the stack. Useful for jumping to a namespace you want to work in while keeping the stack intact.

```bash
$ peekns
a = staging  ← top
b = dev
c = prod

$ switchns c
switched to 'prod'  (stack unchanged)
```

### `movens <letter> <letter>`
Swaps two stack entries by their letter positions without changing the current namespace. Useful for reordering the stack.

```bash
$ peekns
a = staging  ← top
b = dev
c = prod

$ movens a c
swapped a (prod) ↔ c (staging)

$ peekns
a = prod  ← top
b = dev
c = staging
```

### `clearns`
Empties the stack.

## Namespace Shorthand with `k`

The `k` wrapper intercepts `-n @<letter>` arguments and resolves them to stack entries before passing everything to your underlying kubectl command.

| Syntax | Example | Meaning |
|---|---|---|
| `-n @a` | `k get pods -n @a` | Use the top of the stack |
| `-n@a` | `k get pods -n@a` | Same, no space |
| `-n=@a` | `k get pods -n=@a` | Same, with equals |
| `-n foo` | `k get pods -n foo` | Regular namespace, passed through as-is |

Letters map to stack depth: `@a` = top, `@b` = second from top, `@c` = third, and so on.

## Tab Completion

When typing `-n` with the `k` command, tab completion offers both `@<letter>` references from your stack and real namespace names from the cluster.

## Example Session

```bash
$ pushns dev
pushed 'dev'  (stack depth: 1)

$ pushns staging
pushed 'staging'  (stack depth: 2)

$ peekns
a = staging  ← top
b = dev

$ k get pods -n @b       # gets pods in 'dev'
$ k get pods -n@a        # gets pods in 'staging'

$ swapns                  # switch to 'staging', push current ns
swapped: now in 'staging', pushed 'prod'  (stack depth: 2)

$ swapns                  # flip back
swapped: now in 'prod', pushed 'staging'  (stack depth: 2)

$ pushns monitoring
pushed 'monitoring'  (stack depth: 3)

$ peekns
a = monitoring  ← top
b = staging
c = prod

$ switchns c              # jump to prod, stack stays the same
switched to 'prod'  (stack unchanged)

$ movens a c              # reorder: swap monitoring and prod
swapped a (prod) ↔ c (monitoring)
```

## Notes

- The stack is persisted to `~/.kns_stack` (override with `KNS_STACK_FILE` env var)
- If `k` is already aliased (e.g. to `kubecolor`), the script captures and wraps it automatically — just make sure stackns.sh is sourced after the alias
- This does play nice with kubens and I would recomend it is used in conjuction with.