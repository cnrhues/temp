SELECT
    DATE_TRUNC('week', ORIGINAL_BOOKINGDATE_LOCAL)::DATE AS book_week,
    IFF(COALESCE(ARRAY_TO_STRING(PROMOTION_CODES, ','), '')
            ILIKE ANY ('%BF2%', '%BLACKFRIDAY%', '%EARLYACCESS%'),
        'Black Friday code', 'No BF code')              AS promo_group,
    SUM(IFF(NET_MOVEMENT_TYPE = 'Option', PAX, 0))       AS new_holds,
    SUM(PAX)                                             AS net_pax,
    ROUND(1 - SUM(PAX) / NULLIF(SUM(IFF(NET_MOVEMENT_TYPE = 'Option', PAX, 0)), 0), 3)
                                                         AS share_lost_to_cancellation,
    ROUND(AVG(IFF(NET_MOVEMENT_TYPE = 'Option', ASSUMED_DISCOUNT, NULL)), 3)
                                                         AS avg_discount_on_new_holds
FROM ANALYTICS_DEV_CONNOR.SALES.SALES_MOVEMENT
WHERE ORIGINAL_BOOKINGDATE_LOCAL BETWEEN '2024-07-01' AND CURRENT_DATE
  AND UPPER(DIVISION_BRAND) = 'TOURING'
  AND IS_FTC = FALSE
GROUP BY 1, 2
ORDER BY 1, 2;
