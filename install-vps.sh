#!/bin/bash
# ==================================================
# INSTALLER OTOMATIS GRE + IPsec - NATVPS PORT FORWARDING
# MIKROTIK KLIEN (Di belakang NAT / TANPA IP PUBLIK)
# KONDISI: NATVPS pakai Domain / IP Luar + Port Luar
# Kompatibel: Semua RouterOS v6 & v7
# Dibuat oleh: Hendri (Disempurnakan)
# ==================================================

# WARNA TEKS
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

clear
echo -e "${GREEN}=================================================="
echo "  INSTALLASI NATVPS -> PORT FORWARDING MODE"
echo "  -> MIKROTIK KLIEN (TANPA IP PUBLIK)"
echo "==================================================${NC}"

# ==================================================
# BAGIAN INPUT DATA DARI PENGGUNA
# ==================================================
echo -e "${YELLOW}Masukkan data sesuai PANEL NATVPS kamu:${NC}"
read -p "👉 IP / DOMAIN PUBLIK NATVPS LUAR     : " DOMAIN_LUAR  # Contoh: 203.0.123.45 atau vps-anda.xyz
read -p "👉 PORT UDP LUAR (Mapping)            : " PORT_LUAR    # Contoh: 35000, 45000 (Wajib UDP)
read -p "👉 PORT UDP DALAM (Asli di VPS)       : " PORT_DALAM   # Standar IPsec: 500 & 4500
read -p "👉 JARINGAN LOKAL MIKROTIK            : " JARINGAN_LOKAL # Contoh: 172.16.0.0/16
read -p "👉 KATA SANDI IPSEC (Kuat)            : " KUNCI_RAHASIA

# Validasi input
if [ -z "$DOMAIN_LUAR" ] || [ -z "$PORT_LUAR" ] || [ -z "$PORT_DALAM" ] || [ -z "$JARINGAN_LOKAL" ] || [ -z "$KUNCI_RAHASIA" ]; then
    echo -e "${RED}❌ ERROR: Semua isian wajib diisi!${NC}"
    exit 1
fi

# Variabel Tetap
IP_TUNNEL_VPS="10.8.0.1"
IP_TUNNEL_MIKROTIK="10.8.0.2"
NETMASK_TUNNEL="30"
INTERFACE_WAN_VPS="venet0" # Kartu jaringan bawaan NATVPS
IP_VPS_INTERNAL=$(hostname -I | awk '{print $1}') # Ambil IP Internal VPS

echo -e "\n${GREEN}>>> Ringkasan Konfigurasi:${NC}"
echo -e "Domain/IP Luar : $DOMAIN_LUAR"
echo -e "Port Mapping   : $PORT_LUAR -> $PORT_DALAM"
echo -e "IP Internal VPS: $IP_VPS_INTERNAL"

echo -e "\n${GREEN}>>> Memulai instalasi...${NC}"

# ==================================================
# BAGIAN 1: BERSIHKAN KONFIGURASI LAMA
# ==================================================
echo -e "${YELLOW}Membersihkan sisa konfigurasi lama...${NC}"
systemctl stop gre-ipsec-vps.service 2>/dev/null
systemctl disable gre-ipsec-vps.service 2>/dev/null
rm -rf /etc/tinc /usr/local/bin/wireguard-go /etc/wireguard

# Hapus antarmuka & aturan lama
ip tunnel del gre1 2>/dev/null
ip xfrm state flush
ip xfrm policy flush
iptables -F
iptables -t nat -F
iptables -X

# ==================================================
# BAGIAN 2: INSTALASI PAKET DASAR
# ==================================================
echo -e "${YELLOW}Menginstal paket pendukung...${NC}"
apt update -y
apt install -y iproute2 iptables iptables-persistent

# Aktifkan modul jaringan (Wajib di NATVPS/OpenVZ)
modprobe ip_gre 2>/dev/null || true
modprobe xfrm4_tunnel 2>/dev/null || true
modprobe af_key 2>/dev/null || true

