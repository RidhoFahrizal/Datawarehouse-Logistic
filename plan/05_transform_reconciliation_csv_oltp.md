# Panduan Rekonsiliasi & Transformasi Perbedaan Kolom CSV vs OLTP di Apache Hop

**Tanggal:** 2026-11-12  
**Sumber 1:** `data/partner_shipments.csv` (15 kolom bahasa Indonesia, string, tanggal format lokal)  
**Sumber 2:** `data/01_seed_oltp.sql` (`oltp.shipment` + `oltp.shipment_status_log`)  
**Target:** Skema Terpadu untuk `dwh.fact_shipment`

---

## 1. Matriks Perbedaan Kolom & Aturan Transformasi

| No | Atribut Bisnis | Kolom di CSV | Kolom di OLTP | Masalah / Perbedaan | Solusi Transform di Apache Hop |
|---|---|---|---|---|---|
| 1 | Nomor Resi | `NO_RESI_PARTNER` | `receipt_number` | Nama kolom berbeda | Rename ke `receipt_number` via `Select Values` |
| 2 | ID Pelanggan | `ID_CUSTOMER` | `sender_customer_id` | Nama kolom berbeda | Rename ke `customer_id` via `Select Values` |
| 3 | Lokasi Asal | `KODE_ORIGIN` | `origin_location_id` | Nama kolom berbeda | Rename ke `origin_location_id` via `Select Values` |
| 4 | Lokasi Tujuan | `KODE_DESTINASI` | `destination_location_id` | Nama kolom berbeda | Rename ke `destination_location_id` via `Select Values` |
| 5 | Tipe Layanan | `JENIS_PAKET` | `service_type_id` | Nama kolom berbeda | Rename ke `service_type_id` via `Select Values` |
| 6 | Bobot Paket | `BOBOT_KG` | `package_weight_kg` | CSV teks, OLTP Numeric | Rename & Cast ke `Number(8,2)` via `Select Values (MetaData)` |
| 7 | Tarif Kirim (Revenue) | `TARIF_KIRIM_IDR` | `shipping_fee` | CSV teks, OLTP Numeric | Rename & Cast ke `BigNumber(12,2)` via `Select Values (MetaData)` |
| 8 | Estimasi Biaya (Cost) | `BIAYA_INTERNAL_IDR` | `estimated_cost` | CSV teks, OLTP Numeric | Rename & Cast ke `BigNumber(12,2)` via `Select Values (MetaData)` |
| 9 | Tanggal Transaksi | `TGL_TRANSAKSI` | `booking_timestamp` | Format CSV `dd/MM/yyyy HH:mm:ss`, OLTP ISO | Parsing Date Format `dd/MM/yyyy HH:mm:ss` ke `Timestamp` |
| 10 | Estimasi Tiba | `TGL_ESTIMASI_TIBA` | `estimated_delivery_date` | Format CSV `dd/MM/yyyy HH:mm:ss`, OLTP ISO | Parsing Date Format `dd/MM/yyyy HH:mm:ss` ke `Timestamp` |
| 11 | Status Akhir | `STATUS_PENGIRIMAN` | Tidak ada di `shipment` | Letak tabel berbeda (OLTP di log) | OLTP: CTE Window Function. CSV: Rename ke `final_status_code` |
| 12 | Tanggal Tiba Aktual | `TGL_STATUS_AKHIR` | Tidak ada di `shipment` | Letak tabel berbeda (OLTP di log) | OLTP: CTE Window Function. CSV: Rename ke `actual_delivery_date` + parse tanggal |
| 13 | Keterangan Gagal | `KETERANGAN_GAGAL` | Ada di log OLTP | Nullable, nama berbeda | Rename ke `failure_reason` + `If Field Value is Null` |
| 14 | Kolom Pelanggan CSV | `NAMA_SENDER`, `SEGMEN_PELANGGAN` | Tidak ada di `shipment` | Kolom berlebih di CSV | Dihapus di tab `Remove` pada `Select Values` |
| 15 | Kolom PII OLTP | Tidak ada di CSV | `recipient_name`, `phone`, `address` | Kolom PII di OLTP | Tidak diselect saat kueri SQL OLTP |
| 16 | Kolom Audit OLTP | Tidak ada di CSV | `created_at`, `updated_at`, `is_deleted` | Kolom audit internal | Difilter `WHERE is_deleted = FALSE`, dibuang dari stream |

