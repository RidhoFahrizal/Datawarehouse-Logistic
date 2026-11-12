# Master Project Plan: End-to-End Data Warehouse & ETL Pipeline

**Tanggal Pembaruan:** 2026-11-12  
**Status:** Terkunci & Diselaraskan Resmi  
**Referensi:** `Project.md`, `data/01_init_oltp.sql`, `data/01_seed_oltp.sql`, `data/partner_shipments.csv`, `data/02_init_staging_dwh.sql`, `plan/03_decoupled_pipeline_architecture.md`

---

## 1. Spesifikasi Arsitektur & Alur Kerja (Fixed Pipeline)

Alur pemrosesan data dari hulu ke hilir ditetapkan secara berurutan:

| Tahap | Komponen / Layer | Implementasi Teknis |
|---|---|---|
| **1. Data Sources** | PostgreSQL OLTP & File CSV | Sumber data transaksional operasional 3NF (`01_seed_oltp.sql`) dan data mitra eksternal (`partner_shipments.csv` 100 baris, header bahasa Indonesia). |
| **2. ETL: Extract & Transform** | Apache Hop (`.hpl`) | Ekstraksi dual-source, translasi kolom Indonesia ke Inggris, parsing tanggal ke ISO Timestamp, dan penyatuan stream (*Append Streams*). |
| **3. Staging Area** | PostgreSQL (`schema: staging`) | Wadah penampung sementara (`staging.stg_unified_shipment`) berisi 200 baris hasil olahan dan derivasi metrik sebelum masuk ke OLAP. |
| **4. ETL: Validate & Load** | Apache Hop (`.hpl`) | Filter validasi kualitas data, lookup surrogate keys ke tabel dimensi, kalkulasi integer Date SK (`YYYYMMDD`), dan pemuatan massal. |
| **5. Data Warehouse / OLAP** | PostgreSQL (`schema: dwh`) | Penyimpanan dimensional Star Schema permanen (7 tabel dimensi conformed dan tabel fakta `fact_shipment` terpartisi kuartalan). |
| **6. BI & Reporting** | Metabase / Apache Superset | Lapisan visualisasi analitik terhubung langsung ke skema `dwh` untuk dashboard COO, Head of Hub, dan Finance Manager. |

---

## 2. Rencana Eksekusi Detail per Fase

### Fase 1: Persiapan Lingkungan & Skema Database
1. **Isolasi Database Target:** Menyiapkan instance PostgreSQL khusus untuk analitik agar beban query BI tidak mengganggu database operasional harian (OLTP).
2. **Pembuatan Skema Relasional:**
   - Menjalankan `data/01_init_oltp.sql` pada database sumber untuk skema transaksional 3NF.
   - Menjalankan `data/02_init_staging_dwh.sql` pada database target untuk skema `staging` dan `dwh`.
3. **Konfigurasi Metadata Apache Hop:** Mendaftarkan koneksi database terpusat pada *Metadata Perspective*:
   - `CONN_POSTGRES_OLTP`: Mengarah ke database operasional.
   - `CONN_POSTGRES_DWH`: Mengarah ke database target analitik.

### Fase 2: Pemuatan Master Data Dimensi (`pipelines/01_dimensions/`)
1. **Pemuatan Conformed Dimensions:** Ekstraksi data master dari OLTP ke tabel dimensi `dim_customer`, `dim_location`, `dim_service_type` (SCD Type 2), `dim_hub`, dan `dim_courier`.
2. **Penanganan Unknown Member (-1):** Menyisipkan nilai default surrogate key `-1` (`UNKNOWN / PARTNER FLEET`) pada dimensi hub dan kurir untuk mengakomodasi data transaksi mitra CSV.
3. **Pembangkitan Dimensi Tanggal:** Mengisi tabel `dim_date` dengan integer surrogate key berformat `YYYYMMDD`.

### Fase 3: ETL Ekstraksi, Transformasi, dan Unifikasi Staging (`pipelines/02_staging/`)
1. **Ekstraksi Dual-Source:**
   - **Stream CSV:** Menggunakan `CSV File Input` untuk membaca `data/partner_shipments.csv`.
   - **Stream OLTP:** Menggunakan `Table Input` untuk membaca `oltp.shipment` yang di-join dengan status akhir dari `oltp.shipment_status_log`.
2. **Standarisasi Metadata & Pembersihan:**
   - Mentranslasi 13 nama kolom bahasa Indonesia ke bahasa Inggris standar menggunakan transformasi `Select Values`.
   - Mengonversi format tanggal lokal `dd/MM/yyyy HH:mm:ss` ke ISO Timestamp standar serta casting angka desimal.
   - Menambahkan audit lineage: `source_type = 'CSV'` dan `source_type = 'OLTP'`.
