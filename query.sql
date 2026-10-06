-- ######################################################################
-- TTC Black Friday & pricing analysis — all SQL queries, in run order
-- Source: TTC BF Build Guide.md (Parts 4 and 7)
--
-- Run each query in its own Snowflake SQL cell, named as shown.
-- Step 0a and Step 0b build TEMPORARY tables: rerun them at the start of
-- every working session, or later queries fail with
-- "Object 'TMP_TTC_BK' does not exist or not authorized".
-- Break-even (BE) is built in Excel only and has no query.
-- ######################################################################

-- ######################################################################
-- SESSION 1
-- ######################################################################

-- ====================================================================
-- CHECK 0 — make sure the columns mean what we think  (guide 4.4)
-- ====================================================================
-- Cell: check0  ·  Download: not needed
-- Tests four assumptions: prices are per passenger, DEPARTURE_YEAR is the
-- departure year, START_AT is the departure date, and lead time counts from
-- the original booking date. See the decision rules in 4.4 before continuing.

SELECT
  NET_MOVEMENT_TYPE,
  COUNT(*) AS n_rows,
  ROUND(AVG(GROSS_PRICE_USD_2025_RATE))
    AS avg_price_usd25,
  ROUND(MIN(GROSS_PRICE_USD_2025_RATE))
    AS min_price_usd25,
  ROUND(MAX(GROSS_PRICE_USD_2025_RATE))
    AS max_price_usd25,
  ROUND(AVG(ASSUMED_DISCOUNT), 3)
    AS avg_assumed_discount,
  ROUND(AVG(DEPARTURE_YEAR - YEAR(START_AT)), 2)
    AS depyear_minus_startyear,
  ROUND(AVG(
    DATEDIFF('day',
             ORIGINAL_BOOKINGDATE_LOCAL,
             START_AT)
    - BOOKING_TO_DEPARTURE_DAYS), 1)
    AS lead_check
FROM ANALYTICS_DEV_CONNOR.SALES.SALES_MOVEMENT
WHERE UPPER(DIVISION_BRAND) = 'TOURING'
  AND ORIGINAL_BOOKINGDATE_LOCAL >= '2025-09-01'
GROUP BY NET_MOVEMENT_TYPE
ORDER BY n_rows DESC;

-- ====================================================================
-- STEP 0a — bookings working table, one row per booking  (guide 4.5)
-- ====================================================================
-- Cell: step0a  ·  Download: not needed  ·  Creates: TMP_TTC_BK
-- Temporary table: rerun at the start of EVERY session (guide 4.3).
-- Reads all touring rows since July 2024; allow a minute or two.

CREATE OR REPLACE TEMPORARY TABLE
  ANALYTICS_DEV_CONNOR.SALES.TMP_TTC_BK AS
