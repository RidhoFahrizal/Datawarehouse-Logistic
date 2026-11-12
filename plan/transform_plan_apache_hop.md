# Plan Transformasi ETL — Apache Hop (CSV partner_shipments → OLTP → Staging → OLAP)

## 1. Jawaban Pertanyaan: Apakah Hanya 1 Transform?

**Tidak.** Dalam Apache Hop, satu pipeline terdiri dari banyak **transform** (steps) yang dihubungkan via hops. Mengubah nama kolom hanyalah **satu** transform kecil (`Select Values` / `Rename`). Untuk data `partner_shipments.csv` yang perlu siap masuk OLTP dan OLAP, kita butuh banyak transform karena ada perbedaan:

- Nama kolom (Indonesia → standar OLTP/Inggris)
- Format tanggal (`DD/MM/YYYY HH:MM:SS` → `YYYY-MM-DD HH:MM:SS`)
- Tipe data (string → NUMERIC/TIMESTAMP)
- Validasi Foreign Key terhadap master OLTP (customer, location, service_type)
- Nilai default untuk kolom yang tidak ada di CSV (hub_id, courier_id)
- Derived metrics (delivery_days, is_late, margin, flag delivered/returned/failed)
- Penanganan status log (1 baris CSV → minimal 1 baris shipment_status_log)

## 2. Daftar Transform yang Dapat Dilakukan

Berikut transformasi yang dapat kita lakukan dalam pipeline Apache Hop, diurutkan dari awal sampai akhir:

| No | Transform (Step Apache Hop) | Tujuan | Kolom Terlibat |
|----|-----------------------------|--------|----------------|
| 1 | **CSV File Input** | Membaca file partner_shipments.csv | Semua kolom CSV |
| 2 | **Select Values (Rename)** | Ganti nama kolom bahasa Indonesia → standar OLTP | Semua kolom |
| 3 | **Date/Time Formatter** | Ubah `DD/MM/YYYY HH:MM:SS` → `YYYY-MM-DD HH:MM:SS` | TGL_TRANSAKSI, TGL_ESTIMASI_TIBA, TGL_STATUS_AKHIR |
| 4 | **Select Values (Cast)** | Ubah tipe data string → NUMERIC / TIMESTAMP | BOBOT_KG, TARIF_KIRIM_IDR, BIAYA_INTERNAL_IDR, tanggal |
| 5 | **Add Constants** | Tambahkan kolom default (hub_id=-1, courier_id=-1, is_deleted=false, created_at) | Kolom baru |
| 6 | **Lookup (CUSTOMER)** | Validasi ID_CUSTOMER ada di master CUSTOMER | ID_CUSTOMER |
| 7 | **Lookup (LOCATION - Origin)** | Validasi KODE_ORIGIN ada di master LOCATION | KODE_ORIGIN |
| 8 | **Lookup (LOCATION - Destination)** | Validasi KODE_DESTINASI ada di master LOCATION | KODE_DESTINASI |
| 9 | **Lookup (SERVICE_TYPE)** | Validasi JENIS_PAKET ada di master SERVICE_TYPE | JENIS_PAKET |
| 10 | **Filter Rows** | Pisahkan baris valid vs invalid (FK tidak ditemukan) | Semua FK |
| 11 | **Add Formula (Derived)** | Hitung delivery_days, is_late, margin, is_delivered, is_returned, is_failed | TGL_TRANSAKSI, TGL_ESTIMASI_TIBA, TGL_STATUS_AKHIR, STATUS_PENGIRIMAN, TARIF, BIAYA |
| 12 | **Add Formula (Status Log)** | Siapkan baris shipment_status_log (status_code, log_timestamp, failure_reason) | STATUS_PENGIRIMAN, TGL_STATUS_AKHIR, KETERANGAN_GAGAL |
| 13 | **Table Output (OLTP - shipment)** | Insert ke tabel shipment | receipt_number, sender_customer_id, origin/destination_location_id, service_type_id, package_weight_kg, shipping_fee, estimated_cost, booking_timestamp, estimated_delivery_date |
| 14 | **Table Output (OLTP - shipment_status_log)** | Insert ke tabel shipment_status_log | receipt_number, hub_id, courier_id, status_code, failure_reason, log_timestamp |
| 15 | **Stream Lookup / Merge** | Gabungkan data OLTP + data asli untuk staging | Semua |
| 16 | **Table Output (Staging)** | Simpan ke staging schema sebelum OLAP | Semua kolom staging |
| 17 | **Add Formula (OLAP derived)** | Hitung metrik akhir untuk fact_shipment / fact_shipment_event | delivery_days, is_late, margin |
| 18 | **Dimension Lookup (SK)** | Map natural key → surrogate key (customer_sk, location_sk, service_type_sk, date_sk) | ID natural |
| 19 | **Table Output (OLAP - fact_shipment)** | Insert ke fact_shipment | Semua FK SK + measures |
| 20 | **Table Output (OLAP - fact_shipment_event)** | Insert ke fact_shipment_event | event_sk, shipment_sk, hub_sk, courier_sk, status_sk, log_date_sk |
| 21 | **Table Output (OLAP - fact_claim)** | Insert ke fact_claim (jika ada klaim dari CSV) | claim_sk, claim_amount, claim_date_sk |
| 22 | **Log / Email** | Catat jumlah baris berhasil, gagal, dan ditolak | Statistik pipeline |

**Jumlah transform minimum yang direkomendasikan: ~22 transform** (semakin banyak transform yang valid dan terstruktur, semakin bagus untuk lineage data dan debugging).

