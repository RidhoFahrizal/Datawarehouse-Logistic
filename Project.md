# Project Planning

## A. Tujuan Umum (Goal)

Membangun satu data warehouse sebagai single source of truth untuk mengintegrasikan seluruh data operasional pengiriman barang dari berbagai entitas dan hub logistik. Data warehouse ini bertujuan untuk memantau performa pengiriman (on-time delivery), efisiensi alokasi armada/kurir, serta profitabilitas operasional per wilayah demi mendukung pengambilan keputusan strategis oleh manajemen logistik.

## B. Pemangku Kepentingan, Sasaran, dan Harapan Pengguna

### 1. Chief Operating Officer (COO) / Vice President Logistics

- **Kepentingan Utama:** Menilai performa ketepatan waktu pengiriman secara nasional, mengidentifikasi bottleneck pengiriman per wilayah, serta efisiensi performa vendor/armada.
- **Kebutuhan Informasi:** Persentase ketepatan waktu pengiriman (On-Time Delivery Rate), rerata durasi pengiriman, serta tren keterlambatan per provinsi dan per layanan (Express vs Reguler).
- **Frekuensi Update Data:** Bulanan / Bulanan berulang.

### 2. Head of Branch & Hub Operations

- **Kepentingan Utama:** Memantau produktivitas dan kapasitas hub transit serta performa pengantaran oleh kurir.
- **Kebutuhan Informasi:** Jumlah paket terproses per hub, rasio paket gagal kirim (failed delivery), serta produktivitas kurir per wilayah operasional.
- **Frekuensi Update Data:** Harian atau Mingguan.

### 3. Finance & Commercial Manager

- **Kepentingan Utama:** Menganalisis pendapatan, total biaya operasional, serta margin keuntungan dari berbagai segmen layanan dan tipe pelanggan (B2B vs B2C).
- **Kebutuhan Informasi:** Total pendapatan ongkos kirim, total bobot ditagih, dan statistik klaim ganti rugi paket rusak/hilang.
- **Frekuensi Update Data:** Mingguan / Bulanan.

## Kepentingan Bisnis untuk OLAP

Berikut adalah representasi teks dari tabel pada gambar:

| Proses Bisnis | Stakeholder | Tujuan |
| --- | --- | --- |
| **Pemantauan Performa Pengiriman** | COO / VP Logistics | Mengukur rasio ketepatan waktu pengiriman (SLA) dan menganalisis area terjadinya delay. |
| **Operasional Hub & Kurir** | Head of Branch & Hub | Mengukur volume penanganan paket per hub serta keberhasilan pengantaran akhir oleh kurir. |
| **Analisis Pendapatan & Layanan** | Finance Manager | Mengukur total pendapatan dari ongkos kirim berdasarkan produk layanan dan segmen pelanggan. |

## Deskripsi Project

1. OLTP (Database harian / backend): digunakan untuk input data
2. Project memiliki 2 input: satu dari OLTP, satu dari CSV
3. CSV perlu transformasi nama kolom dan tipe data
4. Ke-2 data akan disatukan dan masuk ke staging untuk menjadi OLAP
5. OLAP harus memenuhi standar kebutuhan yang sudah ditulis di project planning
