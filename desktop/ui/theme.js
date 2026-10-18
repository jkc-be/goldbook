// Runs in the head, before the first paint, so that a saved light theme never
// flashes dark. The dark theme is the default whatever the system prefers.
try {
  if (localStorage.getItem("goldbook-theme") === "light") {
    document.documentElement.dataset.theme = "light";
  }
} catch {
  // Storage can be blocked; the default theme needs none.
}
