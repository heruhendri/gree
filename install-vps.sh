#!/bin/bash
# ==================================================
# INSTALLER OTOMATIS GRE + IPsec - NATVPS SERVER
# MIKROTIK KLIEN (Di belakang NAT / TANPA IP PUBLIK)
# Kompatibel: Semua RouterOS v6 & v7
# Dibuat oleh: Hendri
# ==================================================

# WARNA TEKS
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

clear
echo -e "${GREEN}=================================================="
echo "  INSTALLASI OTOMATIS GRE + IPSEC - NATVPS SERVER"
echo "  -> MIKROTIK KLIEN (TANPA IP PUBLIK)"
echo "==================================================${NC}"

# ==================================================
# BAGIAN INPUT DATA DARI PENGGUNA
# ==================================================
echo -e "${YELLOW}Masukkan data yang diminta di bawah ini:${NC}"
read -p "👉 Masukkan IP PUBLIK NATVPS ANDA       : " IP_VPS
read -p "👉 Masukkan JARINGAN LOKAL MIKROTIK     : " JARINGAN_LOKAL # Contoh: 172.16.0.0/16
read -p "👉 Masukkan KATA SANDI IPSEC (Kuat)     : " KUNCI_RAHASIA

# Validasi input
if [ -z "$IP_VPS" ] || [ -z "$JARINGAN_LOKAL" ] || [ -z "$KUNCI_RAHASIA" ]; then
    echo -e "${RED}❌ ERROR: Semua isian wajib diisi!${NC}"
    exit 1
fi

# Variabel Tetap
IP_TUNNEL_VPS="10.8.0.1"
IP_TUNNEL_MIKROTIK="10.8.0.2"
NETMASK_TUNNEL="30"
INTERFACE_WAN_VPS="venet0" # Sesuai kartu jaringan NATVPS kamu

echo -e "\n${GREEN}>>> Memulai instalasi & konfigurasi...${NC}"

# ==================================================
# BAGIAN 1: BERSIHKAN KONFIGURASI LAMA
# ==================================================
echo -e "${YELLOW}Membersihkan sisa konfigurasi lama...${NC}"
systemctl stop tinc@vpn-lan 2>/dev/null
systemctl disable tinc@vpn-lan 2>/dev/null
rm -rf /etc/tinc /usr/local/bin/wireguard-go /etc/wireguard

# Hapus antarmuka GRE jika sudah ada
ip tunnel del gre1 2>/dev/null

# Hapus aturan IPsec lama
ip xfrm state flush
ip xfrm policy flush

# Reset Iptables
iptables -F
iptables -t nat -F
iptables -X

# ==================================================
# BAGIAN 2: INSTALASI PAKET DASAR
# ==================================================
echo -e "${YELLOW}Menginstal paket pendukung...${NC}"
apt update -y
apt install -y iproute2 iptables

# Aktifkan modul jaringan (Wajib di NATVPS/OpenVZ)
modprobe ip_gre 2>/dev/null || true
modprobe xfrm4_tunnel 2>/dev/null || true

# ==================================================
# BAGIAN 3: KONFIGURASI TEROWONGAN GRE DI VPS (SEBAGAI SERVER)
# ==================================================
echo -e "${YELLOW}Membuat Terowongan GRE (Mode Server)...${NC}"

# Buat Terowongan - KUNCI: local=IP_VPS, remote=0.0.0.0 (terima dari mana saja)
ip tunnel add gre1 mode gre local $IP_VPS remote 0.0.0.0 ttl 255

# Pasang IP Address
ip addr add ${IP_TUNNEL_VPS}/${NETMASK_TUNNEL} dev gre1

# Nyalakan Antarmuka
ip link set gre1 up

# Tambah Rute ke Jaringan Lokal MikroTik (lewat IP Tunnel MikroTik)
ip route add $JARINGAN_LOKAL via $IP_TUNNEL_MIKROTIK dev gre1

# ==================================================
# BAGIAN 4: KONFIGURASI NAT & FORWARDING
# ==================================================
echo -e "${YELLOW}Mengatur NAT & Forwarding...${NC}"

# Izinkan paket lewat
echo 1 > /proc/sys/net/ipv4/ip_forward
echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
sysctl -p > /dev/null

