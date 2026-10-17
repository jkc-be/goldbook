// Runs in the head, before the first paint, so that a reader who chose the
// dark theme never sees the light one flash. The light theme is the default
// whatever the system prefers; without storage the page stays light.
try {
  if (localStorage.getItem("goldbook-theme") === "dark") {
    document.documentElement.dataset.theme = "dark";
  }
} catch {
  // Storage can be blocked; the default theme needs none.
}
