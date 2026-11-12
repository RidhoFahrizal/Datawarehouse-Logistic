# Panduan Teknis Apache Hop: Menjadikan Database Connection sebagai Input Utama Pipeline

**Tanggal:** 2026-11-12  
**Konteks:** Pasca-seeding PostgreSQL OLTP (`oltp.shipment`, `oltp.shipment_status_log`, master tables) dan konfigurasi DB Connection di Apache Hop.

---

## 1. Konsep Alur Ekstraksi OLTP di Apache Hop
Database Connection yang telah dibuat di Apache Hop (Relational Database Metadata Connection) tidak otomatis menarik data. Untuk menjadikannya **input utama**, kita harus menggunakan transform khusus bernama **`Table Input`** di dalam Pipeline (`.hpl`).

Karena database OLTP memisahkan data transaksi dasar (`oltp.shipment`) dan log pergerakan kurir/hub (`oltp.shipment_status_log`), ekstraksi data OLTP memerlukan kueri analitik (Window Function / CTE) agar status akhir pengiriman (*delivered, returned, failed*) serta tanggal aktual kedatangan dapat digabungkan langsung pada saat ekstraksi.

---

## 2. SQL Ekstraksi Input Utama (OLTP Shipment & Latest Status)
Kueri SQL berikut dimasukkan ke dalam step `Table Input`:

```sql
WITH latest_status AS (
    SELECT 
        ssl.receipt_number,
        ssl.status_code AS final_status_code,
        ssl.log_timestamp AS actual_delivery_date,
        ssl.failure_reason,
        ROW_NUMBER() OVER (
            PARTITION BY ssl.receipt_number 
            ORDER BY ssl.log_timestamp DESC, ssl.status_log_id DESC
        ) AS rn
    FROM oltp.shipment_status_log ssl
)
SELECT 
    'OLTP' AS source_type,
    s.receipt_number,
    s.sender_customer_id AS customer_id,
    s.origin_location_id,
    s.destination_location_id,
    s.service_type_id,
    s.package_weight_kg,
    s.shipping_fee,
    s.estimated_cost,
    s.booking_timestamp,
    s.estimated_delivery_date,
    ls.actual_delivery_date,
    COALESCE(ls.final_status_code, 'PICKUP') AS final_status_code,
    ls.failure_reason
FROM oltp.shipment s
LEFT JOIN latest_status ls 
    ON s.receipt_number = ls.receipt_number AND ls.rn = 1
WHERE s.is_deleted = FALSE;
```

---

## 3. Langkah Demi Langkah di GUI Apache Hop
1. **Buka / Buat Pipeline Baru (`.hpl`):**
   - Di Hop GUI, klik File $\rightarrow$ New $\rightarrow$ Pipeline (`Ctrl+N` lalu pilih Pipeline).
2. **Ambil Transform `Table Input`:**
   - Di panel kiri (*Transforms*), cari `Table Input`.
   - Drag & drop ke canvas kerja.
3. **Konfigurasi `Table Input`:**
   - Dobel klik step `Table Input`.
   - Ganti nama step menjadi: `Extract OLTP Shipments`.
   - Pada dropdown **Connection**, pilih koneksi PostgreSQL yang telah dibuat sebelumnya.
   - Tempelkan (*paste*) kueri SQL di atas ke dalam kotak **SQL**.
   - Klik tombol **Preview** untuk memverifikasi bahwa data berhasil ditarik langsung dari PostgreSQL.
4. **Hubungkan ke Downstream Pipeline:**
   - Buat Hop (panah penghubung) dari `Extract OLTP Shipments` menuju step transformasi lanjutan:
     - `Calculator` / `Formula` (perhitungan margin, durasi kirim, lateness).
     - `Append Streams` (penggabungan dengan input partner CSV).
     - `Table Output` (pemuatan ke staging atau target OLAP).
