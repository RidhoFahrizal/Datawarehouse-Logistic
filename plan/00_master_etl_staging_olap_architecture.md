# Master Arsitektur Resmi: ETL - STAGING AREA - OLAP

**Tanggal Pembaruan:** 2026-11-12  
**Status:** Terkoreksi Penuh Sesuai Pola: `ETL -> STAGING AREA -> OLAP`  
**Referensi:** `data/01_seed_oltp.sql`, `data/partner_shipments.csv`, `data/02_init_staging_dwh.sql`, `Project.md`

---

## 1. Rantai Aliran Baku: ETL -> STAGING AREA -> OLAP

Sesuai arsitektur yang Anda tetapkan, proses ETL dilakukan terlebih dahulu dari sumber data, hasilnya ditampung di Staging Area, baru kemudian divalidasi dan dimuat ke OLAP:

```
         DATA SOURCES
         /          \
    PostgreSQL      CSV
         \          /
          \        /
       [1. ETL: EXTRACT & TRANSFORM] (Apache Hop)
       • Ekstraksi berkas CSV & database OLTP
       • Transformasi kolom Indo -> Inggris
       • Parsing tanggal dd/MM/yyyy -> Timestamp
       • Penyatuan stream (Append Streams 200 resi)
              │
              ▼
       +--------------+
       | STAGING AREA | (PostgreSQL: staging.stg_unified_shipment)
       |              |
       | Data hasil   | Menampung data yang telah diekstrak
       | transformasi | dan ditransformasi oleh ETL awal
       +--------------+
              │
              ▼
       [2. ETL: VALIDATE & LOAD] (Apache Hop)
       • Validasi kelengkapan data & anomali
       • Lookup Surrogate Keys dimensi conformed
       • Pemuatan massal data fakta
              │
              ▼
       DATA WAREHOUSE / OLAP (PostgreSQL: dwh.fact_shipment)
              │
              ▼
          DATA MART
              │
              ▼
          REPORTING (Apache Superset / Metabase)
```

---

## 2. Rincian Dua Pipeline Apache Hop

### Pipeline 1: `01_etl_source_to_staging.hpl` (ETL $\rightarrow$ STAGING AREA)
- **Fungsi:** Mengambil data dari PostgreSQL OLTP dan CSV mitra, menjalankan transformasi awal, dan menyimpannya di Staging Area.
- **Tahapan:**
  1. `CSV File Input`: Membaca `partner_shipments.csv`.
  2. `Select Values`: Mengubah 13 nama kolom bahasa Indonesia ke Bahasa Inggris.
  3. `Select Values (MetaData)`: Mengubah format tanggal `dd/MM/yyyy HH:mm:ss` ke ISO Timestamp dan casting angka.
  4. `Table Input (OLTP)`: Membaca `oltp.shipment` yang di-join dengan status akhir dari `oltp.shipment_status_log`.
  5. `Append Streams`: Menyatukan data CSV (100 baris) dan OLTP (100 baris) $\rightarrow$ 200 baris.
  6. `Calculator`: Menghitung `margin = shipping_fee - estimated_cost` dan `delivery_days`.
  7. `Formula`: Menghasilkan flag `is_late`, `is_delivered`, `is_returned`, `is_failed`.
  8. `Table Output`: Memuat 200 baris ke **`staging.stg_unified_shipment` (STAGING AREA)**.

### Pipeline 2: `02_etl_staging_to_olap.hpl` (STAGING AREA $\rightarrow$ VALIDATE & LOAD $\rightarrow$ OLAP)
- **Fungsi:** Membaca data dari Staging Area, melakukan validasi dan lookup dimensi, lalu memuatnya ke OLAP.
- **Tahapan:**
  1. `Table Input`: Membaca 200 baris dari `staging.stg_unified_shipment`.
  2. `Filter Rows (Validation)`: Memvalidasi data (cek bobot > 0, tarif >= 0, tanggal valid).
  3. `Calculator`: Menghasilkan integer `booking_date_sk`, `estimated_delivery_date_sk`, `actual_delivery_date_sk` (YYYYMMDD).
  4. `Database Lookup` $\times 4$: Mencari `customer_sk`, `origin_location_sk`, `destination_location_sk`, `service_type_sk`.
  5. `Table Output`: Memuat ke tabel partisi **`dwh.fact_shipment` (OLAP)**.
