-- P1: schema for the High-Concurrency Booking Engine.
-- Target: MySQL 8.0.16 or later (tested on 8.4). Run this file first.
-- WARNING: it drops and recreates the database `booking_engine`.

DROP DATABASE IF EXISTS booking_engine;
CREATE DATABASE booking_engine CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;
USE booking_engine;

-- 1. A cinema building.
CREATE TABLE theatre (
    theatre_id    INT UNSIGNED NOT NULL AUTO_INCREMENT,
    name          VARCHAR(100) NOT NULL,
    city          VARCHAR(60)  NOT NULL,
    address       VARCHAR(255) NOT NULL,
    PRIMARY KEY (theatre_id),
    UNIQUE KEY uq_theatre_city_name (city, name)
) ENGINE=InnoDB;

-- 2. A physical auditorium inside a theatre.
CREATE TABLE screen (
    screen_id     INT UNSIGNED NOT NULL AUTO_INCREMENT,
    theatre_id    INT UNSIGNED NOT NULL,
    name          VARCHAR(40)  NOT NULL,
    screen_type   ENUM('STANDARD','DOLBY_ATMOS','IMAX') NOT NULL DEFAULT 'STANDARD',
    PRIMARY KEY (screen_id),
    UNIQUE KEY uq_screen_theatre_name (theatre_id, name),
    CONSTRAINT fk_screen_theatre FOREIGN KEY (theatre_id) REFERENCES theatre (theatre_id)
) ENGINE=InnoDB;

-- 3. The fixed seat layout of a screen. Category is chosen per seat.
CREATE TABLE seat (
    seat_id       INT UNSIGNED      NOT NULL AUTO_INCREMENT,
    screen_id     INT UNSIGNED      NOT NULL,
    row_label     VARCHAR(3)        NOT NULL,
    seat_number   SMALLINT UNSIGNED NOT NULL,
    category      ENUM('SILVER','GOLD','RECLINER') NOT NULL,
    PRIMARY KEY (seat_id),
    UNIQUE KEY uq_seat_position (screen_id, row_label, seat_number),
    CONSTRAINT fk_seat_screen FOREIGN KEY (screen_id) REFERENCES screen (screen_id),
    CONSTRAINT chk_seat_number CHECK (seat_number > 0)
) ENGINE=InnoDB;

-- 4. A film, independent of where or when it is screened.
CREATE TABLE movie (
    movie_id      INT UNSIGNED      NOT NULL AUTO_INCREMENT,
    title         VARCHAR(150)      NOT NULL,
    duration_min  SMALLINT UNSIGNED NOT NULL,
    certificate   ENUM('U','UA','A') NOT NULL,
    release_date  DATE              NOT NULL,
    PRIMARY KEY (movie_id),
    UNIQUE KEY uq_movie_title_release (title, release_date),
    CONSTRAINT chk_movie_duration CHECK (duration_min > 0)
) ENGINE=InnoDB;

-- 5. One screening of a movie on a screen. (`SHOW` is a reserved word.)
--    No theatre_id (comes from screen) and no end_time (start + duration).
CREATE TABLE movie_show (
    show_id       INT UNSIGNED NOT NULL AUTO_INCREMENT,
    screen_id     INT UNSIGNED NOT NULL,
    movie_id      INT UNSIGNED NOT NULL,
    language      VARCHAR(20)  NOT NULL,
    format        ENUM('2D','3D','IMAX') NOT NULL,
    show_date     DATE         NOT NULL,
    start_time    TIME         NOT NULL,
    PRIMARY KEY (show_id),
    -- Also the access path for P2: screen_id + show_date, ordered by start_time.
    UNIQUE KEY uq_show_slot (screen_id, show_date, start_time),
    KEY idx_show_movie_date (movie_id, show_date),
    CONSTRAINT fk_show_screen FOREIGN KEY (screen_id) REFERENCES screen (screen_id),
    CONSTRAINT fk_show_movie  FOREIGN KEY (movie_id)  REFERENCES movie (movie_id),
    CONSTRAINT chk_show_language
        CHECK (language IN ('English','Hindi','Tamil','Telugu','Kannada','Malayalam'))
) ENGINE=InnoDB;

-- 6. Price of each seat category for a given show.
CREATE TABLE show_price (
    show_id       INT UNSIGNED  NOT NULL,
    category      ENUM('SILVER','GOLD','RECLINER') NOT NULL,
    price         DECIMAL(8,2)  NOT NULL,
    PRIMARY KEY (show_id, category),
    CONSTRAINT fk_price_show FOREIGN KEY (show_id) REFERENCES movie_show (show_id),
    CONSTRAINT chk_price CHECK (price >= 0)
) ENGINE=InnoDB;

-- 7. A person who books. (Named `customer` to avoid the keyword USER.)
CREATE TABLE customer (
    customer_id   BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    name          VARCHAR(100)    NOT NULL,
    email         VARCHAR(150)    NOT NULL,
    phone         VARCHAR(20)     NOT NULL,
    PRIMARY KEY (customer_id),
    UNIQUE KEY uq_customer_email (email),
    UNIQUE KEY uq_customer_phone (phone)
) ENGINE=InnoDB;

