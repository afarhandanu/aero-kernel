# Aero Kernel Builder (MSM8937 / mi89x7)

Automated Kernel Build Pipeline untuk perangkat Xiaomi berbasis Snapdragon 435 / 430 / 425 (**MSM8937 / mi89x7**), ditenagai oleh **ZephyrSU**, **Baseband Guard**, **NoMount**, dan **Droidspaces**.

Builder ini dikelola oleh **kucingbalap1644** ([@afarhandanu](https://github.com/afarhandanu)), disederhanakan khusus untuk lini perangkat `mi89x7` dengan basis kernel Linux 4.19 dari tim **Mi-Thorium**.

---

## ⚡ Fitur Utama

| Fitur | Keterangan |
| :--- | :--- |
| **Root Solution** | **[ZephyrSU](https://github.com/afarhandanu/ZephyrSU)** (KernelSU fork berbasis SukiSU-Ultra dengan antarmuka manager modern) |
| **Kernel Release Name** | Custom release name: `4.19.xxx-Aero-Mi8937v2` |
| **Radio Protection** | **Baseband Guard (BBG)** via LSM hook untuk memantau & memproteksi IPC radio modem |
| **Mount Protection** | **NoMount** di level kernel untuk membatasi manipulasi mount namespace |
| **Linux Containers** | **Droidspaces** (Dukungan penuh container Linux / Docker / LXC / systemd chroot di Android) |
| **Filesystem** | **EROFS**, Ext4, F2FS, exFAT, NTFS |
| **Compiler & Optimasi** | **Neutron Clang** LLVM terbaru + **ThinLTO** (*Link-Time Optimization*) |

---

## 📱 Daftar Perangkat yang Didukung (MSM8937 / mi89x7)

Kernel ini dikemas dengan format **AnyKernel3** universal yang mendukung berbagai varian perangkat Xiaomi MSM8937/8917:

| Perangkat | Codename | Platform | Android Didukung |
| :--- | :--- | :--- | :--- |
| **Redmi 4X** | `santoni` | MSM8940 / MSM8937 | Android 11 ~ 17 |
| **Redmi 4A** | `rolex` | MSM8917 | Android 11 ~ 17 |
| **Redmi 5A** | `riva` | MSM8917 | Android 11 ~ 17 |
| **Redmi Note 5A Prime / Y1** | `ugg` | MSM8940 / MSM8937 | Android 11 ~ 17 |
| **Redmi Note 5A Lite / Y1 Lite** | `ugglite` | MSM8917 | Android 11 ~ 17 |
| **Redmi 4** | `prada` | MSM8937 | Android 11 ~ 17 |
| **Redmi 3S / 3X** | `land` | MSM8937 | Android 11 ~ 17 |

> **Catatan:** Jika Anda menggunakan *bootloader bypass exploit* pada perangkat MSM8937 tertentu, jangan lupa untuk mem-flash appender setelah memasang kernel.

---

## 🏷️ Custom Kernel Version String (`Aero-Mi8937v2`)

Secara default, kernel Mi-Thorium menghasilkan string versi berupa:
```
4.19.325-cip136-st20-Mi8937v2-gb22b61aa0b3c
```

Pada **Aero Kernel**, skrip patch (`scripts/patches/mi89x7-mithorium.sh`) secara otomatis:
1. Menghapus file `localversion*` bawaan (seperti `localversion-cip` dan `localversion-st`).
2. Mengganti `CONFIG_LOCALVERSION` menjadi:
   ```ini
   CONFIG_LOCALVERSION="-Aero-Mi8937v2"
   ```
3. Membuat file dummy `.scmversion` agar tidak menambahkan hash git kotor di akhir string.

Hasilnya, di menu **Tentang Ponsel -> Versi Kernel**, sistem akan menampilkan identitas bersih:
```
4.19.xxx-Aero-Mi8937v2
```

---

## 🛠️ Cara Build

### 1. Build Lokal di Komputer (Linux / WSL2)
Pastikan dependensi build telah terpasang:
```bash
sudo apt-get update && sudo apt-get install -y \
    bc build-essential bison flex zip p7zip-full libc6 curl libstdc++6 \
    git wget libssl-dev zstd lld python3 patchutils ccache libc6-dev unzip cpio
```

Jalankan perintah build:
```bash
chmod +x build.sh
./build.sh mi89x7 mithorium
```
Hasil file flashable zip akan berada di root folder:
`Aero-Kernel-mi89x7-msm8937-<Tanggal>.zip`

### 2. Build Otomatis via GitHub Actions
Repositori ini dilengkapi dengan workflow GitHub Actions siap pakai:
* **Workflow Dispatch (Manual Build):** Buka tab *Actions* -> Pilih *Build & Test Run* atau *Build & Release* -> Klik *Run workflow*.
* **Scheduled Release:** Otomatis berjalan setiap hari Minggu pukul 01:30 UTC dan mengunggah paket ZIP ke tab **Releases**.

---

## 📦 Pemasangan (Instalasi)

1. Unduh file zip rilis terbaru dari tab [Releases](https://github.com/afarhandanu/aero-kernel/releases).
2. Cadangkan (*backup*) partisi `boot` dan `dtbo` (jika ada) via TWRP / OrangeFox Recovery.
3. Flash file zip melalui Recovery (atau via `adb sideload <nama_file.zip>`).
4. Reboot ke sistem.
5. Unduh dan pasang aplikasi **[ZephyrSU Manager](https://github.com/afarhandanu/ZephyrSU/releases)** untuk mengelola izin akses root.

---

## ❤️ Penghargaan & Kredit (Credits)

Proyek ini tidak akan terwujud tanpa karya luar biasa dari komunitas open source:

* **[Riaru Moda](https://github.com/riarumoda)** ([perf_neon-builder](https://github.com/riarumoda/perf_neon-builder)) - Konsep arsitektur build automation, logika penggabungan defconfig, skrip AnyKernel3, dan patch kompatibilitas tombol hardware riva.
* **[Mi-Thorium Team](https://github.com/Mi-Thorium)** - Source code kernel Linux 4.19, device tree, dan techpack drivers untuk lini Xiaomi MSM8937.
* **[Danu / kucingbalap1644](https://github.com/afarhandanu)** ([ZephyrSU](https://github.com/afarhandanu/ZephyrSU)) - Solusi root berbasis kernel ZephyrSU.
* **[vc-teahouse](https://github.com/vc-teahouse)** - Pengembang Baseband Guard (BBG).
* **[maxsteeel](https://github.com/maxsteeel)** - Pengembang NoMount.
* **[ravindu644](https://github.com/ravindu644)** - Pengembang Droidspaces (Container di Android).
* **[osm0sis](https://github.com/osm0sis)** - Pengembang AnyKernel3 flashable installer.
* **[Neutron Toolchains Team](https://github.com/Neutron-Toolchains)** - Compiler Clang LLVM berkualitas tinggi yang dioptimalkan.
