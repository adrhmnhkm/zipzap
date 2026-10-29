// KirimAja Desktop Frontend Controller

const hasTauri = window.__TAURI__ !== undefined;
const invoke = hasTauri ? window.__TAURI__.core.invoke : async (cmd, args) => mockInvoke(cmd, args);

// State
let appState = {
  alias: "Windows Laptop",
  ip: "192.168.1.100",
  port: 53317,
  saveDir: "C:\\Users\\User\\Downloads\\KirimAja",
  wifiBand: "5GHz", // or "2.4GHz"
  transfer: null,
};

// DOM Elements
const elServerStatus = document.getElementById("server-status");
const elDeviceAlias = document.getElementById("device-alias");
const elDeviceNetwork = document.getElementById("device-network");
const elWifiWarning = document.getElementById("wifi-warning");
const elSaveDir = document.getElementById("current-save-dir");

const elTransferCard = document.getElementById("transfer-card");
const elTransferFilename = document.getElementById("transfer-filename");
const elTransferSpeed = document.getElementById("transfer-speed");
const elTransferEta = document.getElementById("transfer-eta");
const elProgressFill = document.getElementById("progress-fill");
const elTransferBytes = document.getElementById("transfer-bytes");
const elTransferPercentage = document.getElementById("transfer-percentage");
const elResumeBadge = document.getElementById("resume-badge");

const elModalManualIp = document.getElementById("modal-manual-ip");
const elInputManualIp = document.getElementById("input-manual-ip");

// Initialize
async function init() {
  try {
    const status = await invoke("get_server_status");
    if (status) {
      appState = { ...appState, ...status };
      updateUI();
    }
  } catch (err) {
    console.warn("Using fallback/mock status:", err);
    updateUI();
  }

  setupEventListeners();
  setupTauriEvents();
}

function updateUI() {
  elDeviceAlias.textContent = appState.alias;
  elDeviceNetwork.textContent = `IP: ${appState.ip} | Port: ${appState.port}`;
  elSaveDir.textContent = appState.saveDir;

  // Wi-Fi 2.4GHz warning (FR-08)
  if (appState.wifiBand === "2.4GHz") {
    elWifiWarning.style.display = "flex";
  } else {
    elWifiWarning.style.display = "none";
  }

  // Active Transfer UI
  if (appState.transfer) {
    elTransferCard.style.display = "flex";
    elTransferFilename.textContent = appState.transfer.filename;
    elResumeBadge.style.display = appState.transfer.isResume ? "inline-block" : "none";

    const percent = Math.round((appState.transfer.bytesReceived / appState.transfer.totalBytes) * 100) || 0;
    elProgressFill.style.width = `${percent}%`;
    elTransferPercentage.textContent = `${percent}%`;
    elTransferBytes.textContent = `${formatBytes(appState.transfer.bytesReceived)} / ${formatBytes(appState.transfer.totalBytes)}`;
    elTransferSpeed.textContent = `${(appState.transfer.speedMBs || 0).toFixed(1)} MB/s`;
    elTransferEta.textContent = appState.transfer.eta ? `ETA: ${appState.transfer.eta}` : "ETA: --";
  } else {
    elTransferCard.style.display = "none";
  }
}

function setupEventListeners() {
  document.getElementById("btn-manual-ip").addEventListener("click", () => {
    elModalManualIp.style.display = "flex";
  });

  document.getElementById("btn-modal-close").addEventListener("click", () => {
    elModalManualIp.style.display = "none";
  });

  document.getElementById("btn-modal-connect").addEventListener("click", async () => {
    const ip = elInputManualIp.value.trim();
    if (ip) {
      await invoke("connect_manual_ip", { ip });
      elModalManualIp.style.display = "none";
    }
  });

  document.getElementById("btn-open-dir").addEventListener("click", () => {
    invoke("open_save_dir");
  });

  document.getElementById("btn-change-dir").addEventListener("click", async () => {
    const newDir = await invoke("change_save_dir");
    if (newDir) {
      appState.saveDir = newDir;
      updateUI();
    }
  });

  document.getElementById("btn-cancel").addEventListener("click", () => {
    invoke("cancel_active_transfer");
  });

  document.getElementById("btn-consent-accept").addEventListener("click", () => {
    document.getElementById("modal-consent").style.display = "none";
    invoke("respond_consent", { accept: true });
  });

  document.getElementById("btn-consent-reject").addEventListener("click", () => {
    document.getElementById("modal-consent").style.display = "none";
    invoke("respond_consent", { accept: false });
  });
}

function setupTauriEvents() {
  if (hasTauri && window.__TAURI__.event) {
    window.__TAURI__.event.listen("transfer-progress", (event) => {
      appState.transfer = event.payload;
      updateUI();
    });

    window.__TAURI__.event.listen("transfer-complete", () => {
      appState.transfer = null;
      updateUI();
    });

    window.__TAURI__.event.listen("consent-requested", (event) => {
      const data = event.payload;
      document.getElementById("consent-sender-text").textContent = `${data.senderAlias || "Perangkat"} ingin mengirim file:`;
      document.getElementById("consent-filename").textContent = data.fileName || "File";
      document.getElementById("consent-filesize").textContent = `Ukuran: ${formatBytes(data.fileSize || 0)}`;
      document.getElementById("modal-consent").style.display = "flex";
    });
  }
}

function formatBytes(bytes) {
  if (bytes === 0) return "0 B";
  const k = 1024;
  const sizes = ["B", "KB", "MB", "GB", "TB"];
  const i = Math.floor(Math.log(bytes) / Math.log(k));
  return parseFloat((bytes / Math.pow(k, i)).toFixed(1)) + " " + sizes[i];
}

function mockInvoke(cmd, args) {
  console.log(`[Mock Invoke] ${cmd}`, args);
  return null;
}

window.addEventListener("DOMContentLoaded", init);