# ==================================================
# BAGIAN 3: KONFIGURASI TEROWONGAN GRE
# ==================================================
echo -e "${YELLOW}Membuat Terowongan GRE...${NC}"

# Di NATVPS, kita ikat ke IP INTERNAL VPS, karena IP Luar milik penyedia
ip tunnel add gre1 mode gre local $IP_VPS_INTERNAL remote 0.0.0.0 ttl 255

# Pasang IP Address Terowongan
ip addr add ${IP_TUNNEL_VPS}/${NETMASK_TUNNEL} dev gre1

# Nyalakan Antarmuka
ip link set gre1 up

# Tambah Rute ke Jaringan Lokal MikroTik
ip route add $JARINGAN_LOKAL via $IP_TUNNEL_MIKROTIK dev gre1

# ==================================================
# BAGIAN 4: KONFIGURASI NAT & PORT FORWARDING (KUNCI UTAMA)
# ==================================================
echo -e "${YELLOW}Mengatur Aturan NAT & Penerusan Port...${NC}"

# Izinkan paket lewat
echo 1 > /proc/sys/net/ipv4/ip_forward
echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
sysctl -p > /dev/null

# --- ATURAN NAT PAKET DATA ---
# 1. Forward Port IPsec (500 & 4500) dari Port Luar ke Dalam
#    Contoh: 35000 -> 500  |  35001 -> 4500
iptables -t nat -A PREROUTING -i $INTERFACE_WAN_VPS -p udp --dport $PORT_LUAR -j REDIRECT --to-port $PORT_DALAM
iptables -t nat -A PREROUTING -i $INTERFACE_WAN_VPS -p udp --dport 4500 -j REDIRECT --to-port 4500

# 2. Aturan Utama NAT Internet (Agar MikroTik bisa akses internet lewat VPS)
iptables -A FORWARD -i gre1 -j ACCEPT
iptables -t nat -A POSTROUTING -o $INTERFACE_WAN_VPS -j MASQUERADE

# 3. Izinkan Trafik GRE & UDP di Firewall
iptables -A INPUT -p gre -j ACCEPT
iptables -A INPUT -p udp --dport $PORT_DALAM -j ACCEPT
iptables -A INPUT -p udp --dport 4500 -j ACCEPT
iptables -A INPUT -p udp --dport 500 -j ACCEPT

# ==================================================
# BAGIAN 5: KONFIGURASI IPsec (Sesuai Port NATVPS)
# ==================================================
echo -e "${YELLOW}Mengatur Enkripsi IPsec...${NC}"

# KITA GUNAKAN IP INTERNAL VPS di dalam konfigurasi, tapi MikroTik akses pakai DOMAIN+PORT
ip xfrm state add src $IP_VPS_INTERNAL dst 0.0.0.0 proto esp spi 0xc0ffee01 reqid 1 mode tunnel auth sha256 $KUNCI_RAHASIA enc aes256 $KUNCI_RAHASIA
ip xfrm state add src 0.0.0.0 dst $IP_VPS_INTERNAL proto esp spi 0xc0ffee02 reqid 1 mode tunnel auth sha256 $KUNCI_RAHASIA enc aes256 $KUNCI_RAHASIA

# Kebijakan: Izinkan semua koneksi ke jaringan terowongan
ip xfrm policy add src 10.8.0.0/24 dst 10.8.0.0/24 dir out tmpl src $IP_VPS_INTERNAL dst 0.0.0.0 proto esp reqid 1 mode tunnel
ip xfrm policy add src 10.8.0.0/24 dst 10.8.0.0/24 dir in tmpl src 0.0.0.0 dst $IP_VPS_INTERNAL proto esp reqid 1 mode tunnel

# ==================================================
# BAGIAN 6: BUATKAN FILE SCRIPT UNTUK MIKROTIK
# ==================================================
echo -e "${GREEN}Membuatkan file skrip MIKROTIK: /root/mikrotik-script.rsc${NC}"

