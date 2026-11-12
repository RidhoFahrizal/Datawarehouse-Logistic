### 0. Pengecekan Deskripsi Project dan Master Plan

  Pemeriksaan konsistensi telah dilakukan terhadap berkas arsitektur:

  • Dokumen Master Plan: plan/project-plan.md (Fase 2: Dimensi, Fase 3: Unifikasi Staging, Fase 4: Pemuatan Fakta OLAP).
  • Deskripsi Kebutuhan & Relasi OLAP: Project.md (Bagian F: Star/Galaxy Schema dengan 3 Fact Table & 7 Dimension Table).
  • Data Hulu Operasional (3NF): data/01_init_oltp.sql (Tabel customer, location, service_type, hub, courier, shipment, shipment_status_log, claim).
  • Data Hulu Partner Eksternal: data/partner_shipments.csv (100 baris transaksi mitra, header Indonesia).
  • Skema Target Staging & DWH: data/02_init_staging_dwh.sql (Tabel staging.stg_unified_shipment serta tabel dimensi dan fakta terpartisi di skema dwh).

  Dengan kesepakatan menggunakan arsitektur Streaming In-Memory ETL, data diekstrak dari hulu, dialirkan dan ditransformasikan secara in-memory pada buffer memori Apache Hop, lalu dimuat ke staging terunifikasi dan tabel fakta OLAP
  secara berkesinambungan.
  ──────
  ### 1. Penjelasan Berparagraf

  Pendekatan Streaming In-Memory ETL mengeliminasi kebutuhan penulisan berkas temporer ke media penyimpanan lokal (disk I/O bottleneck) dengan cara memanfaatkan antrean memori internal (row buffer) Apache Hop selama data bergerak dari
  hulu ke hilir. Data diproses melalui tiga kluster aliran utama: Aliran Master Dimensi, Aliran Staging Transaksi Terunifikasi, dan Aliran Pemuatan Tabel Fakta OLAP (Galaxy Schema).

  Seluruh data hulu dipetakan secara terstruktur:

  1. Entitas Master Pelanggan: Data dari oltp.customer dan pengirim unik dari berkas CSV disatukan in-memory, disaring informasi PII sensitifnya, lalu dialirkan ke dwh.dim_customer dengan tipe SCD 1.
  2. Entitas Master Wilayah & Layanan: oltp.location dialirkan ke dwh.dim_location (berperan ganda sebagai asal dan tujuan kirim), sedangkan oltp.service_type dialirkan ke dwh.dim_service_type dengan mekanisme SCD Type 2 untuk melacak
  riwayat perubahan tarif dasar (base rate) dan target SLA.
  3. Entitas Operasional Logistik (Denormalisasi): oltp.hub digabungkan secara in-memory dengan oltp.location untuk membentuk dwh.dim_hub, dan oltp.courier digabungkan dengan data hub untuk membentuk dwh.dim_courier (SCD Type 2),
  lengkap dengan penanganan nilai unknown member (-1).
  4. Entitas Kalender Analitik: Dimensi dwh.dim_date dibangkitkan dari baris tanggal sintetis kalender lengkap dengan integer SK berformat YYYYMMDD.
  5. Entitas Transaksi & Fakta: 100 baris CSV dan 100 baris OLTP shipment disatukan di memori melalui Append Streams, diperkaya dengan derivasi metrik bisnis (margin, delivery_days, is_late), mendarat di staging.stg_unified_shipment,
  kemudian langsung dialirkan ke dwh.fact_shipment setelah lookup surrogate key selesai. Log status pergerakan paket (oltp.shipment_status_log) dialirkan ke dwh.fact_shipment_event, dan data klaim ganti rugi (oltp.claim) dialirkan ke
  dwh.fact_claim.

  #### Inventarisasi Skenario Transformasi (Tercatat: 28 Transformasi)

  1. Delimited text parsing (CSV File Input).
  2. Metadata schema mapping (translasi 13 nama field ID ke EN).
  3. Numeric type casting ke NUMERIC(8,2) dan NUMERIC(12,2).
  4. Date string parsing dari format Indonesia dd/MM/yyyy HH:mm:ss ke ISO Timestamp.
  5. String whitespace trimming pada kode identitas dan status.
  6. Audit constant tagging (source_type = 'CSV').
  7. Audit constant tagging (source_type = 'OLTP').
  8. In-memory stream concatenation via Append Streams.
  9. Financial metric derivation: margin = shipping_fee - estimated_cost.
  10. Operational duration derivation: delivery_days = actual_delivery - booking_date.
  11. SLA evaluation logic: is_late komparasi timestamp tiba terhadap estimasi.
  12. Binary indicator derivation: is_delivered = 1 untuk status DELIVERED.
  13. Binary indicator derivation: is_returned = 1 untuk status RETURNED.
  14. Binary indicator derivation: is_failed = 1 untuk status FAILED.
  15. SLA baseline lookup/mapping berdasarkan service type.
  16. PII stripping (penghapusan alamat jalan, nomor telepon, dan email pelanggan).
  17. Inferred member resolution untuk customer CSV yang belum ada di master OLTP.
  18. Denormalization join hub dengan lokasi kota dan provinsi.
  19. Denormalization join kurir dengan hub penugasan.
  20. SCD Type 2 historization pada dimensi layanan.
  21. SCD Type 2 historization pada dimensi kurir operasional.
  22. Synthetic calendar date generation (year, quarter, month, day, is_weekend).
  23. Unknown member fallback substitution (-1 untuk Hub/Kurir dan 0 untuk Tanggal).
  24. Data Quality filtering: pemastian bobot paket > 0 dan biaya kirim ≥ 0.
  25. Integer Date SK calculation: pembangkitan formula (YYYY * 10000) + (MM * 100) + DD.
  26. Surrogate Key lookups ke 7 tabel dimensi.
  27. Additive measure injection (delivery_count = 1, event_count = 1, claim_count = 1).
  28. Partition-routed table output ke partisi range PostgreSQL fact_shipment_2026 dan fact_shipment_event_2026.
  ──────
  ### 2. Visualisasi CLI

    ========================================================================================================================
                 STREAMING IN-MEMORY ETL ARCHITECTURE: DATA HULU ---> STAGING ---> TARGET OLAP
    ========================================================================================================================
    
     [ SUMBER HULU (OLTP & CSV) ]          [ IN-MEMORY HOP ENGINE TRANSFORM ]              [ TARGET OLAP (DWH SCHEMA) ]
     ----------------------------          ----------------------------------              ----------------------------
    
     [oltp.customer] ──────────┐           (PII Strip, Dedup, Union)
     [partner_shipments.csv] ──┴─────────► [Customer Inferred Resolver] ─────────────────► dwh.dim_customer (SCD 1)
     
     [oltp.location] ────────────────────► [Standardize & Trim] ─────────────────────────► dwh.dim_location (Role-Playing)
     
     [oltp.service_type] ────────────────► [SCD-2 Date Validity Tracker] ────────────────► dwh.dim_service_type (SCD 2)
     
     [oltp.hub] + [oltp.location] ───────► [In-Memory Denormalize + Fallback -1] ────────► dwh.dim_hub (SK: -1 fallback)
     
     [oltp.courier] + [oltp.hub] ────────► [In-Memory Denormalize + SCD-2] ──────────────► dwh.dim_courier (SK: -1 fallback)
     
     (Status Codes & Reasons) ───────────► [Unique Enums Consolidator] ──────────────────► dwh.dim_status
     
     (Synthetic Date Range) ─────────────► [Date Math & YYYYMMDD Derivation] ────────────► dwh.dim_date (SK: 0 fallback)
     
     ----------------------------------------------------------------------------------------------------------------------
     (Transactional Streams)
     
     [partner_shipments.csv] (100) ──┐     [Parse Dates, Cast Types, Map Header] ──┐
                                     │                                             │
     [oltp.shipment] (100) ──────────┼───► [Read Lateral Join Status Log] ─────────┴─► [Append Streams (200)]
                                     │                                                           │
                                     │                                                           ▼
                                     │                                               [Derive Margin & SLA Flags]
                                     │                                                           │
                                     │                                                           ▼
                                     │                                            +-------------------------------+
                                     │                                            | staging.stg_unified_shipment  |
                                     │                                            +-------------------------------+
                                     │                                                           │
                                     │                                                           ▼ (In-Memory SK Lookups)
                                     │                                               [Lookup Date, Cust, Loc, Srv]
                                     │                                                           │
                                     │                                                           ▼
                                     │                                               dwh.fact_shipment (Partisi 2026)
                                     │
     [oltp.shipment_status_log] (440)┴─────────────────────────────────────────────► [Lookup Date, Hub, Cour, Stat]
                                                                                                 │
                                                                                                 ▼
                                                                                     dwh.fact_shipment_event (Partisi 2026)
    
     [oltp.claim] (30) ────────────────────────────────────────────────────────────► [Lookup Date, Customer, Status]
                                                                                                 │
                                                                                                 ▼
                                                                                     dwh.fact_claim (Finance Klaim)
    ========================================================================================================================
  ──────
  ### 3. Penjelasan Visualisasi

  Visualisasi CLI di atas menggambarkan aliran data berkesinambungan tanpa hambatan disk (in-memory streaming):

  1. Aliran Dimensi Master Data: Menyiapkan seluruh tabel acuan. Informasi sensitif dari tabel pelanggan dihilangkan, data geografis hub didenormalisasikan langsung dari tabel lokasi, dan versi tarif layanan dihistorisasikan (SCD 2).
  2. Aliran Staging Transaksi: Menyatukan 100 baris transaksi internal OLTP dan 100 baris berkas CSV mitra di memori Hop menggunakan Append Streams. Setelah dilakukan translasi kolom, perbaikan format tanggal, serta kalkulasi metrik
  margin dan flag SLA, data mendarat bersih di staging.stg_unified_shipment.
  3. Aliran Pemuatan Fakta Dimensional (Galaxy Schema):
      • Data staging dibaca dan langsung ditukar foreign key-nya menjadi surrogate key dimensi (_sk), lalu dimasukkan ke dwh.fact_shipment.
      • Log operasional status paket (oltp.shipment_status_log) diproses langsung menjadi baris fakta granular pada dwh.fact_shipment_event untuk mengukur throughput hub dan kurir.
      • Tabel klaim ganti rugi (oltp.claim) dialirkan langsung menjadi dwh.fact_claim untuk pelaporan kerugian keuangan.

  ──────
  ### 4. Panduan Step-by-Step GUI-ONLY Apache Hop (Hulu hingga OLAP)

  Berikut adalah panduan teknis langkah demi langkah menggunakan antarmuka grafis Apache Hop GUI untuk setiap modul pipeline dari hulu hingga OLAP.
  ──────
  #### MODUL 1: Pipeline Dimensi Master (pipelines/01_dimensions/02_load_dim_customer.hpl)

  ##### 1. Tujuan

  Mengekstrak data master pelanggan dari oltp.customer, menggabungkannya dengan pelanggan baru dari CSV mitra (inferred customer), menyaring informasi PII, dan memuatnya ke dwh.dim_customer (SCD Type 1).

  ##### 2. Persiapan

  • Koneksi CONN_POSTGRES_OLTP dan CONN_POSTGRES_DWH telah terkonfigurasi pada Metadata Perspective.
  • Tabel dwh.dim_customer telah dibuat di database DWH melalui data/02_init_staging_dwh.sql:114-121.

  ##### 3. Tahapan Pembuatan melalui GUI

  1. Membuat Pipeline Baru:
      • Klik menu File → New → Pipeline. Simpan sebagai 02_load_dim_customer.hpl.
  2. Ekstraksi Master Customer OLTP:
      • Tambahkan transformasi Table Input, beri nama: Read OLTP Customer.
      • Konfigurasi: Connection: CONN_POSTGRES_OLTP, SQL:
        SELECT customer_id, customer_name, customer_type, created_at AS registered_at
        FROM oltp.customer WHERE is_deleted = FALSE;

  3. Ekstraksi Inferred Customer dari CSV Mitra:
      • Tambahkan transformasi CSV File Input, beri nama: Read Partner CSV Customer.
      • Browse ke data/partner_shipments.csv, klik Get Fields.
      • Tambahkan transformasi Select Values, hubungkan dari Read Partner CSV Customer, beri nama: Filter CSV Customer Fields.
          • Pilih field: ID_CUSTOMER (rename: customer_id), NAMA_SENDER (rename: customer_name), SEGMEN_PELANGGAN (rename: customer_type).
      • Tambahkan transformasi Sort Rows berdasarkan customer_id, lalu lanjutkan ke Unique Rows agar pelanggan mitra yang muncul berulang kali menjadi unik.
      • Tambahkan transformasi Add Constants, beri nama: Add Registered At Null (field registered_at, Type: Date, Format: yyyy-MM-dd HH:mm:ss, kosongkan value).
  4. Penggabungan Stream Pelanggan (In-Memory Merge):
      • Tambahkan transformasi Append Streams, hubungkan stream OLTP sebagai Head dan stream CSV sebagai Tail.
      • Lanjutkan ke transformasi Sort Rows (customer_id) → Unique Rows (berdasarkan customer_id, ambil baris pertama agar data master OLTP diutamakan daripada data CSV).
  5. Pemuatan Target Dimensi:
      • Tambahkan transformasi Insert / Update, beri nama: Load Dim Customer.
      • Hubungkan ke Insert / Update:
          • Connection: CONN_POSTGRES_DWH, Target schema: dwh, Target table: dim_customer.
          • The key(s) to look up the value(s): customer_id = customer_id.
          • Update fields:
              • customer_id | Update: N
              • customer_name | Update: Y
              • customer_type | Update: Y
              • registered_at | Update: N




  ##### 4. Visualisasi Alur

    [Read OLTP Customer] ────────────────────────────────────────────────────────┐
                                                                                 ▼
    [Read CSV Partner] ──► [Select Fields] ──► [Sort & Unique] ──► [Add Date] ──► [Append Streams] ──► [Dedup] ──► [Load Dim Customer]

  ##### 5. Validasi dan Pengujian

  • Jalankan pipeline di Hop GUI (Run → Launch).
  • Buka tab Transform Metrics: pastikan baris yang tertulis pada Load Dim Customer sesuai jumlah pelanggan unik tanpa error.
  • Validasi query SQL di database DWH:
    SELECT count(*), count(DISTINCT customer_id) FROM dwh.dim_customer;


  ##### 6. Hasil Akhir

  Tabel dwh.dim_customer terisi master pelanggan gabungan internal dan mitra secara idempoten.
  ──────
  #### MODUL 2: Pipeline Dimensi Denormalisasi (pipelines/01_dimensions/05_load_dim_hub.hpl)

  ##### 1. Tujuan

  Mengekstrak master hub dari oltp.hub, melakukan denormalisasi in-memory dengan menggabungkan nama kota dan provinsi dari oltp.location, serta menyuntikkan unknown member fallback (hub_sk = -1) ke dwh.dim_hub.

  ##### 2. Persiapan

  • Tabel dwh.dim_hub telah diinisialisasi melalui data/02_init_staging_dwh.sql:145-153.

  ##### 3. Tahapan Pembuatan melalui GUI

  1. Membuat Pipeline: Menu File → New → Pipeline, simpan sebagai 05_load_dim_hub.hpl.
  2. Ekstraksi Data Hub & Lokasi Hulu:
      • Tambahkan Table Input, beri nama: Read OLTP Hub With Location.
      • Connection: CONN_POSTGRES_OLTP, SQL:
        SELECT 
            h.hub_id,
            h.hub_name,
            l.city_name,
            l.province_name,
            h.capacity_per_day
        FROM oltp.hub h
        JOIN oltp.location l ON h.location_id = l.location_id
        WHERE h.is_deleted = FALSE;

  3. Pembangkitan Integer SK Hub:
      • Tambahkan transformasi Add Sequence, beri nama: Generate Hub SK.
      • Name of value: hub_sk, Start at value: 1, Increment by: 1.
  4. Pemuatan Target Dimensi Hub:
      • Tambahkan Table Output, beri nama: Load Dim Hub.
      • Connection: CONN_POSTGRES_DWH, Target schema: dwh, Target table: dim_hub.
      • Buka tab Database fields, petakan: hub_sk, hub_id, hub_name, city_name, province_name, capacity_per_day.


  ##### 4. Visualisasi Alur

    [Read OLTP Hub With Location] ──► [Generate Hub SK] ──► [Load Dim Hub]

  ##### 5. Validasi dan Pengujian

  • Eksekusi pipeline di Hop GUI.
  • Jalankan kueri verifikasi:
    SELECT * FROM dwh.dim_hub ORDER BY hub_sk;
  Ekspektasi: Baris hub_sk = -1 (Unknown) tetap ada, dan data hub operasional ber-SK positif (1, 2, …) terisi lengkap dengan nama kota dan provinsi.

  ##### 6. Hasil Akhir

  Tabel dwh.dim_hub terisi struktur flat star schema siap pakai.
  ──────
  #### MODUL 3: Pipeline Pemuatan Fakta Pengiriman (pipelines/03_facts/09_load_fact_shipment.hpl)

  ##### 1. Tujuan

  Membaca data bersih dari staging.stg_unified_shipment, melakukan in-memory lookup ke 4 tabel dimensi (dim_date, dim_customer, dim_location, dim_service_type), dan memuat data fakta transaksi ke partisi dwh.fact_shipment_2026.

  ##### 2. Persiapan

  • Pipeline staging 08_stg_unified_shipment.hpl telah selesai dijalankan dan tabel staging terisi 200 baris.
  • Seluruh dimensi conformed (dim_date, dim_customer, dim_location, dim_service_type) telah terisi.

  ##### 3. Tahapan Pembuatan melalui GUI

  1. Membuat Pipeline: Simpan dengan nama 09_load_fact_shipment.hpl.
  2. Membaca Data Staging Terunifikasi:
      • Tambahkan Table Input, beri nama: Read Staging Unified.
      • Connection: CONN_POSTGRES_DWH, SQL: SELECT * FROM staging.stg_unified_shipment;.
  3. Pembangkitan Date SK (In-Memory Math):
      • Tambahkan Calculator, beri nama: Calculate Date SKs.
      • Buat field kalkulasi integer YYYYMMDD:
          • booking_year: Year of Date A (booking_timestamp)
          • booking_month: Month of Date A (booking_timestamp)
          • booking_day: Day of Month of Date A (booking_timestamp)
          • Tambahkan formula atau calculation berikutnya: booking_date_sk = (booking_year * 10000) + (booking_month * 100) + booking_day.
          • Lakukan langkah yang sama untuk estimated_delivery_date_sk dan actual_delivery_date_sk (jika null, gunakan nilai default 0).

  4. Surrogate Key Lookup - Dimensi Pelanggan:
      • Tambahkan Database Lookup, beri nama: Lookup Dim Customer.
      • Hubungkan dari Calculate Date SKs.
      • Lookup table: dwh.dim_customer, Match: customer_id = customer_id, Retrieve: customer_sk (default: 0).
  5. Surrogate Key Lookup - Dimensi Lokasi Asal:
      • Tambahkan Database Lookup, beri nama: Lookup Origin Location.
      • Lookup table: dwh.dim_location, Match: origin_location_id = location_id, Retrieve: location_sk → Rename: origin_location_sk (default: 0).
  6. Surrogate Key Lookup - Dimensi Lokasi Tujuan:
      • Tambahkan Database Lookup, beri nama: Lookup Dest Location.
      • Lookup table: dwh.dim_location, Match: destination_location_id = location_id, Retrieve: location_sk → Rename: destination_location_sk (default: 0).
  7. Surrogate Key Lookup - Dimensi Layanan (SCD Type 2 As-Of):
      • Tambahkan Database Lookup, beri nama: Lookup Dim Service Type SCD2.
      • Lookup table: dwh.dim_service_type.
      • Keys:
          • service_type_id = service_type_id
          • booking_timestamp >= effective_date
          • booking_timestamp <= expiration_date
      • Retrieve: service_type_sk (default: 0).
  8. Injeksi Additive Metric Counter:
      • Tambahkan Add Constants, beri nama: Add Fact Counter.
      • Field: Name: delivery_count, Type: Integer, Value: 1.
  9. Pemuatan Massal ke Tabel Fakta Terpartisi:
      • Tambahkan Table Output, beri nama: Load Fact Shipment.
      • Connection: CONN_POSTGRES_DWH, Target schema: dwh, Target table: fact_shipment.
      • Commit size: 1000, Centang Specify database fields.
      • Klik Enter field mapping → Guess, lalu klik OK.


  ##### 4. Visualisasi Alur

    [Read Staging Unified] ──► [Calculate Date SKs] ──► [Lookup Dim Customer] ──► [Lookup Origin Loc]
                                                                                          │
                                                                                          ▼
    [Load Fact Shipment] ◄── [Add Fact Counter] ◄── [Lookup Service Type SCD2] ◄── [Lookup Dest Loc]

  ##### 5. Validasi dan Pengujian

  • Eksekusi pipeline di Hop GUI.
  • Verifikasi hasil pemuatan pada partisi range PostgreSQL:
    SELECT count(*) FROM dwh.fact_shipment;
    SELECT count(*) FROM dwh.fact_shipment_2026;
  Ekspektasi: Kedua query menghasilkan angka tepat 200 baris tanpa satupun kolom foreign key bernilai NULL.

  ##### 6. Hasil Akhir

  Tabel fakta dwh.fact_shipment terisi data analitik terintegrasi siap saji untuk dasbor COO dan Finance.
  ──────
  #### MODUL 4: Pipeline Fakta Operasional & Log Event (pipelines/03_facts/10_load_fact_shipment_event.hpl)

  ##### 1. Tujuan

  Mengekstrak seluruh status log paket operasional hulu dari oltp.shipment_status_log (440 baris), melakukan in-memory lookup ke dim_hub, dim_courier, dim_status, dan dim_date, lalu memuatnya ke tabel terpartisi
  dwh.fact_shipment_event.

  ##### 2. Persiapan

  • Tabel dwh.dim_hub, dwh.dim_courier, dan dwh.dim_status telah siap di skema dwh.
  • Partisi dwh.fact_shipment_event_2026 telah aktif sesuai data/02_init_staging_dwh.sql:229-255.

  ##### 3. Tahapan Pembuatan melalui GUI

  1. Membuat Pipeline: Simpan dengan nama 10_load_fact_shipment_event.hpl.
  2. Ekstraksi Log Status Operasional:
      • Tambahkan Table Input, beri nama: Read OLTP Status Log.
      • Connection: CONN_POSTGRES_OLTP, SQL:
        SELECT 
            status_log_id,
            receipt_number,
            hub_id,
            courier_id,
            status_code,
            failure_reason,
            log_timestamp,
            log_timestamp::time AS log_time
        FROM oltp.shipment_status_log
        WHERE is_deleted = FALSE;

  3. Pembangkitan Log Date SK:
      • Tambahkan Calculator, beri nama: Calculate Log Date SK.
      • Derivasi integer log_date_sk berformat YYYYMMDD dari log_timestamp.
  4. Lookup Dimensi Hub (Fallback -1):
      • Tambahkan Database Lookup, beri nama: Lookup Hub SK.
      • Table: dwh.dim_hub, Key: hub_id = hub_id, Retrieve: hub_sk, Default: -1.
  5. Lookup Dimensi Kurir (Fallback -1):
      • Tambahkan Database Lookup, beri nama: Lookup Courier SK.
      • Table: dwh.dim_courier, Key: courier_id = courier_id, Retrieve: courier_sk, Default: -1.
  6. Lookup Dimensi Status:
      • Tambahkan Database Lookup, beri nama: Lookup Status SK.
      • Table: dwh.dim_status, Key: status_code = status_code, Retrieve: status_sk, Default: 0.
  7. Injeksi Event Counter & Status Akhir:
      • Tambahkan Formula, beri nama: Derive Final Status Indicators:
          • event_count: 1 (Type: Integer).
          • is_final_success: IF([status_code]="DELIVERED"; 1; 0) (Type: Integer).
          • is_final_fail: IF([status_code]="FAILED"; 1; 0) (Type: Integer).

  8. Pemuatan Massal ke Tabel Fakta Event:
      • Tambahkan Table Output, beri nama: Load Fact Shipment Event.
      • Connection: CONN_POSTGRES_DWH, Target schema: dwh, Target table: fact_shipment_event.
      • Commit size: 1000, petakan seluruh field ke kolom tabel database.


  ##### 4. Visualisasi Alur

    [Read OLTP Status Log] ──► [Calculate Date SK] ──► [Lookup Hub SK (-1)] ──► [Lookup Courier SK (-1)]
                                                                                         │
                                                                                         ▼
    [Load Fact Shipment Event] ◄── [Derive Event Counters] ◄── [Lookup Status SK] ◄──────┘

  ##### 5. Validasi dan Pengujian

  • Jalankan pipeline di Hop GUI.
  • Verifikasi hasil pemuatan pada PostgreSQL:
    SELECT count(*) FROM dwh.fact_shipment_event_2026;
  Ekspektasi: Menghasilkan tepat 440 baris log event operasional.

  ##### 6. Hasil Akhir

  Tabel fakta dwh.fact_shipment_event terisi penuh untuk menjawab kebutuhan dasbor Head of Hub (utilisasi kapasitas hub, produktivitas kurir per armada, dan tingkat kegagalan kirim).
  ──────
  #### MODUL 5: Pipeline Fakta Klaim Ganti Rugi (pipelines/03_facts/11_load_fact_claim.hpl)

  ##### 1. Tujuan

  Mengekstrak data transaksi klaim ganti rugi dari oltp.claim (30 baris), melakukan lookup surrogate key ke dim_date, dim_customer, dan dim_status, lalu memuatnya ke dwh.fact_claim.

  ##### 2. Persiapan

  • Tabel dwh.fact_claim telah diinisialisasi melalui data/02_init_staging_dwh.sql:257-271.

  ##### 3. Tahapan Pembuatan melalui GUI

  1. Membuat Pipeline: Simpan dengan nama 11_load_fact_claim.hpl.
  2. Ekstraksi Data Klaim Hulu:
      • Tambahkan Table Input, beri nama: Read OLTP Claim.
      • Connection: CONN_POSTGRES_OLTP, SQL:
	SELECT 
	    c.claim_id,
	    c.receipt_number,
	    c.claim_date,
	    c.claim_type,
	    c.claim_amount,
	    c.claim_status,
	    s.sender_customer_id AS customer_id
	FROM oltp.claim c
	JOIN oltp.shipment s ON c.receipt_number = s.receipt_number
	WHERE c.is_deleted = FALSE;

  3. Pembangkitan Claim Date SK:
      • Tambahkan Calculator, derivasikan integer claim_date_sk berformat YYYYMMDD dari claim_date.
  4. Surrogate Key Lookups:
      • Tambahkan Database Lookup untuk dwh.dim_customer (retrieve: customer_sk).
      • Tambahkan Database Lookup untuk dwh.dim_status (match: claim_status = status_code, retrieve: status_sk).
  5. Derivasi Flag Klaim Disetujui:
      • Tambahkan Formula, beri nama: Derive Approval Flags:
	  • claim_count: 1 (Type: Integer).
	  • is_approved: IF([claim_status]="APPROVED"; 1; 0) (Type: Integer).

  6. Pemuatan Target Fakta Klaim:
      • Tambahkan Table Output, beri nama: Load Fact Claim.
      • Connection: CONN_POSTGRES_DWH, Target schema: dwh, Target table: fact_claim.
      • Petakan: claim_id, receipt_number, claim_date_sk, customer_sk, status_sk, claim_amount, claim_count, is_approved.


  ##### 4. Visualisasi Alur

    [Read OLTP Claim] ──► [Calc Claim Date SK] ──► [Lookup Customer] ──► [Lookup Status] ──► [Derive Flags] ──► [Load Fact Claim]

  ##### 5. Validasi dan Pengujian

  • Eksekusi pipeline di Hop GUI.
  • Jalankan kueri verifikasi finansial:
    SELECT count(*) AS total_klaim, sum(claim_amount) AS total_nominal, sum(is_approved) AS klaim_disetujui
    FROM dwh.fact_claim;
  Ekspektasi: Menghasilkan tepat 30 baris klaim dengan total nominal dan rasio persetujuan yang valid sesuai data operasional.

  ##### 6. Hasil Akhir

  Tabel dwh.fact_claim terisi penuh untuk mendukung pelaporan analisis risiko finansial dan rasio klaim pada dasbor Finance Manager.
  ──────
  ### 5. Rekomendasi Data Engineer

  1. Atur Ukuran Buffer Memori Antartransformasi:
  Dalam mode Streaming In-Memory ETL, buka dialog Pipeline Properties di Hop GUI (klik area kosong kanvas → ikon roda gerigi) → tab Performance Tuning → atur properti Number of rows in rowset ke 5000 (default: 10000). Nilai ini menjaga
  agar penggunaan memori JVM tetap optimal dan responsif saat menangani proses penggabungan stream serta lookup ganda secara serentak.
  2. Aktifkan Fitur In-Memory Caching pada Database Lookup:
  Pada seluruh transformasi Database Lookup (dim_customer, dim_location, dim_hub, dim_courier, dim_status), buka tab konfigurasi komponen, beri centang pada opsi Enable cache? dan pilih Cache all data in memory. Karena tabel dimensi
  logistik kita berukuran kecil hingga menengah, teknik ini akan memuat seluruh tabel dimensi ke memori RAM sekali di awal, menghilangkan latency bolak-balik koneksi jaringan ke database untuk setiap baris transaksi yang lewat.
  3. Pelihara Idempotensi Pemuatan Massal:
  Untuk pipeline staging terunifikasi (08_stg_unified_shipment.hpl), pertahankan opsi Truncate table. Namun untuk pipeline fakta (fact_shipment), pastikan eksekusi diatur dalam batch per kuartal/tahun sesuai rentang partisi, dan
  hindari menjalankan pemuatan fakta berulang kali tanpa membersihkan partisi target terkait terlebih dahulu guna mencegah penumpukan baris ganda.

