- The server no longer risks hanging under parallel requests: it bundles
  SQLite 3.53.2, which includes the fix for a deadlock in 3.51.1 between a connection
  closing and others opening.
