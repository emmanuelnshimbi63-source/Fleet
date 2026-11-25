Transport Fleet Maintenance
DROP SCHEMA IF EXISTS q8_fleet CASCADE;
CREATE SCHEMA q8_fleet;
SET search_path TO q8_fleet;

(a) Tables and vehicles
CREATE TABLE vehicles (
    vehicle_id            SERIAL PRIMARY KEY,
    registration          VARCHAR(20) UNIQUE NOT NULL,
    current_odometer      INT NOT NULL CHECK (current_odometer >= 0),
    last_service_odometer INT NOT NULL CHECK (last_service_odometer >= 0),
    CHECK (last_service_odometer <= current_odometer)
);
CREATE TABLE trips (
    trip_id        SERIAL PRIMARY KEY,
    vehicle_id     INT NOT NULL REFERENCES vehicles(vehicle_id),
    trip_on        DATE NOT NULL,
    start_odometer INT NOT NULL CHECK (start_odometer >= 0),
    end_odometer   INT NOT NULL CHECK (end_odometer >= 0)
);
CREATE TABLE service_alerts (
    vehicle_id       INT PRIMARY KEY REFERENCES vehicles(vehicle_id),
    km_since_service INT NOT NULL,
    flagged_on       DATE NOT NULL
);

INSERT INTO vehicles (registration, current_odometer, last_service_odometer) VALUES
('ZM 001', 20000, 14000),   -- 6000 km since service (due)
('ZM 002', 10000,  8000),   -- 2000 km (not due)
('ZM 003', 15000, 10000);   -- exactly 5000 km (due)

(b) Function: is service due (5000 km or more)?
CREATE FUNCTION fn_service_due(p_vehicle_id INT) RETURNS BOOLEAN AS $$
DECLARE v_km INT;
BEGIN
    SELECT current_odometer - last_service_odometer INTO v_km
    FROM vehicles WHERE vehicle_id = p_vehicle_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown vehicle';
    END IF;
    RETURN v_km >= 5000;
END;
$$ LANGUAGE plpgsql;

SELECT fn_service_due(1), fn_service_due(2), fn_service_due(3);   -- t, f, t

(c) Procedure: record a trip (does NOT touch the odometer)
CREATE PROCEDURE pr_record_trip(p_vehicle_id INT, p_trip_on DATE, p_start INT, p_end INT)
LANGUAGE plpgsql AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM vehicles WHERE vehicle_id = p_vehicle_id) THEN
        RAISE EXCEPTION 'Unknown vehicle';
    END IF;
    IF p_end IS NULL OR p_start IS NULL OR p_end <= p_start THEN
        RAISE EXCEPTION 'End odometer must be greater than start odometer';
    END IF;
    INSERT INTO trips (vehicle_id, trip_on, start_odometer, end_odometer)
    VALUES (p_vehicle_id, p_trip_on, p_start, p_end);
END;
$$;

(d) Trigger: check start, check mileage, update odometer once
CREATE FUNCTION trg_trip_fn() RETURNS TRIGGER AS $$
DECLARE v_current INT;
BEGIN
    SELECT current_odometer INTO v_current
    FROM vehicles WHERE vehicle_id = NEW.vehicle_id;
    IF NEW.start_odometer IS DISTINCT FROM v_current THEN
        RAISE EXCEPTION 'Start odometer must equal current odometer (%)', v_current;
    END IF;
    IF NEW.end_odometer IS NULL OR NEW.end_odometer <= NEW.start_odometer THEN
        RAISE EXCEPTION 'Invalid mileage';
    END IF;
    UPDATE vehicles SET current_odometer = NEW.end_odometer
    WHERE vehicle_id = NEW.vehicle_id;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_trip
BEFORE INSERT ON trips
FOR EACH ROW EXECUTE FUNCTION trg_trip_fn();

(a) continued: 6 trips through the procedure
CALL pr_record_trip(1, '2026-11-10', 20000, 20100);
CALL pr_record_trip(1, '2026-11-12', 20100, 20250);
CALL pr_record_trip(2, '2026-11-11', 10000, 10200);
CALL pr_record_trip(2, '2026-11-13', 10200, 10500);
CALL pr_record_trip(3, '2026-11-14', 15000, 15300);
CALL pr_record_trip(3, '2026-11-16', 15300, 15400);

SELECT * FROM trips;
SELECT * FROM vehicles;     -- 20250, 10500, 15400

-- Error tests: run each line alone
-- CALL pr_record_trip(1, CURRENT_DATE, 20000, 20500);   -- wrong start (trigger)
-- CALL pr_record_trip(1, CURRENT_DATE, 20250, 20250);   -- end not greater
-- CALL pr_record_trip(99, CURRENT_DATE, 0, 10);         -- unknown vehicle

-- (e) View: vehicles due for service
CREATE VIEW v_service_due AS
SELECT registration, current_odometer - last_service_odometer AS km_since_service
FROM vehicles
WHERE current_odometer - last_service_odometer >= 5000;

SELECT * FROM v_service_due;      -- ZM 001 and ZM 003

-- (f) Index: one vehicle's trips in a date range
-- Justification: the query filters vehicle_id (equal) then trip_on (range),
-- so this index finds those trips in date order without reading the whole table.
CREATE INDEX idx_trips_vehicle_date ON trips (vehicle_id, trip_on);

SET enable_seqscan = off;
EXPLAIN SELECT * FROM trips
WHERE vehicle_id = 1 AND trip_on BETWEEN '2026-11-01' AND '2026-11-30';
SET enable_seqscan = on;

(g) Scheduled job: refresh service alerts
CREATE PROCEDURE pr_refresh_service_alerts()
LANGUAGE plpgsql AS $$
BEGIN
    -- add or update an alert for each due vehicle
    INSERT INTO service_alerts (vehicle_id, km_since_service, flagged_on)
    SELECT vehicle_id, current_odometer - last_service_odometer, CURRENT_DATE
    FROM vehicles
    WHERE fn_service_due(vehicle_id)
    ON CONFLICT (vehicle_id) DO UPDATE
    SET km_since_service = EXCLUDED.km_since_service;

    -- remove alerts for vehicles no longer due
    DELETE FROM service_alerts
    WHERE NOT fn_service_due(vehicle_id);
END;
$$;

CALL pr_refresh_service_alerts();
SELECT * FROM service_alerts;      -- vehicles 1 and 3

-- Service vehicle 1, then refresh: its alert is removed
UPDATE vehicles SET last_service_odometer = current_odometer WHERE vehicle_id = 1;
CALL pr_refresh_service_alerts();
SELECT * FROM service_alerts;      -- vehicle 3 only

CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule('refresh_service_alerts', '0 6 * * 1',
    $$CALL q8_fleet.pr_refresh_service_alerts()$$);
SELECT * FROM cron.job;