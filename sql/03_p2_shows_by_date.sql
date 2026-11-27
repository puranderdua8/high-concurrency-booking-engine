-- P2: all shows on a given date at a given theatre, with their show timings.
-- Run after 02_seed.sql. Change the two variables to query other inputs.

USE booking_engine;

-- Current date and time in India (IST), independent of the server's time zone.
SET @now_local := UTC_TIMESTAMP() + INTERVAL 330 MINUTE;
SET @today     := DATE(@now_local);

SET @theatre_id := 1;
-- Tomorrow, so that no show has started yet. Use @today for today.
SET @show_date  := @today + INTERVAL 1 DAY;

-- P2 (a): every show on the date, one row per show.
SELECT
    t.name                                              AS theatre,
    m.title                                             AS movie,
    m.certificate,
    ms.language,
    ms.format,
    sc.name                                             AS screen,
    ms.show_date,
    TIME_FORMAT(ms.start_time, '%h:%i %p')              AS start_time,
    TIME_FORMAT(ADDTIME(ms.start_time, SEC_TO_TIME(m.duration_min * 60)),
                '%h:%i %p')                             AS end_time,
    -- Free seats, plus seats whose hold has timed out (a new hold releases them).
    (SELECT COUNT(*)
       FROM show_seat ss
       LEFT JOIN booking_seat bs ON bs.booking_seat_id = ss.booking_seat_id
       LEFT JOIN booking b       ON b.booking_id = bs.booking_id
      WHERE ss.show_id = ms.show_id
        AND (ss.booking_seat_id IS NULL
             OR (b.status = 'PENDING' AND b.expires_at <= UTC_TIMESTAMP(3)))
    )                                                   AS seats_available,
    IF(TIMESTAMP(ms.show_date, ms.start_time) > @now_local,
       'YES', 'NO')                                     AS booking_open
FROM theatre t
JOIN screen     sc ON sc.theatre_id = t.theatre_id
JOIN movie_show ms ON ms.screen_id  = sc.screen_id
                  AND ms.show_date  = @show_date
JOIN movie      m  ON m.movie_id    = ms.movie_id
WHERE t.theatre_id = @theatre_id
ORDER BY m.title, ms.language, ms.format, ms.start_time;

-- P2 (b): one row per movie + language + format, timings listed together,
-- which is the shape of the theatre page. Shows that have started are left out.
-- show_ids is in the same order as show_timings.
SELECT
    m.title                                             AS movie,
    m.certificate,
    ms.language,
    ms.format,
    GROUP_CONCAT(TIME_FORMAT(ms.start_time, '%h:%i %p')
                 ORDER BY ms.start_time
                 SEPARATOR ', ')                        AS show_timings,
    GROUP_CONCAT(ms.show_id
                 ORDER BY ms.start_time
                 SEPARATOR ', ')                        AS show_ids
FROM screen sc
JOIN movie_show ms ON ms.screen_id = sc.screen_id
                  AND ms.show_date = @show_date
JOIN movie      m  ON m.movie_id   = ms.movie_id
WHERE sc.theatre_id = @theatre_id
  AND TIMESTAMP(ms.show_date, ms.start_time) > @now_local
GROUP BY m.movie_id, m.title, m.certificate, ms.language, ms.format
ORDER BY m.title, ms.language, ms.format;

-- Date picker: always the next 7 dates, with the number of shows on each.
WITH RECURSIVE d (show_date) AS (
    SELECT @today
    UNION ALL
    SELECT show_date + INTERVAL 1 DAY FROM d
    WHERE show_date < @today + INTERVAL 6 DAY
)
SELECT
    d.show_date,
    DATE_FORMAT(d.show_date, '%a %d %b')                AS label,
    COUNT(ms.show_id)                                   AS shows
FROM d
LEFT JOIN (movie_show ms
           JOIN screen sc ON sc.screen_id = ms.screen_id
                         AND sc.theatre_id = @theatre_id)
       ON ms.show_date = d.show_date
GROUP BY d.show_date
ORDER BY d.show_date;

-- Query plan for P2 (b): movie_show should be reached through uq_show_slot.
EXPLAIN
SELECT m.title, ms.language, ms.format, ms.start_time
FROM screen sc
JOIN movie_show ms ON ms.screen_id = sc.screen_id
                  AND ms.show_date = @show_date
JOIN movie      m  ON m.movie_id   = ms.movie_id
WHERE sc.theatre_id = @theatre_id;
