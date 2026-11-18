-- =====================================================================
-- 02_fungsi_trigger.sql : aturan bisnis yang dijaga oleh basis data
-- Setiap blok diberi kode aturan dari Business_Rule_Limielle v1.1
-- =====================================================================
SET search_path TO limielle;

-- ---------------------------------------------------------------------
-- [PEL] Pelanggan baru: kode_referral otomatis + royalty card otomatis
-- ---------------------------------------------------------------------
CREATE FUNCTION fn_pelanggan_kode_referral() RETURNS trigger AS $$
BEGIN
    IF NEW.kode_referral IS NULL THEN
        NEW.kode_referral := 'LIM' || lpad(NEW.id_pelanggan::text, 4, '0');
    END IF;
    RETURN NEW;
END $$ LANGUAGE plpgsql;

CREATE TRIGGER trg_pelanggan_kode_referral
BEFORE INSERT ON pelanggan
FOR EACH ROW EXECUTE FUNCTION fn_pelanggan_kode_referral();

CREATE FUNCTION fn_pelanggan_buat_kartu() RETURNS trigger AS $$
BEGIN
    INSERT INTO royalty_card (id_pelanggan) VALUES (NEW.id_pelanggan);
    RETURN NEW;
END $$ LANGUAGE plpgsql;

CREATE TRIGGER trg_pelanggan_buat_kartu
AFTER INSERT ON pelanggan
FOR EACH ROW EXECUTE FUNCTION fn_pelanggan_buat_kartu();

-- id_pengajak hanya boleh diisi sekali (satu teman hanya punya satu pengajak)
CREATE FUNCTION fn_pelanggan_kunci_pengajak() RETURNS trigger AS $$
BEGIN
    IF OLD.id_pengajak IS NOT NULL AND NEW.id_pengajak IS DISTINCT FROM OLD.id_pengajak THEN
        RAISE EXCEPTION 'Pelanggan % sudah terhubung dengan pengajak %', OLD.id_pelanggan, OLD.id_pengajak;
    END IF;
    RETURN NEW;
END $$ LANGUAGE plpgsql;

CREATE TRIGGER trg_pelanggan_kunci_pengajak
BEFORE UPDATE OF id_pengajak ON pelanggan
FOR EACH ROW EXECUTE FUNCTION fn_pelanggan_kunci_pengajak();

-- ---------------------------------------------------------------------
-- [BOK-04/05/06] Time slot
-- buat_time_slot : membuat slot kosong 30 menit sesuai jam buka studio
--   Senin-Jumat 10.00-20.00, Sabtu-Minggu 10.00-21.00
-- pesan_slot     : mengisi slot berurutan sesuai total durasi layanan booking
-- ---------------------------------------------------------------------
CREATE FUNCTION buat_time_slot(p_dari DATE, p_sampai DATE) RETURNS INTEGER AS $$
DECLARE
    v_tgl  DATE;
    v_jam  TIME;
    v_tutup TIME;
    v_n    INTEGER := 0;
BEGIN
    FOR v_tgl IN SELECT d::date FROM generate_series(p_dari, p_sampai, interval '1 day') d LOOP
        v_tutup := CASE WHEN extract(isodow FROM v_tgl) >= 6 THEN TIME '21:00' ELSE TIME '20:00' END;
        v_jam := TIME '10:00';
        WHILE v_jam < v_tutup LOOP
            INSERT INTO time_slot (tanggal, jam_mulai, jam_selesai)
            VALUES (v_tgl, v_jam, v_jam + interval '30 minutes')
            ON CONFLICT (tanggal, jam_mulai) DO NOTHING;
            IF FOUND THEN v_n := v_n + 1; END IF;
            v_jam := v_jam + interval '30 minutes';
        END LOOP;
    END LOOP;
    RETURN v_n;
END $$ LANGUAGE plpgsql;

CREATE FUNCTION pesan_slot(p_booking INTEGER, p_tanggal DATE, p_jam_mulai TIME) RETURNS INTEGER AS $$
DECLARE
    v_durasi  INTEGER;
    v_jumlah  INTEGER;
    v_ada     INTEGER;
    v_kosong  INTEGER;
