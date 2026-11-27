-- Sample data. Run after 01_schema.sql, once, on an empty schema.
-- All names are fictional. Show dates are relative to today in India (IST),
-- so the 7-day window is always populated on the day you run this.

USE booking_engine;
SET SESSION sql_safe_updates = 0;  -- MySQL Workbench turns this on

-- Theatres are in India: show dates and times are IST (UTC+05:30).
SET @today := DATE(UTC_TIMESTAMP() + INTERVAL 330 MINUTE);

START TRANSACTION;

INSERT INTO theatre (theatre_id, name, city, address) VALUES
    (1, 'Aurora Cineplex',  'Bengaluru', '12 Lake View Road, Indiranagar'),
    (2, 'Meridian Talkies', 'Mumbai',    '48 Harbour Street, Andheri West');

INSERT INTO screen (screen_id, theatre_id, name, screen_type) VALUES
    (1, 1, 'Screen 1', 'DOLBY_ATMOS'),
    (2, 1, 'Screen 2', 'IMAX'),
    (3, 2, 'Screen 1', 'STANDARD');

-- 3 rows x 6 seats per screen. Row B mixes two categories on purpose.
INSERT INTO seat (screen_id, row_label, seat_number, category)
WITH RECURSIVE n (seat_number) AS (
    SELECT 1
    UNION ALL
    SELECT seat_number + 1 FROM n WHERE seat_number < 6
),
r (row_label) AS (
    SELECT 'A' UNION ALL SELECT 'B' UNION ALL SELECT 'C'
)
SELECT s.screen_id,
       r.row_label,
       n.seat_number,
       CASE
           WHEN r.row_label = 'C' THEN 'RECLINER'
           WHEN r.row_label = 'B' AND n.seat_number BETWEEN 2 AND 5 THEN 'GOLD'
           ELSE 'SILVER'
       END
FROM screen s
CROSS JOIN r
CROSS JOIN n
ORDER BY s.screen_id, r.row_label, n.seat_number;

INSERT INTO movie (movie_id, title, duration_min, certificate, release_date) VALUES
    (1, 'The Last Monsoon', 142, 'UA', @today - INTERVAL 14 DAY),
    (2, 'Orbit of Silence', 128, 'UA', @today - INTERVAL 7 DAY),
    (3, 'Chai and Chaos',   118, 'U',  @today - INTERVAL 21 DAY),
    (4, 'Midnight Ledger',  135, 'A',  @today - INTERVAL 3 DAY);

-- The same daily timetable repeated for today and the next 6 days.
INSERT INTO movie_show (screen_id, movie_id, language, format, show_date, start_time)
WITH RECURSIVE d (day_offset) AS (
    SELECT 0
    UNION ALL
    SELECT day_offset + 1 FROM d WHERE day_offset < 6
),
timetable (screen_id, movie_id, language, format, start_time) AS (
              SELECT 1, 1, 'Hindi',   '2D',   '09:30:00'
    UNION ALL SELECT 1, 3, 'Hindi',   '2D',   '13:15:00'
    UNION ALL SELECT 1, 1, 'Hindi',   '2D',   '17:00:00'
    UNION ALL SELECT 1, 4, 'English', '2D',   '20:45:00'
    UNION ALL SELECT 2, 2, 'English', 'IMAX', '10:00:00'
    UNION ALL SELECT 2, 2, 'Hindi',   '3D',   '14:00:00'
    UNION ALL SELECT 2, 2, 'English', 'IMAX', '18:30:00'
    UNION ALL SELECT 2, 1, 'Hindi',   '2D',   '21:15:00'
    UNION ALL SELECT 3, 3, 'Hindi',   '2D',   '11:00:00'
    UNION ALL SELECT 3, 2, 'English', '3D',   '15:00:00'
    UNION ALL SELECT 3, 1, 'Tamil',   '2D',   '19:00:00'
)
SELECT t.screen_id, t.movie_id, t.language, t.format,
       @today + INTERVAL d.day_offset DAY,
       t.start_time
FROM d
CROSS JOIN timetable t
ORDER BY d.day_offset, t.screen_id, t.start_time;

-- Price = category base + format surcharge + evening surcharge.
INSERT INTO show_price (show_id, category, price)
SELECT ms.show_id,
       c.category,
       c.base_price
         + CASE ms.format WHEN 'IMAX' THEN 150 WHEN '3D' THEN 60 ELSE 0 END
         + IF(ms.start_time >= '17:00:00', 40, 0)
FROM movie_show ms
CROSS JOIN (
              SELECT 'SILVER' AS category, 180 AS base_price
    UNION ALL SELECT 'GOLD',     250
    UNION ALL SELECT 'RECLINER', 450
) AS c;

