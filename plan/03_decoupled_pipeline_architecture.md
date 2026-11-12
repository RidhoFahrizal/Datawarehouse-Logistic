# Rencana Arsitektur Decoupled Pipeline Resmi: ETL - STAGING AREA - OLAP

**Tanggal:** 2026-11-12  
**Status:** Perombakan Total Resmi (Clean Decoupled Architecture)  
**Aliran Baku:** Data Sources $\rightarrow$ ETL (Extract & Transform) $\rightarrow$ STAGING AREA $\rightarrow$ ETL (Validate & Load) $\rightarrow$ OLAP

---

## 1. Prinsip Utama Arsitektur

1. **ETL adalah Proses (Apache Hop):** Logika pemrosesan yang membaca data sumber, melakukan standarisasi nama kolom bahasa Indonesia ke Inggris, konversi format tanggal lokal ke Timestamp ISO, dan kalkulasi metrik.
2. **Staging Area adalah Wadah Penampung Sementara (PostgreSQL `staging` schema):** Tempat mendaratnya data yang telah diekstrak dan ditransformasi dari sumber (`staging.stg_unified_shipment`), sebelum data tersebut siap divalidasi dan dimuat ke Data Warehouse.
3. **OLAP adalah Wadah Analitik Permanen (PostgreSQL `dwh` schema):** Model dimensional Star/Galaxy Schema yang menyimpan fakta terpartisi dan dimensi conformed untuk kebutuhan Data Mart dan Reporting.

Tidak ada lagi konsep "Raw Staging" yang mendahului transformasi. Transformasi awal dilakukan langsung saat ekstraksi dari sumber data sebelum masuk ke Staging Area.

---

## 2. Struktur Modul Pipeline Apache Hop (.hpl) dan Workflow (.hwf)

```
ProjectETL/
├── workflows/
│   └── main_daily_etl.hwf                       # Master Orchestrator Workflow
│
├── pipelines/
│   ├── 01_dimensions/                           # ETL Dimensi (Dimuat pertama kali)
│   │   ├── load_dim_customer.hpl                # Master Customer -> dwh.dim_customer
│   │   ├── load_dim_location.hpl                # Master Location -> dwh.dim_location
│   │   ├── load_dim_service_type.hpl            # Master Service Type (SCD2) -> dwh.dim_service_type
│   │   ├── load_dim_hub.hpl                     # Master Hub -> dwh.dim_hub
│   │   └── load_dim_courier.hpl                 # Master Courier (SCD2) -> dwh.dim_courier
│   │
│   ├── 02_staging/                              # ETL Source ke Staging Area
│   │   └── etl_source_to_staging.hpl            # Baca CSV & OLTP, Transform EN/Date,
│   │                                            # Union 200 resi -> staging.stg_unified_shipment
│   │
│   └── 03_facts/                                # ETL Staging Area ke OLAP
│       ├── load_fact_shipment.hpl               # Baca Staging, Validasi, Lookup Dimensi,
│       │                                        # Load -> dwh.fact_shipment (Partisi 2026)
│       ├── load_fact_shipment_event.hpl         # Log status kurir/hub -> dwh.fact_shipment_event
│       └── load_fact_claim.hpl                  # Transaksi klaim -> dwh.fact_claim
```

---

## 3. Rantai Aliran End-to-End

```text
[SUMBER: partner_shipments.csv]       [SUMBER: PostgreSQL OLTP]
              │                                   │
              └─────────────────┬─────────────────┘
                                │
                                ▼ [ETL: EXTRACT & TRANSFORM] (etl_source_to_staging.hpl)
                                │ • Ekstraksi kedua sumber
                                │ • Rename 13 kolom ID -> EN
                                │ • Parse tanggal dd/MM/yyyy -> ISO
                                │ • Append Streams (200 resi)
                                │ • Hitung margin & delivery_days
                                ▼
              ┌───────────────────────────────────┐
              │ STAGING AREA                      │
              │ staging.stg_unified_shipment      │
              │ (Menampung 200 resi hasil olahan) │
              └─────────────────┬─────────────────┘
                                │
                                ▼ [ETL: VALIDATE & LOAD] (load_fact_shipment.hpl)
                                │ • Data quality filter (bobot > 0, tarif >= 0)
                                │ • Lookup Surrogate Keys ke dwh.dim_*
                                │ • Pembangkitan Date SK (YYYYMMDD)
                                ▼
              ┌───────────────────────────────────┐
              │ DATA WAREHOUSE / OLAP             │
              │ dwh.fact_shipment (Partisi 2026)  │
              └─────────────────┬─────────────────┘
                                │
                                ▼
              ┌───────────────────────────────────┐
              │ DATA MART & REPORTING (Metabase)  │
              │ Dashboard COO, Branch, Finance    │
              └───────────────────────────────────┘
```