WITH rows_ AS (
  SELECT
    BOOKING_ID,
    ORIGINAL_BOOKINGDATE_LOCAL::DATE
      AS book_date,
    NET_MOVEMENT_TYPE AS mv,
    PAX,
    MAIN_BRAND AS brand,
    COALESCE(MDM_PAX_COUNTRY, 'Unknown')
      AS market,
    BOOKING_TO_DEPARTURE_DAYS AS lead_d,
    DEPARTURE_YEAR AS dep_y,
    FIRST_PAYMENTDATE_LOCAL AS first_paid,
    SIGN(PAX) * ABS(COALESCE(
      GROSS_PRICE_USD_2025_RATE, 0))
      AS value_usd,
    ',' || COALESCE(ARRAY_TO_STRING(
      PROMOTION_CODES, ','), '') || ','
      AS code_str
  FROM ANALYTICS_DEV_CONNOR.SALES.SALES_MOVEMENT
  WHERE UPPER(DIVISION_BRAND) = 'TOURING'
    AND NOT COALESCE(IS_FTC, FALSE)
    AND NOT COALESCE(IS_BOOKING_QUOTE, FALSE)
    AND ORIGINAL_BOOKINGDATE_LOCAL
        >= '2024-07-01'
),
bk AS (
  SELECT
    BOOKING_ID,
    MIN(book_date) AS book_date,
    ANY_VALUE(brand) AS brand,
    ANY_VALUE(market) AS market,
    MAX(IFF(mv = 'Option', lead_d, NULL))
      AS lead_days,
    MAX(IFF(mv = 'Option', dep_y, NULL))
      AS dep_year,
    MAX(IFF(mv = 'Option',
            TRIM(code_str, ','), NULL))
      AS promo_codes,
    MAX(IFF(code_str <> ',,', 1, 0))
      AS has_code,
    MAX(IFF(code_str ILIKE ANY (
          '%,BF24%', '%,BF25%', '%,BF26%',
          '%,BFDAILY%', '%,BLACKFRIDAY%',
          '%,CYBER%'), 1, 0))
      AS is_bf,
    MAX(IFF(code_str ILIKE '%,EARLYACCESS%',
            1, 0))
      AS is_early_access,
    SUM(IFF(mv = 'Option', PAX, 0))
      AS holds,
    SUM(IFF(mv = 'CX-Option', -PAX, 0))
      AS released,
    SUM(IFF(mv = 'CX-Booking', -PAX, 0))
      AS cancelled,
    SUM(IFF(mv = 'Rebooking', PAX, 0))
      AS rebooked,
    SUM(PAX) AS net_pax,
    SUM(IFF(mv = 'Option', value_usd, 0))
      AS gross_value_usd,
    MAX(IFF(first_paid IS NOT NULL, 1, 0))
      AS paid
  FROM rows_
  GROUP BY BOOKING_ID
  HAVING SUM(IFF(mv = 'Option', PAX, 0)) > 0
),
bf AS (
  SELECT column1 AS season,
         column2::DATE AS bf_date
  FROM VALUES (2024, '2024-11-29'),
              (2025, '2025-11-28'),
              (2026, '2026-11-27')
),
top_mkts AS (
  SELECT market
  FROM bk
  GROUP BY market
  ORDER BY COUNT(*) DESC
  LIMIT 6
)
SELECT
  bk.*,
  YEAR(bk.book_date) AS season,
  bf.bf_date,
  DATEDIFF('day', bf.bf_date, bk.book_date)
    AS days_from_bf,
  FLOOR(DATEDIFF('day', bf.bf_date,
                 bk.book_date) / 7)::INT
    AS weeks_from_bf,
  IFF(MONTH(bk.book_date) >= 9, 1, 0)
    AS in_sep_dec,
  IFF(bk.is_bf = 1
      OR bk.is_early_access = 1, 1, 0)
    AS bf_campaign,
  CASE
    WHEN bk.is_bf = 1 THEN 'Black Friday'
    WHEN bk.is_early_access = 1
      THEN 'Early access'
    WHEN bk.has_code = 1 THEN 'Other code'
    ELSE 'No code'
  END AS promo_group,
  IFF(tm.market IS NULL, 'Other', bk.market)
    AS market_grp,
  CASE
    WHEN bk.lead_days IS NULL
      THEN '5: unknown'
    WHEN bk.lead_days <= 90
      THEN '1: 0-90 days'
    WHEN bk.lead_days <= 180
      THEN '2: 91-180 days'
    WHEN bk.lead_days <= 365
      THEN '3: 181-365 days'
    ELSE '4: 366+ days'
  END AS lead_band,
  bk.dep_year - YEAR(bk.book_date)
    AS dep_years_ahead,
  IFF(bk.book_date BETWEEN '2026-08-24'
                       AND '2026-08-30'
      AND bk.has_code = 0, 1, 0)
    AS suspect
FROM bk
LEFT JOIN bf
  ON bf.season = YEAR(bk.book_date)
LEFT JOIN top_mkts tm
  ON tm.market = bk.market;

-- ====================================================================
-- STEP 0a CHECK — confirm one row per booking  (guide 4.5)
-- ====================================================================
-- Cell: step0a_check  ·  Download: not needed
-- n_rows must equal n_bookings; first_date on/just after 2024-07-01;
-- last_date should be today or yesterday.

