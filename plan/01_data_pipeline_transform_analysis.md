# Analisis Transformasi Data Pipeline & Integrasi Dual-Source (CSV & OLTP)

**Tanggal:** 2026-11-12  
**Status:** Direvisi (perbaikan analisis Gemini)  
**Referensi:** `Project.md`, `oltp.md`, `olap.md`, `data/partner_shipments.csv`, `data/01_seed_oltp.sql`

## 1. Ringkasan Sumber Data

1. **Source 1: `data/partner_shipments.csv` (100 baris)**
   - File CSV eksternal dari mitra pihak ketiga dengan header bahasa Indonesia (*all-caps* snake_case).
   - Format tanggal: `DD/MM/YYYY HH:mm:ss`.
   - Format numerik: Teks (string integer & decimal).
   - Bentuk data: Denormalisasi parsial (terdapat data customer, layanan, tarif, status akhir, tanpa detail event log per hub).
   - Natural key resi menggunakan prefix `PRT-` (beda dengan OLTP yang menggunakan `RESI-`).
   - Tidak memiliki kolom `hub_id` dan `courier_id`.

2. **Source 2: `data/01_seed_oltp.sql` / Database OLTP PostgreSQL**
   - Skema transaksional normal (3NF) terdiri atas 8 tabel: `customer`, `location`, `service_type`, `hub`, `courier`, `shipment`, `shipment_status_log`, `claim`.
   - Format tanggal: ISO `YYYY-MM-DD HH:mm:ss`.
   - Lifecycle tracking: Tersimpan granular di tabel `shipment_status_log` (multiple event per resi: PICKUP, IN_TRANSIT, OUT_FOR_DELIVERY, DELIVERED, FAILED, RETURNED).
   - Setiap tabel memiliki kolom audit standar: `created_at`, `updated_at`, `is_deleted`.

## 2. Pemetaan Standarisasi Kolom (Bahasa Indonesia CSV -> Bahasa Inggris DWH)

| Nama Kolom CSV Asli | Tipe Data Asal | Standarisasi Bahasa Inggris | Tipe Data Target | Penjelasan & Aturan |
|---|---|---|---|---|
| `NO_RESI_PARTNER` | VARCHAR | `receipt_number` | VARCHAR(50) | Natural Key resi pengiriman partner (prefix `PRT-`, beda dengan OLTP `RESI-`) |
| `ID_CUSTOMER` | VARCHAR | `sender_customer_id` | VARCHAR(32) | Foreign Key ke `CUSTOMER.customer_id` |
| `NAMA_SENDER` | VARCHAR | `sender_name` | VARCHAR(150) | Nama pengirim (cocok dengan `CUSTOMER.customer_name`) |
| `SEGMEN_PELANGGAN` | VARCHAR | `customer_type` | VARCHAR(10) | Tipe segmen: B2B atau B2C |
| `KODE_ORIGIN` | VARCHAR | `origin_location_id` | VARCHAR(32) | ID lokasi asal pengiriman (FK ke `LOCATION`) |
| `KODE_DESTINASI` | VARCHAR | `destination_location_id` | VARCHAR(32) | ID lokasi tujuan pengiriman (FK ke `LOCATION`) |
| `JENIS_PAKET` | VARCHAR | `service_type_id` | VARCHAR(32) | Kode layanan pengiriman (SRV-EXP, SRV-REG, SRV-SD, SRV-CRG) |
| `BOBOT_KG` | VARCHAR | `package_weight_kg` | NUMERIC(8,2) | Bobot paket ditagih |
| `TARIF_KIRIM_IDR` | VARCHAR | `shipping_fee` | NUMERIC(12,2) | Tarif tagihan ongkos kirim (Revenue) |
| `BIAYA_INTERNAL_IDR` | VARCHAR | `estimated_cost` | NUMERIC(12,2) | Estimasi beban biaya operasional (Cost) |
| `TGL_TRANSAKSI` | VARCHAR | `booking_timestamp` | TIMESTAMP | Waktu transaksi booking paket |
| `TGL_ESTIMASI_TIBA` | VARCHAR | `estimated_delivery_date` | TIMESTAMP | Janji estimasi waktu pengantaran (SLA) |
| `STATUS_PENGIRIMAN` | VARCHAR | `final_status_code` | VARCHAR(30) | Status akhir (DELIVERED, RETURNED, FAILED, IN_TRANSIT) |
| `TGL_STATUS_AKHIR` | VARCHAR | `last_status_timestamp` | TIMESTAMP | Waktu status terakhir tercatat (bukan selalu actual_delivery_date; hanya DELIVERED yang memiliki tanggal pengiriman aktual) |
| `KETERANGAN_GAGAL` | VARCHAR | `failure_reason` | VARCHAR(100) | Alasan kendala pengiriman jika gagal/retur |