---

## 2. Konfigurasi Transformasi di Apache Hop

### Jalur 1: Penyelarasan CSV Mitra
1. **Transform `CSV File Input`:**
   - Baca file `partner_shipments.csv`, Delimiter: `,`, Enclosure: `"`.
2. **Transform `Select Values - Rename & Remove`:**
   - Tab **Select & Alter**:
     - `NO_RESI_PARTNER` $\rightarrow$ `receipt_number`
     - `ID_CUSTOMER` $\rightarrow$ `customer_id`
     - `KODE_ORIGIN` $\rightarrow$ `origin_location_id`
     - `KODE_DESTINASI` $\rightarrow$ `destination_location_id`
     - `JENIS_PAKET` $\rightarrow$ `service_type_id`
     - `BOBOT_KG` $\rightarrow$ `package_weight_kg`
     - `TARIF_KIRIM_IDR` $\rightarrow$ `shipping_fee`
     - `BIAYA_INTERNAL_IDR` $\rightarrow$ `estimated_cost`
     - `TGL_TRANSAKSI` $\rightarrow$ `booking_timestamp`
     - `TGL_ESTIMASI_TIBA` $\rightarrow$ `estimated_delivery_date`
     - `STATUS_PENGIRIMAN` $\rightarrow$ `final_status_code`
     - `TGL_STATUS_AKHIR` $\rightarrow$ `actual_delivery_date`
     - `KETERANGAN_GAGAL` $\rightarrow$ `failure_reason`
   - Tab **Remove**:
     - `NAMA_SENDER`
     - `SEGMEN_PELANGGAN`
3. **Transform `Select Values - MetaData (Type Casting & Date Formatting)`:**
   - Field `booking_timestamp`: Type = `Timestamp`, Format = `dd/MM/yyyy HH:mm:ss`
   - Field `estimated_delivery_date`: Type = `Timestamp`, Format = `dd/MM/yyyy HH:mm:ss`
   - Field `actual_delivery_date`: Type = `Timestamp`, Format = `dd/MM/yyyy HH:mm:ss`
   - Field `package_weight_kg`: Type = `Number`, Precision = `2`
   - Field `shipping_fee`: Type = `BigNumber`, Precision = `2`
   - Field `estimated_cost`: Type = `BigNumber`, Precision = `2`
4. **Transform `Add Constants`:**
   - Tambahkan `source_type = 'CSV'`

### Jalur 2: Penyelarasan Database OLTP
1. **Transform `Table Input`:**
   - Menggunakan query CTE analitik untuk menggabungkan `oltp.shipment` dan status terakhir dari `oltp.shipment_status_log`.
   - Mengeluarkan kolom dengan nama bahasa Inggris yang identik:
     `source_type ('OLTP')`, `receipt_number`, `customer_id`, `origin_location_id`, `destination_location_id`, `service_type_id`, `package_weight_kg`, `shipping_fee`, `estimated_cost`, `booking_timestamp`, `estimated_delivery_date`, `actual_delivery_date`, `final_status_code`, `failure_reason`.
   - Menghilangkan data PII (`recipient_name`, `recipient_phone`, `recipient_address`) dan audit trail (`is_deleted`).

### Jalur 3: Unifikasi Stream
- **Transform `Append Streams`:** Menggabungkan output Stream CSV dan Stream OLTP yang kini memiliki 14 field dengan nama dan tipe data yang 100% seragam.
