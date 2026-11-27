# High-Concurrency Booking Engine

Data model and MySQL solution for a BookMyShow-style ticketing backend: seat-level locking, timed holds and idempotent payment webhooks.

- **Submission document:** [PDF](docs/High-Concurrency-Booking-Engine.pdf) · [Markdown](docs/SOLUTION.md)
- **Diagram:** [docs/er-diagram.svg](docs/er-diagram.svg)

## SQL

Requires MySQL 8.0.16 or later (tested on 8.4.13). Run the files in order, on a fresh load.
`01_schema.sql` **drops and recreates** the `booking_engine` database.

| File | Contents |
|---|---|
| [sql/01_schema.sql](sql/01_schema.sql) | P1: 12 tables, keys, constraints, indexes |
| [sql/02_seed.sql](sql/02_seed.sql) | P1: sample data, with shows for today and the next 6 days |
| [sql/03_p2_shows_by_date.sql](sql/03_p2_shows_by_date.sql) | P2: shows at a theatre on a date, with timings |
| [sql/04_booking_flow.sql](sql/04_booking_flow.sql) | Hold, expiry and webhook procedures, plus a demonstration |

```bash
cat sql/01_schema.sql sql/02_seed.sql sql/03_p2_shows_by_date.sql sql/04_booking_flow.sql | mysql -u root -p --table
```

No local MySQL? Start one with Docker:

```bash
docker run -d --name booking-mysql -e MYSQL_ALLOW_EMPTY_PASSWORD=yes mysql:8.4
```

Wait about 20 seconds for it to start, then:

```bash
cat sql/0*.sql | docker exec -i booking-mysql mysql -uroot --table
```

## What is implemented

Schema, sample data, queries and the locking logic run in MySQL. The Redis seat gate, burst handling and load test are written designs only.

## Rebuilding the PDF

```bash
sh docs/build_pdf.sh
```