## 3. Visualisasi Alur Pipeline Apache Hop

```
┌──────────────┐
│ CSV File     │──▶ 1. CSV File Input
│ Input        │
└──────────────┘
      │
      ▼
┌──────────────┐──▶ 2. Select Values (Rename kolom)
│ Rename       │
└──────────────┘
      │
      ▼
┌──────────────┐──▶ 3. Date/Time Formatter (DD/MM/YYYY → YYYY-MM-DD)
│ Format Tanggal│
└──────────────┘
      │
      ▼
┌──────────────┐──▶ 4. Select Values (Cast tipe data)
│ Cast         │
└──────────────┘
      │
      ▼
┌──────────────┐──▶ 5. Add Constants (hub_id=-1, courier_id=-1)
│ Default      │
└──────────────┘
      │
      ▼
┌──────────────┐──▶ 6-9. Lookup ×4 (validasi FK ke master OLTP)
│ Lookup FK    │
└──────────────┘
      │
      ▼
┌──────────────┐──▶ 10. Filter Rows (valid vs invalid)
│ Filter       │── valid ──▶
│              │── invalid ──▶ Log Error
└──────────────┘
      │ (valid)
      ▼
┌──────────────┐──▶ 11-12. Add Formula (derived metrics + status log)
│ Derived      │
└──────────────┘
      │
      ▼
┌──────────────┐──▶ 13. Table Output → OLTP.shipment
│ OLTP Shipment│
└──────────────┘
      │
      ▼
┌──────────────┐──▶ 14. Table Output → OLTP.shipment_status_log
│ OLTP Status  │
└──────────────┘
      │
      ▼
┌──────────────┐──▶ 15-16. Merge + Table Output → Staging
│ Staging      │
└──────────────┘
      │
      ▼
┌──────────────┐──▶ 17-18. Derived + Dimension SK Lookup
│ OLAP Prep    │
└──────────────┘
      │
      ▼
┌──────────────┐──▶ 19-21. Table Output → OLAP (3 fact tables)
│ OLAP Facts   │
└──────────────┘
      │
      ▼
┌──────────────┐──▶ 22. Log / Email (summary)
│ Logging      │
└──────────────┘
```

## 4. Contoh Detail Transform (Select Values Rename)

| Kolom CSV (Asli) | Kolom Target (OLTP/Staging) | Keterangan |
|------------------|------------------------------|------------|
| NO_RESI_PARTNER | receipt_number | Natural key partner (prefix PRT-) |
| ID_CUSTOMER | sender_customer_id | FK ke CUSTOMER |
| NAMA_SENDER | customer_name | Enrichment DIM_CUSTOMER |
| SEGMEN_PELANGGAN | customer_type | B2B / B2C |
| KODE_ORIGIN | origin_location_id | FK ke LOCATION |
| KODE_DESTINASI | destination_location_id | FK ke LOCATION |
| JENIS_PAKET | service_type_id | FK ke SERVICE_TYPE |
| BOBOT_KG | package_weight_kg | NUMERIC(8,2) |
| TARIF_KIRIM_IDR | shipping_fee | NUMERIC(12,2) |
| BIAYA_INTERNAL_IDR | estimated_cost | NUMERIC(12,2) |
| TGL_TRANSAKSI | booking_timestamp | TIMESTAMP |
| TGL_ESTIMASI_TIBA | estimated_delivery_date | TIMESTAMP |
| STATUS_PENGIRIMAN | status_code | DELIVERED / RETURNED / FAILED / IN_TRANSIT |
| TGL_STATUS_AKHIR | log_timestamp | TIMESTAMP |
| KETERANGAN_GAGAL | failure_reason | NULL jika tidak gagal |

## 5. Derived Metrics (Add Formula)

| Metrik | Rumus Logika | Digunakan Untuk |
|--------|--------------|-----------------|
| delivery_days | `log_timestamp - booking_timestamp` (jika DELIVERED) | fact_shipment |
| is_late | `log_timestamp > estimated_delivery_date ? 1 : 0` | fact_shipment |
| margin | `shipping_fee - estimated_cost` | fact_shipment (Finance) |
| is_delivered | `status_code = 'DELIVERED' ? 1 : 0` | fact_shipment |
| is_returned | `status_code = 'RETURNED' ? 1 : 0` | fact_shipment |
| is_failed | `status_code = 'FAILED' ? 1 : 0` | fact_shipment |

## 6. Rekomendasi Implementasi Apache Hop

1. **Buat 2 pipeline terpisah:**
   - `01_csv_to_oltp.hpl`: CSV → transformasi → insert ke tabel OLTP (`shipment` + `shipment_status_log`)
   - `02_oltp_to_olap.hpl`: OLTP + CSV gabungan → staging → OLAP (3 fact + dimensi)

2. **Gunakan "Unknown Member" (-1)** untuk `hub_id` dan `courier_id` karena CSV tidak memiliki kolom ini, agar tidak ada FK NULL di OLAP.

3. **Validasi FK di staging** sebelum insert: baris yang `ID_CUSTOMER`, `KODE_ORIGIN`, `KODE_DESTINASI`, atau `JENIS_PAKET` tidak ditemukan di master OLTP → direject ke log error, jangan di-load.

4. **Catat jumlah transform** di `plan/` setelah pipeline dibuat (saat ini direkomendasikan minimal 22 transform).

5. **Insight baru:** CSV partner menambahkan 100 resi dengan layanan Cargo (SRV-CRG) dan SameDay (SRV-SD), serta segmen B2B/B2C yang memperkaya analisis margin & OTD per segmen pelanggan untuk Finance Manager.
