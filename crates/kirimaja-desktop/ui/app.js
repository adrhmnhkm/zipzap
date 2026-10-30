// KirimAja Desktop Frontend Controller

function getTauriInvoke() {
  if (window.__TAURI__) {
    if (window.__TAURI__.core && typeof window.__TAURI__.core.invoke === 'function') {
      return window.__TAURI__.core.invoke;
    }
    if (typeof window.__TAURI__.invoke === 'function') {
      return window.__TAURI__.invoke;
    }
  }
  return null;
}

async function invoke(cmd, args) {
  for (let attempt = 0; attempt < 30; attempt++) {
    const fn = getTauriInvoke();
    if (fn) {
      try {
        return await fn(cmd, args);
      } catch (err) {
        console.error(`Error invoking ${cmd}:`, err);
        throw err;
      }
    }
    await new Promise((r) => setTimeout(r, 100));
  }
  return mockInvoke(cmd, args);
}

// State
let appState = {
  alias: "Windows Laptop",
  ip: "Mendeteksi...",
  port: 53317,
  saveDir: "Downloads/KirimAja",
  wifiBand: "2.4GHz",
  transfer: null,
  peers: [],
};

// DOM Elements
const elServerStatus = document.getElementById("server-status");
const elDeviceAlias = document.getElementById("device-alias");
const elDeviceNetwork = document.getElementById("device-network");
const elWifiWarning = document.getElementById("wifi-warning");
const elSaveDir = document.getElementById("current-save-dir");
const elPeersList = document.getElementById("peers-list");

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
  }

  try {
    const initialPeers = await invoke("get_peers");
    if (initialPeers && Array.isArray(initialPeers)) {
      appState.peers = initialPeers;
      renderPeers(initialPeers);
    }
  } catch (_) {}

  updateUI();
  setupEventListeners();
  setupTauriEvents();

  // Periodic refresh of Wi-Fi / IP status
  setInterval(async () => {
    try {
      const status = await invoke("get_server_status");
      if (status && (status.ip !== appState.ip || status.wifiBand !== appState.wifiBand)) {
        appState = { ...appState, ...status };
        updateUI();
      }
    } catch (_) {}
  }, 5000);
}

function updateUI() {
  if (elDeviceAlias) elDeviceAlias.textContent = appState.alias || "KirimAja Laptop";
  if (elDeviceNetwork) elDeviceNetwork.textContent = `IP: ${appState.ip || "127.0.0.1"} | Port: ${appState.port || 53317}`;
  if (elSaveDir) elSaveDir.textContent = appState.saveDir || "Downloads/KirimAja";

  // Wi-Fi 2.4GHz warning (FR-08)
  if (elWifiWarning) {
    if (appState.wifiBand === "2.4GHz") {
      elWifiWarning.style.display = "flex";
    } else {
      elWifiWarning.style.display = "none";
    }
  }

  // Active Transfer UI
  if (appState.transfer) {
    if (elTransferCard) elTransferCard.style.display = "flex";
    const fileCount = appState.transfer.fileCount || 1;
    if (elTransferFilename) {
      if (fileCount > 1) {
        elTransferFilename.textContent = `${appState.transfer.filename} (${fileCount} berkas)`;
      } else {
        elTransferFilename.textContent = appState.transfer.filename;
      }
    }
    if (elResumeBadge) elResumeBadge.style.display = appState.transfer.isResume ? "inline-block" : "none";

    const percent = Math.round((appState.transfer.bytesReceived / appState.transfer.totalBytes) * 100) || 0;
    if (elProgressFill) elProgressFill.style.width = `${percent}%`;
    if (elTransferPercentage) elTransferPercentage.textContent = `${percent}%`;
    if (elTransferBytes) {
      elTransferBytes.textContent = `${formatBytes(appState.transfer.bytesReceived)} / ${formatBytes(appState.transfer.totalBytes)}`;
    }
    if (elTransferSpeed) elTransferSpeed.textContent = `${(appState.transfer.speedMBs || 0).toFixed(1)} MB/s`;
    if (elTransferEta) elTransferEta.textContent = appState.transfer.eta ? `ETA: ${appState.transfer.eta}` : "ETA: --";
  } else {
    if (elTransferCard) elTransferCard.style.display = "none";
  }
}

