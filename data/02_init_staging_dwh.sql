-- =====================================================================
-- 02_init_staging_dwh.sql
-- Inisialisasi Staging Area & Data Warehouse (OLAP) Sistem Logistik
-- Sesuai rancangan olap.md & materi partisi (Kimball Star/Galaxy Schema)
-- =====================================================================

-- =====================================================================
-- 1. STAGING SCHEMA
-- =====================================================================
CREATE SCHEMA IF NOT EXISTS staging;

DROP TABLE IF EXISTS staging.stg_unified_shipment CASCADE;
DROP TABLE IF EXISTS staging.stg_csv_shipment CASCADE;
DROP TABLE IF EXISTS staging.stg_oltp_shipment CASCADE;

-- Landing table untuk CSV mentah
CREATE TABLE staging.stg_csv_shipment (
    no_resi_partner VARCHAR(100),
    id_customer VARCHAR(100),
    nama_sender VARCHAR(200),
    segmen_pelanggan VARCHAR(50),
    kode_origin VARCHAR(50),
    kode_destinasi VARCHAR(50),
    jenis_paket VARCHAR(50),
    bobot_kg VARCHAR(50),
    tarif_kirim_idr VARCHAR(50),
    biaya_internal_idr VARCHAR(50),
    tgl_transaksi VARCHAR(50),
    tgl_estimasi_tiba VARCHAR(50),
    status_pengiriman VARCHAR(50),
    tgl_status_akhir VARCHAR(50),
    keterangan_gagal VARCHAR(255),
    ingested_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Landing table untuk ekstraksi OLTP
CREATE TABLE staging.stg_oltp_shipment (
    receipt_number VARCHAR(50),
    sender_customer_id VARCHAR(32),
    origin_location_id VARCHAR(32),
    destination_location_id VARCHAR(32),
    service_type_id VARCHAR(32),
    package_weight_kg NUMERIC(8,2),
    shipping_fee NUMERIC(12,2),
    estimated_cost NUMERIC(12,2),
    booking_timestamp TIMESTAMP,
    estimated_delivery_date TIMESTAMP,
    actual_delivery_date TIMESTAMP,
    final_status_code VARCHAR(30),
    failure_reason VARCHAR(100),
    ingested_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Staging terintegrasi yang telah dibersihkan & distandarisasi (siap dimuat ke OLAP)
CREATE TABLE staging.stg_unified_shipment (
    source_type VARCHAR(10), -- 'OLTP' atau 'CSV'
    receipt_number VARCHAR(50) PRIMARY KEY,
    customer_id VARCHAR(32),
    origin_location_id VARCHAR(32),
    destination_location_id VARCHAR(32),
    service_type_id VARCHAR(32),
    package_weight_kg NUMERIC(8,2),
    shipping_fee NUMERIC(12,2),
    estimated_cost NUMERIC(12,2),
    margin NUMERIC(12,2),
    booking_timestamp TIMESTAMP,
    estimated_delivery_date TIMESTAMP,
    actual_delivery_date TIMESTAMP,
    delivery_days INT,
    sla_days INT,
    is_late SMALLINT,
    is_delivered SMALLINT,
    is_returned SMALLINT,
    is_failed SMALLINT,
    final_status_code VARCHAR(30),
    failure_reason VARCHAR(100),
    processed_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);


-- =====================================================================
-- 2. DWH (OLAP) SCHEMA
-- =====================================================================
CREATE SCHEMA IF NOT EXISTS dwh;

-- Drop fact tables terlebih dahulu
DROP TABLE IF EXISTS dwh.fact_claim CASCADE;
DROP TABLE IF EXISTS dwh.fact_shipment_event CASCADE;
DROP TABLE IF EXISTS dwh.fact_shipment CASCADE;

-- Drop dimensions
DROP TABLE IF EXISTS dwh.dim_status CASCADE;
DROP TABLE IF EXISTS dwh.dim_courier CASCADE;
DROP TABLE IF EXISTS dwh.dim_hub CASCADE;
DROP TABLE IF EXISTS dwh.dim_service_type CASCADE;
DROP TABLE IF EXISTS dwh.dim_location CASCADE;
DROP TABLE IF EXISTS dwh.dim_customer CASCADE;
DROP TABLE IF EXISTS dwh.dim_date CASCADE;

-- 2.1 Dimensi Tanggal (Conformed, Role-Playing)
CREATE TABLE dwh.dim_date (
    date_sk INT PRIMARY KEY, -- Format YYYYMMDD
    full_date DATE NOT NULL,
    year INT NOT NULL,
    quarter INT NOT NULL,
    month INT NOT NULL,
    month_name VARCHAR(20) NOT NULL,
    day_of_month INT NOT NULL,
    day_of_week INT NOT NULL,
    day_name VARCHAR(20) NOT NULL,
    is_weekend BOOLEAN NOT NULL
);

-- 2.2 Dimensi Customer (SCD Type 1)
CREATE TABLE dwh.dim_customer (
    customer_sk SERIAL PRIMARY KEY,
    customer_id VARCHAR(32) NOT NULL,
    customer_name VARCHAR(150) NOT NULL,
    customer_type VARCHAR(10) NOT NULL,
    registered_at TIMESTAMP
);

-- 2.3 Dimensi Location (Role-Playing: Origin & Destination)
CREATE TABLE dwh.dim_location (
    location_sk SERIAL PRIMARY KEY,
    location_id VARCHAR(32) NOT NULL,
    city_name VARCHAR(100) NOT NULL,
    province_name VARCHAR(100) NOT NULL,
    postal_code VARCHAR(10) NOT NULL
);

-- 2.4 Dimensi Service Type (SCD Type 2)
CREATE TABLE dwh.dim_service_type (
    service_type_sk SERIAL PRIMARY KEY,
    service_type_id VARCHAR(32) NOT NULL,
    service_name VARCHAR(50) NOT NULL,
    sla_days INT NOT NULL,
    base_rate NUMERIC(12,2) NOT NULL,
    effective_date TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    expiration_date TIMESTAMP NOT NULL DEFAULT '9999-12-31 23:59:59',
    is_current BOOLEAN NOT NULL DEFAULT TRUE
);

-- 2.5 Dimensi Hub (Star Schema denormalized)
CREATE TABLE dwh.dim_hub (
    hub_sk INT PRIMARY KEY,
    hub_id VARCHAR(32) NOT NULL,
    hub_name VARCHAR(100) NOT NULL,
    city_name VARCHAR(100) NOT NULL,
    province_name VARCHAR(100) NOT NULL,
    capacity_per_day INT NOT NULL
);

-- 2.6 Dimensi Courier (SCD Type 2)
CREATE TABLE dwh.dim_courier (
    courier_sk SERIAL PRIMARY KEY,
    courier_id VARCHAR(32) NOT NULL,
    courier_name VARCHAR(150) NOT NULL,
    vehicle_type VARCHAR(30) NOT NULL,
    base_city_name VARCHAR(100),
    base_province_name VARCHAR(100),
    hub_id VARCHAR(32),
    effective_date TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    expiration_date TIMESTAMP NOT NULL DEFAULT '9999-12-31 23:59:59',
    is_current BOOLEAN NOT NULL DEFAULT TRUE
);

-- 2.7 Dimensi Status
CREATE TABLE dwh.dim_status (
    status_sk SERIAL PRIMARY KEY,
    status_code VARCHAR(30) NOT NULL,
    status_group VARCHAR(20) NOT NULL,
    failure_reason VARCHAR(100),
    is_terminal_status BOOLEAN NOT NULL DEFAULT FALSE
);

-- Baris Pengganti Unknown Members (-1) untuk integritas FK
INSERT INTO dwh.dim_date (date_sk, full_date, year, quarter, month, month_name, day_of_month, day_of_week, day_name, is_weekend)
VALUES (0, '1970-01-01', 1970, 1, 1, 'Unknown', 1, 1, 'Unknown', FALSE);

INSERT INTO dwh.dim_hub (hub_sk, hub_id, hub_name, city_name, province_name, capacity_per_day)
VALUES (-1, 'NO-HUB', 'Non-Hub / Belum Ditugaskan', 'Unknown', 'Unknown', 0);

INSERT INTO dwh.dim_courier (courier_sk, courier_id, courier_name, vehicle_type, base_city_name, base_province_name, hub_id, effective_date, is_current)
VALUES (-1, 'NO-COURIER', 'Non-Courier / Belum Ditugaskan', 'None', 'Unknown', 'Unknown', 'NO-HUB', '1970-01-01', TRUE);


-- =====================================================================
-- 2.8 FACT TABLES (DENGAN STRATEGI RANGE PARTITIONING)
-- =====================================================================

-- FACT 1: FACT_SHIPMENT (Dipreparasi untuk Analisis COO & Finance)
-- Dipartisi berdasarkan rentang waktu booking_date_sk
CREATE TABLE dwh.fact_shipment (
    shipment_sk BIGSERIAL,
    receipt_number VARCHAR(50) NOT NULL,
    booking_date_sk INT NOT NULL REFERENCES dwh.dim_date(date_sk),
    estimated_delivery_date_sk INT NOT NULL REFERENCES dwh.dim_date(date_sk),
    actual_delivery_date_sk INT REFERENCES dwh.dim_date(date_sk),
    customer_sk INT NOT NULL REFERENCES dwh.dim_customer(customer_sk),
    origin_location_sk INT NOT NULL REFERENCES dwh.dim_location(location_sk),
    destination_location_sk INT NOT NULL REFERENCES dwh.dim_location(location_sk),
    service_type_sk INT NOT NULL REFERENCES dwh.dim_service_type(service_type_sk),
    shipping_fee NUMERIC(12,2) NOT NULL,
    estimated_cost NUMERIC(12,2) NOT NULL,
    margin NUMERIC(12,2) NOT NULL,
    package_weight_kg NUMERIC(8,2) NOT NULL,
    delivery_count INT DEFAULT 1,
    delivery_days INT,
    sla_days INT,
    is_late SMALLINT,
    is_delivered SMALLINT,
    is_returned SMALLINT,
    is_failed SMALLINT,
    PRIMARY KEY (shipment_sk, booking_date_sk)
) PARTITION BY RANGE (booking_date_sk);

-- Partisi tabel fact_shipment per tahun
CREATE TABLE dwh.fact_shipment_2026 PARTITION OF dwh.fact_shipment
    FOR VALUES FROM (20260101) TO (20270101);

CREATE TABLE dwh.fact_shipment_default PARTITION OF dwh.fact_shipment DEFAULT;

-- Local Prefixed Index untuk optimasi pencarian performa pengiriman & finansial
CREATE INDEX idx_fact_shipment_booking_srv ON dwh.fact_shipment (booking_date_sk, service_type_sk);
CREATE INDEX idx_fact_shipment_dest ON dwh.fact_shipment (destination_location_sk, booking_date_sk);


-- FACT 2: FACT_SHIPMENT_EVENT (Analisis Operasional Hub & Kurir)
-- Dipartisi berdasarkan rentang waktu log_date_sk
CREATE TABLE dwh.fact_shipment_event (
    event_sk BIGSERIAL,
    receipt_number VARCHAR(50) NOT NULL,
    log_date_sk INT NOT NULL REFERENCES dwh.dim_date(date_sk),
    log_time TIME,
    hub_sk INT NOT NULL REFERENCES dwh.dim_hub(hub_sk),
    courier_sk INT NOT NULL REFERENCES dwh.dim_courier(courier_sk),
    status_sk INT NOT NULL REFERENCES dwh.dim_status(status_sk),
    event_count INT DEFAULT 1,
    is_final_success SMALLINT DEFAULT 0,
    is_final_fail SMALLINT DEFAULT 0,
    PRIMARY KEY (event_sk, log_date_sk)
) PARTITION BY RANGE (log_date_sk);

-- Partisi tabel fact_shipment_event per tahun
CREATE TABLE dwh.fact_shipment_event_2026 PARTITION OF dwh.fact_shipment_event
    FOR VALUES FROM (20260101) TO (20270101);

CREATE TABLE dwh.fact_shipment_event_default PARTITION OF dwh.fact_shipment_event DEFAULT;

-- Local Prefixed Index untuk agregasi throughput hub dan kurir
CREATE INDEX idx_fact_event_log_hub ON dwh.fact_shipment_event (log_date_sk, hub_sk);
CREATE INDEX idx_fact_event_log_courier ON dwh.fact_shipment_event (log_date_sk, courier_sk);


-- FACT 3: FACT_CLAIM (Analisis Klaim Ganti Rugi)
CREATE TABLE dwh.fact_claim (
    claim_sk BIGSERIAL PRIMARY KEY,
    claim_id VARCHAR(32) NOT NULL, -- Degenerate dimension
    receipt_number VARCHAR(50) NOT NULL,
    claim_date_sk INT NOT NULL REFERENCES dwh.dim_date(date_sk),
    customer_sk INT NOT NULL REFERENCES dwh.dim_customer(customer_sk),
    status_sk INT NOT NULL REFERENCES dwh.dim_status(status_sk),
    claim_amount NUMERIC(12,2) NOT NULL,
    claim_count INT DEFAULT 1,
    is_approved SMALLINT DEFAULT 0
);

CREATE INDEX idx_fact_claim_date ON dwh.fact_claim (claim_date_sk);
CREATE INDEX idx_fact_claim_resi ON dwh.fact_claim (receipt_number);

