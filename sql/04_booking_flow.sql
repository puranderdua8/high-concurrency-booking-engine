-- Locking strategy: hold, pay (webhook), expire. Run after 02_seed.sql.
-- Part 1 creates the procedures and the expiry event.
-- Part 2 is a demonstration that exercises them.
--
-- Lock order everywhere: booking row first, then show_seat rows by seat_id.
-- Callers should retry a transaction that fails with deadlock error 1213.
--
-- Time: DATETIME columns hold UTC. Show times are IST (UTC+05:30).
--
-- Transactions: each procedure runs its own. Call it with no transaction open
-- (with autocommit off, COMMIT first). Otherwise it fails with error 1568 and
-- leaves the caller's transaction untouched.

USE booking_engine;
SET SESSION sql_safe_updates = 0;  -- MySQL Workbench turns this on

DROP EVENT     IF EXISTS ev_expire_holds;
DROP PROCEDURE IF EXISTS sp_hold_seats;
DROP PROCEDURE IF EXISTS sp_expire_holds;
DROP PROCEDURE IF EXISTS sp_payment_webhook;

DELIMITER $$

-- ---------------------------------------------------------------------------
-- Hold seats for 10 minutes (all requested seats, or none).
-- p_seat_ids: JSON array of seat ids, e.g. '[7, 8]'.
-- p_result  : HELD | SEATS_UNAVAILABLE | SHOW_CLOSED | INVALID_REQUEST
--             | DUPLICATE_REQUEST | KEY_CONFLICT
-- ---------------------------------------------------------------------------
CREATE PROCEDURE sp_hold_seats(
    IN  p_customer_id     BIGINT UNSIGNED,
    IN  p_show_id         INT UNSIGNED,
    IN  p_seat_ids        JSON,
    IN  p_idempotency_key CHAR(36),
    OUT p_booking_id      BIGINT UNSIGNED,
    OUT p_result          VARCHAR(30)
)
proc: BEGIN
    DECLARE v_requested INT DEFAULT 0;
    DECLARE v_priced    INT DEFAULT 0;
    DECLARE v_claimed   INT DEFAULT 0;
    DECLARE v_duplicate BOOLEAN DEFAULT FALSE;
    DECLARE v_valid     INT DEFAULT 0;
    DECLARE v_started   BOOLEAN DEFAULT FALSE;

    -- Roll back only our own transaction, never the caller's.
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        IF v_started THEN ROLLBACK; END IF;
        RESIGNAL;
    END;

    SET p_booking_id = NULL;

    -- The request must be an array of 1 to 10 positive integers.
    IF IFNULL(JSON_TYPE(p_seat_ids), '') <> 'ARRAY'
       OR JSON_LENGTH(p_seat_ids) NOT BETWEEN 1 AND 10 THEN
        SET p_result = 'INVALID_REQUEST';
        LEAVE proc;
    END IF;

    SELECT COUNT(*), COUNT(DISTINCT CAST(j.item AS UNSIGNED))
      INTO v_valid, v_requested
    FROM JSON_TABLE(p_seat_ids, '$[*]' COLUMNS (item JSON PATH '$')) AS j
    WHERE JSON_TYPE(j.item) IN ('INTEGER', 'UNSIGNED INTEGER')
      AND CAST(j.item AS SIGNED) BETWEEN 1 AND 4294967295;

    IF v_valid <> JSON_LENGTH(p_seat_ids) THEN
        SET p_result = 'INVALID_REQUEST';
        LEAVE proc;
    END IF;

    -- Free this show's timed-out holds now, without waiting for the event.
    -- It also fails here if the caller has a transaction open.
    CALL sp_expire_holds(500, p_show_id);

    SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
    START TRANSACTION;
    SET v_started = TRUE;

    -- A retried request hits the unique idempotency key.
    BEGIN
        DECLARE CONTINUE HANDLER FOR 1062 SET v_duplicate = TRUE;
        INSERT INTO booking (customer_id, show_id, idempotency_key, expires_at)
        VALUES (p_customer_id, p_show_id, p_idempotency_key,
                UTC_TIMESTAMP(3) + INTERVAL 10 MINUTE);
    END;

    IF v_duplicate THEN
        ROLLBACK;
        SET p_booking_id = (SELECT booking_id FROM booking
                            WHERE idempotency_key = p_idempotency_key
                              AND customer_id = p_customer_id
                              AND show_id = p_show_id);
        SET p_result = IF(p_booking_id IS NULL, 'KEY_CONFLICT', 'DUPLICATE_REQUEST');
        COMMIT; -- ends the read when autocommit is off
        LEAVE proc;
    END IF;

    SET p_booking_id = LAST_INSERT_ID();

    IF NOT EXISTS (SELECT 1 FROM movie_show
                   WHERE show_id = p_show_id
                     AND TIMESTAMP(show_date, start_time)
                         > UTC_TIMESTAMP() + INTERVAL 330 MINUTE) THEN
        ROLLBACK;
        SET p_booking_id = NULL;
        SET p_result = 'SHOW_CLOSED';
        LEAVE proc;
    END IF;

    INSERT INTO booking_seat (booking_id, seat_id, price_paid)
    SELECT p_booking_id, s.seat_id, sp.price
    FROM (SELECT DISTINCT seat_id
          FROM JSON_TABLE(p_seat_ids, '$[*]'
               COLUMNS (seat_id INT UNSIGNED PATH '$')) AS j) AS req
    JOIN seat s        ON s.seat_id = req.seat_id
    JOIN show_price sp ON sp.show_id = p_show_id AND sp.category = s.category
    ORDER BY s.seat_id;
    SET v_priced = ROW_COUNT();

    -- THE critical statement. It takes an exclusive lock on each inventory row
    -- and claims it only if it is still free. A competing transaction waits for
    -- the lock, re-reads the row, sees it taken and changes nothing.
    UPDATE booking_seat bs
    STRAIGHT_JOIN show_seat ss
           ON ss.show_id = p_show_id AND ss.seat_id = bs.seat_id
    SET ss.booking_seat_id = bs.booking_seat_id,
        ss.version         = ss.version + 1
    WHERE bs.booking_id = p_booking_id
      AND ss.booking_seat_id IS NULL;
    SET v_claimed = ROW_COUNT();

    IF v_priced <> v_requested OR v_claimed <> v_requested THEN
        ROLLBACK;
        SET p_booking_id = NULL;
        SET p_result = 'SEATS_UNAVAILABLE';
    ELSE
        COMMIT;
        SET p_result = 'HELD';
    END IF;
