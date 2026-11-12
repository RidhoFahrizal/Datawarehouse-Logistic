# Rencana Arsitektur Decoupled Pipeline ETL (Apache Hop)

**Tanggal:** 2026-11-12  
**Status:** Disetujui (Decoupled & Modular Design)  
**Referensi Data:** `data/01_seed_oltp.sql`, `data/partner_shipments.csv`, `data/02_init_staging_dwh.sql`

---

## 1. Latar Belakang & Prinsip Decoupling
Memisahkan proses ETL menjadi beberapa sub-pipeline independen (*decoupled*) berbasis domain bisnis dan tingkat agregasi data. 

### Prinsip Utama:
1. **Separation of Concerns:** Pipeline dimensi tidak dicampur dengan pipeline fakta.
2. **Deterministic Dependency Order:** Dimensi selalu selesai dimuat 100% sebelum fakta melakukan lookup.
3. **Resilience & Fault Isolation:** Kegagalan pada salah satu sumber eksternal (misal format CSV mitra berubah) tidak menghentikan pemuatan dimensi atau fakta lain.
4. **Reusability:** Pipeline dimensi dapat dijalankan ulang secara mandiri saat ada data pelanggan atau layanan baru (*SCD Type 1 & 2*).

---

## 2. Struktur Modul Pipeline (.hpl) dan Workflow (.hwf)

```
ProjectETL/
├── workflows/
│   └── main_daily_etl.hwf                  # Master Orchestrator Workflow
├── pipelines/
│   ├── 01_dimensions/
│   │   ├── load_dim_customer.hpl           # Pipeline master customer (SCD1)
│   │   ├── load_dim_location.hpl           # Pipeline master location
│   │   ├── load_dim_service_type.hpl       # Pipeline master service type (SCD2)
│   │   ├── load_dim_hub.hpl                # Pipeline master hub (denormalized with location)
│   │   └── load_dim_courier.hpl            # Pipeline master courier (SCD2)
│   ├── 02_staging/
│   │   ├── stg_load_partner_csv.hpl        # Ingestion, rename ID->EN, date parse CSV
│   │   └── stg_load_oltp_shipment.hpl      # Ingestion OLTP shipment + CTE latest status
│   └── 03_facts/
│       ├── load_fact_shipment.hpl          # Unifikasi staging, KPI, lookup SK, partisi 2026
│       ├── load_fact_shipment_event.hpl    # Granular status logs per hub & kurir
│       └── load_fact_claim.hpl             # Transaksi klaim ganti rugi barang
```

---

## 3. Rincian Modul & Transformasi Tiap Pipeline

### A. Modul Dimensi (`01_dimensions/`)
- **Tujuan:** Mengisi 5 tabel dimensi conformed di skema `dwh`.
- **Pipeline:**
  1. `load_dim_customer.hpl`:
     - `Table Input`: `SELECT * FROM oltp.customer WHERE is_deleted=FALSE`
     - `Select Values`: Pemetaan metadata
     - `Table Output`: `dwh.dim_customer`
  2. `load_dim_location.hpl`:
     - `Table Input`: `SELECT * FROM oltp.location WHERE is_deleted=FALSE`
     - `String Operations`: Trim & Upper
     - `Table Output`: `dwh.dim_location`
  3. `load_dim_service_type.hpl`:
     - `Table Input`: `SELECT * FROM oltp.service_type WHERE is_deleted=FALSE`
     - `Dimension Lookup/Update`: Penanganan SCD Type 2 (`effective_date`, `expiration_date`, `is_current`)
     - `Table Output`: `dwh.dim_service_type`
  4. `load_dim_hub.hpl`:
     - `Table Input`: Join `oltp.hub` dan `oltp.location`
     - `Table Output`: `dwh.dim_hub`
  5. `load_dim_courier.hpl`:
     - `Table Input`: Join `oltp.courier`, `oltp.hub`, dan `oltp.location`
     - `Dimension Lookup/Update`: SCD Type 2
     - `Table Output`: `dwh.dim_courier`

