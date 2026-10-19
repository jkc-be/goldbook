const { invoke } = window.__TAURI__.core;
const siteLayout = () => {
  const stage = document.querySelector(".stage").getBoundingClientRect();
  return { viewportHeight: window.innerHeight, left: stage.left, top: stage.top };
};
window.goldbook = {
  layoutSite: () => invoke("layout_site", siteLayout()),
  setTheme: (theme) => invoke("set_theme", { theme }),
  getUpdates: () => invoke("get_updates"),
  checkUpdates: () => invoke("check_updates"),
  installUpdate: () => invoke("install_update"),
  onUpdates: (listener) => window.__TAURI__.event.listen("updates", ({ payload }) => listener(payload)),
  getState: () => invoke("get_state"),
  chooseFolder: () => invoke("choose_folder"),
  save: (input) => invoke("save", { input }),
  syncNow: () => invoke("sync_now"),
  battlenetLogin: () => invoke("battlenet_login"),
  battlenetLogout: () => invoke("battlenet_logout"),
  onBattlenetCode: (listener) => window.__TAURI__.event.listen("battlenet-code", ({ payload }) => listener(payload)),
  cancelBattlenetLogin: () => invoke("cancel_battlenet_login"),
  getLogins: () => invoke("get_logins"),
  openSite: async (accountId = null) => {
    try {
      await invoke("open_site", { accountId });
      return { ok: true };
    } catch (message) {
      return { ok: false, message: String(message) };
    }
  },
  showView: async (name, accountId = null) => {
    try {
      await invoke("show_view", { name, accountId, ...siteLayout() });
      return { ok: true };
    } catch (message) {
      return { ok: false, message: String(message) };
    }
  },
  onStatus: (listener) => window.__TAURI__.event.listen("status", ({ payload }) => listener(payload)),
};
