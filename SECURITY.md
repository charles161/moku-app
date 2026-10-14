# Security policy

## Reporting a vulnerability

Please **don't open a public issue** for a security problem. Report it privately through GitHub: on this repository's
[Security tab](https://github.com/charles161/moku-app/security), choose **Report a vulnerability**. If you can't use
GitHub, email **hello@hellomoku.com** instead.

Please include:

- what you found and where (file, endpoint or version);
- how to reproduce it;
- what an attacker could do with it.

We'll acknowledge your report within a few days, keep you updated while we fix it, and credit you in the release notes
if you'd like.

## Scope

- The macOS app (`app/`) and its local brain (`brain-go/`), which listens on 127.0.0.1 only and requires a per-user
  bearer token.
- The relay (`proxy/`), which keeps the model gateway key server-side.
- The website (`website/`).

Moku reads what's on your screen, so reports about data leaving the Mac, or other users or apps reading Moku's data,
are especially welcome. The privacy policy, https://hellomoku.com/privacy, says what Moku reads, keeps and sends.

## Secrets in this repository

The repository must never contain credentials. CI runs [gitleaks](https://github.com/gitleaks/gitleaks) on every push
and pull request (`.github/workflows/gitleaks.yml`). Reviewed false positives are listed in `.gitleaksignore`. Local
settings belong in `.env` files, which are git-ignored (see `.env.example` and `proxy/.env.example`).
