// Runs in the head, before the first paint, so that a saved dark theme never
// flashes light. The light theme is the default whatever the system prefers.
try {
  if (localStorage.getItem("goldbook-theme") === "dark") {
    document.documentElement.dataset.theme = "dark";
  }
} catch {
  // Storage can be blocked; the default theme needs none.
}
