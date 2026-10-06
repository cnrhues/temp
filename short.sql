-- Q1
WITH sales AS (
  SELECT
    PRODUCT_CODE,
    LEFT(UPPER(REGEXP_REPLACE(
      ANY_VALUE(MAIN_BRAND), '[^A-Za-z]', '')), 4)
      AS brand4,
    REGEXP_REPLACE(LOWER(
      ANY_VALUE(PRODUCT_NAME)), '[^a-z0-9]', '')
      AS key1,
    REGEXP_REPLACE(LOWER(
      ANY_VALUE(PRODUCT_STANDARD_NAME)), '[^a-z0-9]', '')
      AS key2,
    SUM(PAX) AS net_pax,
    SUM(SIGN(PAX) * ABS(COALESCE(
      GROSS_PRICE_USD_2025_RATE, 0)))
      AS net_revenue_usd
  FROM ANALYTICS_DEV_CONNOR.SALES.SALES_MOVEMENT
  WHERE DEPARTURE_YEAR = 2025
    AND NOT COALESCE(IS_FTC, FALSE)
    AND NOT COALESCE(IS_BOOKING_QUOTE, FALSE)
  GROUP BY PRODUCT_CODE
),
feed AS (
  SELECT
    SITE,
    TOUR_NAME,
    LEFT(UPPER(REGEXP_REPLACE(
      SITE, '[^A-Za-z]', '')), 4) AS brand4,
    REGEXP_REPLACE(LOWER(TOUR_NAME),
      '[^a-z0-9]', '') AS name_key,
    TOUR_ID_CONSOLIDATED::STRING AS tour_id,
    DEPARTURE_DATE::DATE AS departure_date,
    SCRAPE_DATE::DATE AS scrape_date,
    CURRENCY,
    MIN(PRICE) AS price,
    MIN_BY(PRICE_PD, PRICE) AS price_pd
  FROM ANALYTICS_DEV_CONNOR.REPORTING.COMPETITOR_RAW
  WHERE (SCRAPE_DATE BETWEEN '2025-09-01'
                         AND '2025-12-31'
         OR SCRAPE_DATE >= '2026-09-01')
    AND DEPARTURE_DATE > SCRAPE_DATE
    AND PRICE > 0
  GROUP BY 1, 2, 3, 4, 5, 6, 7, 8
),
ttc AS (
  SELECT
    brand4,
    name_key,
    ANY_VALUE(SITE) AS brand,
    ANY_VALUE(TOUR_NAME) AS tour_name,
    COUNT(DISTINCT IFF(scrape_date <= '2025-12-31',
                       scrape_date, NULL))
      AS scrapes_2025,
    COUNT(DISTINCT IFF(scrape_date >= '2026-09-01',
                       scrape_date, NULL))
      AS scrapes_2026
  FROM feed
  WHERE brand4 IN ('TRAF', 'INSI', 'COST', 'CONT')
  GROUP BY brand4, name_key
),
comp AS (
  SELECT DISTINCT
    f.brand4,
    f.name_key,
    mp.COMPETITOR_LOW_SITE AS comp_site,
    mp.COMPETITOR_LOW_TOUR_NAME AS comp_tour
  FROM (SELECT DISTINCT brand4, name_key, tour_id
        FROM feed) f
  JOIN ANALYTICS_DEV_CONNOR.REPORTING.REPORTING_ALYTICS_MATCHED_PRODUCTS mp
    ON mp.TOUR_ID_CONSOLIDATED::STRING = f.tour_id
  WHERE mp.COMPETITOR_LOW_SITE IS NOT NULL
  UNION
  SELECT DISTINCT
    f.brand4,
    f.name_key,
    mp.COMPETITOR_HIGH_SITE,
    mp.COMPETITOR_HIGH_TOUR_NAME
  FROM (SELECT DISTINCT brand4, name_key, tour_id
        FROM feed) f
  JOIN ANALYTICS_DEV_CONNOR.REPORTING.REPORTING_ALYTICS_MATCHED_PRODUCTS mp
    ON mp.TOUR_ID_CONSOLIDATED::STRING = f.tour_id
  WHERE mp.COMPETITOR_HIGH_SITE IS NOT NULL
),
ranked AS (
  SELECT
    RANK() OVER (ORDER BY SUM(s.net_revenue_usd) DESC)
      AS revenue_rank,
    t.brand,
    t.tour_name,
    ROUND(SUM(s.net_revenue_usd))
      AS net_revenue_usd_2025,
    SUM(s.net_pax) AS net_pax_2025,
    t.scrapes_2025,
    t.scrapes_2026,
    t.brand4,
    t.name_key
  FROM ttc t
  JOIN sales s
    ON s.brand4 = t.brand4
   AND t.name_key IN (s.key1, s.key2)
  WHERE t.scrapes_2025 >= 8
    AND EXISTS (SELECT 1 FROM comp c
                WHERE c.brand4 = t.brand4
                  AND c.name_key = t.name_key)
  GROUP BY t.brand, t.tour_name, t.scrapes_2025,
           t.scrapes_2026, t.brand4, t.name_key
)
SELECT
  r.revenue_rank,
  r.brand,
  r.tour_name,
  r.net_revenue_usd_2025,
  r.net_pax_2025,
  r.scrapes_2025,
  r.scrapes_2026,
  LISTAGG(DISTINCT c.comp_site || ': ' || c.comp_tour, ' | ')
    AS compared_with
