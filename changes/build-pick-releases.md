- `make pick-release` releases only the pull requests you name, on top of
  the last release, and leaves the rest of `main` for later. Without
  arguments it lists what `main` holds that no release does. It also picks a
  beta, such as `VERSION=0.6.0-beta.1`.