function renderPeers(peers) {
  if (!elPeersList) return;

  if (!peers || peers.length === 0) {
    elPeersList.innerHTML = `
      <div class="empty-peers">
        <span>Mencari perangkat di jaringan Wi-Fi... Buka aplikasi di iPhone agar otomatis terhubung.</span>
      </div>
    `;
    return;
  }

  let html = "";
  for (const peer of peers) {
    const isMobile = !peer.deviceType || peer.deviceType === "Mobile" || (peer.deviceModel && peer.deviceModel.toLowerCase().includes("iphone"));
    const icon = isMobile ? "📱" : "💻";
    const model = peer.deviceModel || (isMobile ? "iPhone" : "Komputer");
    const ip = peer.ip || "LAN";
    const port = peer.port || 53317;

    html += `
      <div class="peer-item">
        <div class="peer-info">
          <div class="peer-avatar">${icon}</div>
          <div>
            <div class="peer-name">${escapeHtml(peer.alias || "Perangkat")}</div>
            <div class="peer-sub">${escapeHtml(ip)} • ${escapeHtml(model)} • Port ${port}</div>
          </div>
        </div>
        <span class="badge" style="background: rgba(16, 185, 129, 0.2); color: #34d399; font-size: 11px; padding: 4px 10px; border-radius: 6px;">
          ● Siap Terhubung
        </span>
      </div>
    `;
  }
  elPeersList.innerHTML = html;
}

function escapeHtml(text) {
  const map = {
    '&': '&amp;',
    '<': '&lt;',
    '>': '&gt;',
    '"': '&quot;',
    "'": '&#039;'
  };
  return String(text).replace(/[&<>"']/g, (m) => map[m]);
}

function setupEventListeners() {
  const btnScan = document.getElementById("btn-scan");
  if (btnScan) {
    btnScan.addEventListener("click", async () => {
      btnScan.disabled = true;
      btnScan.textContent = "🔄 Memindai...";
      try {
        const peers = await invoke("scan_network");
        if (peers && Array.isArray(peers)) {
          appState.peers = peers;
          renderPeers(peers);
        }
      } catch (err) {
        console.error("Scan error:", err);
      } finally {
        btnScan.disabled = false;
        btnScan.textContent = "🔄 Pindai";
      }
    });
  }

  const btnManualIp = document.getElementById("btn-manual-ip");
  if (btnManualIp) {
    btnManualIp.addEventListener("click", () => {
      elModalManualIp.style.display = "flex";
      elInputManualIp.focus();
    });
  }

  const btnModalClose = document.getElementById("btn-modal-close");
  if (btnModalClose) {
    btnModalClose.addEventListener("click", () => {
      elModalManualIp.style.display = "none";
    });
  }

  const btnModalConnect = document.getElementById("btn-modal-connect");
  if (btnModalConnect) {
    btnModalConnect.addEventListener("click", async () => {
      const ip = elInputManualIp.value.trim();
      if (ip) {
        btnModalConnect.disabled = true;
        btnModalConnect.textContent = "Menghubungkan...";
        try {
          const res = await invoke("connect_manual_ip", { ip });
          alert(res || `Berhasil terhubung ke ${ip}`);
          elModalManualIp.style.display = "none";
        } catch (err) {
          alert(`Gagal menghubungkan ke ${ip}: ${err}`);
        } finally {
          btnModalConnect.disabled = false;
          btnModalConnect.textContent = "Hubungkan";
        }
      }
    });
  }

  const btnOpenDir = document.getElementById("btn-open-dir");
  if (btnOpenDir) {
    btnOpenDir.addEventListener("click", () => {
      invoke("open_save_dir");
    });
  }

  const btnChangeDir = document.getElementById("btn-change-dir");
  if (btnChangeDir) {
    btnChangeDir.addEventListener("click", async () => {
      const newDir = await invoke("change_save_dir");
      if (newDir) {
        appState.saveDir = newDir;
        updateUI();
      }
    });
  }

  const btnCancel = document.getElementById("btn-cancel");
  if (btnCancel) {
    btnCancel.addEventListener("click", () => {
      invoke("cancel_active_transfer");
    });
  }

  const btnConsentAccept = document.getElementById("btn-consent-accept");
  if (btnConsentAccept) {
    btnConsentAccept.addEventListener("click", () => {
      document.getElementById("modal-consent").style.display = "none";
      invoke("respond_consent", { accept: true });
    });
  }

  const btnConsentReject = document.getElementById("btn-consent-reject");
  if (btnConsentReject) {
    btnConsentReject.addEventListener("click", () => {
      document.getElementById("modal-consent").style.display = "none";
      invoke("respond_consent", { accept: false });
    });
  }
}

function setupTauriEvents() {
  if (window.__TAURI__ && window.__TAURI__.event) {
    window.__TAURI__.event.listen("peers-updated", (event) => {
      if (event.payload && Array.isArray(event.payload)) {
        appState.peers = event.payload;
        renderPeers(appState.peers);
      }
    });

    window.__TAURI__.event.listen("transfer-progress", (event) => {
      appState.transfer = event.payload;
      updateUI();
    });

    window.__TAURI__.event.listen("transfer-complete", () => {
      appState.transfer = null;
      updateUI();
    });

    window.__TAURI__.event.listen("transfer-cancelled", () => {
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

if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", init);
} else {
  init();
}