FROM ranked r
LEFT JOIN comp c
  ON c.brand4 = r.brand4
 AND c.name_key = r.name_key
GROUP BY 1, 2, 3, 4, 5, 6, 7
ORDER BY r.revenue_rank
LIMIT 20;

-- Q2
WITH params AS (
  SELECT
    1 AS tour_rank,
    2025 AS season,
    'USD' AS currency,
    NULL::STRING AS tour_name_override
),
sales AS (
  SELECT
    PRODUCT_CODE,
    LEFT(UPPER(REGEXP_REPLACE(
      ANY_VALUE(MAIN_BRAND), '[^A-Za-z]', '')), 4)
      AS brand4,
    REGEXP_REPLACE(LOWER(
      ANY_VALUE(PRODUCT_NAME)), '[^a-z0-9]', '')
      AS key1,
    REGEXP_REPLACE(LOWER(
      ANY_VALUE(PRODUCT_STANDARD_NAME)), '[^a-z0-9]', '')
      AS key2,
    SUM(PAX) AS net_pax,
    SUM(SIGN(PAX) * ABS(COALESCE(
      GROSS_PRICE_USD_2025_RATE, 0)))
      AS net_revenue_usd
  FROM ANALYTICS_DEV_CONNOR.SALES.SALES_MOVEMENT
  WHERE DEPARTURE_YEAR = 2025
    AND NOT COALESCE(IS_FTC, FALSE)
    AND NOT COALESCE(IS_BOOKING_QUOTE, FALSE)
  GROUP BY PRODUCT_CODE
),
feed AS (
  SELECT
    SITE,
    TOUR_NAME,
    LEFT(UPPER(REGEXP_REPLACE(
      SITE, '[^A-Za-z]', '')), 4) AS brand4,
    REGEXP_REPLACE(LOWER(TOUR_NAME),
      '[^a-z0-9]', '') AS name_key,
    TOUR_ID_CONSOLIDATED::STRING AS tour_id,
    DEPARTURE_DATE::DATE AS departure_date,
    SCRAPE_DATE::DATE AS scrape_date,
    CURRENCY,
    MIN(PRICE) AS price,
    MIN_BY(PRICE_PD, PRICE) AS price_pd
  FROM ANALYTICS_DEV_CONNOR.REPORTING.COMPETITOR_RAW
  WHERE (SCRAPE_DATE BETWEEN '2025-09-01'
                         AND '2025-12-31'
         OR SCRAPE_DATE >= '2026-09-01')
    AND DEPARTURE_DATE > SCRAPE_DATE
    AND PRICE > 0
  GROUP BY 1, 2, 3, 4, 5, 6, 7, 8
),
ttc AS (
  SELECT
    brand4,
    name_key,
    ANY_VALUE(SITE) AS brand,
    ANY_VALUE(TOUR_NAME) AS tour_name,
    COUNT(DISTINCT IFF(scrape_date <= '2025-12-31',
                       scrape_date, NULL))
      AS scrapes_2025,
    COUNT(DISTINCT IFF(scrape_date >= '2026-09-01',
                       scrape_date, NULL))
      AS scrapes_2026
  FROM feed
  WHERE brand4 IN ('TRAF', 'INSI', 'COST', 'CONT')
  GROUP BY brand4, name_key
),
comp AS (
  SELECT DISTINCT
    f.brand4,
    f.name_key,
    mp.COMPETITOR_LOW_SITE AS comp_site,
    mp.COMPETITOR_LOW_TOUR_NAME AS comp_tour
  FROM (SELECT DISTINCT brand4, name_key, tour_id
        FROM feed) f
  JOIN ANALYTICS_DEV_CONNOR.REPORTING.REPORTING_ALYTICS_MATCHED_PRODUCTS mp
    ON mp.TOUR_ID_CONSOLIDATED::STRING = f.tour_id
  WHERE mp.COMPETITOR_LOW_SITE IS NOT NULL
  UNION
  SELECT DISTINCT
    f.brand4,
    f.name_key,
    mp.COMPETITOR_HIGH_SITE,
    mp.COMPETITOR_HIGH_TOUR_NAME
  FROM (SELECT DISTINCT brand4, name_key, tour_id
        FROM feed) f
  JOIN ANALYTICS_DEV_CONNOR.REPORTING.REPORTING_ALYTICS_MATCHED_PRODUCTS mp
    ON mp.TOUR_ID_CONSOLIDATED::STRING = f.tour_id
  WHERE mp.COMPETITOR_HIGH_SITE IS NOT NULL
),
ranked AS (
  SELECT
    RANK() OVER (ORDER BY SUM(s.net_revenue_usd) DESC)
      AS revenue_rank,
    t.brand,
    t.tour_name,
    ROUND(SUM(s.net_revenue_usd))
      AS net_revenue_usd_2025,
    SUM(s.net_pax) AS net_pax_2025,
    t.scrapes_2025,
    t.scrapes_2026,
    t.brand4,
    t.name_key
  FROM ttc t
  JOIN sales s
    ON s.brand4 = t.brand4
   AND t.name_key IN (s.key1, s.key2)
  WHERE t.scrapes_2025 >= 8
    AND EXISTS (SELECT 1 FROM comp c
                WHERE c.brand4 = t.brand4
                  AND c.name_key = t.name_key)
  GROUP BY t.brand, t.tour_name, t.scrapes_2025,
           t.scrapes_2026, t.brand4, t.name_key
),
pick AS (
  SELECT r.brand4, r.name_key
  FROM ranked r, params p
  WHERE p.tour_name_override IS NULL
    AND r.revenue_rank = p.tour_rank
  UNION ALL
  SELECT t.brand4, t.name_key
  FROM ttc t, params p
  WHERE t.tour_name = p.tour_name_override
),
lines AS (
  SELECT 'TTC ' || f.SITE || ': ' || f.TOUR_NAME
           AS series_name,
         f.*
  FROM feed f
  JOIN pick k
    ON f.brand4 = k.brand4
   AND f.name_key = k.name_key
  UNION ALL
  SELECT f.SITE || ': ' || f.TOUR_NAME,
         f.*
  FROM feed f
  JOIN comp c
    ON f.SITE = c.comp_site
   AND f.TOUR_NAME = c.comp_tour
  JOIN pick k
    ON c.brand4 = k.brand4
   AND c.name_key = k.name_key
)
SELECT
  l.scrape_date,
  l.series_name,
  ROUND(MEDIAN(l.price_pd), 1) AS price_per_day,
  COUNT(*) AS departures_priced
FROM lines l, params p
WHERE YEAR(l.scrape_date) = p.season
  AND l.CURRENCY = p.currency
  AND YEAR(l.departure_date)
      = YEAR(l.scrape_date) + 1
GROUP BY 1, 2
ORDER BY 1, 2;