SELECT
  COUNT(*) AS n_rows,
  COUNT(DISTINCT BOOKING_ID) AS n_bookings,
  MIN(book_date) AS first_date,
  MAX(book_date) AS last_date
FROM ANALYTICS_DEV_CONNOR.SALES.TMP_TTC_BK;

-- ====================================================================
-- STEP 0b — competitor prices working table  (guide 4.6)
-- ====================================================================
-- Cell: step0b  ·  Download: not needed  ·  Creates: TMP_TTC_COMP
-- One lead-in price per operator, tour, departure, scrape date and currency.
-- Temporary table: rerun at the start of EVERY session (guide 4.3).

CREATE OR REPLACE TEMPORARY TABLE
  ANALYTICS_DEV_CONNOR.SALES.TMP_TTC_COMP AS
SELECT
  SITE,
  TOUR_ID_CONSOLIDATED::STRING AS tour_id,
  TOUR_NAME,
  DEPARTURE_DATE::DATE AS departure_date,
  SCRAPE_DATE::DATE AS scrape_date,
  CURRENCY,
  MIN(PRICE) AS price,
  MIN_BY(PRE_OFFER_PRICE, PRICE)
    AS pre_offer_price,
  MIN_BY(PRICE_PD, PRICE) AS price_pd
FROM ANALYTICS_DEV_CONNOR.REPORTING.COMPETITOR_RAW
WHERE SCRAPE_DATE >= '2024-09-01'
  AND DEPARTURE_DATE > SCRAPE_DATE
  AND PRICE > 0
GROUP BY 1, 2, 3, 4, 5, 6;

-- ====================================================================
-- Q3 — your manager's periods, side by side  (guide 7.1)
-- ====================================================================
-- Cell: q03  ·  File: q03_periods.csv
-- Sep-Dec 2024 vs Sep-Dec 2025, and 2026 to date vs 2025 to the same point.

WITH periods AS (
  SELECT 'A: Sep-Dec 2024' AS period,
         '2024-09-01'::DATE AS p_start,
         '2024-12-31'::DATE AS p_end
  UNION ALL
  SELECT 'B: Sep-Dec 2025',
         '2025-09-01'::DATE,
         '2025-12-31'::DATE
  UNION ALL
  SELECT 'C: 2025 to same point',
         '2025-09-01'::DATE,
         DATEADD('day',
           DATEDIFF('day', '2026-11-27'::DATE,
             DATEADD('day', -1, CURRENT_DATE)),
           '2025-11-28'::DATE)
  UNION ALL
  SELECT 'D: 2026 to date',
         '2026-09-01'::DATE,
         DATEADD('day', -1, CURRENT_DATE)
)
SELECT
  p.period,
  IFF(GROUPING(b.brand) = 1,
      'All brands', b.brand) AS brand,
  COUNT(*) AS bookings,
  SUM(b.holds) AS new_holds,
  SUM(b.released) AS released,
  SUM(b.cancelled) AS cancelled,
  SUM(b.net_pax) AS net_pax,
  SUM(b.gross_value_usd) AS gross_value_usd,
  SUM(b.has_code) AS bookings_with_code,
  SUM(b.bf_campaign) AS bookings_bf_campaign
FROM ANALYTICS_DEV_CONNOR.SALES.TMP_TTC_BK b
JOIN periods p
  ON b.book_date BETWEEN p.p_start
                     AND p.p_end
WHERE b.suspect = 0
GROUP BY GROUPING SETS (
  (p.period, b.brand),
  (p.period)
)
ORDER BY 1, 2;

-- ====================================================================
-- Q5 — Black Friday weeks, year on year (the headline)  (guide 7.2)
-- ====================================================================
-- Cell: q05  ·  File: q05_bf_weekly.csv
-- Weekly bookings lined up on Black Friday week for 2024, 2025 and 2026.

SELECT
  season,
  weeks_from_bf,
  DATEADD('day', weeks_from_bf * 7,
          ANY_VALUE(bf_date)) AS week_start,
  COUNT(*) AS bookings,
  SUM(bf_campaign) AS bf_campaign_bookings,
  SUM(is_early_access)
    AS early_access_bookings,
  SUM(holds) AS new_holds,
  SUM(IFF(bf_campaign = 1, holds, 0))
    AS bf_campaign_holds,
  SUM(net_pax) AS net_pax,
  SUM(gross_value_usd) AS gross_value_usd,
  SUM(IFF(bf_campaign = 1,
          gross_value_usd, 0))
    AS bf_campaign_value_usd