cat > /root/mikrotik-script.rsc <<EOF
# ==================================================
# SKRIP OTOMATIS MIKROTIK -> NATVPS (PORT FORWARDING)
# MIKROTIK KLIEN - TANPA IP PUBLIK
# Dibuat otomatis oleh Installer VPS
# ==================================================

# 1. Hapus Konfigurasi Lama
/interface gre remove [find name="ke-natvps"] 2>/dev/null
/ip ipsec peer remove [find name="peer-natvps"] 2>/dev/null
/ip ipsec policy remove [find comment="ke-natvps"] 2>/dev/null
/ip address remove [find comment="IP-TUNNEL-VPS"] 2>/dev/null
/ip firewall nat remove [find comment="NAT-IPSEC-VPS"] 2>/dev/null

# 2. BUAT ATURAN NAT KHUSUS (PENTING UNTUK PORT FORWARDING)
# Karena NATVPS pakai Port Luar berbeda, kita rubah paket tujuan ke Port yang benar
/ip firewall nat add chain=dstnat action=change-dst-port protocol=udp dst-port=500 to-ports=$PORT_LUAR comment="UBAH PORT KE NATVPS"
/ip firewall nat add chain=dstnat action=change-dst-port protocol=udp dst-port=4500 to-ports=4500 comment="UBAH PORT NAT-T"
/ip firewall nat add chain=srcnat action=change-src-port protocol=udp src-port=$PORT_LUAR to-ports=500 comment="UBAH BALIK PORT"

# 3. Buat Terowongan GRE
/interface gre add name=ke-natvps \\
    remote-address=$DOMAIN_LUAR \\
    local-address=0.0.0.0 \\
    keepalive=10,5 \\
    ttl=255 \\
    comment="TUNNEL KE NATVPS"

# 4. Pasang Alamat IP Terowongan
/ip address add address=${IP_TUNNEL_MIKROTIK}/${NETMASK_TUNNEL} \\
    interface=ke-natvps \\
    comment="IP-TUNNEL-VPS"

# 5. Pasang Rute
# Internet Lewat VPS
/ip route add dst-address=0.0.0.0/0 gateway=ke-natvps distance=1 comment="INTERNET LEWAT VPS"
# Akses Jaringan Lokal VPS (jika ada)
# /ip route add dst-address=10.10.0.0/24 gateway=ke-natvps

# 6. KONFIGURASI IPSEC (Disesuaikan NATVPS)
/ip ipsec profile add name=profil-natvps \\
    auth-algorithm=sha256 \\
    enc-algorithm=aes-256 \\
    dh-group=modp2048 \\
    nat-traversal=yes \\
    dpd-interval=10s dpd-timeout=30s

/ip ipsec peer add name=peer-natvps \\
    address=$DOMAIN_LUAR \\
    port=$PORT_LUAR \\
    profile=profil-natvps \\
    secret="$KUNCI_RAHASIA" \\
    exchange-mode=ike2

/ip ipsec policy add src-address=10.8.0.0/24 dst-address=10.8.0.0/24 \\
    protocol=gre action=encrypt \\
    peer=peer-natvps \\
    tunnel=yes \\
    comment="ke-natvps"

# 7. Izinkan di Firewall
/ip firewall filter add chain=input protocol=gre action=accept comment="IZINKAN GRE"
/ip firewall filter add chain=input protocol=ipsec-esp action=accept comment="IZINKAN IPSEC ESP"
/ip firewall filter add chain=input dst-port=500,4500,$PORT_LUAR protocol=udp action=accept comment="IZINKAN UDP IPSEC"

# ==================================================
echo "✅ SELESAI!"
echo "👉 Cek Koneksi: /ping $IP_TUNNEL_VPS"
echo "👉 Cek Status: /ip ipsec installed-sa print"
echo "👉 Pastikan Status = established"
# ==================================================
EOF

# ==================================================
# BAGIAN 7: BUATKAN SKRIP AUTO START SAAT REBOOT
# ==================================================
echo -e "${YELLOW}Membuat layanan otomatis saat nyala...${NC}"