# Aturan Firewall & NAT - Agar internet jalan dari MikroTik
iptables -A FORWARD -i gre1 -j ACCEPT
iptables -t nat -A POSTROUTING -o $INTERFACE_WAN_VPS -j MASQUERADE

# ==================================================
# BAGIAN 5: KONFIGURASI IPsec (ENKRIPSI) - DUKUNG NAT-T
# ==================================================
echo -e "${YELLOW}Mengatur Enkripsi IPsec (Mendukung NAT)...${NC}"

# Aturan Status Keamanan - TIDAK KUNCIP ALAMAT JAUH (penting untuk di belakang NAT)
ip xfrm state add src $IP_VPS dst 0.0.0.0 proto esp spi 0xc0ffee01 reqid 1 mode tunnel auth sha256 $KUNCI_RAHASIA enc aes256 $KUNCI_RAHASIA
ip xfrm state add src 0.0.0.0 dst $IP_VPS proto esp spi 0xc0ffee02 reqid 1 mode tunnel auth sha256 $KUNCI_RAHASIA enc aes256 $KUNCI_RAHASIA

# Aturan Kebijakan - Izinkan koneksi dari alamat apa saja ke VPS
ip xfrm policy add src 10.8.0.0/24 dst 10.8.0.0/24 dir out tmpl src $IP_VPS dst 0.0.0.0 proto esp reqid 1 mode tunnel
ip xfrm policy add src 10.8.0.0/24 dst 10.8.0.0/24 dir in tmpl src 0.0.0.0 dst $IP_VPS proto esp reqid 1 mode tunnel

# ==================================================
# BAGIAN 6: BUATKAN FILE SCRIPT UNTUK MIKROTIK (KLIEN)
# ==================================================
echo -e "${GREEN}Membuatkan file skrip MIKROTIK: /root/mikrotik-script.rsc${NC}"

cat > /root/mikrotik-script.rsc <<EOF
# ==================================================
# SKRIP OTOMATIS MIKROTIK -> NATVPS
# MIKROTIK KLIEN (Di belakang NAT / TANPA IP PUBLIK)
# Dibuat otomatis oleh Installer VPS
# Kompatibel: RouterOS v6 & v7
# ==================================================

# 1. Hapus Konfigurasi Lama (Opsional)
/interface gre remove [find name="ke-natvps"] 2>/dev/null
/ip ipsec peer remove [find name="peer-natvps"] 2>/dev/null
/ip ipsec policy remove [find comment="ke-natvps"] 2>/dev/null
/ip address remove [find comment="IP-TUNNEL-VPS"] 2>/dev/null

# 2. Buat Terowongan GRE -> KUNCI: remote=IP_VPS, local=0.0.0.0 (ambil otomatis IP WAN)
/interface gre add name=ke-natvps \
    remote-address=$IP_VPS \
    local-address=0.0.0.0 \
    keepalive=10,5 \
    ttl=255 \
    comment="TUNNEL KE NATVPS"

# 3. Pasang Alamat IP Terowongan
/ip address add address=${IP_TUNNEL_MIKROTIK}/${NETMASK_TUNNEL} \
    interface=ke-natvps \
    comment="IP-TUNNEL-VPS"

# 4. Pasang Rute Internet / Jaringan
# UNTUK INTERNET LEWAT VPS:
/ip route add dst-address=0.0.0.0/0 gateway=ke-natvps distance=1 comment="INTERNET LEWAT VPS"
# KHUSUS AKSES JARINGAN TERTENTU:
# /ip route add dst-address=192.168.100.0/24 gateway=ke-natvps

# 5. KONFIGURASI IPSEC (PENTING: AKTIFKAN NAT-T)
/ip ipsec profile add name=profil-natvps \
    auth-algorithm=sha256 \
    enc-algorithm=aes-256 \
    dh-group=modp2048 \
    nat-traversal=yes

/ip ipsec peer add name=peer-natvps \
    address=$IP_VPS \
    profile=profil-natvps \
    secret="$KUNCI_RAHASIA" \
    exchange-mode=ike2

/ip ipsec policy add src-address=10.8.0.0/24 dst-address=10.8.0.0/24 \
    protocol=gre action=encrypt \
    peer=peer-natvps \
    tunnel=yes \
    comment="ke-natvps"

