# Why this branch exists

`tuned` is upstream `master` plus the two changes that are waiting in pull
requests, with the Xdebug default set the way we want it locally.

* Healthchecks: mysql and selenium poll every 30s once they are up instead of
  every 2s and 1s forever. Upstream PR:
  https://github.com/OXID-eSales/docker-eshop-sdk/pull/42
* Xdebug: `XDEBUG_MODE` is settable per checkout. Upstream PR:
  https://github.com/OXID-eSales/docker-eshop-sdk/pull/43

The one deliberate difference from PR 43: the default here is
`${XDEBUG_MODE:-off}`, while the PR keeps upstream's `debug,profile`. Changing
someone else's default in a PR is not our call, choosing our own default in our
own fork is.

Set `XDEBUG_MODE=debug` in a checkout's `.env` and run `make up` when you need a
debugger. `docker compose restart` is not enough, environment is baked in when
the container is created.

## Keeping it current

    git fetch origin
    git rebase origin/master
    git push --force-with-lease fork tuned

Once both PRs are merged, the healthcheck commit and most of the Xdebug commit
become redundant. What stays is the two-line default change.
