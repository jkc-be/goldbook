// Runs in the head, before the first paint, so that a reader who chose the
// light theme never sees the dark one flash. The dark theme is the default
// whatever the system prefers; without storage the page stays dark.
try {
  if (localStorage.getItem("goldbook-theme") === "light") {
    document.documentElement.dataset.theme = "light";
  }
} catch {
  // Storage can be blocked; the default theme needs none.
}
