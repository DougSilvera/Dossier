---
name: dossier-product
description: Work with the firm product this client is built on. Use when the user asks which product or base repo this client uses, what changed in it, how far a fork is behind, whether to bring product changes into a client repo, or how something in the client compares with the product.
---

<!-- managed by dossier -->

# Working with this client's product

This client is built on one or more firm products. Dossier records what this home may know about them in `dossier.products.json`, in this home's config directory (`$CLAUDE_CONFIG_DIR`). Read it first. It is current as of its `syncedAt`, the last time the user ran Sync.

For each product it lists:

- `readable`: whether this home may read any of it. When false, nothing in the product is readable from here; say so and stop.
- `paths`: the only product paths this home may read. Everything else in the product is denied, and none of it is editable.
- `repos`: product repos readable in full, with their current `head`.
- `forks`: this client's repos that are forks of a product repo, each with `base` (the newest product commit in the fork's history), `behind` (product commits since), `changed` (file names changed since) and `state`.

`state` other than `ok`:

- `no-shared-commit`: the repo shares no history with the product repo, for example after a squashed import. Compare files by hand; don't guess a base.
- `not-cloned` / `product-not-cloned`: one side isn't on this machine.
- `product-repo-not-readable`: the registry is wrong. Tell the user; a fork must come from a repo clients may read in full.

## Comparing with the product

Read product files only under `paths`. Inside a fully readable product repo, `git -C <repo path> log <base>..HEAD` and `git -C <repo path> diff <base> HEAD -- <file>` show what changed since the fork's base.

## Bringing product changes into a client repo

Changes flow one way: product to client.

1. Show the user what changed since `base` and agree what to take.
2. In the client repo: `git fetch <product repo path> HEAD`, then `git merge --no-commit --no-ff FETCH_HEAD`, or the client's own convention (rebase, cherry-pick).
3. Resolve conflicts in favour of the client's own decisions, and point each one out.
4. Stop with the changes staged and show the diff. The user commits.

The `behind` count updates at the next Sync.

## Never toward the product

Never write to a product, and never copy this client's code, memory, tickets or data toward one. If something here looks worth promoting into the product, describe it to the user as a candidate (what, where, why) and stop. Promoting is the user's call, made outside this home.
