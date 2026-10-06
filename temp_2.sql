WITH rev AS (
  SELECT
    TOUR_COL::STRING AS tour_id,
    ANY_VALUE(MAIN_BRAND) AS brand,
    COUNT(DISTINCT BOOKING_ID) AS bookings,
    SUM(PAX) AS net_pax,
    SUM(SIGN(PAX) * ABS(COALESCE(
      GROSS_PRICE_USD_2025_RATE, 0)))
      AS net_revenue_usd
  FROM ANALYTICS_DEV_CONNOR.SALES.SALES_MOVEMENT
  WHERE UPPER(DIVISION_BRAND) = 'TOURING'
    AND NOT COALESCE(IS_FTC, FALSE)
    AND NOT COALESCE(IS_BOOKING_QUOTE, FALSE)
    AND DEPARTURE_YEAR = 2025
  GROUP BY 1
),
cov AS (
  SELECT
    tour_id,
    ANY_VALUE(TOUR_NAME) AS tour_name,
    COUNT(DISTINCT IFF(
      scrape_date BETWEEN '2025-09-01'
                      AND '2025-12-31',
      scrape_date, NULL)) AS scrapes_sepdec25,
    COUNT(DISTINCT IFF(
      scrape_date >= '2026-09-01',
      scrape_date, NULL)) AS scrapes_2026
  FROM ANALYTICS_DEV_CONNOR.SALES.TMP_TTC_COMP
  WHERE SITE IN ('Trafalgar', 'Insight',
                 'CostSaver', 'Contiki')
  GROUP BY tour_id
),
m AS (
  SELECT
    TOUR_ID_CONSOLIDATED::STRING AS tour_id,
    ANY_VALUE(COMPETITOR_LOW_SITE || ': '
      || COMPETITOR_LOW_TOUR_NAME) AS comp_low,
    ANY_VALUE(COMPETITOR_HIGH_SITE || ': '
      || COMPETITOR_HIGH_TOUR_NAME) AS comp_high
  FROM ANALYTICS_DEV_CONNOR.REPORTING.REPORTING_ALYTICS_MATCHED_PRODUCTS
  GROUP BY 1
)
SELECT
  RANK() OVER (ORDER BY r.net_revenue_usd DESC)
    AS revenue_rank,
  r.tour_id,
  c.tour_name,
  r.brand,
  r.bookings,
  r.net_pax,
  ROUND(r.net_revenue_usd) AS net_revenue_usd,
  ROUND(r.net_revenue_usd
    / SUM(r.net_revenue_usd) OVER (), 4)
    AS share_of_revenue,
  ROUND(SUM(r.net_revenue_usd) OVER (
          ORDER BY r.net_revenue_usd DESC
          ROWS UNBOUNDED PRECEDING)
    / SUM(r.net_revenue_usd) OVER (), 4)
    AS cumulative_share,
  m.comp_low,
  m.comp_high,
  COALESCE(c.scrapes_sepdec25, 0)
    AS scrapes_sepdec25,
  COALESCE(c.scrapes_2026, 0) AS scrapes_2026,
  CASE
    WHEN m.tour_id IS NULL
      THEN 'No: no matched competitor'
    WHEN COALESCE(c.scrapes_sepdec25, 0) < 12
      THEN 'No: too few autumn 2025 prices'
    WHEN COALESCE(c.scrapes_2026, 0) < 3
      THEN 'No: too few 2026 prices'
    ELSE 'Yes'
  END AS chartable
FROM rev r
LEFT JOIN cov c ON c.tour_id = r.tour_id
LEFT JOIN m ON m.tour_id = r.tour_id
ORDER BY revenue_rank
LIMIT 50;