**Catatan:** `TGL_STATUS_AKHIR` tidak boleh dipetakan langsung ke `actual_delivery_date` karena untuk status `RETURNED`, `FAILED`, atau `IN_TRANSIT` tidak ada tanggal pengiriman aktual.

## 3. Inventaris & Taksonomi Transformasi ETL (Total 32 Transform)

Sesuai constraint evaluasi kualitas pipeline Apache Hop dan desain OLAP di `olap.md`, seluruh proses dibagi menjadi 11 lapisan utama:

1. **Extraction & Landing (2 Transform):**
   - CSV File Input (`partner_shipments.csv`)
   - OLTP Table Input (`shipment`, `shipment_status_log`, `customer`, `location`, `service_type`, `hub`, `courier`)

2. **Column Renaming & Metadata Alignment (1 Transform):**
   - Select Values: Mapping 15 kolom bahasa Indonesia ke standar bahasa Inggris DWH

3. **Type Casting & Date Parsing (2 Transform):**
   - Date/Time Formatter: `DD/MM/YYYY HH:mm:ss` → `YYYY-MM-DD HH:mm:ss` (ISO Timestamp)
   - Select Values (Cast): String → NUMERIC (`package_weight_kg`, `shipping_fee`, `estimated_cost`); String → TIMESTAMP (`booking_timestamp`, `estimated_delivery_date`, `last_status_timestamp`)

4. **Data Cleaning & Null Handling (3 Transform):**
   - Trim/Uppercase text pada kolom kode (`ID_CUSTOMER`, `KODE_ORIGIN`, `KODE_DESTINASI`, `JENIS_PAKET`)
   - Default value replacement: `hub_id = -1`, `courier_id = -1` (Unknown Member; CSV tidak memiliki kolom ini)
   - Row validation check: validasi apakah `ID_CUSTOMER`, `KODE_ORIGIN`, `KODE_DESTINASI`, `JENIS_PAKET` ada di master OLTP

5. **Metadata & Lineage Enrichment (2 Transform):**
   - Source system flag tagging (`source_type = 'CSV' | 'OLTP'`)
   - Ingestion timestamp audit (`ingested_at`, `batch_id`)

6. **OLTP Shipment Load Preparation (2 Transform):**
   - Add Constants: `created_at = now()`, `updated_at = now()`, `is_deleted = false` (wajib per `oltp.md`)
   - Filter Rows: pisahkan baris valid (lolos FK check) vs invalid (reject ke log error)

7. **Stream Integration (1 Transform):**
   - Append / Sorted Merge Stream data CSV + data OLTP ke Unified Shipment staging

8. **Business Logic & KPI Derivations (7 Transform):**
   - Margin calculation: `shipping_fee - estimated_cost`
   - Delivery duration: `last_status_timestamp - booking_timestamp` (hanya jika `final_status_code = 'DELIVERED'`, else NULL)
   - SLA violation check: `last_status_timestamp > estimated_delivery_date` → `is_late`
   - Binary KPI flag: `is_delivered` (`STATUS_PENGIRIMAN = 'DELIVERED'`)
   - Binary KPI flag: `is_returned` (`STATUS_PENGIRIMAN = 'RETURNED'`)
   - Binary KPI flag: `is_failed` (`STATUS_PENGIRIMAN = 'FAILED'` dan belum delivered)
   - Add delivery counter unit: `delivery_count = 1`

9. **Generate DIM_DATE (1 Transform):**
   - Generate baris dimensi tanggal dari `MIN(booking_timestamp, last_status_timestamp)` sampai `MAX(...)` dengan format `date_sk = YYYYMMDD`