BEGIN
    SELECT COALESCE(SUM(l.durasi_estimasi), 0) INTO v_durasi
    FROM detail_booking d JOIN layanan l USING (id_layanan)
    WHERE d.id_booking = p_booking;

    IF v_durasi = 0 THEN
        RAISE EXCEPTION 'Booking % belum memiliki layanan (BR: minimal satu DETAIL_BOOKING)', p_booking;
    END IF;
    IF EXISTS (SELECT 1 FROM time_slot WHERE id_booking = p_booking) THEN
        RAISE EXCEPTION 'Booking % sudah memiliki jadwal', p_booking;
    END IF;

    -- jadwal tidak boleh lebih awal dari saat booking dibuat (tidak bisa booking ke masa lalu)
    IF p_tanggal + p_jam_mulai <= (SELECT waktu_pemesanan FROM booking WHERE id_booking = p_booking) THEN
        RAISE EXCEPTION 'Jadwal % % sudah lewat saat booking % dibuat', p_tanggal, p_jam_mulai, p_booking;
    END IF;

    v_jumlah := ceil(v_durasi / 30.0);

    SELECT count(*), count(*) FILTER (WHERE id_booking IS NULL) INTO v_ada, v_kosong
    FROM time_slot
    WHERE tanggal = p_tanggal
      AND jam_mulai >= p_jam_mulai
      AND jam_mulai <  p_jam_mulai + make_interval(mins => v_jumlah * 30);

    IF v_ada < v_jumlah THEN
        RAISE EXCEPTION 'Jadwal % % melewati jam buka studio (butuh % slot)', p_tanggal, p_jam_mulai, v_jumlah;
    END IF;
    IF v_kosong < v_jumlah THEN
        RAISE EXCEPTION 'Time slot % mulai % sudah terisi booking lain', p_tanggal, p_jam_mulai;
    END IF;

    UPDATE time_slot SET id_booking = p_booking
    WHERE tanggal = p_tanggal
      AND jam_mulai >= p_jam_mulai
      AND jam_mulai <  p_jam_mulai + make_interval(mins => v_jumlah * 30);

    RETURN v_jumlah;
END $$ LANGUAGE plpgsql;

-- Slot yang sudah terisi tidak boleh direbut booking lain
CREATE FUNCTION fn_slot_tidak_direbut() RETURNS trigger AS $$
BEGIN
    IF OLD.id_booking IS NOT NULL AND NEW.id_booking IS NOT NULL
       AND NEW.id_booking <> OLD.id_booking THEN
        RAISE EXCEPTION 'Slot % sudah ditempati booking %', OLD.id_slot, OLD.id_booking;
    END IF;
    RETURN NEW;
END $$ LANGUAGE plpgsql;

CREATE TRIGGER trg_slot_tidak_direbut
BEFORE UPDATE OF id_booking ON time_slot
FOR EACH ROW EXECUTE FUNCTION fn_slot_tidak_direbut();

-- ---------------------------------------------------------------------
-- [BOK-07, KNF] Perubahan status booking (tanpa DP)
--   Menunggu Konfirmasi -> Terkonfirmasi / Dibatalkan
--   Terkonfirmasi       -> Selesai / Dibatalkan / Tidak Hadir
--   Dibatalkan          -> slot dilepas agar bisa dipesan orang lain
--   Selesai             -> INVOICE dibuat otomatis dari DETAIL_BOOKING
-- ---------------------------------------------------------------------
CREATE FUNCTION fn_booking_status() RETURNS trigger AS $$
DECLARE
    v_no VARCHAR(20);
BEGIN
    IF NEW.status = OLD.status THEN
        RETURN NEW;
    END IF;

    IF NOT (
        (OLD.status = 'Menunggu Konfirmasi' AND NEW.status IN ('Terkonfirmasi','Dibatalkan')) OR
        (OLD.status = 'Terkonfirmasi'       AND NEW.status IN ('Selesai','Dibatalkan','Tidak Hadir'))
    ) THEN
        RAISE EXCEPTION 'Status booking % tidak boleh berubah dari "%" ke "%"',
            OLD.id_booking, OLD.status, NEW.status;
    END IF;

    IF NEW.status = 'Dibatalkan' THEN
        UPDATE time_slot SET id_booking = NULL WHERE id_booking = NEW.id_booking;
    END IF;

    IF NEW.status = 'Selesai' THEN
        INSERT INTO invoice (id_pelanggan, id_pengguna, id_booking)
        VALUES (NEW.id_pelanggan, NEW.id_pengguna, NEW.id_booking)
        RETURNING no_invoice INTO v_no;

        INSERT INTO detail_invoice (no_invoice, id_layanan, harga, jumlah)
        SELECT v_no, id_layanan, harga_kesepakatan, 1
        FROM detail_booking WHERE id_booking = NEW.id_booking;
    END IF;

    RETURN NEW;