FROM ANALYTICS_DEV_CONNOR.SALES.TMP_TTC_BK
WHERE in_sep_dec = 1
  AND suspect = 0
  AND weeks_from_bf BETWEEN -12 AND 3
  AND DATEADD('day', weeks_from_bf * 7 + 6,
              bf_date) < CURRENT_DATE
GROUP BY season, weeks_from_bf
ORDER BY season, weeks_from_bf;

-- ######################################################################
-- SESSION 2  (rerun Step 0a and Step 0b first)
-- ######################################################################

-- ====================================================================
-- Q1a — busiest booking weeks  (guide 7.3)
-- ====================================================================
-- Cell: q01a  ·  File: q01a_top_weeks.csv
-- Shows that January, not Black Friday, is the peak.

SELECT
  DATE_TRUNC('week', book_date) AS week_start,
  COUNT(*) AS bookings,
  SUM(holds) AS new_holds,
  SUM(net_pax) AS net_pax
FROM ANALYTICS_DEV_CONNOR.SALES.TMP_TTC_BK
WHERE suspect = 0
GROUP BY 1
ORDER BY bookings DESC
LIMIT 15;

-- ====================================================================
-- Q1b — hold outcomes by quarter  (guide 7.3)
-- ====================================================================
-- Cell: q01b  ·  File: q01b_hold_outcomes.csv
-- Shows the maturing effect. Run in a separate cell from Q1a.

SELECT
  DATE_TRUNC('quarter', book_date)
    AS quarter_start,
  COUNT(*) AS bookings,
  SUM(holds) AS new_holds,
  SUM(released) AS released,
  SUM(cancelled) AS cancelled,
  SUM(net_pax) AS net_pax,
  ROUND(SUM(released) / SUM(holds), 3)
    AS release_rate,
  ROUND(SUM(cancelled) / SUM(holds), 3)
    AS cancel_rate,
  ROUND(SUM(paid) / COUNT(*), 3)
    AS share_paid
FROM ANALYTICS_DEV_CONNOR.SALES.TMP_TTC_BK
WHERE suspect = 0
GROUP BY 1
ORDER BY 1;

-- ====================================================================
-- Q4 — promotion code league table  (guide 7.4)
-- ====================================================================
-- Cell: q04  ·  File: q04_promo_codes.csv
-- Every code used 20+ times per period. Feeds the code map sheet, which the
-- break-even calculator needs.

WITH periods AS (
  SELECT 'A: Sep-Dec 2024' AS period,
         '2024-09-01'::DATE AS p_start,
         '2024-12-31'::DATE AS p_end
  UNION ALL
  SELECT 'B: Sep-Dec 2025',
         '2025-09-01'::DATE,
         '2025-12-31'::DATE
  UNION ALL
  SELECT 'D: 2026 to date',
         '2026-09-01'::DATE,
         DATEADD('day', -1, CURRENT_DATE)
),
coded AS (
  SELECT p.period, b.*
  FROM ANALYTICS_DEV_CONNOR.SALES.TMP_TTC_BK b
  JOIN periods p
    ON b.book_date BETWEEN p.p_start
                       AND p.p_end
  WHERE b.suspect = 0
    AND b.has_code = 1
)
SELECT
  c.period,
  TRIM(f.value::STRING) AS promo_code,
  COUNT(*) AS bookings,
  SUM(c.holds) AS new_holds,
  SUM(c.net_pax) AS net_pax,
  SUM(c.gross_value_usd) AS gross_value_usd,
  MIN(c.book_date) AS first_used,
  MAX(c.book_date) AS last_used
FROM coded c,
  LATERAL FLATTEN(
    input => SPLIT(c.promo_codes, ',')) f
WHERE TRIM(f.value::STRING) <> ''
GROUP BY 1, 2
HAVING COUNT(*) >= 20
ORDER BY 1, bookings DESC;