### B. Modul Staging Terpadu (`02_staging/`)
- **Tujuan:** Mengakomodasi kebutuhan CSV dan OLTP secara terpisah sebelum disatukan.
- **Pipeline:**
  1. `stg_load_partner_csv.hpl`:
     - `CSV File Input`: `partner_shipments.csv`
     - `Select Values`: Rename 15 kolom bahasa Indonesia $\rightarrow$ Inggris
     - `Calculator / Formula`: Parsing tanggal `DD/MM/YYYY HH:mm:ss` ke ISO Timestamp
     - `Select Values`: Casting numerik `package_weight_kg`, `shipping_fee`, `estimated_cost`
     - `Add Constants`: `source_type = 'CSV'`
     - `Table Output`: `staging.stg_csv_shipment`
  2. `stg_load_oltp_shipment.hpl`:
     - `Table Input`: Kueri CTE `oltp.shipment` + status log terakhir
     - `Add Constants`: `source_type = 'OLTP'`
     - `Table Output`: `staging.stg_oltp_shipment`

### C. Modul Fakta (`03_facts/`)
- **Tujuan:** Menghitung KPI bisnis dan memuat fakta ke OLAP.
- **Pipeline:**
  1. `load_fact_shipment.hpl`:
     - `Table Input`: Membaca data dari `staging.stg_csv_shipment` dan `staging.stg_oltp_shipment`
     - `Append Streams`: Menyatukan menjadi 200 transaksi terpadu
     - `Calculator`: `margin = shipping_fee - estimated_cost`
     - `Calculator`: `delivery_days = actual_delivery_date - booking_timestamp`
     - `Database Lookup`: `sla_days` dari `dim_service_type`
     - `Formula`: Flag biner `is_late`, `is_delivered`, `is_returned`, `is_failed`
     - `Add Constants`: `delivery_count = 1`
     - `Calculator`: Pembangkit date SK (`booking_date_sk`, `estimated_date_sk`, `actual_date_sk`)
     - `Database Lookup` $\times 4$: Ambil `customer_sk`, `origin_location_sk`, `destination_location_sk`, `service_type_sk`
     - `Table Output`: Masuk ke tabel partisi `dwh.fact_shipment_2026`
  2. `load_fact_shipment_event.hpl`:
     - `Table Input`: `SELECT * FROM oltp.shipment_status_log`
     - `Calculator`: Ekstraksi `log_date_sk` dan `log_time`
     - `Database Lookup`: `hub_sk`, `courier_sk`, `status_sk` (default `-1` untuk null)
     - `Table Output`: Masuk ke `dwh.fact_shipment_event_2026`
  3. `load_fact_claim.hpl`:
     - `Table Input`: `SELECT * FROM oltp.claim`
     - `Calculator`: Ekstraksi `claim_date_sk`
     - `Database Lookup`: `customer_sk`, `status_sk`
     - `Table Output`: Masuk ke `dwh.fact_claim`

---

## 4. Orkestrasi Master Workflow (`main_daily_etl.hwf`)
Urutan eksekusi sekuensial yang dijamin di dalam workflow:
1. **Start**
2. **Check DB Connections** (Validasi koneksi `postgres_oltp` dan `postgres_dwh`)
3. **Truncate Staging Tables** (SQL Script pembersihan `staging.*`)
4. **Action Pipeline 1:** Jalankan modul dimensi (`load_dim_*.hpl`) secara sekuensial/paralel
5. **Action Pipeline 2:** Jalankan modul staging (`stg_load_*.hpl`)
6. **Action Pipeline 3:** Jalankan `load_fact_shipment.hpl`
7. **Action Pipeline 4 & 5:** Jalankan `load_fact_shipment_event.hpl` dan `load_fact_claim.hpl`
8. **Success / Failure Notification**