END $$ LANGUAGE plpgsql;

CREATE TRIGGER trg_booking_status
AFTER UPDATE OF status ON booking
FOR EACH ROW EXECUTE FUNCTION fn_booking_status();

-- Layanan booking tidak boleh diubah setelah booking selesai/batal
CREATE FUNCTION fn_detail_booking_kunci() RETURNS trigger AS $$
DECLARE
    v_status VARCHAR(25);
BEGIN
    SELECT status INTO v_status FROM booking
    WHERE id_booking = COALESCE(NEW.id_booking, OLD.id_booking);
    IF v_status IN ('Selesai','Dibatalkan','Tidak Hadir') THEN
        RAISE EXCEPTION 'Layanan pada booking berstatus % tidak dapat diubah', v_status;
    END IF;
    RETURN COALESCE(NEW, OLD);
END $$ LANGUAGE plpgsql;

CREATE TRIGGER trg_detail_booking_kunci
BEFORE INSERT OR UPDATE OR DELETE ON detail_booking
FOR EACH ROW EXECUTE FUNCTION fn_detail_booking_kunci();

-- ---------------------------------------------------------------------
-- [INV, VOU-03] Hitung potongan_voucher dan total_tagihan invoice
--   total_tagihan = SUM(harga x jumlah) - potongan_voucher
--   potongan_voucher = subtotal x nilai_potongan% (dibulatkan ke rupiah)
-- ---------------------------------------------------------------------
CREATE FUNCTION fn_invoice_hitung() RETURNS trigger AS $$
DECLARE
    v_subtotal NUMERIC(12,2);
    v_persen   NUMERIC(5,2);
    v_pemilik  INTEGER;
    v_status   VARCHAR(11);
    v_berlaku  DATE;
BEGIN
    SELECT COALESCE(SUM(harga * jumlah), 0) INTO v_subtotal
    FROM detail_invoice WHERE no_invoice = NEW.no_invoice;

    IF NEW.kode_voucher IS NULL THEN
        NEW.potongan_voucher := 0;
    ELSE
        SELECT nilai_potongan, id_pelanggan, status, berlaku_sampai
        INTO v_persen, v_pemilik, v_status, v_berlaku
        FROM voucher WHERE kode_voucher = NEW.kode_voucher;

        IF TG_OP = 'INSERT' OR NEW.kode_voucher IS DISTINCT FROM OLD.kode_voucher THEN
            IF v_pemilik <> NEW.id_pelanggan THEN
                RAISE EXCEPTION 'Voucher % bukan milik pelanggan %', NEW.kode_voucher, NEW.id_pelanggan;
            END IF;
            IF v_status <> 'Tersedia' THEN
                RAISE EXCEPTION 'Voucher % berstatus % dan tidak dapat dipakai', NEW.kode_voucher, v_status;
            END IF;
            -- [VOU-06] voucher hanya berlaku 1 tahun
            IF NEW.tanggal > v_berlaku THEN
                RAISE EXCEPTION 'Voucher % sudah kedaluwarsa (berlaku sampai %)', NEW.kode_voucher, v_berlaku;
            END IF;
            IF TG_OP = 'UPDATE' AND OLD.status <> 'Belum Lunas' THEN
                RAISE EXCEPTION 'Voucher hanya dapat diterapkan pada invoice yang belum lunas';
            END IF;
        END IF;
        NEW.potongan_voucher := round(v_subtotal * v_persen / 100, 0);
    END IF;

    NEW.total_tagihan := v_subtotal - NEW.potongan_voucher;
    RETURN NEW;
END $$ LANGUAGE plpgsql;

CREATE TRIGGER trg_invoice_hitung
BEFORE INSERT OR UPDATE ON invoice
FOR EACH ROW EXECUTE FUNCTION fn_invoice_hitung();

