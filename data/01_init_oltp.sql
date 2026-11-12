-- =====================================================================
-- 01_init_oltp.sql
-- Inisialisasi Skema & Tabel DDL Database Operasional (OLTP)
-- Sesuai rancangan oltp.md dan oltp.dbml
-- =====================================================================

CREATE SCHEMA IF NOT EXISTS oltp;
SET search_path TO oltp, public;

-- Drop existing tables jika ada (urutan child ke parent)
DROP TABLE IF EXISTS claim CASCADE;
DROP TABLE IF EXISTS shipment_status_log CASCADE;
DROP TABLE IF EXISTS shipment CASCADE;
DROP TABLE IF EXISTS courier CASCADE;
DROP TABLE IF EXISTS hub CASCADE;
DROP TABLE IF EXISTS service_type CASCADE;
DROP TABLE IF EXISTS location CASCADE;
DROP TABLE IF EXISTS customer CASCADE;

-- 1. Table Customer
CREATE TABLE customer (
    customer_id VARCHAR(32) PRIMARY KEY,
    customer_name VARCHAR(150) NOT NULL,
    customer_type VARCHAR(10) NOT NULL CHECK (customer_type IN ('B2B', 'B2C')),
    phone_number VARCHAR(20) NOT NULL,
    email VARCHAR(100),
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    is_deleted BOOLEAN DEFAULT FALSE
);

-- 2. Table Location
CREATE TABLE location (
    location_id VARCHAR(32) PRIMARY KEY,
    city_name VARCHAR(100) NOT NULL,
    province_name VARCHAR(100) NOT NULL,
    postal_code VARCHAR(10) NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    is_deleted BOOLEAN DEFAULT FALSE
);

-- 3. Table Service Type
CREATE TABLE service_type (
    service_type_id VARCHAR(32) PRIMARY KEY,
    service_name VARCHAR(50) NOT NULL,
    sla_days INT NOT NULL,
    base_rate NUMERIC(12,2) NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    is_deleted BOOLEAN DEFAULT FALSE
);

-- 4. Table Hub
CREATE TABLE hub (
    hub_id VARCHAR(32) PRIMARY KEY,
    hub_name VARCHAR(100) NOT NULL,
    location_id VARCHAR(32) NOT NULL REFERENCES location(location_id),
    capacity_per_day INT NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    is_deleted BOOLEAN DEFAULT FALSE
);

-- 5. Table Courier
CREATE TABLE courier (
    courier_id VARCHAR(32) PRIMARY KEY,
    courier_name VARCHAR(150) NOT NULL,
    vehicle_type VARCHAR(30) NOT NULL CHECK (vehicle_type IN ('Motorcycle', 'Van', 'Truck')),
    hub_id VARCHAR(32) NOT NULL REFERENCES hub(hub_id),
    phone_number VARCHAR(20) NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    is_deleted BOOLEAN DEFAULT FALSE
);

-- 6. Table Shipment
CREATE TABLE shipment (
    receipt_number VARCHAR(50) PRIMARY KEY,
    sender_customer_id VARCHAR(32) NOT NULL REFERENCES customer(customer_id),
    recipient_name VARCHAR(150) NOT NULL,
    recipient_phone VARCHAR(20) NOT NULL,
    recipient_address TEXT NOT NULL,
    origin_location_id VARCHAR(32) NOT NULL REFERENCES location(location_id),
    destination_location_id VARCHAR(32) NOT NULL REFERENCES location(location_id),
    service_type_id VARCHAR(32) NOT NULL REFERENCES service_type(service_type_id),
    package_weight_kg NUMERIC(8,2) NOT NULL CHECK (package_weight_kg > 0),
    shipping_fee NUMERIC(12,2) NOT NULL CHECK (shipping_fee >= 0),
    estimated_cost NUMERIC(12,2) NOT NULL CHECK (estimated_cost >= 0),
    booking_timestamp TIMESTAMP NOT NULL,
    estimated_delivery_date TIMESTAMP NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    is_deleted BOOLEAN DEFAULT FALSE
);

-- 7. Table Shipment Status Log
CREATE TABLE shipment_status_log (
    status_log_id BIGSERIAL PRIMARY KEY,
    receipt_number VARCHAR(50) NOT NULL REFERENCES shipment(receipt_number),
    hub_id VARCHAR(32) REFERENCES hub(hub_id),
    courier_id VARCHAR(32) REFERENCES courier(courier_id),
    status_code VARCHAR(30) NOT NULL CHECK (status_code IN ('PICKUP', 'IN_TRANSIT', 'OUT_FOR_DELIVERY', 'DELIVERED', 'FAILED', 'RETURNED')),
    failure_reason VARCHAR(100),
    log_timestamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    notes TEXT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    is_deleted BOOLEAN DEFAULT FALSE
);

-- 8. Table Claim
CREATE TABLE claim (
    claim_id VARCHAR(32) PRIMARY KEY,
    receipt_number VARCHAR(50) NOT NULL UNIQUE REFERENCES shipment(receipt_number),
    claim_date TIMESTAMP NOT NULL,
    claim_type VARCHAR(20) NOT NULL CHECK (claim_type IN ('LOST', 'DAMAGED')),
    claim_amount NUMERIC(12,2) NOT NULL CHECK (claim_amount >= 0),
    claim_status VARCHAR(20) NOT NULL CHECK (claim_status IN ('SUBMITTED', 'INVESTIGATING', 'APPROVED', 'REJECTED')),
    resolution_notes TEXT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    is_deleted BOOLEAN DEFAULT FALSE
);

-- Index penunjang performa kueri operasional
CREATE INDEX idx_shipment_booking ON shipment (booking_timestamp);
CREATE INDEX idx_shipment_sender ON shipment (sender_customer_id);
CREATE INDEX idx_status_log_receipt ON shipment_status_log (receipt_number);
CREATE INDEX idx_status_log_time ON shipment_status_log (log_timestamp);
