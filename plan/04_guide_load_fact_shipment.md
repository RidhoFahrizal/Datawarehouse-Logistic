# Panduan Pembuatan Pipeline load_fact_shipment.hpl di Apache Hop

**Tanggal:** 2026-11-12  
**Target:** Skema `dwh.fact_shipment` (Range Partitioned by `booking_date_sk`)  
**Sumber:** Staging OLTP (`staging.stg_oltp_shipment`) & Staging CSV (`staging.stg_csv_shipment`)  
**Total Transform:** 20 Transform Steps  

---

## 1. Daftar dan Urutan Transform (20 Steps)

| No | Nama Transform di Hop | Tipe Transform | Konfigurasi Utama |
|----|-----------------------|----------------|-------------------|
| 1  | Read Staging OLTP     | Table Input    | `SELECT * FROM staging.stg_oltp_shipment` |
| 2  | Read Staging CSV      | Table Input    | `SELECT * FROM staging.stg_csv_shipment` |
| 3  | Union Streams         | Append Streams | Gabungkan stream OLTP dan CSV (Head: OLTP, Tail: CSV) |
| 4  | Calc Financial Margin | Calculator     | `margin = A - B` (A: `shipping_fee`, B: `estimated_cost`) |
| 5  | Calc Delivery Days    | Calculator     | `delivery_days = DateDiffInDays(actual_delivery_date, booking_timestamp)` |
| 6  | Lookup SLA Days       | Database Lookup| Lookup ke `dwh.dim_service_type` berdasarkan `service_type_id` |
| 7  | Flag Is Late          | Formula        | `IF([actual_delivery_date] > [estimated_delivery_date]; 1; 0)` |
| 8  | Flag Is Delivered     | Formula        | `IF([final_status_code] = "DELIVERED"; 1; 0)` |
| 9  | Flag Is Returned      | Formula        | `IF([final_status_code] = "RETURNED"; 1; 0)` |
| 10 | Flag Is Failed        | Formula        | `IF([final_status_code] = "FAILED"; 1; 0)` |
| 11 | Add Delivery Count    | Add Constants  | Field `delivery_count` (Integer) = `1` |
| 12 | Calc Booking Date SK  | Calculator     | `booking_date_sk = Year(A)*10000 + Month(A)*100 + Day(A)` |
| 13 | Calc Est Date SK      | Calculator     | `estimated_delivery_date_sk = Year(A)*10000 + Month(A)*100 + Day(A)` |
| 14 | Calc Actual Date SK   | Calculator     | `actual_delivery_date_sk = Year(A)*10000 + Month(A)*100 + Day(A)` |
| 15 | Handle Null Actual SK | If Null        | Jika `actual_delivery_date_sk` IS NULL ganti dengan `0` (Unknown Member) |
| 16 | Lookup Customer SK    | Database Lookup| Table: `dwh.dim_customer`, Match: `customer_id`, Return: `customer_sk` |
| 17 | Lookup Origin Loc SK  | Database Lookup| Table: `dwh.dim_location`, Match: `origin_location_id`, Return: `origin_location_sk` |
| 18 | Lookup Dest Loc SK    | Database Lookup| Table: `dwh.dim_location`, Match: `destination_location_id`, Return: `destination_location_sk` |
| 19 | Lookup Service SK SCD2| Database Lookup| Table: `dwh.dim_service_type`, Match: `service_type_id` AND `is_current=true`, Return: `service_type_sk` |
| 20 | Load Fact Shipment    | Table Output   | Schema: `dwh`, Table: `fact_shipment`, Commit size: `1000` |

---

## 2. Detail Pengisian Dialog GUI di Apache Hop

### Step 1 & 2: `Table Input`
- **Connection:** `postgres_dwh`
- **SQL (Step 1):** `SELECT * FROM staging.stg_oltp_shipment;`
- **SQL (Step 2):** `SELECT * FROM staging.stg_csv_shipment;`

### Step 3: `Append Streams`
- **Head step:** `Read Staging OLTP`
- **Tail step:** `Read Staging CSV`

### Step 4 & 5: `Calculator`
- **Field 1:** `margin`, Calculation: `A - B`, Field A: `shipping_fee`, Field B: `estimated_cost`, Value type: `Number`.
- **Field 2:** `delivery_days`, Calculation: `Date A - Date B (in days)`, Field A: `actual_delivery_date`, Field B: `booking_timestamp`, Value type: `Integer`.

### Step 7–10: `Formula`
- `is_late`: `IF([actual_delivery_date] > [estimated_delivery_date]; 1; 0)` (Tipe Integer).
- `is_delivered`: `IF([final_status_code] == "DELIVERED"; 1; 0)`
- `is_returned`: `IF([final_status_code] == "RETURNED"; 1; 0)`
- `is_failed`: `IF([final_status_code] == "FAILED"; 1; 0)`

### Step 12–14: Date Surrogate Key Generation
- Mengubah timestamp tanggal menjadi integer format `YYYYMMDD` untuk foreign key ke `dwh.dim_date`.

### Step 16–19: `Database Lookup`
- Menyocokkan natural key ke surrogate key integer `_sk`.
- Jika tidak cocok, beri nilai pengganti `-1`.

### Step 20: `Table Output`
- **Target schema:** `dwh`
- **Target table:** `fact_shipment`
- **Insert fields:**
  - `receipt_number`
  - `booking_date_sk`
  - `estimated_delivery_date_sk`
  - `actual_delivery_date_sk`
  - `customer_sk`
  - `origin_location_sk`
  - `destination_location_sk`
  - `service_type_sk`
  - `shipping_fee`
  - `estimated_cost`
  - `margin`
  - `package_weight_kg`
  - `delivery_count`
  - `delivery_days`
  - `sla_days`
  - `is_late`
  - `is_delivered`
  - `is_returned`
  - `is_failed`
