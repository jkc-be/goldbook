- The server no longer risks hanging under parallel requests: it bundles
  SQLite 3.51.3, which fixes a deadlock in 3.51.1 between a connection
  closing and others opening.
