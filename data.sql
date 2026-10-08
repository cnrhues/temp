WITH
params AS (
  SELECT
    10 AS tours_per_brand,
    '2025-11-30'::DATE AS bf_scrape
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
    MIN(PRICE) AS price
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
      AS scrapes_2025
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
    RANK() OVER (PARTITION BY t.brand4
                 ORDER BY SUM(s.net_revenue_usd) DESC)
      AS brand_rank,
    t.brand,
    t.tour_name,
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
  GROUP BY t.brand, t.tour_name, t.brand4, t.name_key
),
pick AS (
  SELECT r.brand_rank, r.brand, r.tour_name, r.brand4, r.name_key
  FROM ranked r, params p
  WHERE r.brand_rank <= p.tours_per_brand
),
ttc_m AS (
  SELECT
    k.brand4, k.name_key, k.brand, k.tour_name, k.brand_rank,
    DATE_TRUNC('month', f.departure_date) AS dep_month,
    MODE(IFF(f.scrape_date <> p.bf_scrape, f.price, NULL))
      AS mode_price,
    MODE(IFF(f.scrape_date = p.bf_scrape, f.price, NULL))
      AS bf_price
  FROM feed f
  JOIN pick k
    ON f.brand4 = k.brand4
   AND f.name_key = k.name_key
  CROSS JOIN params p
  WHERE f.CURRENCY = 'USD'
    AND f.scrape_date <= '2025-12-31'
    AND YEAR(f.departure_date) = 2026
  GROUP BY 1, 2, 3, 4, 5, 6
),
comp_m AS (
  SELECT
    k.brand4, k.name_key,
    c.comp_site || ': ' || c.comp_tour AS comp_name,
    DATE_TRUNC('month', f.departure_date) AS dep_month,
    MODE(IFF(f.scrape_date <> p.bf_scrape, f.price, NULL))
      AS mode_price,
    MODE(IFF(f.scrape_date = p.bf_scrape, f.price, NULL))
      AS bf_price
  FROM pick k
  JOIN comp c
    ON c.brand4 = k.brand4
   AND c.name_key = k.name_key
  JOIN feed f
    ON f.SITE = c.comp_site
   AND f.TOUR_NAME = c.comp_tour
  CROSS JOIN params p
  WHERE f.CURRENCY = 'USD'
    AND f.scrape_date <= '2025-12-31'
    AND YEAR(f.departure_date) = 2026
  GROUP BY 1, 2, 3, 4
)
SELECT
  t.brand AS "Brand",
  t.tour_name AS "Trip Name",
  TO_CHAR(t.dep_month, 'YYYY-MM') AS "Departure Month",
  c.comp_name AS "Competitor Trip Name",
  t.mode_price AS "TTC Mode Price",
  c.mode_price AS "Competitor Mode Price",
  t.bf_price AS "TTC BF Price",
  c.bf_price AS "Competitor BF Price",
  ROUND(100 * (t.bf_price / NULLIF(t.mode_price, 0) - 1), 1)
    AS "TTC BF % Change",
  ROUND(100 * (c.bf_price / NULLIF(c.mode_price, 0) - 1), 1)
    AS "Competitor BF % Change"
FROM ttc_m t
LEFT JOIN comp_m c
  ON c.brand4 = t.brand4
 AND c.name_key = t.name_key
 AND c.dep_month = t.dep_month
ORDER BY t.brand, t.brand_rank, t.dep_month, c.comp_name;