-- Voucher yang diterapkan berubah menjadi Terpakai
CREATE FUNCTION fn_invoice_pakai_voucher() RETURNS trigger AS $$
BEGIN
    IF NEW.kode_voucher IS NOT NULL AND
       (TG_OP = 'INSERT' OR NEW.kode_voucher IS DISTINCT FROM OLD.kode_voucher) THEN
        UPDATE voucher SET status = 'Terpakai' WHERE kode_voucher = NEW.kode_voucher;
    END IF;
    RETURN NEW;
END $$ LANGUAGE plpgsql;

CREATE TRIGGER trg_invoice_pakai_voucher
AFTER INSERT OR UPDATE OF kode_voucher ON invoice
FOR EACH ROW EXECUTE FUNCTION fn_invoice_pakai_voucher();

-- Perubahan rincian invoice menghitung ulang total (dilarang jika sudah lunas/batal)
CREATE FUNCTION fn_detail_invoice_ubah() RETURNS trigger AS $$
DECLARE
    v_no     VARCHAR(20) := COALESCE(NEW.no_invoice, OLD.no_invoice);
    v_status VARCHAR(12);
BEGIN
    SELECT status INTO v_status FROM invoice WHERE no_invoice = v_no;
    IF v_status <> 'Belum Lunas' THEN
        RAISE EXCEPTION 'Rincian invoice % (status %) tidak dapat diubah', v_no, v_status;
    END IF;
    UPDATE invoice SET no_invoice = no_invoice WHERE no_invoice = v_no;   -- memicu hitung ulang
    RETURN NULL;
END $$ LANGUAGE plpgsql;

CREATE TRIGGER trg_detail_invoice_ubah
AFTER INSERT OR UPDATE OR DELETE ON detail_invoice
FOR EACH ROW EXECUTE FUNCTION fn_detail_invoice_ubah();

-- ---------------------------------------------------------------------
-- [BYR-02..04] Pembayaran
--   total pembayaran tidak boleh melebihi total_tagihan
--   invoice otomatis Lunas jika total pembayaran = total_tagihan
-- ---------------------------------------------------------------------
CREATE FUNCTION fn_pembayaran_cek() RETURNS trigger AS $$
DECLARE
    v_total  NUMERIC(12,2);
    v_status VARCHAR(12);
    v_sudah  NUMERIC(12,2);
BEGIN
    SELECT total_tagihan, status INTO v_total, v_status
    FROM invoice WHERE no_invoice = NEW.no_invoice FOR UPDATE;

    IF v_status <> 'Belum Lunas' THEN
        RAISE EXCEPTION 'Invoice % berstatus %, tidak menerima pembayaran', NEW.no_invoice, v_status;
    END IF;

    SELECT COALESCE(SUM(jumlah_bayar), 0) INTO v_sudah
    FROM pembayaran WHERE no_invoice = NEW.no_invoice AND status = 'Diterima';

    IF NEW.status = 'Diterima' AND v_sudah + NEW.jumlah_bayar > v_total THEN
        RAISE EXCEPTION 'Pembayaran melebihi tagihan invoice % (tagihan %, sudah dibayar %, dibayar sekarang %)',
            NEW.no_invoice, v_total, v_sudah, NEW.jumlah_bayar;
    END IF;
    RETURN NEW;
END $$ LANGUAGE plpgsql;

CREATE TRIGGER trg_pembayaran_cek
BEFORE INSERT ON pembayaran
FOR EACH ROW EXECUTE FUNCTION fn_pembayaran_cek();

CREATE FUNCTION fn_pembayaran_lunas() RETURNS trigger AS $$
DECLARE
    v_total NUMERIC(12,2);
    v_sudah NUMERIC(12,2);
BEGIN
    SELECT total_tagihan INTO v_total FROM invoice WHERE no_invoice = NEW.no_invoice;
    SELECT COALESCE(SUM(jumlah_bayar), 0) INTO v_sudah
    FROM pembayaran WHERE no_invoice = NEW.no_invoice AND status = 'Diterima';

    IF v_sudah = v_total AND v_total > 0 THEN
        UPDATE invoice SET status = 'Lunas' WHERE no_invoice = NEW.no_invoice;
    END IF;
    RETURN NULL;
END $$ LANGUAGE plpgsql;

CREATE TRIGGER trg_pembayaran_lunas
AFTER INSERT ON pembayaran
FOR EACH ROW EXECUTE FUNCTION fn_pembayaran_lunas();

