CREATE OR REPLACE FORCE VIEW SOPORTEDBA.VW_LOG_ENMASCARADO
(LOG_RUN_ID, STARTED_AT, ENDED_AT, SOURCE_OWNER, SOURCE_TABLE, 
 OPERATION, AFFECTED_ROWS, BACKFILLED_ROWS, REMAINING_MISSING, ORACLE_SESSION_ID, 
 APP_MODULE, APP_ACTION, ERROR_CODE, ERROR_MESSAGE, ERROR_BACKTRACE, 
 ERROR_CALLSTACK, NOTES)
BEQUEATH DEFINER
AS 
SELECT
  run_id                         AS log_run_id,
  start_ts                       AS started_at,
  end_ts                         AS ended_at,
  owner_name                     AS source_owner,
  table_name                     AS source_table,
  op_label                       AS operation,
  merged_count                   AS affected_rows,
  backfilled_count               AS backfilled_rows,
  missing_after_tmt              AS remaining_missing,
  session_id                     AS oracle_session_id,
  module                         AS app_module,
  action                         AS app_action,
  err_code                       AS error_code,
  err_msg                        AS error_message,
  err_stack                      AS error_backtrace,
  err_callstack                  AS error_callstack,
  notes                          AS notes
FROM SOPORTEDBA.LOG_ENMASCARADO;


CREATE OR REPLACE FORCE VIEW SOPORTEDBA.VW_LOG_ENMASCARADO_DET
(LOG_RUN_ID, STAGE_NAME, SOURCE_OWNER, SOURCE_TABLE, STARTED_AT,
 ENDED_AT, ELAPSED_SECONDS, ROWS_PROCESSED, STATUS, ERROR_CODE,
 ERROR_MESSAGE, NOTES)
BEQUEATH DEFINER
AS
SELECT
  run_id          AS log_run_id,
  stage_name      AS stage_name,
  owner_name      AS source_owner,
  table_name      AS source_table,
  start_ts        AS started_at,
  end_ts          AS ended_at,
  elapsed_seconds AS elapsed_seconds,
  rows_processed  AS rows_processed,
  status          AS status,
  err_code        AS error_code,
  err_msg         AS error_message,
  notes           AS notes
FROM SOPORTEDBA.LOG_ENMASCARADO_DET;
