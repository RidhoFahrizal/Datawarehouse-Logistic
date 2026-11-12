# Project Planning: Data Warehouse Logistik & Pengiriman Barang

Dokumen ini menyelaraskan kebutuhan bisnis dengan skema OLTP (`01_init_oltp.sql`), desain OLAP (`olap.md`), dan file CSV partner (`partner_shipments.csv`).

---

## A. Tujuan Umum (Goal)

Membangun data warehouse sebagai single source of truth untuk data operasional pengiriman barang. Data warehouse ini memantau performa ketepatan waktu pengiriman, produktivitas hub dan kurir, serta pendapatan dan klaim per layanan dan segmen pelanggan. Hasilnya dipakai manajemen logistik untuk pengambilan keputusan.

## B. Pemangku Kepentingan dan Kebutuhan

### 1. Chief Operating Officer (COO) / VP Logistics

- Kepentingan: menilai ketepatan waktu pengiriman nasional dan menemukan bottleneck per wilayah.
- Informasi yang dibutuhkan: On-Time Delivery Rate, rata-rata durasi pengiriman, tren keterlambatan per provinsi dan per layanan (Express, Regular, Cargo, Same Day).
- Frekuensi: bulanan.
- Data yang menjawab: `fact_shipment`.

### 2. Head of Branch & Hub Operations

- Kepentingan: memantau produktivitas hub dan kinerja pengantaran kurir.
- Informasi yang dibutuhkan: jumlah paket terproses per hub, utilisasi kapasitas hub, rasio gagal kirim, produktivitas kurir per wilayah, performa per jenis armada.
- Frekuensi: harian atau mingguan.
- Data yang menjawab: `fact_shipment_event`.

### 3. Finance & Commercial Manager

- Kepentingan: menganalisis pendapatan, biaya, margin, dan klaim per layanan dan tipe pelanggan (B2B vs B2C).
- Informasi yang dibutuhkan: total pendapatan ongkos kirim, total biaya estimasi, margin estimasi, total bobot kirim, jumlah dan nilai klaim, rasio klaim disetujui.
- Frekuensi: mingguan atau bulanan.
- Data yang menjawab: `fact_shipment` dan `fact_claim`.

## C. Kepentingan Bisnis untuk OLAP

| Proses Bisnis | Stakeholder | Fact Table | Grain |
| --- | --- | --- | --- |
| Pemantauan Performa Pengiriman | COO / VP Logistics | `fact_shipment` | 1 baris = 1 resi |
| Operasional Hub & Kurir | Head of Branch & Hub | `fact_shipment_event` | 1 baris = 1 event status log |
| Analisis Pendapatan, Biaya & Klaim | Finance & Commercial Manager | `fact_shipment` dan `fact_claim` | 1 resi dan 1 klaim |

## D. Sumber Data

### 1. PostgreSQL OLTP (schema `oltp`, bahasa Inggris)

| Tabel | Peran | Kunci |
| --- | --- | --- |
| `customer` | Master pelanggan, memuat `customer_type` B2B atau B2C | `customer_id` |
| `location` | Master kota, provinsi, kode pos | `location_id` |
| `service_type` | Master layanan, memuat `sla_days` dan `base_rate` | `service_type_id` |
| `hub` | Master hub, memuat `capacity_per_day` dan lokasi | `hub_id` |
| `courier` | Master kurir, memuat `vehicle_type` dan hub penugasan | `courier_id` |
| `shipment` | Transaksi resi | `receipt_number` |
| `shipment_status_log` | Log status per resi, memuat hub, kurir, status, alasan gagal | `status_log_id` |
| `claim` | Klaim ganti rugi, satu klaim per resi | `claim_id` |

Semua tabel memiliki `updated_at` dan `is_deleted`. Keduanya dipakai untuk load inkremental dan penanganan data terhapus.

### 2. File CSV `partner_shipments.csv` (header bahasa Indonesia, 15 kolom, 100 baris)

CSV berisi satu baris per resi partner dengan status akhir. CSV tidak memiliki hub, kurir, log event per status, dan klaim. Karena itu CSV hanya masuk ke `fact_shipment`.

Pemetaan kolom CSV ke kolom `shipment`:

