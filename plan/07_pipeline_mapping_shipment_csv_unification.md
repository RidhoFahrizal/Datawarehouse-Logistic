# Pemetaan File Pipeline (.hpl) untuk Penyatuan CSV & OLTP Shipment

**Tanggal:** 2026-11-12  
**Tujuan:** Menetapkan nama dan peran file `.hpl` tempat bertemunya data `partner_shipments.csv` dan `oltp.shipment`.

---

## 1. Tempat Terjadinya Penyatuan ETL

Penyatuan data CSV dan OLTP dilakukan pada:
**`pipelines/02_staging/stg_unify_shipments.hpl`** (Pendekatan Staging Fisik Terpisah)  
ATAU  
**`pipelines/03_facts/load_fact_shipment.hpl`** (Pendekatan Stream Langsung / Direct Pipeline).

---

## 2. Perbandingan Dua Pendekatan Implementasi di Apache Hop

### Pendekatan A: Staging Fisik (`stg_unify_shipments.hpl`)
- **Input:** `CSV File Input` (partner_shipments.csv) dan `Table Input` (oltp.shipment + status).
- **Proses:** Penyelarasan kolom ID -> EN, parsing tanggal lokal -> ISO, casting numerik, penggabungan via `Append Streams`, dan kalkulasi metrik staging.
- **Output:** Masuk ke tabel fisik `staging.stg_unified_shipment`.
- **Kelebihan:** Data hasil pembersihan tersimpan di database staging sehingga dapat diaudit jika ada komplain dari pihak operasional atau partner.
- **Pipeline Lanjutan:** `load_fact_shipment.hpl` hanya membaca dari `staging.stg_unified_shipment` untuk melakukan lookup ke `dim_*` dan load ke `dwh.fact_shipment`.

### Pendekatan B: Streaming Langsung di `load_fact_shipment.hpl`
- **Input:** `CSV File Input` dan `Table Input` berada langsung di dalam kanvas `load_fact_shipment.hpl`.
- **Proses:** Penyelarasan kolom, `Append Streams`, kalkulasi KPI, dan `Database Lookup` dimensi dilakukan dalam 1 aliran memori tanpa mendarat ke tabel perantara staging.
- **Output:** Langsung masuk ke `dwh.fact_shipment`.
- **Kelebihan:** Jumlah file `.hpl` lebih ringkas, eksekusi memori lebih cepat.

---

## 3. Rekomendasi
Gunakan **Pendekatan A (`stg_unify_shipments.hpl`)** karena tabel `staging.stg_unified_shipment` sudah didefinisikan secara resmi di DDL `02_init_staging_dwh.sql` dan sesuai deskripsi `Project.md` (*"Ke-2 data akan disatukan dan masuk ke staging untuk menjadi OLAP"*).
