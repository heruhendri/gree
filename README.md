# Installer Otomatis GRE + IPsec - NATVPS & Mikrotik

Skrip ini dibuat untuk memudahkan koneksi antara **NATVPS (Ubuntu/Debian)** ke **Router Mikrotik** menggunakan protokol GRE Tunnel + IPsec.

✅ **Keunggulan:**
- Kompatibel SEMUA Versi RouterOS (v6 & v7)
- Berjalan lancar di OpenVZ / LXC / NATVPS (tidak butuh modul kernel WireGuard/Tinc)
- Terenkripsi aman standar industri
- Instalasi 1 kali, otomatis nyala saat reboot

---

## 🚀 Cara Penggunaan

### 1. Di NATVPS
Jalankan perintah berikut di Terminal:
```bash
wget https://raw.githubusercontent.com/heruhendri/gree/main/install-vps.sh
chmod +x install-vps.sh
./install-vps.sh