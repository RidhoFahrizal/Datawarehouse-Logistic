# Klarifikasi Konsep Data Warehouse: Posisi Staging vs OLAP dalam Siklus ETL

**Tanggal:** 2026-11-12  
**Konteks:** Meluruskan urutan fase Staging vs OLAP sesuai standar Ralph Kimball & W.H. Inmon.

---

## 1. Urutan Standar Siklus ETL / Data Warehouse

Urutan arsitektur data warehouse yang benar adalah:
```
[Sumber Data (OLTP & CSV)] 
       │
       ▼ (Extract)
[STAGING AREA (Landing & Transit)] 
       │
       ▼ (Transform & Cleanse)
[DATA WAREHOUSE / OLAP (Storage Akhir - Star Schema)] 
       │
       ▼ (Present)
[DATA MART / REPORTING / BI DASHBOARD]
```

## 2. Definisi & Peran Komponen

### A. Staging Area (`schema: staging`)
- **Posisi:** Berada di **AWAL / TENGAH** (antara sistem operasional dan DWH).
- **Sifat:** Bersifat sementara (*transient* / *volatile*), sering di-truncate/overwrite setiap batch ETL baru berjalan.
- **Tujuan:** 
  1. Tempat pendaratan data mentah (*landing zone*) agar proses ekstraksi dari database operasional OLTP cepat selesai dan tidak mengganggu performa transaksi produksi.
  2. Tempat "bengkel kerja" untuk rekonsiliasi format tanggal, penyeragaman nama kolom, deduping, dan join tabel sebelum data bersih disetor ke DWH.
  3. Pengguna bisnis (COO, Finance) **DILARANG** mengakses staging area karena datanya belum dimodelkan dan masih kotor.

### B. Data Warehouse / OLAP (`schema: dwh`)
- **Posisi:** Berada di **AKHIR** (sebagai muara tunggal / *Single Source of Truth*).
- **Sifat:** Permanen, historis (*non-volatile*), bertambah terus (*append-only* / partisi).
- **Tujuan:** 
  1. Menyimpan data yang sudah bersih dalam bentuk model dimensional (Tabel Fakta dan Tabel Dimensi).
  2. Dioptimasi untuk kueri analitik cepat, agregasi bisnis (SLA, margin, rasio gagal kirim).
  3. Menjadi sumber data utama yang dibaca langsung oleh aplikasi BI Dashboard (Metabase, Superset, Power BI).
