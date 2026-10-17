// Loaded in the head so a saved dark theme applies before the first paint.
// Light is the default whatever the system setting.
{
  const root = document.documentElement;
  const key = "goldbook-theme";
  try {
    if (localStorage.getItem(key) === "dark") {
      root.dataset.theme = "dark";
    }
  } catch {}

  const showChoice = () => {
    for (const choice of document.querySelectorAll("[data-theme-choice]")) {
      choice.setAttribute("aria-pressed", String(choice.dataset.themeChoice === root.dataset.theme));
    }
  };

  document.addEventListener("DOMContentLoaded", () => {
    for (const choice of document.querySelectorAll("[data-theme-choice]")) {
      choice.addEventListener("click", () => {
        root.dataset.theme = choice.dataset.themeChoice;
        try {
          localStorage.setItem(key, root.dataset.theme);
        } catch {}
        showChoice();
      });
    }
    showChoice();
  });
}
