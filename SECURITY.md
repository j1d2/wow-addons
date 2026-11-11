# Security policy

## Reporting a problem

Please report security or privacy problems privately, not in a public issue.

Use GitHub's **private vulnerability reporting**: open the repo's **Security** tab and choose **Report a vulnerability**. Include:

- which addon and file
- what can go wrong, and the steps to show it
- the game client and version (`/run print(GetBuildInfo())`)

We aim to reply within 14 days. Please give us time to fix the problem before you talk about it publicly.

## What counts

- An addon leaks or saves personal data, such as other players' names
- An addon breaks `RULES.md` or Blizzard's [UI Add-On Development Policy](https://us.forums.blizzard.com/en/wow/t/ui-add-on-development-policy/24534), for example by acting without a click or sending requests on a timer
- A secret or a personal detail in the code or the git history
- Code that runs text as Lua, or anything that hides what the code does

Bugs in the game itself go to Blizzard, not here.

## Supported versions

Only the latest `main` is supported. Fixes are not backported.

## How the repo checks itself

See [`security/README.md`](security/README.md): the scans that run on every commit and PR, and the addon security review.