-- Pembayaran yang sudah tercatat tidak boleh diubah isinya; koreksi dilakukan
-- dengan membatalkan (status Dibatalkan) lalu mencatat pembayaran baru.
-- Pembatalan hanya boleh selama invoice Belum Lunas, karena invoice Lunas sudah
-- memicu kunjungan royalty card dan voucher referral (status Lunas bersifat final).
CREATE FUNCTION fn_pembayaran_ubah() RETURNS trigger AS $$
DECLARE
    v_status VARCHAR(12);
BEGIN
    IF NEW.no_invoice IS DISTINCT FROM OLD.no_invoice
       OR NEW.jumlah_bayar IS DISTINCT FROM OLD.jumlah_bayar
       OR NEW.metode_pembayaran IS DISTINCT FROM OLD.metode_pembayaran
       OR NEW.tanggal_bayar IS DISTINCT FROM OLD.tanggal_bayar THEN
        RAISE EXCEPTION 'Pembayaran % tidak boleh diubah; batalkan lalu catat pembayaran baru', OLD.id_pembayaran;
    END IF;

    IF NEW.status IS DISTINCT FROM OLD.status THEN
        IF NOT (OLD.status = 'Diterima' AND NEW.status = 'Dibatalkan') THEN
            RAISE EXCEPTION 'Status pembayaran tidak boleh berubah dari "%" ke "%"', OLD.status, NEW.status;
        END IF;
        SELECT status INTO v_status FROM invoice WHERE no_invoice = OLD.no_invoice;
        IF v_status <> 'Belum Lunas' THEN
            RAISE EXCEPTION 'Invoice % sudah %, pembayarannya tidak dapat dibatalkan', OLD.no_invoice, v_status;
        END IF;
    END IF;
    RETURN NEW;
END $$ LANGUAGE plpgsql;

CREATE TRIGGER trg_pembayaran_ubah
BEFORE UPDATE ON pembayaran
FOR EACH ROW EXECUTE FUNCTION fn_pembayaran_ubah();

-- ---------------------------------------------------------------------
-- [LOY-02, REF-02/03] Saat invoice menjadi Lunas:
--   1. jumlah_kunjungan royalty card pelanggan bertambah 1
--   2. jika pelanggan diajak orang lain dan total_tagihan > Rp100.000,
--      pengajak mendapat 1 voucher 10% (paling banyak 1 voucher per invoice)
--      yang berlaku 1 tahun sejak tanggal transaksi pemicu [VOU-04]
-- [LOY-05] Setelah kunjungan ke-10 kunjungan tetap dihitung, tetapi tidak
--          ada penghargaan lagi (penghargaan dibaca dari jumlah_kunjungan)
-- ---------------------------------------------------------------------
CREATE FUNCTION fn_invoice_lunas() RETURNS trigger AS $$
DECLARE
    v_pengajak INTEGER;
BEGIN
    IF NEW.status = 'Lunas' AND OLD.status <> 'Lunas' THEN
        UPDATE royalty_card SET jumlah_kunjungan = jumlah_kunjungan + 1
        WHERE id_pelanggan = NEW.id_pelanggan;

        SELECT id_pengajak INTO v_pengajak FROM pelanggan WHERE id_pelanggan = NEW.id_pelanggan;
        IF v_pengajak IS NOT NULL AND NEW.total_tagihan > 100000 THEN
            INSERT INTO voucher (kode_voucher, id_pelanggan, no_invoice_pemicu, nilai_potongan, berlaku_sampai)
            VALUES ('REF-' || NEW.no_invoice, v_pengajak, NEW.no_invoice, 10,
                    (NEW.tanggal + interval '1 year')::date);
        END IF;
    END IF;

    IF OLD.status = 'Lunas' AND NEW.status <> 'Lunas' THEN
        RAISE EXCEPTION 'Invoice % sudah lunas dan tidak dapat diubah statusnya', NEW.no_invoice;
    END IF;
    RETURN NULL;
END $$ LANGUAGE plpgsql;

CREATE TRIGGER trg_invoice_lunas
AFTER UPDATE OF status ON invoice
FOR EACH ROW EXECUTE FUNCTION fn_invoice_lunas();

