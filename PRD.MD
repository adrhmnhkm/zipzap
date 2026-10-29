**

# Dokumen Produk & Teknis — "KirimAja"

  

**Versi**: 1.0 (Draft)

**Tanggal**: 2026-10-29

**Status**: Untuk direview

  

---

  

# DAFTAR ISI

  

1. [Ringkasan Eksekutif](#1-ringkasan-eksekutif)

2. [PRD — Product Requirements Document](#2-prd--product-requirements-document)

3. [TRD — Technical Requirements Document](#3-trd--technical-requirements-document)

4. [Lampiran](#4-lampiran)

  

---

  

# 1. Ringkasan Eksekutif

  

**KirimAja** adalah aplikasi transfer file lokal (LAN) untuk pengguna iPhone yang ingin memindahkan file ke laptop Windows. Dibangun dengan **Rust** sebagai core lintas platform, dengan UI tipis di atasnya (Tauri untuk Windows, SwiftUI untuk iOS).

  

**Diferensiasi utama** dibanding LocalSend:

  

| Aspek | LocalSend | KirimAja |

|-------|-----------|----------|

| Ukuran aplikasi | ~50–100 MB (Flutter) | < 15 MB (Windows), < 25 MB (iOS) |

| Resume transfer | ❌ Tidak ada | ✅ Ada (offset-based) |

| Penanganan layar padam iOS | Sering putus | BGProcessingTask + idleTimerDisabled + resume |

| Interop | — | ✅ Kompatibel protokol LocalSend v2 |

| UX untuk pengguna awam | Cukup | Panduan eksplisit + peringatan Wi-Fi |

  

**Target rilis v1.0**: Windows + iOS, transfer file/folder, resume, interoperabel LocalSend.

  

---

  

# 2. PRD — Product Requirements Document

  

## 2.1 Latar Belakang & Masalah

  

Pengguna iPhone di Indonesia sering kesulitan memindahkan file (foto, video, dokumen) ke laptop Windows. Alternatif yang ada memiliki kelemahan:

  

- **iTunes / Apple Devices**: lambat, UX buruk, sering gagal sync.

- **LocalSend**: open-source, tetapi (a) dibangun dengan Flutter sehingga berat, (b) di iOS sering **putus saat layar padam**, (c) throughput file besar tidak konsisten, (d) **tidak ada resume**.

- **Cloud (iCloud/Google Drive)**: butuh internet, mahal untuk file besar, privasi kurang.

  

**Peluang**: aplikasi native ringan (Rust di backend), kompatibel dengan protokol LocalSend agar dapat interoperasi dengan pengguna LocalSend yang sudah ada, dengan fokus **stabilitas transfer file besar** dan **UX yang jelas untuk pengguna awam Indonesia**.

  

## 2.2 Tujuan Produk

  

| # | Tujuan | Metrik Keberhasilan |

|---|--------|---------------------|

| G1 | Transfer file 1 GB iPhone→Windows tanpa putus | ≥ 95% sesi sukses tanpa intervensi |

| G2 | Throughput kompetitif | ≥ 20 MB/s di Wi-Fi 5GHz |

| G3 | Ringan | Windows < 15 MB, RAM idle < 40 MB; iOS < 25 MB |

| G4 | Mudah dipakai | Pengguna awam bisa kirim file dalam < 30 detik tanpa panduan |

| G5 | Interoperabel | Bisa terima/kirim dengan LocalSend resmi (protokol v2) |

  

## 2.3 Target Pengguna

  

**Persona A — "Ibu Rina" (non-teknis)**

Punya iPhone dan laptop Windows. Ingin mengirim video liburan ke laptop. Tidak memahami IP, band Wi-Fi, atau istilah teknis. Butuh alur yang jelas dan umpan balik visual.

  

**Persona B — "Budi" (power user)**

Sering mengirim file besar (video editing, backup foto). Peduli kecepatan, resume, dan kontrol folder tujuan.

  

## 2.4 Lingkup

  

### In Scope (MVP / v1.0)

  

- Aplikasi **Windows** (GUI ringan via Tauri) dan **iOS** (native SwiftUI).

- Discovery otomatis via UDP multicast (kompatibel LocalSend) + **mode input IP manual**.

- Transfer file & folder, satu atau banyak file.

- **Resume transfer** setelah putus.

- Indikator progres, kecepatan, ETA.

- Notifikasi & panduan "jangan matikan layar" di iOS.

- Kompatibel protokol LocalSend v2 (terima/kirim dengan app LocalSend resmi).

  

### Out of Scope (v1.0)

  

- Android (menyusul v1.1).

- macOS / Linux.

- Sinkronisasi folder otomatis.

- Transfer via internet (relay).

- Clipboard sync.

  

## 2.5 User Stories Kunci

  

| ID | User Story | Prioritas |

|----|-----------|-----------|

| US-01 | Sebagai pengguna, saya membuka app di iPhone & Windows, keduanya otomatis muncul di daftar perangkat, lalu saya pilih file dan kirim. | P0 |

| US-02 | Sebagai pengguna, saat mengirim video 2 GB, saya melihat progres & kecepatan; jika layar iPhone padam dan koneksi putus, saya bisa **lanjutkan** tanpa mengulang dari awal. | P0 |

| US-03 | Sebagai pengguna dengan Wi-Fi 2.4GHz, saya mendapat **peringatan** bahwa pindah ke 5GHz akan lebih cepat. | P1 |

| US-04 | Sebagai pengguna LocalSend, saya tetap bisa mengirim ke pengguna KirimAja (dan sebaliknya). | P1 |

| US-05 | Sebagai pengguna, saya bisa mengubah folder tujuan penyimpanan di Windows. | P1 |

| US-06 | Sebagai pengguna, saya bisa melihat riwayat transfer yang lalu. | P2 |

  

## 2.6 Alur UX Utama (Happy Path)

  

```

[Windows] Buka app → tampil "Menunggu koneksi" + daftar perangkat

[iOS]     Buka app → otomatis discover Windows

[iOS]     Pilih file → tap perangkat tujuan → konfirmasi

[Windows] Muncul dialog "Terima file dari [iPhone]?" → Terima

[Keduanya] Progres transfer (bar, MB/s, ETA)

[Selesai] File tersimpan di folder default (bisa diubah)

```

  

### Alur Resume (US-02)

  

```

[iOS] Transfer 60% → layar padam → koneksi putus

[iOS] Layar dinyalakan → app dibuka kembali

[iOS] App mendeteksi ada sesi transfer belum selesai

[iOS] Tap "Lanjutkan" → query offset ke Windows

[Windows] Balas offset (mis. 1.2 GB dari 2 GB)

[iOS] Kirim dari byte 1.2 GB → selesai

```

  

## 2.7 Persyaratan Fungsional (FR)

  

| ID | Requirement | Prioritas |

|----|-------------|-----------|

| FR-01 | Discovery perangkat via UDP multicast (port 53317, protokol LocalSend) | P0 |

| FR-02 | Mode input IP manual jika discovery gagal | P0 |

| FR-03 | Transfer file tunggal & multiple | P0 |

| FR-04 | Resume transfer setelah koneksi putus (offset-based) | P0 |

| FR-05 | Progres real-time + kecepatan + ETA | P0 |

| FR-06 | Peringatan & toggle "Layar tetap menyala" saat transfer (iOS) | P0 |

| FR-07 | Kompatibel protokol LocalSend v2 | P1 |

| FR-08 | Peringatan Wi-Fi 2.4GHz → sarankan 5GHz | P1 |

| FR-09 | Folder tujuan dapat dikonfigurasi (Windows) | P1 |

| FR-10 | Riwayat transfer | P2 |

| FR-11 | Transfer folder (rekursif) | P1 |

| FR-12 | PIN/konfirmasi opsional sebelum menerima | P1 |

  

## 2.8 Persyaratan Non-Fungsional (NFR)

  

| Kategori | Requirement |

|----------|-------------|

| **Performa** | Throughput ≥ 20 MB/s di 5GHz; CPU < 15% saat transfer 1 Gbps LAN |

| **Stabilitas** | Sesi 1 GB sukses ≥ 95%; auto-reconnect maks 3x |

| **Ukuran** | Windows < 15 MB, iOS < 25 MB |

| **Privasi** | Tidak ada telemetry default; transfer hanya LAN |

| **Keamanan** | HTTPS self-signed (kompatibel LocalSend) + opsi enkripsi payload |

| **Lokalisasi** | Bahasa Indonesia + English |

| **Aksesibilitas** | Kontras warna WCAG AA; dukungan Dynamic Type di iOS |

  

## 2.9 Risiko Produk

  

| Risiko | Dampak | Mitigasi |

|--------|--------|----------|

| iOS mematikan background task → transfer putus | Tinggi | Resume + panduan UX + BGProcessingTask |

| Discovery multicast diblokir router | Sedang | Mode IP manual |

| Interop LocalSend berubah | Sedang | Pin ke spesifikasi protokol v2, uji berkala |

| App Store review (background/network) | Sedang | Ikuti pedoman, jelaskan use-case transfer lokal |

| Firewall Windows memblokir | Sedang | Panduan UAC saat pertama kali + dokumentasi |

  

## 2.10 Kriteria Penerimaan v1.0

  

- [ ] Transfer 1 GB iPhone→Windows sukses ≥ 95% di 10 percobaan.

- [ ] Resume berfungsi setelah simulasi putus koneksi (Wi-Fi dimatikan manual).

- [ ] Kirim/terima dengan LocalSend resmi berhasil (dua arah).

- [ ] Ukuran installer Windows < 15 MB; app iOS < 25 MB.

- [ ] Pengujian di perangkat fisik iPhone (bukan simulator) lulus.

- [ ] Lokalisasi ID + EN lengkap.

  

---

  

# 3. TRD — Technical Requirements Document

  

## 3.1 Arsitektur Tingkat Tinggi

  

```

┌─────────────────┐         LAN (Wi-Fi)         ┌─────────────────┐

│   iOS App       │  ←── UDP multicast disc ──→ │  Windows App    │

│  (SwiftUI UI)   │  ←── HTTPS / QUIC xfer ───→ │  (Tauri UI)     │

│       │         │                             │       │         │

│  ┌────▼──────┐  │                             │  ┌────▼──────┐  │

│  │ Rust Core │  │                             │  │ Rust Core │  │

│  │ (kirimaja-│  │                             │  │ (kirimaja-│  │

│  │  core)    │  │                             │  │  core)    │  │

│  └───────────┘  │                             │  └───────────┘  │

└─────────────────┘                             └─────────────────┘

```

  

**Prinsip**: satu **core library Rust** (`kirimaja-core`) dipakai di kedua platform → logika protokol, discovery, transfer, dan resume identik. UI tipis di atasnya.

  

- **Windows**: **Tauri v2** (Rust backend + web UI ringan) → ukuran kecil, memakai core langsung.

- **iOS**: **SwiftUI** untuk UI + `kirimaja-core` dikompilasi sebagai **static library / xcframework** via FFI (UniFFI).

  

## 3.2 Stack Teknologi

  

| Komponen | Pilihan | Alasan |

|----------|---------|--------|

| Bahasa core | Rust (edition 2021) | Aman, cepat, cross-platform |

| Async runtime | Tokio | Standar, matang |

| HTTP/HTTPS | `axum` + `rustls` | Ringan, async |

| QUIC (opsional v1.1) | `quinn` | Multiplexing, tahan Wi-Fi jelek |

| Discovery | UDP multicast (`socket2` / `tokio`) | Kompatibel LocalSend |

| Serialization | `serde` + `serde_json` | Protokol LocalSend memakai JSON |

| FFI ke iOS | **UniFFI** | Bindings otomatis Rust↔Swift |

| UI Windows | Tauri v2 (webview) | Bundle kecil, native feel |

| UI iOS | SwiftUI | Native, akses API background |

| Build | Cargo + `xcodebuild` (Android menyusul: `cargo-ndk`) | — |

  

## 3.3 Struktur Modul `kirimaja-core`

  

```

kirimaja-core/

├── discovery/      // UDP multicast announce + listen

├── protocol/       // structs LocalSend v2 (DeviceInfo, PrepareUpload, dll)

├── server/         // HTTPS server (axum) penerima file

├── client/         // HTTPS client pengirim

├── transfer/       // streaming, chunking, resume state

├── crypto/         // self-signed cert gen (rcgen), fingerprint

└── ffi/            // UniFFI definitions (feature flag)

```

  

## 3.4 Protokol & Interop

  

### 3.4.1 Kompatibilitas LocalSend v2 (wajib)

  

- **Discovery**: UDP multicast `224.0.0.167:53317`, pesan JSON `Announce` (deviceInfo: alias, version, deviceModel, deviceType, fingerprint, port, protocol).

- **Transfer**: HTTPS di port dinamis. Endpoint kunci:

  - `POST /api/localsend/v2/prepare-upload` → minta izin + dapat `sessionId` & token file.

  - `POST /api/localsend/v2/upload?sessionId=..&fileId=..&token=..` → stream isi file.

  - `POST /api/localsend/v2/cancel`

- **Sertifikat**: self-signed; fingerprint dipertukarkan saat discovery, diverifikasi klien.

  

### 3.4.2 Ekstensi KirimAja (non-breaking)

  

- Header `X-KirimAja-Resume-Offset` untuk resume.

- Endpoint `/api/kirimaja/v1/resume-info` untuk menanyakan offset terakhir.

- Jika lawan bicara bukan KirimAja → fallback ke perilaku LocalSend standar (mulai dari 0).

  

## 3.5 Desain Resume (FR-04)

  

**Masalah**: LocalSend asli tidak memiliki resume. Kita tambahkan tanpa merusak interop.

  

**Mekanisme (sisi penerima, Windows/iOS):**

  

1. Saat mulai menerima file, buat file tujuan `.part` + catat metadata `{fileId, expectedSize, sha256_prefix, bytesReceived}` di **journal** (SQLite ringan / file JSON).

2. Tulis stream ke `.part` secara **append + fsync berkala** (mis. tiap 16 MB).

3. Jika koneksi putus: `.part` & journal tetap ada.

4. Saat klien reconnect (dengan `fileId` sama):

   - Klien memanggil `GET /api/kirimaja/v1/resume-info?fileId=..`

   - Server membalas `{offset: N}`.

   - Klien mengirim dari byte ke-N (`Range`/query `?offset=N`).

5. Setelah selesai: verifikasi ukuran (+checksum jika dikirim), rename `.part` → nama final, hapus journal.

  

**Edge case:**

  

- Ukuran/checksum berbeda → tolak resume, mulai ulang.

- Journal kedaluwarsa (mis. > 7 hari) → bersihkan.

  

## 3.6 Strategi Transfer File Besar

  

- **Streaming**, bukan load ke memori (hindari OOM). Buffer 256 KB–1 MB per chunk.

- **Backpressure** via `tokio::io::copy` / `ReaderStream` di axum.

- **Multiplex**: untuk banyak file, kirim sekuensial per file tetapi paralel terbatas (mis. 2–3 koneksi) agar tidak saling menghalangi.

- **Keep-alive** & timeout terukur (read timeout 30 dtk, reconnect otomatis maks 3x dengan backoff).

  

## 3.7 iOS: Menangani Layar Padam (risiko terbesar)

  

Implementasi di layer Swift:

  

1. **`UIApplication.shared.beginBackgroundTask`** saat transfer aktif → mendapat ~30 detik–beberapa menit ekstra setelah app ke background.

2. **`BGProcessingTask`** (BackgroundTasks framework) untuk transfer yang butuh waktu lama; daftarkan task ID, jadwalkan saat transfer mulai. Sistem memberi waktu lebih lama (khususnya saat charging).

3. **`UIApplication.shared.isIdleTimerDisabled = true`** selama transfer di foreground + **toggle UI** "Layar tetap menyala".

4. **Notifikasi lokal** mengingatkan pengguna jika transfer masih berjalan di background.

5. **Resume** (poin 3.5) sebagai jaring pengaman terakhir — jika OS tetap mematikan, transfer lanjut saat app dibuka lagi.

  

**Catatan realistis**: iOS tidak menjamin transfer berjalan tanpa batas di background. Kombinasi (1)+(3)+(5) memberi hasil praktis terbaik. Harus diuji di perangkat fisik (bukan simulator).

  

## 3.8 Windows App (Tauri)

  

- **Bundle**: Tauri v2 → MSI/NSIS, target < 15 MB.

- **UI**: HTML/CSS/JS ringan (vanilla + utilitas minimal, atau Svelte jika perlu).

- **Tray icon** + notifikasi native.

- **Auto-start server** saat app dibuka; port dinamis.

- **Firewall**: dokumentasikan aturan; minta user allow saat pertama (UAC).

  

## 3.9 Keamanan

  

- TLS via `rustls` + sertifikat self-signed (`rcgen`), fingerprint diverifikasi saat discovery.

- Opsi **PIN 6 digit** sebelum menerima (FR-12): server minta PIN, klien input.

- Tidak ada data keluar LAN. Tidak ada telemetry default.

- Validasi path (cegah path traversal saat menerima nama file dari klien).

  

## 3.10 Pengujian

  

| Jenis | Cakupan |

|-------|---------|

| Unit | Protocol ser/de, resume journal, path validation |

| Integrasi | Transfer 1 file / banyak file, putus-sambung (simulasi `iptables` drop / matikan Wi-Fi) |

| Interop | Uji silang dengan LocalSend resmi (kirim & terima) |

| Perangkat | iPhone fisik (layar padam, background), Windows 10/11 |

| Performa | Benchmark 1 GB & 5 GB di 2.4GHz vs 5GHz |

| Fuzz | Parser pesan protokol (anti-crash) |

  

## 3.11 Rencana Rilis

  

| Fase | Durasi (estimasi) | Deliverable |

|------|-------------------|-------------|

| M0 | 2 minggu | `kirimaja-core` skeleton: discovery + protocol structs + uji interop dasar |

| M1 | 3 minggu | Transfer 1 file end-to-end Windows↔Windows, lalu Windows↔LocalSend |

| M2 | 3 minggu | Resume + journal + uji putus-sambung |

| M3 | 3 minggu | iOS app (SwiftUI + UniFFI) + background handling |

| M4 | 2 minggu | Windows Tauri GUI + tray + settings |

| M5 | 2 minggu | Hardening, interop matrix, QA perangkat, rilis beta |

  

**Total estimasi**: ~15 minggu (3,5 bulan) untuk v1.0 beta.

  

## 3.12 Metrik Teknis yang Dipantau (QA)

  

- Throughput (MB/s) per band Wi-Fi.

- % sesi sukses 1 GB tanpa intervensi.

- Waktu resume (dari putus ke lanjut).

- RAM/CPU idle & saat transfer.

- Ukuran installer.

  

## 3.13 Dependency & Library Kunci

  

| Kebutuhan | Crate / Framework |

|-----------|-------------------|

| Async runtime | `tokio` |

| HTTP server | `axum` |

| TLS | `rustls`, `rcgen` |

| JSON | `serde`, `serde_json` |

| UDP socket | `socket2`, `tokio::net::UdpSocket` |

| FFI | `uniffi` |

| Logging | `tracing` |

| SQLite (journal) | `rusqlite` atau `sled` |

| QUIC (v1.1) | `quinn` |

  

---

  

# 4. Lampiran

  

## 4.1 Contoh Pesan Discovery (LocalSend v2)

  

```json

{

  "alias": "iPhone Rina",

  "version": "2.1",

  "deviceModel": "iPhone14,5",

  "deviceType": "mobile",

  "fingerprint": "sha256:abc123...",

  "port": 53317,

  "protocol": "https",

  "download": false

}

```

  

## 4.2 Contoh Alur prepare-upload

  

```

POST /api/localsend/v2/prepare-upload

Body: {

  "info": { "alias": "...", "version": "2.1", ... },

  "files": {

    "file1": { "id": "file1", "fileName": "video.mp4", "size": 2147483648, "fileType": "video/mp4" }

  }

}

Response: {

  "sessionId": "sess-xyz",

  "files": { "file1": "token-abc" }

}

```

  

## 4.3 Glosarium

  

| Istilah | Definisi |

|---------|----------|

| Discovery | Proses menemukan perangkat lain di LAN |

| Multicast | Pengiriman paket ke grup alamat IP |

| Resume | Melanjutkan transfer dari titik terakhir |

| Fingerprint | Hash sertifikat untuk verifikasi identitas |

| FFI | Foreign Function Interface (Rust↔Swift) |

| Tauri | Framework aplikasi desktop berbasis Rust + webview |

  

## 4.4 Riwayat Revisi

  

| Versi | Tanggal | Perubahan |

|-------|---------|-----------|

| 0.1 | 2026-10-29 | Draft awal (PRD + TRD) |

  

---

  

**Dokumen ini siap untuk direview.** Langkah berikutnya yang disarankan:

  

1. **Review teknis** oleh tim engineering (khususnya bagian 3.5 resume dan 3.7 iOS background).

2. **Validasi pasar** — wawancara singkat 5–10 pengguna target untuk memastikan prioritas fitur.

3. **Skeleton Cargo workspace** `kirimaja-core` siap diisi.

  

Mau saya lanjutkan dengan membuat **skeleton Cargo workspace** atau **spesifikasi protokol detail** (skema struct lengkap LocalSend v2)?

  
**