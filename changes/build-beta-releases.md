- `make release BETA=0.6.0-beta.1` builds and promotes a beta through
  **Release build** and **Release promote**, without a release PR. The beta
  goes to the beta update feed, to CurseForge and Wago as a beta, and to
  goldbook-addon as a prerelease; WoWInterface skips it.
