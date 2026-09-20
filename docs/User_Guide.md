# Codex Switch5 User Guide

Codex Switch5 manages and switches Codex accounts on your Mac, shows remaining quota, and summarizes local Token usage. Start with installation if you are new to the app, or jump to the final section to find data files.

Updated: September 20, 2026.

- [Install and open for the first time](#install-and-open-for-the-first-time)
- [Add and switch accounts](#add-and-switch-accounts)
- [When to keep the app running](#when-to-keep-the-app-running)
- [Organize accounts and check quota](#organize-accounts-and-check-quota)
- [View usage statistics](#view-usage-statistics)
- [Switch history and settings](#switch-history-and-settings)
- [Troubleshooting](#troubleshooting)
- [Uninstall](#uninstall)
- [Statistics sources and calculations](#statistics-sources-and-calculations)
- [Local files and data storage](#local-files-and-data-storage)

## Install and open for the first time

1. Download the DMG from the [download page](https://github.com/justamanm/codex-switch5/releases/tag/latest). Requires macOS 14 or later.
2. Open the DMG, drag Codex Switch5 into Applications, then launch it from Applications.
3. The app automatically discovers locally signed-in accounts and supported account archives. Existing accounts appear on the Accounts page. If there are none, click Add account.

The first quota query may take a moment. “—” means quota data is not yet available, not that your quota is zero.

The downloaded app uses an ad hoc signature. If macOS blocks it, verify that the download comes from this project, then check System Settings → Privacy & Security for Open Anyway and follow the prompts.

## Add and switch accounts

### Add another account

1. Click Add account at the top right.
2. Follow the dialog. Depending on installed software, the app opens a sign-in entry point or asks you to run `codex login`.
3. Sign in to the intended account and wait for the app to recognize and save it. Keep Switch5 running throughout sign-in.

Adding accounts requires ChatGPT or Codex CLI. If neither is installed, the app stops before changing account files. Switching existing accounts does not require ChatGPT.

To stop, use Cancel in the dialog and wait for the original account to be restored instead of terminating the process.

### Switch to an existing account

1. Check the quota of the active and recommended accounts on the Accounts page.
2. Click Switch in the center, or beside another account in the list.
3. Follow the confirmation dialog and verify that the intended account is marked as active.

If you use Codex CLI, exit relevant sessions before switching or adding accounts, then reopen them afterward so they pick up the new credentials. The recommendation is a convenient option; you can choose another account yourself.

### Expired sign-in

When an account requires sign-in again, use its sign-in action and follow the prompts. Keep Switch5 running; if you cancel, wait for restoration to finish.

## When to keep the app running

**After a switch completes, you can quit Switch5 and continue using ChatGPT or Codex CLI.** Switch5 does not need to run as an intermediary. Quitting does not undo a completed switch. For CLI use, reopen sessions after switching.

| Situation | Keep Switch5 running? | Why |
| --- | --- | --- |
| Adding an account or signing in again | Yes | The app waits for sign-in, verifies identity, and saves the account |
| Switching accounts or restoring the original account after cancellation | Yes | Wait for completion to avoid interrupting credential saving or recovery |
| Switch completed; you only want to use ChatGPT or Codex CLI | No | Credentials have been saved locally and the client can operate independently |
| Automatic quota updates and ongoing quota observations | Yes, with automatic refresh enabled | Queries stop after quitting; changes during that gap cannot be fully reconstructed later |
| Detecting expired sign-in promptly | Quota queries must run | Expiry is recorded when a failure is detected, not at the actual server-side expiry time; the app cannot detect failures while closed |

The window does not need to stay in the foreground. To keep collecting records, do not use Quit or `Command-Q`. Sleep and network disconnections can also interrupt sampling.

### Prefer switching through Switch5

For more complete switch history and per-account usage attribution, use Switch5 to switch, add, and renew sign-in for accounts. The app handles statistics and records around these operations.

Manually replacing credentials, running a login command independently, or using another switching tool does not necessarily prevent ChatGPT or Codex from working. However, Switch5 may be unable to reconstruct the exact switch time and sequence, and usage may be assigned to the wrong account. Do not let another tool modify credentials while Switch5 is signing in or recovering an account.

### What happens to statistics while the app is closed?

- **Tokens**: On reopening, the app can scan Codex sessions still stored locally. Quitting does not necessarily lose that Token usage, but account changes made externally can prevent accurate attribution to each account.
- **Quota**: No queries run while the app is closed. Reopening retrieves the quota at that time; it cannot recover every intermediate change or the exact expiry time.
- **Switch history**: Operations outside the app are not guaranteed to be added later. For more complete records, perform account operations through Switch5 and keep it running with automatic refresh enabled.

## Organize accounts and check quota

The account list shows **remaining 5-hour quota, remaining weekly quota, and their reset times** together. Percentages show what remains. Refresh data marked as a previous record before relying on it.

| What you want to do | Where to go |
| --- | --- |
| Refresh all accounts | Refresh at the top right |
| Refresh one account | Refresh icon beside that account |
| Give an account a recognizable name | Account’s “…” menu → alias action |
| Change an account’s group | “…” → change-group action |
| Create or manage groups | Groups above the list → group manager |
| Display accounts by group | Groups → grouped display option |
| Reorder manually | Drag the handle on the left of an account; restore manual sorting in Sort first if needed |
| Sort by rules | Sort above the list |
| View account information | “…” → account-information action |

Removing an account through the “…” menu moves its credentials to Trash after confirmation. **It does not merely hide the list entry.** This is different from uninstalling Switch5.

### Quota refresh rules

| Trigger | Accounts queried | Network request |
| --- | --- | --- |
| App launch | The app first shows locally cached data, then refreshes all discovered accounts in the background | Yes |
| Refresh at the top right | All discovered accounts, up to three at a time | Yes |
| Refresh beside an account | Only that account | Yes |
| Automatic refresh | All accounts whose sign-in is not already marked as expired; minimum interval is one minute | Yes |
| Known 5-hour quota reset | The corresponding valid account, while Switch5 remains running | Yes |
| Automatic refresh disabled | Local Token records are scanned every five minutes; this timer does not query quota | No |

Automatic refresh schedules the next round after the current round finishes, so quota queries do not overlap. Temporary network failures, HTTP 429, and server errors are retried up to twice. A failed account does not discard successful results from other accounts or erase its last valid quota.

If sign-in expires, the app keeps the last valid quota, reset-card count, and known reset-card expiration times, and marks the account for sign-in again. Automatic refresh skips accounts already marked this way. A manual refresh can try the account again; after sign-in becomes valid and the reset-card details are retrieved successfully, the saved expiration times are updated. Saved expiration times are cleared only when the service confirms that there are no reset cards.

## View usage statistics

Open Usage at the top, then choose a page below it.

### Overview

- The top cards show Token totals and API-equivalent cost estimates for today, this week, and this month.
- Click Token details on any card to expand or collapse all three periods together. Input and output are the main figures; cached, reasoning, and auto-review usage are supplementary.
- In Token history, select daily, weekly, or monthly intervals. Drag horizontally to browse the chart. Use the period selector to inspect a specific period’s Token count and estimated cost.

### Account details

View each account’s 5-hour and weekly quota cycles alongside today’s, this week’s, and this month’s usage. Start and reset times appear below the cycle. Use the account sorting selector at the top right to choose the comparison period.

### Usage habits

Select this week, this month, or the last 30 days on the right to see hourly Token distribution, quota observations, and sampling records. Bar height is the total Token usage for that hour; the number above the bar counts days with usage.

These are summaries of existing records, not work-time tracking. They do not schedule account switches. Costs are API-equivalent estimates, not subscription bills. See [Statistics sources and calculations](#statistics-sources-and-calculations) for details.

## Switch history and settings

History separates account operations from group changes. Review results after switching, adding, or signing in to an account again.

Open settings with the gear at the top left to choose Chinese or English, enable automatic refresh, and set its interval. Automatic refresh updates quota; it does not automatically switch accounts. See [Quota refresh rules](#quota-refresh-rules) for the full behavior. When automatic refresh is enabled, Token statistics update with each quota query. When disabled, the app scans only new local Token records every five minutes without using that timer to query quota over the network.

## Troubleshooting

| Problem | What to try |
| --- | --- |
| No accounts on first launch | Complete sign-in through Add account. The app recognizes supported local credentials, not every account previously used in a browser |
| Signed in to Codex but no account appears | Check that credentials are in the current macOS user’s `~/.codex/`. Custom `CODEX_HOME` paths and API-key-only credentials are currently unsupported |
| Quota shows “—” or a previous record | Refresh and check for query errors or a sign-in prompt. Missing data does not mean quota is exhausted |
| No recommended account | Refresh quota and check whether other accounts are available or require sign-in |
| CLI still uses the previous account | Exit the old CLI session and reopen it |
| Token usage and quota changes differ | Tokens come from local sessions, while quota comes from service queries and may include other devices. They measure different things |
| Historical Tokens appear immediately after installation | Existing local Codex sessions can be counted. A new Switch5 installation does not mean there is no usage history |
| Different habit ranges show the same result | Available records may all fall within those ranges. Quota observations accumulate over time |
| Sign-in is interrupted or data cannot be read | Follow the app’s recovery prompts. Keep original files and error messages; do not delete credentials as a repair attempt |

If the issue persists, [report it](https://github.com/justamanm/codex-switch5/issues) with reproduction steps, the error message, and app version. Hide personal account details in screenshots and never attach credential files.

## Uninstall

Moving only Codex Switch5 to Trash preserves existing local account credentials and does not disrupt ChatGPT or Codex sign-in or use. It does not switch back to the previously used account. App settings and statistics also remain and can be read after reinstalling.

Third-party uninstallers may remove additional files depending on what you select. See [Local files and data storage](#local-files-and-data-storage) for file ownership and deletion effects.

## Statistics sources and calculations

Statistics cover today, this week, this month, and per-account cycles. Input and output are primary; cached and reasoning Tokens are supplementary. Auto-review usage is shown separately and excluded from Token totals and costs. An asterisk means some additional usage cannot be priced. Costs and full-week quota projections use API-equivalent pricing, not your subscription bill.

Tokens come from local Codex session records; quota comes from app queries. Credentials and statistics are stored locally, but querying quota and refreshing login tokens require connections to OpenAI services.

Usage habits supports this week, this month, and the last 30 days. Bar height shows cumulative Tokens for an hour; labels count days with usage. Quota observations use valid intervals for the same account, excluding gaps over 30 minutes, failed queries, resets, and quota increases. Query intervals include idle time, and other devices can consume quota, so observations do not represent actual working hours.

Quota query results and individual Token-usage records are stored in the local SQLite database. Detailed records from the latest 90 days are retained; older Token details are reduced to daily totals, while older quota observations are reduced to daily summaries. Existing local sessions can rebuild Token statistics, so first installation does not imply zero historical usage.

## Local files and data storage

`~` means the current macOS user’s home directory.

The app discovers accounts in `~/.codex/`, then reads its own quota, grouping, and history data. The application and user data are stored separately; deleting the `.app` does not clear account data.

### How Switch5 uses `~/.codex/`

Your Codex credentials and local session records are stored in `~/.codex/`. Switch5 reads this directory to discover accounts and count Tokens, but it does not rewrite, move, or delete your session records. Switch5 stores its own quota, grouping, settings, and statistics in `~/Library/Application Support/Codex Switch5/`, outside the Codex session directory.

| When you do this | What Switch5 does |
| --- | --- |
| Launch, account discovery, and Token statistics | Reads `auth.json`, account archives, `sessions/`, and `archived_sessions/` without modifying session contents |
| Quota query | Reads the relevant credential and connects to OpenAI services. Credential and local session files are not uploaded. If an access token has expired and refresh succeeds, the updated tokens are written back to the same credential file |
| Account switch | Renames credential files between `auth.json` and `auth.json.<account-name>`. The switch logic does not rewrite credential contents and attempts to restore the original file state if switching fails |
| Add account or sign in again | Archives and restores existing credentials. The new `auth.json` is created by the ChatGPT or Codex CLI sign-in flow. A replaced account archive may be removed after the operation succeeds |
| Remove account | Moves the corresponding `auth.json.<account-name>` to Trash after you confirm |

Your credential and local session files are not uploaded as files. When checking quota, Switch5 uses only the access token in the credential for authentication.

### Original Codex directories and files

Directory: `~/.codex/`.

| Path | Owner and source | How Switch5 uses it |
| --- | --- | --- |
| `auth.json` | Codex’s current login credentials, produced by sign-in | Reads identity; replaces the contents or file during switching; may update it when refreshing login tokens |
| `sessions/` | Codex’s original session records | Reads Token usage without moving original sessions |
| `archived_sessions/` | Codex’s original archived sessions | Reads Token usage without moving original sessions |

Although `auth.json` belongs to Codex, Switch5 uses it in the situations listed above. Do not move other Codex files, such as `config.toml`, when resetting Switch5.

Switch5 looks for accounts only in the current macOS user’s `~/.codex/` directory and does not follow a custom `CODEX_HOME`. An account does not appear in the list if its file contains only an API key, cannot be read, or lacks `tokens.access_token`.

### Codex credential archives and temporary switching files

These also reside in `~/.codex/`. Account archives still contain Codex credentials; Switch5 saves and switches them by renaming files. They are not private Switch5 statistics. Account-name suffixes are a convention used by switching tools, not evidence that Codex generates these archives itself.

| File | Purpose |
| --- | --- |
| `auth.json.<account-name>` | Archived Codex credentials managed by renaming |
| `.codex-switch5-auth-<UUID>` | Temporarily holds active credentials during switching |
| `.codex-switch5-stale-<UUID>` | Temporarily holds an older archive during switching |

A filename alone does not prove that Switch5 created an archive. `auth.json.bak`, `auth.json.hub`, and `auth.json.hub.*` do not appear in the Switch5 account list.

Temporary credentials normally exist only during an operation. If files remain after an abnormal exit, check sign-in recovery status before deleting them.

### App data directory

Directory: `~/Library/Application Support/Codex Switch5/`.

| File | Source and purpose |
| --- | --- |
| `account_usage.json` | App-generated: most recent account quota queries |
| `account_aliases.json` | App-generated: account aliases |
| `codex_switch5_account_groups.json` | App-generated: groups and account assignments |
| `.active-auth-profile` | App-generated: current account-name marker |
| `codex_switch5.sqlite3` | Main app database: individual Token-usage records, reading progress, quota history, and long-term summaries |
| `codex_switch5.sqlite3-wal`, `codex_switch5.sqlite3-shm` | SQLite working files that may exist while the app is running |
| `codex_switch5_switch_history.json` | App-generated: switching, sign-in, and related operation history |
| `codex_switch5_weekly_quota_projection.json` | App-generated: weekly quota estimates |
| `.codex-switch5-addition-pending.json` | App-generated: recovery state for unfinished account additions, created when needed |
| `.codex-switch5-reauthentication-pending.json` | App-generated: recovery state for unfinished sign-in renewals, created when needed |

### System preferences

File: `~/Library/Preferences/local.justaman.codex-switch5.plist`.

Managed by macOS for this app. It stores:

- Language, automatic refresh setting, and interval.
- Manual account order, sorting rules, and grouped display setting.
- Statistics sorting options.
- Current account name.

macOS caches preferences, so editing this file directly may not take effect immediately. Change these options in Switch5 settings.

### What removal deletes

| Action | Effect |
| --- | --- |
| Move one `.app` to Trash | Moves that app bundle and its code and icons; data, preferences, credentials, and sessions remain |
| Empty Trash containing the app | Deletes the trashed bundle, without automatically clearing external data |
| Delete a DMG | Deletes only the installer, not the installed app or user data |
| Use a third-party uninstaller and select related files | Depends on the tool and selections; it may also remove app data and preferences |

Switch5 has no uninstall routine that automatically clears external files when its `.app` is deleted. Ordinary app removal does not delete credentials in `~/.codex/`.