-- ---------------------------------------------------------------------
-- [STK-02/03] Mutasi stok memperbarui jumlah_stok barang
-- ---------------------------------------------------------------------
CREATE FUNCTION fn_mutasi_stok() RETURNS trigger AS $$
BEGIN
    UPDATE barang
    SET jumlah_stok = jumlah_stok + CASE NEW.jenis WHEN 'Keluar' THEN -NEW.jumlah ELSE NEW.jumlah END
    WHERE id_barang = NEW.id_barang;     -- CHECK jumlah_stok >= 0 menolak stok minus
    RETURN NULL;
END $$ LANGUAGE plpgsql;

CREATE TRIGGER trg_mutasi_stok
AFTER INSERT ON mutasi_stok
FOR EACH ROW EXECUTE FUNCTION fn_mutasi_stok();

-- ---------------------------------------------------------------------
-- [DAT-02] Data transaksi tidak dihapus permanen; pembatalan lewat status
-- ---------------------------------------------------------------------
CREATE FUNCTION fn_larang_hapus() RETURNS trigger AS $$
BEGIN
    RAISE EXCEPTION 'Data % tidak boleh dihapus; ubah statusnya menjadi Dibatalkan', TG_TABLE_NAME;
END $$ LANGUAGE plpgsql;

CREATE TRIGGER trg_larang_hapus_booking    BEFORE DELETE ON booking    FOR EACH ROW EXECUTE FUNCTION fn_larang_hapus();
CREATE TRIGGER trg_larang_hapus_invoice    BEFORE DELETE ON invoice    FOR EACH ROW EXECUTE FUNCTION fn_larang_hapus();
CREATE TRIGGER trg_larang_hapus_pembayaran BEFORE DELETE ON pembayaran FOR EACH ROW EXECUTE FUNCTION fn_larang_hapus();
CREATE TRIGGER trg_larang_hapus_mutasi     BEFORE DELETE ON mutasi_stok FOR EACH ROW EXECUTE FUNCTION fn_larang_hapus();

-- ---------------------------------------------------------------------
-- [INV-03] Fungsi bantu: invoice walk-in (tanpa booking) sekaligus rinciannya
--   contoh: SELECT buat_invoice_walkin(9, DATE '2026-11-04', ARRAY[7,1], ARRAY[30000,70000]);
-- ---------------------------------------------------------------------
CREATE FUNCTION buat_invoice_walkin(p_pelanggan INTEGER, p_tanggal DATE,
                                    p_layanan INTEGER[], p_harga NUMERIC[],
                                    p_jumlah INTEGER[] DEFAULT NULL,
                                    p_pengguna INTEGER DEFAULT 1)
RETURNS VARCHAR AS $$
DECLARE
    v_no VARCHAR(20);
BEGIN
    IF array_length(p_layanan, 1) IS DISTINCT FROM array_length(p_harga, 1) THEN
        RAISE EXCEPTION 'Jumlah layanan dan harga tidak sama';
    END IF;
    INSERT INTO invoice (id_pelanggan, id_pengguna, tanggal)
    VALUES (p_pelanggan, p_pengguna, p_tanggal)
    RETURNING no_invoice INTO v_no;

    INSERT INTO detail_invoice (no_invoice, id_layanan, harga, jumlah)
    SELECT v_no, l, h, COALESCE(p_jumlah[i], 1)
    FROM unnest(p_layanan, p_harga) WITH ORDINALITY AS t(l, h, i);
    RETURN v_no;
END $$ LANGUAGE plpgsql;

-- [VOU-06] Menandai voucher yang sudah lewat masa berlaku sebagai Kedaluwarsa.
--   Dijalankan berkala (mis. setiap hari), contoh: SELECT tandai_voucher_kedaluwarsa();
--   Tanpa fungsi ini pun voucher lewat masa berlaku tetap ditolak saat dipakai.
CREATE FUNCTION tandai_voucher_kedaluwarsa(p_tanggal DATE DEFAULT current_date) RETURNS INTEGER AS $$
DECLARE
    v_n INTEGER;
BEGIN
    UPDATE voucher SET status = 'Kedaluwarsa'
    WHERE status = 'Tersedia' AND berlaku_sampai < p_tanggal;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    RETURN v_n;
END $$ LANGUAGE plpgsql;

-- Fungsi bantu: no_invoice dari sebuah booking
CREATE FUNCTION invoice_booking(p_booking INTEGER) RETURNS VARCHAR AS $$
    SELECT no_invoice FROM limielle.invoice WHERE id_booking = p_booking;
$$ LANGUAGE sql STABLE;
