const { invoke } = window.__TAURI__.core;
const siteLayout = () => ({
  viewportHeight: window.innerHeight,
  barHeight: document.querySelector(".masthead").getBoundingClientRect().bottom,
});
window.goldbook = {
  layoutSite: () => invoke("layout_site", siteLayout()),
  getUpdates: () => invoke("get_updates"),
  checkUpdates: () => invoke("check_updates"),
  installUpdate: () => invoke("install_update"),
  onUpdates: (listener) => window.__TAURI__.event.listen("updates", ({ payload }) => listener(payload)),
  getState: () => invoke("get_state"),
  chooseFolder: () => invoke("choose_folder"),
  save: (input, tokenEdited) => invoke("save", { input, tokenEdited }),
  syncNow: () => invoke("sync_now"),
  battlenetLogin: () => invoke("battlenet_login"),
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
  onUploadReady: (listener) => window.__TAURI__.event.listen("upload-ready", listener),
};