END$$

-- ---------------------------------------------------------------------------
-- Release holds whose timer has run out, for one show or (NULL) all shows.
-- Safe to run from many workers: SKIP LOCKED passes over bookings that a
-- payment is confirming right now.
-- ---------------------------------------------------------------------------
CREATE PROCEDURE sp_expire_holds(IN p_batch INT, IN p_show_id INT UNSIGNED)
BEGIN
    DECLARE v_started BOOLEAN DEFAULT FALSE;

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        IF v_started THEN ROLLBACK; END IF;
        RESIGNAL;
    END;

    CREATE TEMPORARY TABLE IF NOT EXISTS tmp_expired (
        booking_id BIGINT UNSIGNED PRIMARY KEY
    );

    SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
    START TRANSACTION;
    SET v_started = TRUE;

    DELETE FROM tmp_expired;

    INSERT INTO tmp_expired (booking_id)
    SELECT booking_id
    FROM booking
    WHERE status = 'PENDING' AND expires_at <= UTC_TIMESTAMP(3)
      AND (p_show_id IS NULL OR show_id = p_show_id)
    ORDER BY expires_at
    LIMIT p_batch
    FOR UPDATE SKIP LOCKED;

    UPDATE tmp_expired e
    STRAIGHT_JOIN booking_seat bs ON bs.booking_id = e.booking_id
    STRAIGHT_JOIN show_seat ss    ON ss.booking_seat_id = bs.booking_seat_id
    SET ss.booking_seat_id = NULL,
        ss.version         = ss.version + 1;

    UPDATE tmp_expired e
    STRAIGHT_JOIN booking b ON b.booking_id = e.booking_id
    SET b.status = 'EXPIRED';

    COMMIT;