-- ====================================================================
-- Q6 — did Black Friday holds turn into real bookings?  (guide 7.5)
-- ====================================================================
-- Cell: q06  ·  File: q06_holds_stick.csv

SELECT
  season,
  promo_group,
  brand,
  COUNT(*) AS bookings,
  SUM(holds) AS new_holds,
  SUM(released) AS released,
  SUM(cancelled) AS cancelled,
  SUM(rebooked) AS rebooked,
  SUM(net_pax) AS net_pax,
  SUM(paid) AS bookings_paid
FROM ANALYTICS_DEV_CONNOR.SALES.TMP_TTC_BK
WHERE season IN (2024, 2025)
  AND in_sep_dec = 1
  AND suspect = 0
  AND weeks_from_bf BETWEEN -7 AND 1
GROUP BY 1, 2, 3
ORDER BY 1, 2, 3;

-- ######################################################################
-- SESSION 3  (rerun Step 0a and Step 0b first)
-- ######################################################################

-- ====================================================================
-- Q8 — competitor discounting around Black Friday  (guide 7.6)
-- ====================================================================
-- Cell: q08  ·  File: q08_comp_discounting.csv

WITH bf AS (
  SELECT column1 AS season,
         column2::DATE AS bf_date
  FROM VALUES (2024, '2024-11-29'),
              (2025, '2025-11-28'),
              (2026, '2026-11-27')
),
c AS (
  SELECT
    t.*,
    bf.season,
    FLOOR(DATEDIFF('day', bf.bf_date,
                   t.scrape_date) / 7)::INT
      AS weeks_from_bf,
    IFF(t.pre_offer_price > t.price,
        1 - t.price / t.pre_offer_price, 0)
      AS discount_pct
  FROM ANALYTICS_DEV_CONNOR.SALES.TMP_TTC_COMP t
  JOIN bf
    ON bf.season = YEAR(t.scrape_date)
  WHERE MONTH(t.scrape_date) >= 9
    AND DATEDIFF('day', t.scrape_date,
                 t.departure_date)
        BETWEEN 30 AND 540
)
SELECT
  season,
  weeks_from_bf,
  scrape_date,
  SITE,
  CURRENCY,
  COUNT(*) AS departures_priced,
  SUM(IFF(discount_pct > 0, 1, 0))
    AS departures_discounted,
  ROUND(MEDIAN(IFF(discount_pct > 0,
                   discount_pct, NULL)), 3)
    AS median_discount_if_discounted,
  ROUND(MEDIAN(price_pd), 1)
    AS median_price_pd,
  COUNT(DISTINCT TOUR_NAME) AS tours
FROM c
GROUP BY 1, 2, 3, 4, 5
ORDER BY 3, 4, 5;

-- ====================================================================
-- Q9a — which tours can we plot?  (guide 7.7)
-- ====================================================================
-- Cell: q09a  ·  File: q09a_tour_list.csv
-- Keep the long matched-products table name on one line.
-- Use the result to pick 4-6 tours for Q9b.

WITH matches AS (
  SELECT
    TOUR_ID_CONSOLIDATED::STRING
      AS ttc_tour_id,
    COMPETITOR_LOW_SITE AS comp_site,
    COMPETITOR_LOW_TOUR_NAME AS comp_tour
  FROM ANALYTICS_DEV_CONNOR.REPORTING.REPORTING_ALYTICS_MATCHED_PRODUCTS
  UNION
  SELECT
    TOUR_ID_CONSOLIDATED::STRING,
    COMPETITOR_HIGH_SITE,
    COMPETITOR_HIGH_TOUR_NAME
  FROM ANALYTICS_DEV_CONNOR.REPORTING.REPORTING_ALYTICS_MATCHED_PRODUCTS
),
ttc AS (
  SELECT
    tour_id,
    ANY_VALUE(SITE) AS brand,
    ANY_VALUE(TOUR_NAME) AS tour_name,
    COUNT(DISTINCT IFF(
      scrape_date BETWEEN '2025-09-01'
                      AND '2025-12-31',
      scrape_date, NULL))
      AS scrapes_sepdec25,
    COUNT(DISTINCT IFF(
      scrape_date >= '2026-09-01',
      scrape_date, NULL))
      AS scrapes_2026,
    COUNT(DISTINCT departure_date)
      AS departures_seen
  FROM ANALYTICS_DEV_CONNOR.SALES.TMP_TTC_COMP
  WHERE SITE IN ('Trafalgar', 'Insight',
                 'CostSaver', 'Contiki')
  GROUP BY tour_id
)
SELECT
  t.tour_id,
  t.brand,
  t.tour_name,
  t.scrapes_sepdec25,
  t.scrapes_2026,
  t.departures_seen,
  LISTAGG(DISTINCT m.comp_site || ': '
          || m.comp_tour, ' | ')
    AS matched_competitors
