const field = (id) => document.getElementById(id);
let tokenEdited = false;
field("token").addEventListener("input", () => { tokenEdited = true; });

// Whether the app holds a Battle.net session, which signs in Inventory and
// Ledger without asking for a game account.
let signedIn = false;

function drawSession(session) {
  signedIn = Boolean(session);
  field("session").textContent = signedIn ? "Signed in with Battle.net" : "Not signed in";
  field("log-in").hidden = signedIn;
  field("log-out").hidden = !signedIn;
}

// The app's own pages, under the website view.
const PAGES = {
  settings: ["Settings", "Uploads your scans and characters, and keeps the app and the addon up to date."],
  login: ["Log in", "Sign in once to see your characters, inventory and ledger, and to set up uploads."],
};

// Settings opens on the tab it last showed.
let settingsTab = "general";

function showPage(name, current) {
  field("page-title").textContent = PAGES[name][0];
  field("page-sub").textContent = PAGES[name][1];
  field("settings-tabs").hidden = name !== "settings";
  field("settings-page").hidden = name !== "settings" || settingsTab !== "general";
  field("advanced-page").hidden = name !== "settings" || settingsTab !== "advanced";
  field("login-page").hidden = name !== "login";
  for (const other of document.querySelectorAll(".views button, #log-in")) {
    if (other === current) {
      other.setAttribute("aria-current", "page");
    } else {
      other.removeAttribute("aria-current");
    }
  }
}

for (const tab of field("settings-tabs").querySelectorAll("button")) {
  tab.addEventListener("click", () => {
    settingsTab = tab.dataset.tab;
    for (const other of field("settings-tabs").querySelectorAll("button")) {
      if (other === tab) {
        other.setAttribute("aria-current", "page");
      } else {
        other.removeAttribute("aria-current");
      }
    }
    showPage("settings", document.querySelector('[data-view="settings"]'));
  });
}

// Filled in from the app, which owns the default.
let defaultApi = "";
field("default-api").addEventListener("click", () => {
  field("api").value = defaultApi;
});

field("log-in").addEventListener("click", async () => {
  const result = await window.goldbook.showView("login").catch(() => ({ ok: false, message: "Goldbook could not open that view." }));
  if (!result.ok) {
    notify(result.message);
    return;
  }
  showPage("login", field("log-in"));
});

field("log-out").addEventListener("click", async () => {
  try {
    await window.goldbook.battlenetLogout();
    drawSession(null);
    const settings = document.querySelector('[data-view="settings"]');
    await window.goldbook.showView("settings");
    showPage("settings", settings);
    notify("Logged out of Battle.net. Uploads continue for the game accounts already set up.");
  } catch (message) {
    notify(String(message));
  }
});

field("battlenet-login").addEventListener("click", async () => {
  field("battlenet-login").disabled = true;
  field("battlenet-cancel").hidden = false;
  notify("Complete Battle.net sign-in in your browser. You can cancel here.");
  try {
    const result = await window.goldbook.battlenetLogin();
    notify(result.message);
    if (result.ok && result.settings) {
      field("token").value = result.settings.token;
      tokenEdited = false;
      drawSession(result.settings.battlenetSession);
      showPage("settings", document.querySelector('[data-view="settings"]'));
    }
  } catch {
    notify("Goldbook could not complete Battle.net sign-in. Try again.");
  } finally {
    field("battlenet-login").disabled = false;
    field("battlenet-cancel").hidden = true;
    field("battlenet-code").hidden = true;
    field("battlenet-code").textContent = "";
  }
});
field("battlenet-cancel").addEventListener("click", () => {
  window.goldbook.cancelBattlenetLogin().catch(() => notify("Goldbook could not cancel sign-in."));
  notify("Cancelling Battle.net sign-in...");
});

function notify(text) {
  field("notice").textContent = text;
  field("notice").hidden = !text;
}

const layoutObserver = new ResizeObserver(() => {
  window.goldbook.layoutSite().catch(() => notify("Goldbook could not resize that view."));
});
layoutObserver.observe(document.documentElement);
layoutObserver.observe(document.querySelector(".rail"));

// The rail's button names the theme it switches to, as the addon's tooltip does.
function drawTheme() {
  const other = document.documentElement.dataset.theme === "dark" ? "light" : "dark";
  field("theme").title = other === "light" ? "Light window" : "Dark window";
  field("theme").setAttribute("aria-label", `Switch to the ${other} window`);
}

function shareTheme() {
  window.goldbook.setTheme(document.documentElement.dataset.theme)
    .catch(() => notify("Goldbook could not change the theme of the website view."));
}

field("theme").addEventListener("click", () => {
  const theme = document.documentElement.dataset.theme === "dark" ? "light" : "dark";
  document.documentElement.dataset.theme = theme;
  try {
    localStorage.setItem("goldbook-theme", theme);
  } catch {
    // Without storage the choice lasts until the app restarts.
  }
  drawTheme();
  shareTheme();
});
drawTheme();
shareTheme();

// The game account to open, null when there is one or none, undefined when
// the player cancels the choice between several.
async function pickAccount() {
  const accounts = await window.goldbook.getLogins();
  if (accounts.length < 2) {
    return null;
  }
  const picker = field("account-picker");
  const select = field("account");
  select.replaceChildren(...accounts.map((account) => {
    const option = document.createElement("option");
    option.value = account.id;
    option.textContent = account.label;
    return option;
  }));
  const chosen = new Promise((resolve) => picker.addEventListener("close", () => resolve(picker.returnValue), { once: true }));
  picker.showModal();
  return (await chosen) === "open" ? select.value : undefined;
}