END$$

-- ---------------------------------------------------------------------------
-- Idempotent payment webhook. The caller must verify the provider's signature
-- before calling. Everything below is one transaction, so a crash leaves no
-- trace and the provider's retry is processed normally.
-- p_event_type: payment.succeeded | payment.failed | refund.processed
-- p_result    : CONFIRMED | CONFIRMED_LATE | REFUND_REQUIRED | AMOUNT_MISMATCH
--             | PAYMENT_FAILED | REFUNDED | PARTIAL_REFUND | OUT_OF_ORDER
--             | ALREADY_APPLIED | DUPLICATE_EVENT | UNKNOWN_BOOKING
--             | PAYMENT_CONFLICT | IGNORED
-- UNKNOWN_BOOKING, PAYMENT_CONFLICT and OUT_OF_ORDER record nothing: answer
-- the provider with an error so that it delivers the event again.
-- ---------------------------------------------------------------------------
CREATE PROCEDURE sp_payment_webhook(
    IN  p_provider            VARCHAR(30),
    IN  p_event_id            VARCHAR(100),
    IN  p_event_type          VARCHAR(50),
    IN  p_booking_id          BIGINT UNSIGNED,
    IN  p_provider_payment_id VARCHAR(100),
    IN  p_amount              DECIMAL(10,2),
    IN  p_payload             JSON,
    OUT p_result              VARCHAR(30)
)
proc: BEGIN
    DECLARE v_duplicate      BOOLEAN DEFAULT FALSE;
    DECLARE v_booking_status VARCHAR(20);
    DECLARE v_show_id        INT UNSIGNED;
    DECLARE v_payment_id     BIGINT UNSIGNED;
    DECLARE v_pay_booking    BIGINT UNSIGNED;
    DECLARE v_pay_status     VARCHAR(20);
    DECLARE v_amount_due     DECIMAL(10,2);
    DECLARE v_seat_count     INT;
    DECLARE v_claimed        INT;
    DECLARE v_pay_amount     DECIMAL(10,2);
    DECLARE v_started        BOOLEAN DEFAULT FALSE;

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        IF v_started THEN ROLLBACK; END IF;
        RESIGNAL;
    END;

    SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
    START TRANSACTION;
    SET v_started = TRUE;

    -- Step 1: record the event. A second delivery blocks here until the first
    -- commits, then gets a duplicate key error and does nothing.
    BEGIN
        DECLARE CONTINUE HANDLER FOR 1062 SET v_duplicate = TRUE;
        INSERT INTO webhook_event (provider, provider_event_id, event_type, payload)
        VALUES (p_provider, p_event_id, p_event_type, p_payload);
    END;

    IF v_duplicate THEN
        ROLLBACK;
        SET p_result = 'DUPLICATE_EVENT';
        LEAVE proc;
    END IF;

    -- Event types we do not handle are recorded and change nothing else.
    IF p_event_type NOT IN ('payment.succeeded', 'payment.failed', 'refund.processed') THEN
        UPDATE webhook_event SET processed_at = UTC_TIMESTAMP(3)
        WHERE provider = p_provider AND provider_event_id = p_event_id;
        COMMIT;
        SET p_result = 'IGNORED';
        LEAVE proc;
    END IF;

    -- Step 2: lock the booking (serialises against the expiry sweeper).
    BEGIN
        DECLARE CONTINUE HANDLER FOR NOT FOUND BEGIN END;
        SELECT status, show_id INTO v_booking_status, v_show_id
        FROM booking WHERE booking_id = p_booking_id FOR UPDATE;
    END;

    IF v_booking_status IS NULL THEN
        ROLLBACK;
        SET p_result = 'UNKNOWN_BOOKING';
        LEAVE proc;
    END IF;

    -- Step 3: find or create the payment attempt.
    INSERT INTO payment (booking_id, provider, provider_payment_id, amount)
    VALUES (p_booking_id, p_provider, p_provider_payment_id, p_amount)
    ON DUPLICATE KEY UPDATE payment_id = LAST_INSERT_ID(payment_id);
    SET v_payment_id = LAST_INSERT_ID();

    SELECT booking_id, status, amount INTO v_pay_booking, v_pay_status, v_pay_amount
    FROM payment WHERE payment_id = v_payment_id FOR UPDATE;

    IF v_pay_booking <> p_booking_id THEN
        ROLLBACK;
        SET p_result = 'PAYMENT_CONFLICT';
        LEAVE proc;
    END IF;

    -- A refund that overtakes its success event must be delivered again.
    IF p_event_type = 'refund.processed' AND v_pay_status IN ('INITIATED', 'FAILED') THEN
        ROLLBACK;
        SET p_result = 'OUT_OF_ORDER';
        LEAVE proc;
    END IF;

    UPDATE webhook_event
    SET provider_payment_id = p_provider_payment_id, processed_at = UTC_TIMESTAMP(3)
    WHERE provider = p_provider AND provider_event_id = p_event_id;

    -- Step 4: apply the event. Status only ever moves forward.
    IF p_event_type = 'payment.failed' THEN
        -- The hold stays until it expires, so the customer can retry.
        UPDATE payment SET status = 'FAILED'
        WHERE payment_id = v_payment_id AND status = 'INITIATED';
        SET p_result = IF(ROW_COUNT() = 1, 'PAYMENT_FAILED', 'ALREADY_APPLIED');

    ELSEIF p_event_type = 'refund.processed' THEN
        IF v_pay_status = 'REFUNDED' THEN
            SET p_result = 'ALREADY_APPLIED';
        ELSEIF p_amount <> v_pay_amount THEN
            -- Only full refunds are supported; the event is kept for review.
            SET p_result = 'PARTIAL_REFUND';
        ELSE
            IF v_pay_status = 'SUCCEEDED' AND v_booking_status = 'CONFIRMED' THEN
                -- The payment that paid for the booking was refunded: free the seats.
                UPDATE booking_seat bs
                STRAIGHT_JOIN show_seat ss ON ss.booking_seat_id = bs.booking_seat_id
                SET ss.booking_seat_id = NULL, ss.version = ss.version + 1
                WHERE bs.booking_id = p_booking_id;
                UPDATE booking SET status = 'CANCELLED' WHERE booking_id = p_booking_id;
            END IF;
            UPDATE payment SET status = 'REFUNDED' WHERE payment_id = v_payment_id;
            SET p_result = 'REFUNDED';
        END IF;

    ELSEIF p_event_type = 'payment.succeeded' THEN
        SELECT SUM(price_paid), COUNT(*) INTO v_amount_due, v_seat_count
        FROM booking_seat WHERE booking_id = p_booking_id;

        -- Keep the amount that was actually charged.
        IF v_pay_status IN ('INITIATED', 'FAILED') THEN
            UPDATE payment SET amount = p_amount WHERE payment_id = v_payment_id;
        END IF;

        IF v_pay_status IN ('SUCCEEDED', 'REFUND_PENDING', 'REFUNDED') THEN
            SET p_result = 'ALREADY_APPLIED';

        ELSEIF p_amount <> v_amount_due THEN
            UPDATE payment SET status = 'REFUND_PENDING' WHERE payment_id = v_payment_id;
            SET p_result = 'AMOUNT_MISMATCH';

        ELSEIF v_booking_status = 'PENDING' THEN
            -- Still PENDING means the seats were never released, so confirm even
            -- if the timer ran out a moment ago.
            UPDATE booking SET status = 'CONFIRMED', confirmed_at = UTC_TIMESTAMP(3)
            WHERE booking_id = p_booking_id;
            UPDATE payment SET status = 'SUCCEEDED' WHERE payment_id = v_payment_id;
            SET p_result = 'CONFIRMED';

        ELSEIF v_booking_status = 'EXPIRED' THEN
            -- Late payment: take the same seats back if all are still free
            -- and the show has not started.
            SAVEPOINT reclaim;
            UPDATE booking_seat bs
            STRAIGHT_JOIN show_seat ss
                   ON ss.show_id = v_show_id AND ss.seat_id = bs.seat_id
            SET ss.booking_seat_id = bs.booking_seat_id, ss.version = ss.version + 1
            WHERE bs.booking_id = p_booking_id
              AND ss.booking_seat_id IS NULL
              AND EXISTS (SELECT 1 FROM movie_show ms
                          WHERE ms.show_id = v_show_id
                            AND TIMESTAMP(ms.show_date, ms.start_time)
                                > UTC_TIMESTAMP() + INTERVAL 330 MINUTE);
            SET v_claimed = ROW_COUNT();

            IF v_claimed = v_seat_count THEN
                UPDATE booking SET status = 'CONFIRMED', confirmed_at = UTC_TIMESTAMP(3)
                WHERE booking_id = p_booking_id;
                UPDATE payment SET status = 'SUCCEEDED' WHERE payment_id = v_payment_id;
                SET p_result = 'CONFIRMED_LATE';
            ELSE
                ROLLBACK TO SAVEPOINT reclaim;
                UPDATE payment SET status = 'REFUND_PENDING' WHERE payment_id = v_payment_id;
                SET p_result = 'REFUND_REQUIRED';
            END IF;

        ELSE
            -- Already confirmed by another payment, or cancelled.
            UPDATE payment SET status = 'REFUND_PENDING' WHERE payment_id = v_payment_id;
            SET p_result = 'REFUND_REQUIRED';
        END IF;

    END IF;

    COMMIT;
