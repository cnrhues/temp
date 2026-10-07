WITH
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
    MIN_BY(PRICE_PD, PRICE) AS price_pd,
    MIN_BY(PRE_OFFER_PRICE, PRICE) AS pre_offer
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
    RANK() OVER (PARTITION BY t.brand4
                 ORDER BY SUM(s.net_revenue_usd) DESC)
      AS brand_rank,
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
  SELECT brand_rank, brand, tour_name, brand4, name_key
  FROM ranked
  WHERE brand_rank <= 3
),
lines AS (
  SELECT k.brand_rank, k.brand, k.tour_name AS ttc_tour,
         k.brand4 AS ttc_brand4,
         'TTC (us)' AS series_name,
         f.scrape_date, f.departure_date, f.price,
         f.pre_offer, f.price_pd, f.CURRENCY
  FROM feed f
  JOIN pick k
    ON f.brand4 = k.brand4
   AND f.name_key = k.name_key
  UNION ALL
  SELECT k.brand_rank, k.brand, k.tour_name, k.brand4,
         f.SITE || ': ' || f.TOUR_NAME,
         f.scrape_date, f.departure_date, f.price,
         f.pre_offer, f.price_pd, f.CURRENCY
  FROM feed f
  JOIN comp c
    ON f.SITE = c.comp_site
   AND f.TOUR_NAME = c.comp_tour
  JOIN pick k
    ON c.brand4 = k.brand4
   AND c.name_key = k.name_key
),
labelled AS (
  SELECT
    l.*,
    'Wk ' || LPAD((FLOOR(DATEDIFF('day',
        DATE_FROM_PARTS(YEAR(scrape_date), 9, 1),
        scrape_date) / 7) + 1)::INT::STRING, 2, '0') AS wk,
    IFF(scrape_date BETWEEN
          IFF(ttc_brand4 = 'CONT', '2025-11-04'::DATE,
                                   '2025-10-30'::DATE)
          AND '2025-12-04'::DATE,
        ' SALE', '') AS sale_flag
  FROM lines l
)
SELECT
  brand || ' #' || brand_rank || ': ' || ttc_tour AS tour,
  IFF(YEAR(scrape_date) = 2025,
      'Sep-Dec 2025', 'Sep 2026 to now') AS period,
  wk || ' (' || TO_CHAR(scrape_date, 'DD Mon') || ')'
     || sale_flag AS week,
  series_name,
  ROUND(MEDIAN(price_pd), 1) AS price_per_day,
  COUNT(*) AS departures_priced,
  wk,
  ROUND(100 * AVG(IFF(pre_offer > price,
                      1 - price / pre_offer, 0)), 1)
    AS avg_discount_pct
FROM labelled
WHERE CURRENCY = 'USD'
  AND YEAR(departure_date) = YEAR(scrape_date) + 1
GROUP BY 1, 2, 3, 4, 7
ORDER BY 1, 2, 3, 4;
