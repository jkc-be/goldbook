- **Release build** and **Release promote** keep waiting for the checks and
  for goldbook-addon's release when GitHub answers a poll with a server error
  or drops the connection, instead of failing the run.