END$$

DELIMITER ;

-- Runs the sweeper every 30 seconds (event_scheduler is ON by default in 8.x).
CREATE EVENT ev_expire_holds
    ON SCHEDULE EVERY 30 SECOND
    DO CALL sp_expire_holds(500, NULL);

-- ===========================================================================
-- Part 2: demonstration. Uses tomorrow's 20:45 show in Screen 1 (all seats free).
-- ===========================================================================

SET @show_id := (SELECT show_id FROM movie_show
                 WHERE screen_id = 1 AND show_date = DATE(UTC_TIMESTAMP() + INTERVAL 330 MINUTE) + INTERVAL 1 DAY
                   AND start_time = '20:45:00');
SET @a2 := (SELECT seat_id FROM seat WHERE screen_id = 1 AND row_label = 'A' AND seat_number = 2);
SET @a3 := (SELECT seat_id FROM seat WHERE screen_id = 1 AND row_label = 'A' AND seat_number = 3);
SET @a4 := (SELECT seat_id FROM seat WHERE screen_id = 1 AND row_label = 'A' AND seat_number = 4);

-- 1. Customer 1 holds A2 + A3.                          Expect HELD.
CALL sp_hold_seats(1, @show_id, JSON_ARRAY(@a2, @a3), UUID(), @b1, @r);
SELECT '1 hold A2,A3' AS step, @r AS result;