| Kolom CSV | Kolom Target | Keterangan |
| --- | --- | --- |
| `NO_RESI_PARTNER` | `receipt_number` | Berprefix `PRT-`, tidak bentrok dengan resi OLTP |
| `ID_CUSTOMER` | `sender_customer_id` | Format sama dengan OLTP |
| `NAMA_SENDER` | `customer_name` | Dipakai hanya jika customer belum ada di OLTP |
| `SEGMEN_PELANGGAN` | `customer_type` | B2B atau B2C |
| `KODE_ORIGIN` | `origin_location_id` | Format `LOC-xxx-nn` |
| `KODE_DESTINASI` | `destination_location_id` | Format `LOC-xxx-nn` |
| `JENIS_PAKET` | `service_type_id` | Berisi kode layanan (`SRV-EXP`, `SRV-REG`, `SRV-CRG`, `SRV-SD`) |
| `BOBOT_KG` | `package_weight_kg` | Numeric |
| `TARIF_KIRIM_IDR` | `shipping_fee` | Integer ke NUMERIC(12,2) |
| `BIAYA_INTERNAL_IDR` | `estimated_cost` | Integer ke NUMERIC(12,2) |
| `TGL_TRANSAKSI` | `booking_timestamp` | Format `dd/MM/yyyy HH:mm:ss` |
| `TGL_ESTIMASI_TIBA` | `estimated_delivery_date` | Format `dd/MM/yyyy HH:mm:ss` |
| `STATUS_PENGIRIMAN` | `status_code` | DELIVERED, RETURNED, FAILED |
| `TGL_STATUS_AKHIR` | `final_status_timestamp` | Waktu status akhir, dasar `delivered_at` jika DELIVERED |
| `KETERANGAN_GAGAL` | `failure_reason` | Terisi untuk RETURNED dan FAILED |

Asumsi zona waktu: seluruh timestamp OLTP dan CSV berada pada zona WIB, tanpa konversi.

## E. Arsitektur dan Alur Kerja

```text
PostgreSQL OLTP (schema oltp) ----\
                                   +--> Apache Hop (.hpl / .hwf) --> Staging (stg) --> OLAP (olap) --> Metabase
File CSV partner -----------------/
```

| Tahap | Komponen | Fungsi |
| --- | --- | --- |
| 1 | PostgreSQL OLTP dan CSV | Sumber data |
| 2 | Apache Hop | Ekstraksi, pemetaan kolom CSV, pembersihan, orkestrasi |
| 3 | Schema `stg` | Salinan mentah OLTP, CSV bertipe data benar, dan gabungan shipment |
| 4 | Transformasi dimensional | Pembentukan dimensi dan fact dengan SQL di database |
| 5 | Schema `olap` | Star schema untuk analitik (galaxy dengan 3 fact) |
| 6 | Metabase | Dashboard dengan user read-only ke schema `olap` |

Database analitik dipisah dari database OLTP. Schema yang dipakai: `etl` (kontrol), `stg`, `olap`.

## F. Model OLAP

### Fact Table

| Fact | Grain | Sumber | Catatan |
| --- | --- | --- | --- |
| `fact_shipment` | 1 resi | `shipment` OLTP dan CSV, `shipment_status_log` | Accumulating snapshot. Baris diperbarui saat status berubah |
| `fact_shipment_event` | 1 event status log | `shipment_status_log` | Hanya dari OLTP |
| `fact_claim` | 1 klaim | `claim` | Hanya dari OLTP. `claim_id` sebagai degenerate dimension |

### Dimension Table

| Dimensi | Tipe | Sumber | Catatan |
| --- | --- | --- | --- |
| `dim_date` | Conformed, role-playing | Di-generate | Key `YYYYMMDD`. Baris unknown `date_sk = 0` |
| `dim_customer` | SCD 1 | `customer`, CSV | Customer dari CSV yang belum ada di OLTP ditambahkan sebagai inferred member |
| `dim_location` | SCD 1, role-playing | `location` | Dipakai sebagai origin dan destination |
| `dim_service_type` | SCD 2 | `service_type` | Fact menaut ke versi as-of `booking_timestamp` |
| `dim_hub` | SCD 1 | `hub` dan `location` | Denormalisasi kota dan provinsi. Baris unknown `hub_sk = -1` |
| `dim_courier` | SCD 2 | `courier` dan `hub` | Fact menaut ke versi as-of `log_timestamp`. Baris unknown `courier_sk = -1` |
| `dim_status` | SCD 1 | Enum `status_code` dan `claim_status` | Dipisah dengan `status_group`, memuat `failure_reason` |

### Kolom tambahan terhadap rancangan awal

1. `fact_shipment.delivered_at` (TIMESTAMP) dan `delivery_hours` agar ketepatan waktu dihitung dari timestamp penuh.
2. `fact_shipment.source_system` (`POSTGRES` atau `CSV`) untuk analisis kontribusi sumber.
3. `fact_shipment.actual_delivery_date_sk` memakai `0` jika belum terkirim, bukan NULL.

## G. Definisi KPI

