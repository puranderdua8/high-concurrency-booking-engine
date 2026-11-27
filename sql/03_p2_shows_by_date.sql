-- P2: all shows on a given date at a given theatre, with their show timings.
-- Run after 02_seed.sql. Change the two variables to query other inputs.

USE booking_engine;

SET @theatre_id := 1;
SET @show_date  := CURDATE();

-- P2 (a): one row per show.
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
    (SELECT COUNT(*)
       FROM show_seat ss
      WHERE ss.show_id = ms.show_id
        AND ss.booking_seat_id IS NULL)                 AS seats_available
FROM theatre t
JOIN screen     sc ON sc.theatre_id = t.theatre_id
JOIN movie_show ms ON ms.screen_id  = sc.screen_id
                  AND ms.show_date  = @show_date
JOIN movie      m  ON m.movie_id    = ms.movie_id
WHERE t.theatre_id = @theatre_id
ORDER BY m.title, ms.language, ms.format, ms.start_time;

-- P2 (b): one row per movie + language + format, timings listed together,
-- which is the shape of the theatre page.
SELECT
    m.title                                             AS movie,
    m.certificate,
    ms.language,
    ms.format,
    GROUP_CONCAT(TIME_FORMAT(ms.start_time, '%h:%i %p')
                 ORDER BY ms.start_time
                 SEPARATOR ', ')                        AS show_timings
FROM screen sc
JOIN movie_show ms ON ms.screen_id = sc.screen_id
                  AND ms.show_date = @show_date
JOIN movie      m  ON m.movie_id   = ms.movie_id
WHERE sc.theatre_id = @theatre_id
GROUP BY m.movie_id, m.title, m.certificate, ms.language, ms.format
ORDER BY m.title, ms.language, ms.format;

-- Date picker: which of the next 7 dates have shows at this theatre.
SELECT DISTINCT
    ms.show_date,
    DATE_FORMAT(ms.show_date, '%a %d %b')               AS label
FROM screen sc
JOIN movie_show ms ON ms.screen_id = sc.screen_id
WHERE sc.theatre_id = @theatre_id
  AND ms.show_date BETWEEN CURDATE() AND CURDATE() + INTERVAL 6 DAY
ORDER BY ms.show_date;

-- Query plan for P2 (b): movie_show should be reached through uq_show_slot.
EXPLAIN
SELECT m.title, ms.language, ms.format, ms.start_time
FROM screen sc
JOIN movie_show ms ON ms.screen_id = sc.screen_id
                  AND ms.show_date = @show_date
JOIN movie      m  ON m.movie_id   = ms.movie_id
WHERE sc.theatre_id = @theatre_id;