cat > /etc/systemd/system/gre-ipsec-vps.service <<EOF
[Unit]
Description=GRE + IPsec - NATVPS Port Forwarding Mode
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
# Konfigurasi Jaringan
ip tunnel add gre1 mode gre local $IP_VPS_INTERNAL remote 0.0.0.0 ttl 255
ip addr add ${IP_TUNNEL_VPS}/${NETMASK_TUNNEL} dev gre1
ip link set gre1 up
ip route add $JARINGAN_LOKAL via $IP_TUNNEL_MIKROTIK dev gre1

# Aturan Firewall & NAT
iptables -t nat -A PREROUTING -i $INTERFACE_WAN_VPS -p udp --dport $PORT_LUAR -j REDIRECT --to-port $PORT_DALAM
iptables -t nat -A PREROUTING -i $INTERFACE_WAN_VPS -p udp --dport 4500 -j REDIRECT --to-port 4500
iptables -A FORWARD -i gre1 -j ACCEPT
iptables -t nat -A POSTROUTING -o $INTERFACE_WAN_VPS -j MASQUERADE
iptables -A INPUT -p gre -j ACCEPT
iptables -A INPUT -p udp --dport $PORT_DALAM -j ACCEPT
iptables -A INPUT -p udp --dport 4500 -j ACCEPT

# Konfigurasi Enkripsi
ip xfrm state add src $IP_VPS_INTERNAL dst 0.0.0.0 proto esp spi 0xc0ffee01 reqid 1 mode tunnel auth sha256 $KUNCI_RAHASIA enc aes256 $KUNCI_RAHASIA
ip xfrm state add src 0.0.0.0 dst $IP_VPS_INTERNAL proto esp spi 0xc0ffee02 reqid 1 mode tunnel auth sha256 $KUNCI_RAHASIA enc aes256 $KUNCI_RAHASIA
ip xfrm policy add src 10.8.0.0/24 dst 10.8.0.0/24 dir out tmpl src $IP_VPS_INTERNAL dst 0.0.0.0 proto esp reqid 1 mode tunnel
ip xfrm policy add src 10.8.0.0/24 dst 10.8.0.0/24 dir in tmpl src 0.0.0.0 dst $IP_VPS_INTERNAL proto esp reqid 1 mode tunnel
EOF

cat > /usr/local/bin/gre-stop.sh <<EOF
#!/bin/bash
ip tunnel del gre1 2>/dev/null
ip xfrm state flush
ip xfrm policy flush
iptables -t nat -D PREROUTING -i $INTERFACE_WAN_VPS -p udp --dport $PORT_LUAR -j REDIRECT --to-port $PORT_DALAM 2>/dev/null
iptables -t nat -D PREROUTING -i $INTERFACE_WAN_VPS -p udp --dport 4500 -j REDIRECT --to-port 4500 2>/dev/null
iptables -D FORWARD -i gre1 -j ACCEPT 2>/dev/null
iptables -t nat -D POSTROUTING -o $INTERFACE_WAN_VPS -j MASQUERADE 2>/dev/null
EOF

# Berikan izin akses eksekusi
chmod +x /usr/local/bin/gre-start.sh
chmod +x /usr/local/bin/gre-stop.sh

# Aktifkan dan jalankan layanan
systemctl daemon-reload
systemctl enable gre-ipsec-vps.service
systemctl start gre-ipsec-vps.service

echo -e "\n${GREEN}=================================================="
echo -e " ✅ INSTALASI SELESAI & BERHASIL!"
echo -e "==================================================${NC}"
echo -e "${YELLOW}Langkah Selanjutnya:${NC}"
echo -e "Salin teks konfigurasi untuk MikroTik kamu dengan mengetik perintah:"
echo -e "👉  ${GREEN}cat /root/mikrotik-script.rsc${NC}"
echo -e "Lalu paste hasilnya ke Terminal Winbox MikroTik kamu."