FROM ttc t
JOIN matches m
  ON m.ttc_tour_id = t.tour_id
GROUP BY 1, 2, 3, 4, 5, 6
ORDER BY t.scrapes_sepdec25 DESC,
         t.departures_seen DESC;

-- ====================================================================
-- Q9b — our tour prices vs matched competitor tours  (guide 7.7)
-- ====================================================================
-- Cell: q09b  ·  File: q09b_tour_prices.csv
-- BEFORE RUNNING: replace PASTE_ID_1 etc. with the tour IDs chosen from Q9a,
-- keeping the quotes. Add or remove ('...') entries as needed.

WITH chosen AS (
  SELECT column1::STRING AS ttc_tour_id
  FROM VALUES ('PASTE_ID_1'), ('PASTE_ID_2'),
              ('PASTE_ID_3'), ('PASTE_ID_4')
),
matches AS (
  SELECT
    TOUR_ID_CONSOLIDATED::STRING
      AS ttc_tour_id,
    COMPETITOR_LOW_SITE AS comp_site,
    COMPETITOR_LOW_TOUR_NAME AS comp_tour
  FROM ANALYTICS_DEV_CONNOR.REPORTING.REPORTING_ALYTICS_MATCHED_PRODUCTS
  UNION
  SELECT
    TOUR_ID_CONSOLIDATED::STRING,
    COMPETITOR_HIGH_SITE,
    COMPETITOR_HIGH_TOUR_NAME
  FROM ANALYTICS_DEV_CONNOR.REPORTING.REPORTING_ALYTICS_MATCHED_PRODUCTS
),
bf AS (
  SELECT column1 AS season,
         column2::DATE AS bf_date
  FROM VALUES (2024, '2024-11-29'),
              (2025, '2025-11-28'),
              (2026, '2026-11-27')
),
series AS (
  SELECT c.ttc_tour_id, 'TTC' AS side, t.*
  FROM chosen c
  JOIN ANALYTICS_DEV_CONNOR.SALES.TMP_TTC_COMP t
    ON t.tour_id = c.ttc_tour_id
  WHERE t.SITE IN ('Trafalgar', 'Insight',
                   'CostSaver', 'Contiki')
  UNION ALL
  SELECT m.ttc_tour_id, 'Competitor' AS side,
         t.*
  FROM chosen c
  JOIN matches m
    ON m.ttc_tour_id = c.ttc_tour_id
  JOIN ANALYTICS_DEV_CONNOR.SALES.TMP_TTC_COMP t
    ON t.SITE = m.comp_site
   AND t.TOUR_NAME = m.comp_tour
)
SELECT
  s.ttc_tour_id,
  s.side,
  s.SITE || ': ' || s.TOUR_NAME
    AS series_name,
  s.CURRENCY,
  bf.season,
  FLOOR(DATEDIFF('day', bf.bf_date,
                 s.scrape_date) / 7)::INT
    AS weeks_from_bf,
  s.scrape_date,
  COUNT(*) AS departures,
  ROUND(MEDIAN(s.price_pd), 1)
    AS median_price_pd,
  ROUND(MEDIAN(
    GREATEST(COALESCE(s.pre_offer_price,
                      s.price), s.price)
    * s.price_pd / s.price), 1)
    AS median_pre_offer_pd,
  ROUND(AVG(IFF(s.pre_offer_price > s.price,
                1, 0)), 3)
    AS share_discounted
