- Uploading now always needs Battle.net sign-in in the app. The server no
  longer takes the shared `UPLOAD_TOKEN` or registers upload tokens without a
  Battle.net session, and ignores `UPLOAD_TOKEN` and `SELF_REGISTRATION` in
  its environment. A token registered before Battle.net sign-in stops
  uploading; click **Sign in with Battle.net** in the app to get a new one.