-- 2. Customer 2 wants A3 + A4. A3 is taken.             Expect SEATS_UNAVAILABLE.
CALL sp_hold_seats(2, @show_id, JSON_ARRAY(@a3, @a4), UUID(), @b2, @r);
SELECT '2 overlapping hold' AS step, @r AS result,
       (SELECT booking_seat_id IS NULL FROM show_seat
         WHERE show_id = @show_id AND seat_id = @a4) AS a4_still_free;

-- 3. The same request sent twice.                       Expect HELD, DUPLICATE_REQUEST.
SET @key := UUID();
CALL sp_hold_seats(2, @show_id, JSON_ARRAY(@a4), @key, @b3, @r);
SELECT '3a first send' AS step, @r AS result, @b3 AS booking_id;
CALL sp_hold_seats(2, @show_id, JSON_ARRAY(@a4), @key, @b3again, @r);
SELECT '3b client retry' AS step, @r AS result, @b3again AS booking_id;

-- 4. Payment succeeds, then the provider re-delivers.   Expect CONFIRMED, DUPLICATE_EVENT.
SET @amt := (SELECT SUM(price_paid) FROM booking_seat WHERE booking_id = @b1);
SET @evt := CONCAT('evt_', UUID_SHORT());
SET @pay := CONCAT('pay_', UUID_SHORT());
CALL sp_payment_webhook('demopay', @evt, 'payment.succeeded', @b1, @pay, @amt, JSON_OBJECT(), @r);
SELECT '4a webhook' AS step, @r AS result;
CALL sp_payment_webhook('demopay', @evt, 'payment.succeeded', @b1, @pay, @amt, JSON_OBJECT(), @r);
SELECT '4b redelivery' AS step, @r AS result;