10. **Dimensional Surrogate Key Lookups (8 Transform):**
    - Lookup Customer SK (`dwh.dim_customer`) via `sender_customer_id`
    - Lookup Origin Location SK (`dwh.dim_location`) via `origin_location_id` (role-playing)
    - Lookup Destination Location SK (`dwh.dim_location`) via `destination_location_id` (role-playing)
    - Lookup Service Type SK SCD2 (`dwh.dim_service_type`) via `service_type_id` as-of `booking_timestamp`
    - Lookup Hub SK (`dwh.dim_hub`) via `hub_id`; fallback `-1` (Unknown Member)
    - Lookup Courier SK (`dwh.dim_courier`) via `courier_id`; fallback `-1` (Unknown Member)
    - Lookup Status SK (`dwh.dim_status`) via `final_status_code` + `status_group = 'SHIPMENT'`
    - Lookup Date SK (`dwh.dim_date`) untuk booking, estimated, dan actual date

11. **Target Sinks & Loading (5 Transform):**
    - Table Output → OLTP `shipment` (termasuk kolom audit `created_at`, `updated_at`, `is_deleted`)
    - Table Output → OLTP `shipment_status_log` (satu baris per resi dengan `status_code` dari `final_status_code`, `log_timestamp` dari `last_status_timestamp`, `failure_reason`, `hub_id = -1`, `courier_id = -1`)
    - Table Output → Staging `staging.stg_unified_shipment`
    - Table Output → OLAP `dwh.fact_shipment` (partisi per tahun booking_date)
    - Table Output → OLAP `dwh.fact_shipment_event` (partisi per tahun log_date)

**Total transform: 32 transform** (semakin banyak transform yang valid dan terstruktur, semakin bagus untuk lineage data dan debugging).

## 4. Rekomendasi Teknis Apache Hop

1. **Gunakan Apache Hop Pipeline (`.hpl`) modular terpisah:**
   - `sub_load_partner_csv.hpl` (Ingestion CSV + transformasi kolom)
   - `sub_load_oltp_master.hpl` (Load master data OLTP jika diperlukan)
   - `sub_load_oltp_transaction.hpl` (Ingestion ke OLTP `shipment` + `shipment_status_log` dengan kolom audit)
   - `main_transform_unified_shipment.hpl` (Pembersihan, integrasi, derivasi KPI, dan lookup SK)
   - `load_fact_shipment.hpl` (Lookup dimensi dan pemuatan OLAP fact table)
   - `generate_dim_date.hpl` (Generate dimensi tanggal)

2. **Workflow Apache Hop (`.hwf`) sebagai orkestrator end-to-end:**
   - Inisialisasi tabel (create if not exists)
   - Truncate staging sebelum load
   - Eksekusi pipeline secara berurutan
   - Penanganan kegagalan (*error reject flow*) untuk baris yang gagal FK validation

3. **Penting untuk OLAP:**
   - Jangan mengagregasi `shipment_status_log` menjadi 1 baris per resi. Grain `fact_shipment_event` adalah 1 baris = 1 event status log.
   - Gunakan Unknown Member `-1` untuk `hub_sk` dan `courier_sk` karena CSV tidak memiliki kolom hub/courier.
   - `DIM_SERVICE_TYPE` dan `DIM_COURIER` adalah SCD Type 2; lookup harus match berdasarkan tanggal efektif (as-of `booking_timestamp` atau event date).

## 5. Insight Baru (dicatat di `plan/`)

- CSV partner menambahkan 100 resi dengan layanan Cargo (SRV-CRG) dan SameDay (SRV-SD) yang memperkaya analisis margin & OTD per segmen pelanggan untuk Finance Manager.
- Prefix resi berbeda (`PRT-` vs `RESI-`) memungkinkan integrasi tanpa collision natural key, tetapi perlu didokumentasikan untuk traceability balik ke sumber.
- Kolom `hub_id` dan `courier_id` tidak tersedia di CSV, sehingga transformasi harus menggunakan default `-1` (Unknown Member) agar tidak violated FK constraint di OLAP.
