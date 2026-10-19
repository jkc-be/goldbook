- Add detailed help for every Makefile command, with arguments, examples,
  prerequisites and effects. Use `make help release`, `make help-release`
  or `make release HELP=1`. Help mode skips commands and their prerequisites,
  including when several commands are requested together.
- Explain that `make release --help` displays Make's own help, and point
  missing-version errors to the relevant command help.