-- Create the inventory: every seat of the show's screen starts free.
INSERT INTO show_seat (show_id, seat_id)
SELECT ms.show_id, s.seat_id
FROM movie_show ms
JOIN seat s ON s.screen_id = ms.screen_id;

INSERT INTO customer (customer_id, name, email, phone) VALUES
    (1, 'Asha Rao',     'asha.rao@example.com',     '+91-90000-00001'),
    (2, 'Vikram Shah',  'vikram.shah@example.com',  '+91-90000-00002'),
    (3, 'Neha Iyer',    'neha.iyer@example.com',    '+91-90000-00003'),
    (4, 'Imran Qureshi','imran.qureshi@example.com','+91-90000-00004');

-- Three bookings on tomorrow's 17:00 show in Screen 1.
SET @show_id := (SELECT show_id FROM movie_show
                 WHERE screen_id = 1 AND show_date = @today + INTERVAL 1 DAY AND start_time = '17:00:00');

INSERT INTO booking
    (booking_id, customer_id, show_id, status, idempotency_key, created_at, expires_at, confirmed_at)
VALUES
    (1, 1, @show_id, 'CONFIRMED', '6f1c2a10-0001-4c8e-9a11-000000000001',
        UTC_TIMESTAMP(3) - INTERVAL 60 MINUTE, UTC_TIMESTAMP(3) - INTERVAL 50 MINUTE, UTC_TIMESTAMP(3) - INTERVAL 57 MINUTE),
    (2, 2, @show_id, 'PENDING',   '6f1c2a10-0002-4c8e-9a11-000000000002',
        UTC_TIMESTAMP(3), UTC_TIMESTAMP(3) + INTERVAL 10 MINUTE, NULL),
    (3, 3, @show_id, 'EXPIRED',   '6f1c2a10-0003-4c8e-9a11-000000000003',
        UTC_TIMESTAMP(3) - INTERVAL 30 MINUTE, UTC_TIMESTAMP(3) - INTERVAL 20 MINUTE, NULL);

-- booking 1: B2, B3 | booking 2: C1, C2 | booking 3: A1 (released)
INSERT INTO booking_seat (booking_id, seat_id, price_paid)
SELECT b.booking_id, s.seat_id, sp.price
FROM (
              SELECT 1 AS booking_id, 'B' AS row_label, 2 AS seat_number
    UNION ALL SELECT 1, 'B', 3
    UNION ALL SELECT 2, 'C', 1
    UNION ALL SELECT 2, 'C', 2
    UNION ALL SELECT 3, 'A', 1
) AS w
JOIN booking b     ON b.booking_id = w.booking_id
JOIN movie_show ms ON ms.show_id = b.show_id
JOIN seat s        ON s.screen_id = ms.screen_id
                  AND s.row_label = w.row_label
                  AND s.seat_number = w.seat_number
JOIN show_price sp ON sp.show_id = b.show_id AND sp.category = s.category
ORDER BY b.booking_id, s.seat_id;

-- Only CONFIRMED and PENDING bookings own inventory.
UPDATE booking b
JOIN booking_seat bs ON bs.booking_id = b.booking_id
JOIN show_seat ss    ON ss.show_id = b.show_id AND ss.seat_id = bs.seat_id
SET ss.booking_seat_id = bs.booking_seat_id,
    ss.version = ss.version + 1
WHERE b.status IN ('CONFIRMED', 'PENDING');

INSERT INTO payment (payment_id, booking_id, provider, provider_payment_id, amount, status)
SELECT p.payment_id, p.booking_id, 'demopay', p.provider_payment_id,
       (SELECT SUM(price_paid) FROM booking_seat bs WHERE bs.booking_id = p.booking_id),
       p.status
FROM (
              SELECT 1 AS payment_id, 1 AS booking_id,
                     'pay_0001' AS provider_payment_id, 'SUCCEEDED' AS status
    UNION ALL SELECT 2, 3, 'pay_0002', 'FAILED'
) AS p;

INSERT INTO webhook_event
    (provider, provider_event_id, provider_payment_id, event_type, payload, processed_at)
VALUES
    ('demopay', 'evt_0001', 'pay_0001', 'payment.succeeded',
        JSON_OBJECT('booking_id', 1, 'payment_id', 'pay_0001'), UTC_TIMESTAMP(3)),
    ('demopay', 'evt_0002', 'pay_0002', 'payment.failed',
        JSON_OBJECT('booking_id', 3, 'payment_id', 'pay_0002'), UTC_TIMESTAMP(3));

COMMIT;

ANALYZE TABLE theatre, screen, seat, movie, movie_show, show_price,
              customer, booking, booking_seat, show_seat, payment, webhook_event;