| KPI | Stakeholder | Rumus |
| --- | --- | --- |
| On-Time Delivery Rate | COO | `1 - SUM(is_late) / SUM(is_delivered)` |
| Rata-rata durasi pengiriman (jam) | COO | `SUM(delivery_hours) / SUM(is_delivered)` |
| Tren keterlambatan | COO | `SUM(is_late)` per bulan, provinsi tujuan, layanan |
| Paket terproses per hub | Hub | `COUNT(DISTINCT shipment_sk)` per hub |
| Utilisasi hub | Hub | Paket terproses per hari dibagi `capacity_per_day` |
| Rasio gagal kirim | Hub | Resi dengan event FAILED dibagi resi dengan event OUT_FOR_DELIVERY |
| Produktivitas kurir | Hub | Resi dengan event DELIVERED per kurir per hari |
| Total pendapatan | Finance | `SUM(shipping_fee)` |
| Total biaya estimasi | Finance | `SUM(estimated_cost)` |
| Margin estimasi | Finance | `SUM(margin)` dengan `margin = shipping_fee - estimated_cost` |
| Total bobot kirim | Finance | `SUM(package_weight_kg)` |
| Jumlah dan nilai klaim | Finance | `SUM(claim_count)` dan `SUM(claim_amount)` |
| Rasio klaim disetujui | Finance | `SUM(is_approved) / SUM(claim_count)` |
| Rasio klaim terhadap pengiriman | Finance | `SUM(claim_count)` dibagi jumlah resi |

Catatan definisi:

1. Penyebut rasio ketepatan waktu dan durasi adalah `is_delivered`, bukan `delivery_count`.
2. `is_late` bernilai NULL jika resi belum terkirim.
3. `event_count` bukan jumlah resi unik. Gunakan `COUNT(DISTINCT shipment_sk)` untuk jumlah paket.

## H. Aturan Transformasi

### 1. Strategi pemuatan per tabel

| Tabel OLTP | Strategi | Dasar |
| --- | --- | --- |
| `customer`, `location`, `service_type`, `hub`, `courier` | Full load | Tabel master kecil |
| `shipment`, `shipment_status_log`, `claim` | Inkremental | Watermark `updated_at` pada `etl.watermark` |
| CSV | Full load ke staging | File kecil, lalu upsert ke fact |

Data terhapus ditangani lewat kolom `is_deleted` yang ikut terbawa oleh watermark `updated_at`.

### 2. Aturan turunan di `fact_shipment`

1. `delivered_at` = timestamp event DELIVERED terakhir per resi (OLTP) atau `TGL_STATUS_AKHIR` jika status CSV DELIVERED.
2. `delivery_hours` = selisih `delivered_at` dan `booking_timestamp` dalam jam. `delivery_days` = hasil pembulatan ke hari.
3. `is_late` = 1 jika `delivered_at > estimated_delivery_date`, 0 jika tidak, NULL jika belum terkirim.
4. `is_delivered`, `is_returned` = 1 jika ada status DELIVERED atau RETURNED.
5. `is_failed` = 1 jika pernah ada status FAILED dan belum DELIVERED.
6. `sla_days` diambil dari versi `dim_service_type` yang berlaku saat `booking_timestamp`.
7. Load ke fact memakai upsert dengan `ON CONFLICT (receipt_number) DO UPDATE`.

### 3. Aturan penggabungan OLTP dan CSV

1. Business key adalah `receipt_number`. Prefix `PRT-` memisahkan resi CSV dari resi OLTP.
2. Jika `receipt_number` yang sama muncul di kedua sumber, OLTP menjadi prioritas dan baris CSV dicatat ke `etl.reject`.
3. Resi duplikat di dalam CSV: ambil baris terakhir dan catat sisanya ke `etl.reject`.
4. Customer di CSV yang belum ada di OLTP dibuat sebagai inferred member di `dim_customer` dari `NAMA_SENDER` dan `SEGMEN_PELANGGAN`.
5. Location atau service di CSV yang tidak ada di OLTP ditolak ke `etl.reject`.
6. Baris CSV dengan `BOBOT_KG <= 0`, tarif negatif, atau biaya negatif ditolak, sesuai CHECK constraint OLTP.
7. Header CSV divalidasi sebelum diproses. Pipeline berhenti jika header tidak cocok.

### 4. Aturan dimensi

1. `dim_date` di-generate dari tanggal minimum sampai maksimum `booking_timestamp`, `log_timestamp`, dan `claim_date`, ditambah baris unknown `0`.
2. `shipment_status_log.hub_id` atau `courier_id` yang NULL diarahkan ke `hub_sk = -1` atau `courier_sk = -1`.
3. Versi pertama SCD 2 memakai `effective_date = 1900-01-01` agar lookup as-of untuk data historis selalu menemukan versi.
4. Lookup yang gagal diarahkan ke baris unknown dan dicatat ke `etl.run_log`, bukan menghasilkan NULL.

### 5. Standardisasi