FROM series s
JOIN bf
  ON bf.season = YEAR(s.scrape_date)
WHERE MONTH(s.scrape_date) >= 9
  AND YEAR(s.departure_date)
      = YEAR(s.scrape_date) + 1
GROUP BY 1, 2, 3, 4, 5, 6, 7
ORDER BY 1, 4, 7, 2, 3;

-- ######################################################################
-- SESSION 4  (rerun Step 0a and Step 0b first)
-- ######################################################################

-- ====================================================================
-- Q2 — weekly bookings trend  (guide 7.8)
-- ====================================================================
-- Cell: q02  ·  File: q02_weekly_trend.csv

SELECT
  DATE_TRUNC('week', book_date) AS week_start,
  brand,
  market_grp,
  promo_group,
  suspect,
  COUNT(*) AS bookings,
  SUM(holds) AS new_holds,
  SUM(net_pax) AS net_pax,
  SUM(released) AS released,
  SUM(cancelled) AS cancelled,
  SUM(gross_value_usd) AS gross_value_usd
FROM ANALYTICS_DEV_CONNOR.SALES.TMP_TTC_BK
WHERE book_date
      < DATE_TRUNC('week', CURRENT_DATE)
GROUP BY 1, 2, 3, 4, 5
ORDER BY 1;

-- ====================================================================
-- Q7 — who books in the sale?  (guide 7.9)
-- ====================================================================
-- Cell: q07  ·  File: q07_who_books.csv
-- Skip if Check 0's lead_check or depyear_minus_startyear was not ~0.

SELECT
  season,
  CASE
    WHEN bf_campaign = 1
      THEN '3: BF campaign code'
    WHEN weeks_from_bf BETWEEN -7 AND 1
      THEN '2: Sale weeks, no BF code'
    ELSE '1: Normal weeks (Sep-early Oct)'
  END AS grp,
  lead_band,
  market_grp,
  brand,
  dep_years_ahead,
  COUNT(*) AS bookings,
  SUM(holds) AS new_holds,
  SUM(net_pax) AS net_pax,
  SUM(lead_days) AS sum_lead_days,
  COUNT(lead_days) AS n_with_lead
FROM ANALYTICS_DEV_CONNOR.SALES.TMP_TTC_BK
WHERE season IN (2024, 2025)
  AND in_sep_dec = 1
  AND suspect = 0
  AND weeks_from_bf BETWEEN -12 AND 1
GROUP BY 1, 2, 3, 4, 5, 6;

-- ====================================================================
-- Q10 — next season's bookings so far vs last year  (guide 7.10)
-- ====================================================================
-- Cell: q10  ·  File: q10_next_season.csv
-- Skip if Check 0's depyear_minus_startyear was not ~0.

WITH wk AS (
  SELECT
    season,
    dep_years_ahead,
    weeks_from_bf,
    COUNT(*) AS bookings,
    SUM(holds) AS new_holds,
    SUM(gross_value_usd) AS gross_value_usd
  FROM ANALYTICS_DEV_CONNOR.SALES.TMP_TTC_BK
  WHERE season IN (2025, 2026)
    AND MONTH(book_date) >= 7
    AND dep_years_ahead IN (0, 1)
    AND suspect = 0
    AND DATEADD('day', weeks_from_bf * 7 + 6,
                bf_date) < CURRENT_DATE
  GROUP BY 1, 2, 3
)
SELECT
  wk.*,
  SUM(bookings) OVER (
    PARTITION BY season, dep_years_ahead
    ORDER BY weeks_from_bf)
    AS cum_bookings,
  SUM(new_holds) OVER (
    PARTITION BY season, dep_years_ahead
    ORDER BY weeks_from_bf)
    AS cum_holds,
  SUM(gross_value_usd) OVER (
    PARTITION BY season, dep_years_ahead
    ORDER BY weeks_from_bf)
    AS cum_value_usd
FROM wk
ORDER BY season, dep_years_ahead,
         weeks_from_bf;
