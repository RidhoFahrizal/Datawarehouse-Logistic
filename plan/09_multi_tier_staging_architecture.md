# Arsitektur Resmi Data Pipeline: ETL - STAGING AREA - OLAP

**Tanggal Pembaruan:** 2026-11-12  
**Status:** Disesuaikan Penuh (Sesuai Konsep ETL -> Staging Area -> OLAP)

---

## 1. Definisi Peran Komponen

1. **Sumber Data:** Berkas mentah [partner_shipments.csv](file:///home/ridho-the-engineer/CyberNote/DataWarehouse/ProjectETL/data/partner_shipments.csv) dan database operasional [01_seed_oltp.sql](file:///home/ridho-the-engineer/CyberNote/DataWarehouse/ProjectETL/data/01_seed_oltp.sql).
2. **Proses ETL 1 (Extract & Transform):** Dieksekusi oleh Apache Hop (`etl_source_to_staging.hpl`). Mengambil data, mengubah nama kolom ke bahasa Inggris, mem-parsing format tanggal, dan menyatukan resi.
3. **STAGING AREA:** Wadah penyimpanan sementara di PostgreSQL (`staging.stg_unified_shipment`) yang menampung data hasil proses ETL 1.
4. **Proses ETL 2 (Validate & Load):** Dieksekusi oleh Apache Hop (`load_fact_shipment.hpl`). Memvalidasi data, melakukan lookup ke tabel dimensi, dan memuatnya ke OLAP.
5. **OLAP (Data Warehouse):** Wadah analitik dimensional permanen di PostgreSQL (`dwh.fact_shipment` dan `dwh.dim_*`).
6. **Data Mart & Reporting:** Lapisan konsumsi bisnis untuk dashboard COO, Branch, dan Finance.