-- 5. Customer 2's hold times out.                       Expect EXPIRED, A4 free.
UPDATE booking SET expires_at = UTC_TIMESTAMP(3) - INTERVAL 1 SECOND WHERE booking_id = @b3;
CALL sp_expire_holds(500, NULL);
SELECT '5 expiry' AS step,
       (SELECT status FROM booking WHERE booking_id = @b3) AS result,
       (SELECT booking_seat_id IS NULL FROM show_seat
         WHERE show_id = @show_id AND seat_id = @a4) AS a4_free;

-- 6. Money for that expired hold arrives late and A4 is free.  Expect CONFIRMED_LATE.
SET @amt := (SELECT SUM(price_paid) FROM booking_seat WHERE booking_id = @b3);
CALL sp_payment_webhook('demopay', CONCAT('evt_', UUID_SHORT()), 'payment.succeeded',
                        @b3, CONCAT('pay_', UUID_SHORT()), @amt, JSON_OBJECT(), @r);
SELECT '6 late payment, seat free' AS step, @r AS result;

-- 7. Late payment when someone else now owns the seat.  Expect REFUND_REQUIRED.
SET @a5 := (SELECT seat_id FROM seat WHERE screen_id = 1 AND row_label = 'A' AND seat_number = 5);
CALL sp_hold_seats(3, @show_id, JSON_ARRAY(@a5), UUID(), @b4, @r);
UPDATE booking SET expires_at = UTC_TIMESTAMP(3) - INTERVAL 1 SECOND WHERE booking_id = @b4;
CALL sp_expire_holds(500, NULL);
CALL sp_hold_seats(4, @show_id, JSON_ARRAY(@a5), UUID(), @b5, @r);
SET @amt := (SELECT SUM(price_paid) FROM booking_seat WHERE booking_id = @b4);
CALL sp_payment_webhook('demopay', CONCAT('evt_', UUID_SHORT()), 'payment.succeeded',
                        @b4, CONCAT('pay_', UUID_SHORT()), @amt, JSON_OBJECT(), @r);
SELECT '7 late payment, seat resold' AS step, @r AS result;

-- 8. Pessimistic alternative, shown for comparison: lock first, then decide.
--    NOWAIT fails at once (error 3572) if another session holds the row.
SET @a6 := (SELECT seat_id FROM seat WHERE screen_id = 1 AND row_label = 'A' AND seat_number = 6);
START TRANSACTION;
SELECT seat_id, booking_seat_id
FROM show_seat
WHERE show_id = @show_id AND seat_id IN (@a6)
ORDER BY seat_id
FOR UPDATE NOWAIT;
ROLLBACK;

-- Invariant checks. Both must return 0.
SELECT 'claims pointing at another show' AS check_name, COUNT(*) AS violations
FROM show_seat ss
JOIN booking_seat bs ON bs.booking_seat_id = ss.booking_seat_id
JOIN booking b       ON b.booking_id = bs.booking_id
WHERE b.show_id <> ss.show_id
UNION ALL
SELECT 'active bookings missing a seat', COUNT(*)
FROM booking b
JOIN booking_seat bs ON bs.booking_id = b.booking_id
LEFT JOIN show_seat ss ON ss.booking_seat_id = bs.booking_seat_id
WHERE b.status IN ('PENDING', 'CONFIRMED') AND ss.show_id IS NULL;
