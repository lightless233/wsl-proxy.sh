# Repository instructions

- Do not run `/simplify` as a routine step before commits in this repository.
- Run `/simplify` only when the user explicitly requests it.
- For commits without `/simplify`, use the repository's one-commit `simplify-guard` bypass (`echo simplify-guard:bypass`) and keep normal Git hooks enabled. Do not use `git commit --no-verify`.
