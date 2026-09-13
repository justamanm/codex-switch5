<h1 align="center">
  <img src="docs/images/app-icon.png" width="96" align="middle" alt="Codex Switch5 icon"> Codex Switch5
</h1>

<p align="center">
  v0.2 · English · <a href="README_zh.md">中文</a>
</p>

## Overview

Codex Switch5 is a macOS app for managing multiple Codex accounts. Its main purpose is to make several Plus and Team accounts manageable when their 5-hour limits are reached quickly. It also provides per-account Token statistics and estimates the value represented by a full weekly quota.

Account information and credentials stay on your Mac. The app does not display identity tokens.

## Download

Download the latest version from [Releases](https://github.com/justamanm/codex-switcher/releases), open the DMG, and drag Codex Switch5 into the Applications folder. Development builds are available from the [rolling latest release](https://github.com/justamanm/codex-switcher/releases/tag/latest).

The current build uses an ad hoc signature. On first launch, control-click the app and choose **Open**. If macOS still blocks it, open **System Settings → Privacy & Security** and choose **Open Anyway**.

![Codex Switch5 dashboard](docs/images/dashboard-overview-en.png)

## Primary purpose: manage multiple Plus and Team accounts

Once a Plus or Team account reaches its 5-hour limit, its available usage can run out quickly. Rotating between several accounts can ease this problem, but account management becomes tedious: every switch may require another manual sign-in, remaining usage is easy to forget, and each account can have a different reset time.

Codex Switch5 saves and manages these accounts automatically. Its dashboard shows the active account, 5-hour and weekly usage, and reset times. It recommends the next account based on current availability and supports one-click switching, reducing repeated sign-ins and manual comparisons.

## Secondary purpose: Token statistics and quota value estimates

The Token Usage page shows each account's usage for its 5-hour cycle, weekly quota cycle, today, and the current week. It includes input, cached input, output, and reasoning Tokens.

Using recorded Token usage and quota changes, the app also estimates the approximate value represented by a full weekly quota. This uses OpenAI API-equivalent pricing to show usage scale; it is not the actual bill for a Plus or Team subscription.

## Usage history and patterns

The **Token Usage → Usage patterns** page can switch between this week, this month, and the last 30 days. Bar height shows total Token usage for each hour of the day, while the number above each bar shows how many days contained usage in that hour. The page combines records from all accounts to show the average hourly decrease in the 5-hour quota and the percentage of weekly quota corresponding to one full 5-hour quota.

Usage history starts accumulating after this feature is enabled, so two ranges can temporarily show the same result when all available records fall inside both ranges. The page displays the actual start and end dates. Quota refreshes may include idle time between samples, and usage on other devices may also affect the result, so these values describe observed changes rather than exact working time.

## Other features

- Add accounts through a guided flow, then save and identify them automatically.
- Create manual groups, which is useful for keeping related Team accounts together.
- Combine sorting rules for weekly reset time, weekly quota, 5-hour reset time, and 5-hour quota, or return to manual ordering.
- Assign aliases and clearly identify the active or expired accounts.
- Refresh all accounts together or update one account immediately.
- Automatically refresh an account after its usage resets.
- View the number of reset cards available to each account.
- Keep existing data visible if one account fails to refresh.
- Manage accounts that are no longer needed.
- Use Chinese or English, or follow the macOS system language.

## How to use it

Open the app to see the current account, the recommended next account, and the usage status of every account. You can use the recommendation or select another account from the list.

When adding an account, the app uses ChatGPT when it is installed. If only Codex CLI is available, it asks you to run `codex login` in Terminal and detects the new account after sign-in. If you cancel, it restores the account that was active before you started.

## Usage notes

- Adding an account requires either ChatGPT or Codex CLI. If neither is installed, Codex Switch5 stops before changing any account files.
- When Codex CLI is installed, exit its running sessions before switching or adding an account, then reopen it when prompted.
- Existing accounts can still be switched without ChatGPT installed; automatic ChatGPT reopening is skipped.
- Keep Codex Switch5 open while adding an account so it can complete sign-in or restore the previous account after cancellation.
- Account information and credentials stay on your Mac. The app does not display identity tokens.
