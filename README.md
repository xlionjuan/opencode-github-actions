# OpenCode GitHub Actions

A GitHub Action for OpenCode with pinned `actions/cache` and [OpenCode](https://github.com/anomalyco/opencode/releases/) versions.

This action is a fork of the [official action](https://github.com/anomalyco/opencode/blob/dev/github/action.yml). It updates `actions/cache`, improves the OpenCode installation logic, pins the OpenCode version, and verifies the SHA256 checksum on every run, whether the cache is hit or missed.

> [!IMPORTANT]  
> This action uses `${{ github.token }}` in the `Resolve opencode release metadata` step only so `gh` can fetch OpenCode release metadata. By default, the token is not exposed to OpenCode itself. If you want OpenCode to access the token, for example to create issues, pass it through the step environment as `GH_TOKEN: ${{ github.token }}`.

Both `actions/cache` and OpenCode are updated automatically by [Renovate](https://github.com/xlionjuan/opencode-github-actions/issues/1) with `minimumReleaseAge` set to `1`. Use this action with a pinned Git SHA, and make sure you have a dependency management tool like Renovate or Dependabot enabled so you do not miss updates.

## How to use

Use it the same way as the official action.

First, get the latest Git SHA for this repo:

```sh
curl -fsSL "https://api.github.com/repos/xlionjuan/opencode-github-actions/branches/main" | jq -r '.commit.sha'
```

Then replace `anomalyco/opencode/github@latest` with `xlionjuan/opencode-github-actions@{GIT SHA}`, using the value from the previous step:

> [!WARNING]  
> You should **NEVER** use `latest` ! Check [Upgrade best practices](https://docs.renovatebot.com/upgrade-best-practices).

```yaml
- name: Run opencode
  uses: xlionjuan/opencode-github-actions@{GIT SHA}
```

## Related issues

These are the reasons I created this forked action.

[[FEATURE]: Add version input to the GitHub action anomalyco/opencode#31387](https://github.com/anomalyco/opencode/issues/31387)

[[FEATURE]: Add SHA256 checksum verification to the install script anomalyco/opencode#31390](https://github.com/anomalyco/opencode/issues/31390)

## Mock with act

> For development use only.

```sh
act workflow_dispatch \
  -W .github/workflows/test.yml \
  -j opencode \
  --secret-file .env
```
