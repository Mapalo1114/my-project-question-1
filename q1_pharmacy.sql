-- ICT371 Question 1: Pharmacy Stock and Daily Sales (PostgreSQL)
DROP SCHEMA IF EXISTS q1 CASCADE;
CREATE SCHEMA q1;
SET search_path TO q1, public;

-- (a) TABLES -------------------------------------------------------------
CREATE TABLE medicines (
  medicine_id   INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  medicine_name VARCHAR(100) NOT NULL UNIQUE,
  unit_price    NUMERIC(10,2) NOT NULL CHECK (unit_price > 0),
  stock_qty     INT NOT NULL CHECK (stock_qty >= 0)
);

CREATE TABLE sales (
  sale_id     INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  medicine_id INT NOT NULL REFERENCES medicines(medicine_id),
  quantity    INT NOT NULL CHECK (quantity > 0),
  unit_price  NUMERIC(10,2) NOT NULL CHECK (unit_price > 0),  -- price at time of sale
  sold_on     DATE NOT NULL
);

CREATE TABLE stock_audit (
  audit_id    INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  medicine_id INT NOT NULL REFERENCES medicines(medicine_id),
  old_qty     INT NOT NULL,
  new_qty     INT NOT NULL,
  changed_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE daily_sales (
  sales_date   DATE PRIMARY KEY,
  total_qty    INT NOT NULL DEFAULT 0,
  total_amount NUMERIC(12,2) NOT NULL DEFAULT 0
);

-- (b) FUNCTION -----------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_sale_value(p_medicine_id INT, p_quantity INT)
RETURNS NUMERIC AS $$
DECLARE
  v_price NUMERIC;
BEGIN
  IF p_quantity IS NULL OR p_quantity <= 0 THEN
    RAISE EXCEPTION 'Invalid quantity: %', p_quantity;
  END IF;

  SELECT unit_price INTO v_price FROM medicines WHERE medicine_id = p_medicine_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Unknown medicine: %', p_medicine_id;
  END IF;

  RETURN v_price * p_quantity;
END;
$$ LANGUAGE plpgsql STABLE;

-- (c) PROCEDURE ----------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_record_sale(p_medicine_id INT, p_quantity INT, p_sold_on DATE)
AS $$
DECLARE
  v_price NUMERIC;
  v_stock INT;
BEGIN
  IF p_quantity IS NULL OR p_quantity <= 0 THEN
    RAISE EXCEPTION 'Invalid quantity: %', p_quantity;
  END IF;
  IF p_sold_on IS NULL THEN
    RAISE EXCEPTION 'Sale date is required';
  END IF;

  -- lock the row so two sales cannot oversell at the same time
  SELECT unit_price, stock_qty INTO v_price, v_stock
  FROM medicines WHERE medicine_id = p_medicine_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Unknown medicine: %', p_medicine_id;
  END IF;

  IF v_stock < p_quantity THEN
    RAISE EXCEPTION 'Insufficient stock: have %, need %', v_stock, p_quantity;
  END IF;

  INSERT INTO sales (medicine_id, quantity, unit_price, sold_on)
  VALUES (p_medicine_id, p_quantity, v_price, p_sold_on);   -- current price stored

  UPDATE medicines SET stock_qty = stock_qty - p_quantity   -- stock deducted once
  WHERE medicine_id = p_medicine_id;
  -- any exception above rolls back the whole CALL, so both tables stay unchanged
END;
$$ LANGUAGE plpgsql;

-- (d) TRIGGER ------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_fn_stock_audit() RETURNS TRIGGER AS $$
BEGIN
  INSERT INTO stock_audit (medicine_id, old_qty, new_qty)
  VALUES (OLD.medicine_id, OLD.stock_qty, NEW.stock_qty);
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_stock_audit
AFTER UPDATE ON medicines
FOR EACH ROW
WHEN (OLD.stock_qty IS DISTINCT FROM NEW.stock_qty)
EXECUTE FUNCTION trg_fn_stock_audit();

-- (g) PROCEDURE: refresh daily totals ------------------------------------
CREATE OR REPLACE PROCEDURE pr_refresh_sales(p_day DATE)
AS $$
BEGIN
  INSERT INTO daily_sales (sales_date, total_qty, total_amount)
  SELECT p_day, COALESCE(SUM(quantity), 0), COALESCE(SUM(quantity * unit_price), 0)
  FROM sales WHERE sold_on = p_day
  ON CONFLICT (sales_date) DO UPDATE
    SET total_qty    = EXCLUDED.total_qty,        -- replace, never add
        total_amount = EXCLUDED.total_amount;
END;
$$ LANGUAGE plpgsql;

-- (a) SEED DATA: medicines, then six sales through the procedure ----------
INSERT INTO medicines (medicine_name, unit_price, stock_qty) VALUES
  ('Paracetamol 500mg', 5.00, 100),
  ('Amoxicillin 250mg', 12.50, 12),
  ('Ibuprofen 400mg',    8.00, 50),
  ('Coartem',           45.00, 30);

CALL pr_record_sale(1, 10, DATE '2026-11-20');
CALL pr_record_sale(2,  5, DATE '2026-11-20');
CALL pr_record_sale(3,  4, DATE '2026-11-21');
CALL pr_record_sale(4,  2, DATE '2026-11-21');
CALL pr_record_sale(2,  3, DATE '2026-11-22');   -- Amoxicillin: 12 -> 4
CALL pr_record_sale(1,  6, DATE '2026-11-22');

SELECT * FROM medicines ORDER BY medicine_id;
SELECT * FROM sales ORDER BY sale_id;
SELECT * FROM stock_audit ORDER BY audit_id;

-- test (b) and (c) failures (each should raise an error; run one at a time)
-- SELECT fn_sale_value(1, 10);   -- 50.00
-- SELECT fn_sale_value(99, 1);   -- Unknown medicine
-- SELECT fn_sale_value(1, 0);    -- Invalid quantity
-- CALL pr_record_sale(2, 500, DATE '2026-11-23');  -- Insufficient stock, nothing changes

-- (e) VIEW ---------------------------------------------------------------
CREATE OR REPLACE VIEW v_low_stock AS
SELECT medicine_id, medicine_name, unit_price, stock_qty AS remaining_stock
FROM medicines
WHERE stock_qty < 10;

SELECT * FROM v_low_stock;   -- Amoxicillin (4 left) after the sales

-- (f) INDEX --------------------------------------------------------------
-- Equality column first (medicine_id), range column second (sold_on).
CREATE INDEX idx_sales_med_date ON sales (medicine_id, sold_on);

ANALYZE sales;
SET enable_seqscan = off;   -- tiny table: force the planner to show the index
EXPLAIN
SELECT * FROM sales
WHERE medicine_id = 2 AND sold_on BETWEEN DATE '2026-11-20' AND DATE '2026-11-22';
RESET enable_seqscan;
-- Expect: Index Scan / Bitmap Index Scan using idx_sales_med_date

-- (g) TEST AND SCHEDULE --------------------------------------------------
CALL pr_refresh_sales(DATE '2026-11-20');
CALL pr_refresh_sales(DATE '2026-11-20');   -- rerun: same totals
CALL pr_refresh_sales(DATE '2026-11-21');
CALL pr_refresh_sales(DATE '2026-11-22');
SELECT * FROM daily_sales ORDER BY sales_date;
-- Expect: 11-20 -> 15 / 112.50 ; 11-21 -> 6 / 122.00 ; 11-22 -> 9 / 77.50

-- pg_cron: every day at 00:15 for the previous day
CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule('q1_refresh_sales', '15 0 * * *',
  $$CALL q1.pr_refresh_sales(CURRENT_DATE - 1)$$);