for (const tab of document.querySelectorAll(".views button")) {
  tab.addEventListener("click", async () => {
    let result;
    try {
      const accountId = "signIn" in tab.dataset && !signedIn ? await pickAccount() : null;
      if (accountId === undefined) {
        return;
      }
      result = await window.goldbook.showView(tab.dataset.view, accountId);
    } catch {
      result = { ok: false, message: "Goldbook could not open that view." };
    }
    if (!result.ok) {
      notify(result.message);
      return;
    }
    showPage("settings", tab);
  });
}

field("auto").addEventListener("change", () => {
  field("minutes").disabled = !field("auto").checked;
});

field("choose").addEventListener("click", async () => {
  try {
    const folder = await window.goldbook.chooseFolder();
    if (folder) {
      field("wow").value = folder;
    }
  } catch {
    notify("Goldbook could not open the folder picker. Enter the folder path instead.");
  }
});

// Both tabs save every setting.
async function save(event) {
  event.preventDefault();
  const button = event.submitter;
  button.disabled = true;
  try {
    const result = await window.goldbook.save({
      wowDir: field("wow").value,
      api: field("api").value,
      token: field("token").value,
      openAtLogin: field("login").checked,
      autoSync: field("auto").checked,
      syncMinutes: Number(field("minutes").value),
    }, tokenEdited);
    notify(result.message);
    if (result.settings?.api) {
      field("api").value = result.settings.api;
      field("token").value = result.settings.token;
      tokenEdited = false;
      drawSession(result.settings.battlenetSession);
    }
  } catch {
    notify("Goldbook could not save the settings. Try again.");
  } finally {
    button.disabled = false;
  }
}
field("settings").addEventListener("submit", save);
field("advanced").addEventListener("submit", save);

field("sync").addEventListener("click", async () => {
  field("sync").disabled = true;
  try {
    await window.goldbook.syncNow();
  } catch (message) {
    notify(String(message));
  } finally {
    field("sync").disabled = false;
  }
});

field("site").addEventListener("click", async () => {
  field("site").disabled = true;
  try {
    const accountId = signedIn ? null : await pickAccount();
    if (accountId === undefined) {
      return;
    }
    const result = await window.goldbook.openSite(accountId);
    if (!result.ok) {
      notify(result.message);
    }
  } catch {
    notify("Goldbook could not open your browser.");
  } finally {
    field("site").disabled = false;
  }
});

function showStatus(status) {
  field("live").textContent = status.message;
  field("live").classList.toggle("watching", status.files > 0);
}

window.goldbook.onStatus(showStatus);

window.goldbook.onBattlenetCode((code) => {
  field("battlenet-code").textContent = `Enter code ${code} in your browser to connect Battle.net.`;
  field("battlenet-code").hidden = false;
}).catch(() => notify("Goldbook could not display the sign-in code. Restart the app."));

window.goldbook.onUploadReady(async () => {
  try {
    const state = await window.goldbook.getState();
    if (field("api").value === state.settings.api && !tokenEdited) {
      field("token").value = state.settings.token;
    }
  } catch {
    notify("Goldbook could not refresh its upload settings. Restart the app.");
  }
}).catch(() => notify("Goldbook could not refresh its upload settings. Restart the app."));

async function fill() {
  const initial = await window.goldbook.getState();
  field("wow").value = initial.settings.wowDir;
  field("api").value = initial.settings.api;
  field("token").value = initial.settings.token;
  field("login").checked = initial.settings.openAtLogin;
  field("auto").checked = initial.settings.autoSync;
  field("minutes").value = String(initial.settings.syncMinutes);
  field("minutes").disabled = !initial.settings.autoSync;
  showStatus(initial.status);
  drawSession(initial.settings.battlenetSession);
  defaultApi = initial.defaultApi;
}

fill().catch(() => {
  notify("Goldbook could not load the settings. Restart the app.");
});

function showUpdates(status) {
  field("client-version").textContent = `Goldbook ${status.version}`;
  field("rail-version").textContent = status.version;
  field("addon-update").textContent = status.addon;
  const update = status.client;
  const text = {
    idle: "Client updates have not been checked yet.",
    checking: "Checking for client updates...",
    current: "The client is up to date.",
    downloading: `Downloading Goldbook ${update.version}...`,
    ready: `Goldbook ${update.version} is downloaded and ready to install.`,
    installing: `Installing Goldbook ${update.version}...`,
    failed: update.message,
  };
  field("client-update").textContent = text[update.phase];
  field("client-update").dataset.phase = update.phase;
  field("install-update").hidden = update.phase !== "ready";
  field("update-alert").hidden = update.phase !== "ready" && update.phase !== "failed";
  field("update-alert").textContent = update.phase === "ready" ? "Update ready" : "Update needs attention";
}
field("update-alert").onclick = () => document.querySelector('[data-view="settings"]').click();
field("check-updates").onclick = async () => {
  field("check-updates").disabled = true;
  try { await window.goldbook.checkUpdates(); }
  catch { notify("Goldbook could not check for updates. Try again."); }
  finally { field("check-updates").disabled = false; }
};
field("install-update").onclick = async () => {
  field("install-update").disabled = true;
  try { await window.goldbook.installUpdate(); }
  catch (message) { notify(String(message)); }
  finally { field("install-update").disabled = false; }
};
window.goldbook.onUpdates(showUpdates).then(() => window.goldbook.getUpdates()).then(showUpdates)
  .catch(() => notify("Goldbook could not load its update status."));
