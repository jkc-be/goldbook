// Runs in the head, before the first paint, so that a reader who chose the
// light theme never sees the dark one flash, nor the item's prices at another
// width than the one they dragged them to. The dark theme is the default
// whatever the system prefers; without storage the page stays dark.
try {
  if (localStorage.getItem("goldbook-theme") === "light") {
    document.documentElement.dataset.theme = "light";
  }
  const width = Number(localStorage.getItem("goldbook-detail-width"));
  if (width > 0) {
    document.documentElement.style.setProperty("--detail-width", `${width}px`);
  }
} catch {
  // Storage can be blocked; the default theme needs none.
}
