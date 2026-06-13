# OpenCode GitHub Actions

OpenCode GitHub Actions with pinned version and release digest verification.


## Mock with act

```sh
act workflow_dispatch \
  -W .github/workflows/test.yml \
  -j opencode \
  --secret-file .secrets
```