3. **Penyatuan Stream & Derivasi Metrik:**
   - Menyatukan kedua aliran dengan `Append Streams` menjadi 200 baris seragam.
   - Menghitung metrik bisnis awal: `margin = shipping_fee - estimated_cost`, `delivery_days`, serta flagging status `is_late`, `is_delivered`, `is_returned`, dan `is_failed`.
4. **Pemuatan ke Staging:** Menyimpan hasil olahan ke tabel `staging.stg_unified_shipment` menggunakan opsi *Truncate table* sebelum setiap pemuatan batch baru.

### Fase 4: Validasi Kualitas Data & Pemuatan ke OLAP (`pipelines/03_facts/`)
1. **Penyaringan Data Quality (DQ Gate):** Memeriksa baris pada staging (bobot > 0, tarif >= 0, tanggal valid) menggunakan `Filter Rows`. Baris korup dialihkan ke error stream.
2. **Surrogate Key Lookup:** Mengganti seluruh natural key bisnis (`customer_id`, `location_id`, `service_type_id`) menjadi surrogate key (`_sk`) melalui `Database Lookup`.
3. **Pemuatan Tabel Fakta:** Memuat record transaksi final ke tabel partisi `dwh.fact_shipment` secara bulk insert.

### Fase 5: Orkestrasi Workflow & Integrasi Pelaporan Metabase
1. **Master Orchestrator Workflow (`workflows/main_daily_etl.hwf`):**
   - Mengatur sekuens: `Start` $\rightarrow$ `Check DB Connections` $\rightarrow$ `01_dimensions` $\rightarrow$ `02_staging` $\rightarrow$ `03_facts` $\rightarrow$ `Success`.
   - Menyediakan jalur error handling yang mencatat kegagalan ke berkas log operasional.
2. **Konfigurasi Metabase:**
   - Menghubungkan konektor Metabase hanya ke skema `dwh`.
   - Menyusun 3 dashboard utama:
     - **Dashboard COO:** On-Time Delivery (OTD) Rate, SLA compliance, bottleneck delay per wilayah.
     - **Dashboard Hub Operations:** Volume penanganan paket per hub, delivery failure rate kurir.
     - **Dashboard Finance:** Pendapatan ongkir, margin operasional, dan statistik klaim paket.

---

## 3. Matriks Kontrol Kualitas (Data Quality Gates)

| Titik Pemeriksaan | Indikator Keberhasilan | Penanganan Anomali |
|---|---|---|
| **Post-CSV Mapping** | Seluruh nama kolom berbahasa Inggris dan tipe data numerik/tanggal telah sesuai dengan skema DWH. | Pipeline dihentikan jika parsing tipe data mengalami kegagalan fatal. |
| **Post-Staging Load** | Jumlah baris di `staging.stg_unified_shipment` tepat 200 baris (100 dari CSV + 100 dari OLTP). | Alert dikirim jika total baris tidak mencapai 200 record. |
| **Post-OLAP Load** | Tidak ada nilai `NULL` pada kolom *Surrogate Key* di tabel fakta (`dwh.fact_shipment`). | Baris anomali ditolak ke tabel penampung log reject. |
| **Metabase Reconciliation** | Nilai agregasi total revenue dan margin pada dasbor Metabase 100% cocok dengan query SQL langsung di database. | Audit rekonsiliasi berkala menggunakan skrip testing. |

---

## 4. Diagram Arsitektur Aliran Data End-to-End

```text
+-----------------------------------------------------------------------------+
|                        DATA WAREHOUSE ARCHITECTURE                          |
+-----------------------------------------------------------------------------+

  [ PostgreSQL (OLTP) ] ────┐
  (8 Tabel 3NF, EN Schema)   │
                             ├─► [ Apache Hop (.hpl) ] ────► [ ETL Transform ]
  [     File CSV      ] ────┘    (Extract & Map Schema)      (Rename, Cast, Merge)
  (100 Baris, ID Header)                                              │
                                                                      ▼
                                                              [ STAGING AREA ]
                                                              (staging.stg_unified_shipment)
                                                                      │
                                                                      ▼
                                                              [ ETL Validate & Load ]
                                                              (SK Lookup & DQ Check)
                                                                      │
                                                                      ▼
  [  Report / Metabase ] ◄─── [   PostgreSQL DWH   ] ◄──────── [ OLAP STAR SCHEMA ]
  (COO, Hub, Finance)         (schema: dwh)                    (dim_* & fact_shipment)

+-----------------------------------------------------------------------------+
```