1. Trim string, standarkan huruf besar untuk kode status.
2. Parse tanggal CSV dari `dd/MM/yyyy HH:mm:ss` ke TIMESTAMP.
3. PII `recipient_name`, `recipient_phone`, `recipient_address`, `phone_number`, dan `email` tidak dibawa ke OLAP.

## I. Fase Pengerjaan

| Fase | Pekerjaan | Hasil untuk stakeholder |
| --- | --- | --- |
| 1 | Buat schema `etl`, `stg`, `olap`. Buat `etl.watermark`, `etl.run_log`, `etl.reject`. Isi `dim_date` dan baris unknown. Konfigurasi koneksi Hop dengan variabel environment | Fondasi |
| 2 | Pipeline dimensi: `dim_location`, `dim_service_type`, `dim_customer`, `dim_hub`, `dim_courier`, `dim_status` | Dimensi siap dipakai semua fact |
| 3 | Pipeline CSV: validasi header, pemetaan kolom, parse tanggal, load ke `stg.csv_partner_shipments`. Buat `stg.shipment_unified` | Data CSV siap digabung |
| 4 | `fact_shipment` dari OLTP dan CSV | COO dan sebagian Finance |
| 5 | `fact_shipment_event` | Head of Hub |
| 6 | `fact_claim` | Finance (klaim) |
| 7 | Metabase: user read-only ke schema `olap`, model semantik, dashboard per stakeholder | Seluruh stakeholder |
| 8 | Workflow `.hwf` harian dengan lock agar run tidak tumpang tindih, notifikasi gagal, dan rerun idempoten | Operasional |

Struktur staging:

1. `stg.oltp_<nama_tabel>`: salinan 1:1 tabel OLTP ditambah `load_id` dan `loaded_at`.
2. `stg.csv_partner_shipments`: CSV dengan nama dan tipe kolom sudah dipetakan.
3. `stg.shipment_unified`: gabungan shipment OLTP dan CSV dengan kolom `source_system`.

Pembentukan dimensi dan fact dilakukan dengan SQL (`INSERT ... SELECT` dengan join ke dimensi). Apache Hop berperan sebagai orkestrator dan pemuat ke staging.

## J. Dashboard

| Dashboard | Stakeholder | Isi | Refresh |
| --- | --- | --- | --- |
| Performa Pengiriman | COO | OTD rate, durasi rata-rata, keterlambatan per provinsi dan layanan | Bulanan |
| Operasional Hub | Head of Hub | Paket per hub, utilisasi, rasio gagal kirim, produktivitas kurir, alasan gagal | Harian |
| Pendapatan dan Klaim | Finance | Revenue, biaya, margin estimasi, bobot, klaim, perbandingan B2B vs B2C, kontribusi OLTP vs CSV | Mingguan |

Job ETL berjalan harian. Frekuensi bulanan dan mingguan memakai data dari job yang sama.

## K. Data Quality Gates

| Titik Pemeriksaan | Kriteria |
| --- | --- |
| Header CSV | Jumlah, nama, dan urutan kolom sesuai spesifikasi 15 kolom |
| Nilai CSV | Semua `STATUS_PENGIRIMAN`, `KODE_ORIGIN`, `KODE_DESTINASI`, `JENIS_PAKET` dikenali, jika tidak masuk `etl.reject` |
| Post-Staging | Jumlah baris `stg` sama dengan sumber dikurangi baris di `etl.reject` |
| Post-OLAP | Tidak ada NULL pada kolom `*_sk` di semua fact |
| Rekonsiliasi per sumber | Jumlah baris `fact_shipment` per `source_system` sama dengan `stg.shipment_unified` dikurangi reject |
| Rekonsiliasi nilai | `SUM(shipping_fee)`, `SUM(estimated_cost)`, dan `SUM(claim_amount)` di OLAP sama dengan staging |
| Metabase | Angka dashboard sama dengan hasil SQL langsung ke schema `olap` |

## L. Batasan dan Keputusan Desain

1. CSV hanya memasok `fact_shipment`. Hub, kurir, dan klaim hanya berasal dari OLTP.
2. OLTP tidak memiliki bobot tertagih, sehingga "total bobot ditagih" diganti menjadi total bobot kirim (`package_weight_kg`).
3. `estimated_cost` adalah biaya estimasi, sehingga margin disebut margin estimasi.
4. OLTP tidak memiliki tabel pembayaran dan data vendor. Analisis armada dibatasi pada `vehicle_type` kurir.
5. Partisi tabel belum diterapkan. Estimasi 1.000 resi per hari menghasilkan sekitar 4 juta baris `fact_shipment_event` per tahun, yang cukup ditangani dengan index.
6. Index pada fact dibuat setelah load besar selesai, lalu jalankan `ANALYZE`.
7. Berkas `.hpl` dan `.hwf` disimpan di Git.