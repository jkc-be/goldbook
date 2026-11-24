- **Release build** and **Release promote** read goldbook-addon with the
  workflow's token, so they no longer fail with "GitHub rate limit reached"
  when other jobs on a GitHub-hosted runner's address use up the 60
  anonymous requests an hour.
