-- A. What does the view actually read from?
SELECT GET_DDL('VIEW', 'ANALYTICS_DEV_CONNOR.SALES.SALES_MOVEMENT');

-- B. Are there policies attached to it?
SELECT * FROM TABLE(INFORMATION_SCHEMA.POLICY_REFERENCES(
  REF_ENTITY_NAME   => 'ANALYTICS_DEV_CONNOR.SALES.SALES_MOVEMENT',
  REF_ENTITY_DOMAIN => 'VIEW'));

-- C. Same question for whatever A says it reads from
SELECT * FROM TABLE(INFORMATION_SCHEMA.POLICY_REFERENCES(
  REF_ENTITY_NAME   => '<the upstream db.schema.table from A>',
  REF_ENTITY_DOMAIN => 'TABLE'));

-- D. The decisive test: count rows on the upstream object directly
SELECT COUNT(*) FROM <upstream db.schema.table>;