# 6. Izinkan di Firewall (PENTING JANGAN DIHAPUS)
/ip firewall filter add chain=input protocol=gre action=accept comment="IZINKAN GRE"
/ip firewall filter add chain=input protocol=ipsec-esp action=accept comment="IZINKAN IPSEC ESP"
/ip firewall filter add chain=input dst-port=500,4500 protocol=udp action=accept comment="IZINKAN IPSEC NAT-T"

# ==================================================
echo "✅ SELESAI! Silakan cek koneksi: /ping $IP_TUNNEL_VPS"
echo "✅ Cek Status IPsec: /ip ipsec installed-sa print"
echo "✅ Jika ada tulisan 'state: established' -> BERHASIL!"
# ==================================================
EOF

# ==================================================
# BAGIAN 7: BUATKAN SKRIP AUTO START SAAT REBOOT
# ==================================================
echo -e "${YELLOW}Membuat layanan otomatis saat nyala...${NC}"

cat > /etc/systemd/system/gre-ipsec-vps.service <<EOF
[Unit]
Description=GRE + IPsec Server for Mikrotik Behind NAT
After=network.target

[Service]
ExecStart=/usr/local/bin/gre-start.sh
ExecStop=/usr/local/bin/gre-stop.sh
Type=oneshot
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

cat > /usr/local/bin/gre-start.sh <<EOF
#!/bin/bash
ip tunnel add gre1 mode gre local $IP_VPS remote 0.0.0.0 ttl 255
ip addr add ${IP_TUNNEL_VPS}/${NETMASK_TUNNEL} dev gre1
ip link set gre1 up
ip route add $JARINGAN_LOKAL via $IP_TUNNEL_MIKROTIK dev gre1
iptables -A FORWARD -i gre1 -j ACCEPT
iptables -t nat -A POSTROUTING -o $INTERFACE_WAN_VPS -j MASQUERADE
ip xfrm state add src $IP_VPS dst 0.0.0.0 proto esp spi 0xc0ffee01 reqid 1 mode tunnel auth sha256 $KUNCI_RAHASIA enc aes256 $KUNCI_RAHASIA
ip xfrm state add src 0.0.0.0 dst $IP_VPS proto esp spi 0xc0ffee02 reqid 1 mode tunnel auth sha256 $KUNCI_RAHASIA enc aes256 $KUNCI_RAHASIA
ip xfrm policy add src 10.8.0.0/24 dst 10.8.0.0/24 dir out tmpl src $IP_VPS dst 0.0.0.0 proto esp reqid 1 mode tunnel
ip xfrm policy add src 10.8.0.0/24 dst 10.8.0.0/24 dir in tmpl src 0.0.0.0 dst $IP_VPS proto esp reqid 1 mode tunnel
EOF

cat > /usr/local/bin/gre-stop.sh <<EOF
#!/bin/bash
ip tunnel del gre1
ip route del $JARINGAN_LOKAL via $IP_TUNNEL_MIKROTIK dev gre1 2>/dev/null
iptables -D FORWARD -i gre1 -j ACCEPT 2>/dev/null
iptables -t nat -D POSTROUTING -o $INTERFACE_WAN_VPS -j MASQUERADE 2>/dev/null
ip xfrm state flush
ip xfrm policy flush
EOF

chmod +x /usr/local/bin/gre-start.sh /usr/local/bin/gre-stop.sh
systemctl daemon-reload
systemctl enable gre-ipsec-vps.service
systemctl start gre-ipsec-vps.service

# ==================================================
# SELESAI
# ==================================================
echo -e "${GREEN}=================================================="
echo "✅ INSTALASI NATVPS SELESAI 100%!"
echo "✅ MODE: VPS SERVER - MIKROTIK KLIEN (TANPA IP PUBLIK)"
echo "=================================================="
echo -e "📂 File untuk MikroTik ada di: ${YELLOW}/root/mikrotik-script.rsc${NC}"
echo -e "👉 Ambil isi file tersebut lalu salin semua ke Terminal MikroTik."
echo -e "👉 Cek koneksi dari MikroTik: /ping ${IP_TUNNEL_VPS}"
echo -e "=================================================="

# Tampilkan isi file MikroTik agar bisa disalin langsung
echo -e "\n${YELLOW}--- ISI FILE MIKROTIK (SALIN SEMUA DI BAWAH INI) ---${NC}"
cat /root/mikrotik-script.rsc