-- 8. One checkout attempt for one show. A PENDING booking is a timed hold.
CREATE TABLE booking (
    booking_id       BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    customer_id      BIGINT UNSIGNED NOT NULL,
    show_id          INT UNSIGNED    NOT NULL,
    status           ENUM('PENDING','CONFIRMED','EXPIRED','CANCELLED') NOT NULL DEFAULT 'PENDING',
    idempotency_key  CHAR(36)        NOT NULL,
    created_at       DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    expires_at       DATETIME(3)     NOT NULL,
    confirmed_at     DATETIME(3)     NULL,
    PRIMARY KEY (booking_id),
    UNIQUE KEY uq_booking_idempotency (idempotency_key),
    KEY idx_booking_expiry (status, expires_at),        -- expiry sweeper
    KEY idx_booking_customer (customer_id, created_at), -- "my bookings"
    KEY idx_booking_show (show_id),
    CONSTRAINT fk_booking_customer FOREIGN KEY (customer_id) REFERENCES customer (customer_id),
    CONSTRAINT fk_booking_show     FOREIGN KEY (show_id)     REFERENCES movie_show (show_id)
) ENGINE=InnoDB;

-- 9. The seats a booking asked for, with the price at that moment.
--    Never deleted, so an expired hold still knows what it held.
CREATE TABLE booking_seat (
    booking_seat_id  BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    booking_id       BIGINT UNSIGNED NOT NULL,
    seat_id          INT UNSIGNED    NOT NULL,
    price_paid       DECIMAL(8,2)    NOT NULL,
    PRIMARY KEY (booking_seat_id),
    UNIQUE KEY uq_booking_seat (booking_id, seat_id),
    UNIQUE KEY uq_booking_seat_ref (booking_seat_id, seat_id), -- target of show_seat FK
    KEY idx_booking_seat_seat (seat_id),
    CONSTRAINT fk_bs_booking FOREIGN KEY (booking_id) REFERENCES booking (booking_id),
    CONSTRAINT fk_bs_seat    FOREIGN KEY (seat_id)    REFERENCES seat (seat_id),
    CONSTRAINT chk_bs_price CHECK (price_paid >= 0)
) ENGINE=InnoDB;

-- 10. Live inventory: one row per seat per show. This is the row that is locked.
--     booking_seat_id IS NULL  -> seat is free
--     booking_seat_id NOT NULL -> held or booked (see booking.status)
CREATE TABLE show_seat (
    show_id          INT UNSIGNED    NOT NULL,
    seat_id          INT UNSIGNED    NOT NULL,
    booking_seat_id  BIGINT UNSIGNED NULL,
    version          INT UNSIGNED    NOT NULL DEFAULT 0,
    PRIMARY KEY (show_id, seat_id),
    UNIQUE KEY uq_show_seat_owner (booking_seat_id),
    KEY idx_show_seat_owner_ref (booking_seat_id, seat_id),
    KEY idx_show_seat_seat (seat_id),
    CONSTRAINT fk_ss_show  FOREIGN KEY (show_id) REFERENCES movie_show (show_id),
    CONSTRAINT fk_ss_seat  FOREIGN KEY (seat_id) REFERENCES seat (seat_id),
    CONSTRAINT fk_ss_owner FOREIGN KEY (booking_seat_id, seat_id)
        REFERENCES booking_seat (booking_seat_id, seat_id)
) ENGINE=InnoDB;

-- 11. One payment attempt at a provider. A booking can have several.
CREATE TABLE payment (
    payment_id           BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    booking_id           BIGINT UNSIGNED NOT NULL,
    provider             VARCHAR(30)     NOT NULL,
    provider_payment_id  VARCHAR(100)    NOT NULL,
    amount               DECIMAL(10,2)   NOT NULL,
    status               ENUM('INITIATED','SUCCEEDED','FAILED','REFUND_PENDING','REFUNDED')
                         NOT NULL DEFAULT 'INITIATED',
    created_at           DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    PRIMARY KEY (payment_id),
    UNIQUE KEY uq_payment_provider_ref (provider, provider_payment_id),
    KEY idx_payment_booking (booking_id),
    CONSTRAINT fk_payment_booking FOREIGN KEY (booking_id) REFERENCES booking (booking_id),
    CONSTRAINT chk_payment_amount CHECK (amount >= 0)
) ENGINE=InnoDB;

-- 12. Every webhook delivery, de-duplicated on the provider's event id.
CREATE TABLE webhook_event (
    provider             VARCHAR(30)  NOT NULL,
    provider_event_id    VARCHAR(100) NOT NULL,
    provider_payment_id  VARCHAR(100) NULL,
    event_type           VARCHAR(50)  NOT NULL,
    payload              JSON         NOT NULL,
    received_at          DATETIME(3)  NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    processed_at         DATETIME(3)  NULL,
    PRIMARY KEY (provider, provider_event_id),
    KEY idx_webhook_payment (provider, provider_payment_id),
    CONSTRAINT fk_webhook_payment FOREIGN KEY (provider, provider_payment_id)
        REFERENCES payment (provider, provider_payment_id)
) ENGINE=InnoDB;
