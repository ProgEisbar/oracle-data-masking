CREATE OR REPLACE PACKAGE SOPORTEDBA.PKG_ENMASCARADO_RUN AS

  PROCEDURE RUN_ALL(
    p_owner    IN VARCHAR2,
    p_refresh  IN BOOLEAN,
    p_parallel IN PLS_INTEGER,
    p_buckets  IN PLS_INTEGER
  );

END PKG_ENMASCARADO_RUN;
/

CREATE OR REPLACE PACKAGE BODY SOPORTEDBA.PKG_ENMASCARADO_RUN AS

  ---------------------------------------------------------------------------
  -- Declaración adelantada de privados
  ---------------------------------------------------------------------------
  PROCEDURE verify_sources(p_owner IN VARCHAR2);

  /* ==========================
     Helpers de logging internos
     ========================== */
  PROCEDURE log_start(
    p_run_id   OUT RAW,
    p_owner    IN  VARCHAR2,
    p_op       IN  VARCHAR2,
    p_notes    IN  VARCHAR2 DEFAULT NULL
  ) IS
    PRAGMA AUTONOMOUS_TRANSACTION;
  BEGIN
    p_run_id := SYS_GUID();
    INSERT INTO SOPORTEDBA.LOG_ENMASCARADO
      (run_id,start_ts,owner_name,op_label,session_id,module,action,notes)
    VALUES
      (p_run_id,SYSTIMESTAMP,p_owner,p_op,USERENV('SESSIONID'),
       SYS_CONTEXT('USERENV','MODULE'), SYS_CONTEXT('USERENV','ACTION'), p_notes);
    COMMIT;
  END;

  PROCEDURE log_ok(
    p_run_id    IN RAW,
    p_tmt_rows  IN NUMBER,
    p_backfill  IN NUMBER,
    p_missing   IN NUMBER
  ) IS
    PRAGMA AUTONOMOUS_TRANSACTION;
  BEGIN
    UPDATE SOPORTEDBA.LOG_ENMASCARADO
       SET end_ts              = SYSTIMESTAMP,
           merged_count        = NVL(merged_count,0) + NVL(p_tmt_rows,0),
           backfilled_count    = NVL(backfilled_count,0) + NVL(p_backfill,0),
           missing_after_tmt   = p_missing,
           notes               = CASE WHEN p_backfill>0
                                      THEN NVL(notes,'')||' | backfill='||p_backfill
                                      ELSE notes END
     WHERE run_id = p_run_id;
    COMMIT;
  END;

  PROCEDURE log_err(
    p_run_id     IN RAW,
    p_err_code   IN NUMBER,
    p_err_msg    IN VARCHAR2,
    p_err_stack  IN CLOB,
    p_callstack  IN CLOB
  ) IS
    PRAGMA AUTONOMOUS_TRANSACTION;
  BEGIN
    UPDATE SOPORTEDBA.LOG_ENMASCARADO
       SET end_ts        = SYSTIMESTAMP,
           err_code      = p_err_code,
           err_msg       = SUBSTR(p_err_msg,1,4000),
           err_stack     = p_err_stack,
           err_callstack = p_callstack
     WHERE run_id = p_run_id;
    COMMIT;
  END;

  PROCEDURE log_stage(
    p_run_id         IN RAW,
    p_stage_name     IN VARCHAR2,
    p_owner          IN VARCHAR2,
    p_table_name     IN VARCHAR2 DEFAULT NULL,
    p_start_ts       IN TIMESTAMP DEFAULT NULL,
    p_rows_processed IN NUMBER DEFAULT NULL,
    p_status         IN VARCHAR2 DEFAULT 'OK',
    p_err_code       IN NUMBER DEFAULT NULL,
    p_err_msg        IN VARCHAR2 DEFAULT NULL,
    p_notes          IN VARCHAR2 DEFAULT NULL
  ) IS
    PRAGMA AUTONOMOUS_TRANSACTION;
    v_end_ts          TIMESTAMP(6) := SYSTIMESTAMP;
    v_elapsed_seconds NUMBER;
  BEGIN
    IF p_start_ts IS NOT NULL THEN
      v_elapsed_seconds := ROUND((CAST(v_end_ts AS DATE) - CAST(p_start_ts AS DATE)) * 86400, 2);
    END IF;

    INSERT INTO SOPORTEDBA.LOG_ENMASCARADO_DET
      (run_id, stage_name, owner_name, table_name, start_ts, end_ts,
       elapsed_seconds, rows_processed, status, err_code, err_msg, notes)
    VALUES
      (p_run_id, SUBSTR(p_stage_name,1,80), SUBSTR(p_owner,1,128),
       SUBSTR(p_table_name,1,128), p_start_ts, v_end_ts, v_elapsed_seconds,
       p_rows_processed, SUBSTR(NVL(p_status,'OK'),1,20), p_err_code,
       SUBSTR(p_err_msg,1,4000), SUBSTR(p_notes,1,4000));
    COMMIT;
  EXCEPTION
    WHEN OTHERS THEN
      -- El log de detalle no debe cortar el enmascarado.
      ROLLBACK;
  END;

  ---------------------------------------------------------------------------
  -- Helpers de STAGING / Normalización
  ---------------------------------------------------------------------------

  FUNCTION norm_sql(p_col IN VARCHAR2) RETURN VARCHAR2 IS
  BEGIN
    -- Datos ya vienen normalizados (0-9A-F, uppercase, sin separadores)
    -- Devolvemos el nombre de columna tal cual para evitar CPU de funciones costosas.
    RETURN p_col;
  END;

  PROCEDURE verify_tmt_structure IS
    v_cnt NUMBER;
  BEGIN
    SELECT COUNT(*)
      INTO v_cnt
      FROM all_tab_columns
     WHERE owner='SOPORTEDBA'
       AND table_name='TABLA_MAESTRA_TARJETAS'
       AND column_name='NRO_TARJETA_ENCRIPTADA_ORIGINAL';

    IF v_cnt = 0 THEN
      RAISE_APPLICATION_ERROR(-20002,'Falta columna NRO_TARJETA_ENCRIPTADA_ORIGINAL en TMT');
    END IF;
  END verify_tmt_structure;

  /* ======================================================
     STAGING
     ====================================================== */
  PROCEDURE load_stg_table(
    p_run_id       IN RAW,
    p_owner        IN VARCHAR2,
    p_table        IN VARCHAR2,
    p_card_col     IN VARCHAR2,
    p_parallel_deg IN VARCHAR2,
    p_log_label    IN VARCHAR2 DEFAULT NULL
  ) IS
    v_sql          CLOB;
    v_rows         NUMBER;
    v_stage_start  TIMESTAMP(6);
    v_table        VARCHAR2(128) := DBMS_ASSERT.SIMPLE_SQL_NAME(UPPER(p_table));
    v_card_col     VARCHAR2(128) := DBMS_ASSERT.SIMPLE_SQL_NAME(UPPER(p_card_col));
    v_display_name VARCHAR2(128) := NVL(p_log_label, v_table);
  BEGIN
    v_sql := '
      INSERT /*+ APPEND PARALLEL(dst,'||p_parallel_deg||') */
        INTO SOPORTEDBA.STG_CT_RIDS
          (TABLA_ORIGEN, RID, RID_UROWID, CT_NORM, CT_NEW, MASK_NEW)
      SELECT
        '''||v_table||'''                         AS TABLA_ORIGEN,
        ROWIDTOCHAR(d.ROWID)                      AS RID,
        d.ROWID                                   AS RID_UROWID,
        '||norm_sql('d.'||v_card_col)||'          AS CT_NORM,
        t.NRO_TARJETA_ENCRIPTADA_NUEVA            AS CT_NEW,
        t.NRO_TARJETA_ENMASCARADA_NUEVA           AS MASK_NEW
      FROM '||p_owner||'.'||v_table||' d
      JOIN SOPORTEDBA.TABLA_MAESTRA_TARJETAS t
        ON '||norm_sql('t.NRO_TARJETA_ENCRIPTADA_ORIGINAL')||' =
           '||norm_sql('d.'||v_card_col)||'
      WHERE t.NRO_TARJETA_ENCRIPTADA_NUEVA IS NOT NULL';

    v_stage_start := SYSTIMESTAMP;
    EXECUTE IMMEDIATE v_sql;
    v_rows := SQL%ROWCOUNT;

    DBMS_OUTPUT.PUT_LINE('STG '||v_display_name||' -> '||v_rows||' filas.');
    log_stage(p_run_id, 'STG_LOAD', p_owner, v_table, v_stage_start, v_rows, 'OK',
              p_notes => 'Carga de ROWID a STG_CT_RIDS');
    COMMIT;
  END load_stg_table;

  -- Llena STG_CT_RIDS con los ROWID de las filas reales que matchean TMT.
  PROCEDURE populate_stg_rids(
    p_run_id   IN RAW,
    p_owner    IN VARCHAR2,
    p_parallel IN PLS_INTEGER
  ) IS
    v_owner VARCHAR2(128) := DBMS_ASSERT.SIMPLE_SQL_NAME(UPPER(p_owner));
    v_deg   VARCHAR2(20)  := NVL(TO_CHAR(p_parallel),'1');
  BEGIN
    DBMS_OUTPUT.PUT_LINE('Limpiando STG_CT_RIDS...');
    EXECUTE IMMEDIATE 'TRUNCATE TABLE SOPORTEDBA.STG_CT_RIDS';

    IF p_parallel > 0 THEN
      EXECUTE IMMEDIATE 'ALTER SESSION ENABLE PARALLEL DML';
    ELSE
      EXECUTE IMMEDIATE 'ALTER SESSION DISABLE PARALLEL DML';
    END IF;

    load_stg_table(p_run_id, v_owner, 'AUTORIZACION', 'NRO_TARJETA', v_deg);
    load_stg_table(p_run_id, v_owner, 'AUTORIZACION_CONSULTA', 'NRO_TARJETA', v_deg, 'AUT_CONSULTA');
    load_stg_table(p_run_id, v_owner, 'AUTORIZACION_ADQUIRENTE_LOG', 'IN_NRO_TARJETA', v_deg, 'AUT_ADQ_LOG');
    load_stg_table(p_run_id, v_owner, 'CONSUMOS', 'NRO_TARJETA', v_deg);
    load_stg_table(p_run_id, v_owner, 'IPM', 'NRO_TARJETA', v_deg);
    load_stg_table(p_run_id, v_owner, 'RESPUESTA_MC_LOG', 'IN_NRO_TARJETA', v_deg, 'RESP_MC_LOG');

    -- TQR4_ADQUIRENCIA se actualiza directo desde TMT en la etapa de MERGE.
    EXECUTE IMMEDIATE 'ALTER SESSION DISABLE PARALLEL DML';
  END populate_stg_rids;

  /* ======================================================
     TMT: poblar tabla maestra desde fuentes
     ====================================================== */
  PROCEDURE populate_pan_unicos(
    p_run_id   IN  RAW,
    p_owner    IN  VARCHAR2,
    p_parallel IN  PLS_INTEGER,
    p_buckets  IN  PLS_INTEGER,
    p_rows     OUT NUMBER
  ) IS
    v_owner        VARCHAR2(128) := DBMS_ASSERT.SIMPLE_SQL_NAME(UPPER(p_owner));
    v_sql          CLOB;
    v_deg          VARCHAR2(20) := NVL(TO_CHAR(p_parallel),'1');
    v_bucket_count PLS_INTEGER := GREATEST(NVL(p_buckets,1),1);
    v_stage_start  TIMESTAMP(6);
  BEGIN
    p_rows := 0;

    DBMS_OUTPUT.PUT_LINE('Limpiando STG_PAN_UNICOS...');
    EXECUTE IMMEDIATE 'TRUNCATE TABLE SOPORTEDBA.STG_PAN_UNICOS';

    IF p_parallel > 0 THEN
      EXECUTE IMMEDIATE 'ALTER SESSION ENABLE PARALLEL DML';
    ELSE
      EXECUTE IMMEDIATE 'ALTER SESSION DISABLE PARALLEL DML';
    END IF;

    v_sql := '
      INSERT /*+ APPEND PARALLEL(dst,'||v_deg||') */
        INTO SOPORTEDBA.STG_PAN_UNICOS (CT_NORM, BUCKET_ID)
      SELECT enc_original,
             ORA_HASH(enc_original, '||(v_bucket_count - 1)||') AS bucket_id
      FROM (
        SELECT /*+ PARALLEL(a,'||v_deg||')  */ TRIM(a.nro_tarjeta) AS enc_original
        FROM '||v_owner||'.AUTORIZACION a
        WHERE a.nro_tarjeta IS NOT NULL
        UNION
        SELECT /*+ PARALLEL(al,'||v_deg||') */ TRIM(al.in_nro_tarjeta)
        FROM '||v_owner||'.AUTORIZACION_ADQUIRENTE_LOG al
        WHERE al.in_nro_tarjeta IS NOT NULL
        UNION
        SELECT /*+ PARALLEL(ac,'||v_deg||') */ TRIM(ac.nro_tarjeta)
        FROM '||v_owner||'.AUTORIZACION_CONSULTA ac
        WHERE ac.nro_tarjeta IS NOT NULL
        UNION
        SELECT /*+ PARALLEL(c,'||v_deg||')  */ TRIM(c.nro_tarjeta)
        FROM '||v_owner||'.CONSUMOS c
        WHERE c.nro_tarjeta IS NOT NULL
        UNION
        SELECT /*+ PARALLEL(i,'||v_deg||')  */ TRIM(i.nro_tarjeta)
        FROM '||v_owner||'.IPM i
        WHERE i.nro_tarjeta IS NOT NULL
        UNION
        SELECT /*+ PARALLEL(rl,'||v_deg||') */ TRIM(rl.in_nro_tarjeta)
        FROM '||v_owner||'.RESPUESTA_MC_LOG rl
        WHERE rl.in_nro_tarjeta IS NOT NULL
        UNION
        SELECT /*+ PARALLEL(t4,'||v_deg||') */ TRIM(t4.nro_tarjeta)
        FROM '||v_owner||'.TQR4_ADQUIRENCIA t4
        WHERE t4.nro_tarjeta IS NOT NULL
      )';

    v_stage_start := SYSTIMESTAMP;
    EXECUTE IMMEDIATE v_sql;
    p_rows := SQL%ROWCOUNT;

    DBMS_OUTPUT.PUT_LINE('STG_PAN_UNICOS -> '||p_rows||' PAN únicos.');
    log_stage(p_run_id, 'STG_PAN_UNICOS', v_owner, 'STG_PAN_UNICOS',
              v_stage_start, p_rows, 'OK',
              p_notes => 'Carga de PAN únicos desde fuentes. Buckets='||v_bucket_count);
    COMMIT;
  END populate_pan_unicos;

  PROCEDURE insert_tmt_bucket(
    p_run_id   IN  RAW,
    p_owner    IN  VARCHAR2,
    p_parallel IN  PLS_INTEGER,
    p_bucket   IN  PLS_INTEGER,
    p_rows     OUT NUMBER
  ) IS
    v_sql         CLOB;
    v_deg         VARCHAR2(20) := NVL(TO_CHAR(p_parallel),'1');
    v_stage_start TIMESTAMP(6);
  BEGIN
    p_rows := 0;

    v_sql := '
      INSERT /*+ APPEND PARALLEL(t,'||v_deg||') */
        INTO SOPORTEDBA.TABLA_MAESTRA_TARJETAS (
          NRO_TARJETA_ENCRIPTADA_ORIGINAL,
          NRO_TARJETA_DESENCRIPTADA,
          NRO_TARJETA_MODIFICADA,
          NRO_TARJETA_ENMASCARADA_NUEVA,
          NRO_TARJETA_ENCRIPTADA_NUEVA,
          FECHA_ALTA,
          FUENTE
        )
      WITH fuente AS (
        SELECT /*+ NO_MERGE */ s.CT_NORM AS enc_original,
               s.CT_NORM AS enc_norm
        FROM SOPORTEDBA.STG_PAN_UNICOS s
        WHERE s.BUCKET_ID = '||p_bucket||'
          AND NOT EXISTS (
            SELECT 1
            FROM SOPORTEDBA.TABLA_MAESTRA_TARJETAS t
            WHERE t.NRO_TARJETA_ENCRIPTADA_ORIGINAL = s.CT_NORM
          )
      ),
      base AS (
        SELECT /*+ PARALLEL(f,'||v_deg||') */
               f.enc_original,
               f.enc_norm,
               SOPORTEDBA.PAN_CRYPTO.DECRYPT_HEX(f.enc_original) AS pan_claro
        FROM fuente f
      ),
      calc AS (
        SELECT enc_original,
               enc_norm,
               pan_claro,
               CASE
                 WHEN pan_claro IS NOT NULL
                  AND TRANSLATE(pan_claro, ''0123456789'', '''') IS NULL
                  AND LENGTH(pan_claro) >= 10
                 THEN SOPORTEDBA.GEN_PAN_MODIFICADO(pan_claro)
               END AS pan_mod
        FROM base
      ),
      conv AS (
        SELECT enc_original,
               pan_claro,
               pan_mod,
               CASE WHEN pan_mod IS NOT NULL THEN SOPORTEDBA.MASK_PAN(pan_mod) END AS pan_mask,
               CASE WHEN pan_mod IS NOT NULL THEN SOPORTEDBA.PAN_CRYPTO.ENCRYPT_HEX(pan_mod) END AS enc_nuevo
        FROM calc
      )
      SELECT c.enc_original,
             c.pan_claro,
             c.pan_mod,
             c.pan_mask,
             c.enc_nuevo,
             SYSTIMESTAMP,
             ''TMT_BUCKET''
      FROM conv c';

    v_stage_start := SYSTIMESTAMP;
    EXECUTE IMMEDIATE v_sql;
    p_rows := SQL%ROWCOUNT;

    DBMS_OUTPUT.PUT_LINE('TMT bucket '||p_bucket||' -> '||p_rows||' filas.');
    log_stage(p_run_id, 'TMT_BUCKET', p_owner, 'TABLA_MAESTRA_TARJETAS',
              v_stage_start, p_rows, 'OK',
              p_notes => 'Insercion TMT desde STG_PAN_UNICOS bucket='||p_bucket);
    COMMIT;
  END insert_tmt_bucket;

  PROCEDURE populate_tmt_from_sources(
    p_run_id        IN  RAW,
    p_owner         IN  VARCHAR2,
    p_parallel      IN  PLS_INTEGER,
    p_buckets       IN  PLS_INTEGER,
    p_inserted      OUT NUMBER,
    p_missing_post  OUT NUMBER
  ) IS
    v_owner       VARCHAR2(128) := DBMS_ASSERT.SIMPLE_SQL_NAME(UPPER(p_owner));
    v_sql         CLOB;
    v_stage_rows  NUMBER := 0;
    v_bucket_rows NUMBER := 0;
    v_deg         VARCHAR2(20) := NVL(TO_CHAR(p_parallel),'1');
    v_bucket_count PLS_INTEGER := GREATEST(NVL(p_buckets,1),1);
    v_stage_start TIMESTAMP(6);
  BEGIN
    p_inserted     := 0;
    p_missing_post := 0;

    -- Config de parallel (si aplica)
    IF p_parallel > 0 THEN
      EXECUTE IMMEDIATE 'ALTER TABLE SOPORTEDBA.TABLA_MAESTRA_TARJETAS PARALLEL '||v_deg;
      EXECUTE IMMEDIATE 'ALTER SESSION ENABLE PARALLEL DML';
    ELSE
      EXECUTE IMMEDIATE 'ALTER SESSION DISABLE PARALLEL DML';
      EXECUTE IMMEDIATE 'ALTER TABLE SOPORTEDBA.TABLA_MAESTRA_TARJETAS NOPARALLEL';
    END IF;

    populate_pan_unicos(p_run_id, v_owner, p_parallel, v_bucket_count, v_stage_rows);

    FOR i IN 0 .. (v_bucket_count - 1) LOOP
      insert_tmt_bucket(p_run_id, v_owner, p_parallel, i, v_bucket_rows);
      p_inserted := p_inserted + NVL(v_bucket_rows,0);
    END LOOP;

    ------------------------------------------------------------------
    -- Control de faltantes contra STG_PAN_UNICOS
    ------------------------------------------------------------------
    EXECUTE IMMEDIATE 'ALTER SESSION DISABLE PARALLEL DML';

    v_sql := '
      SELECT COUNT(*)
      FROM SOPORTEDBA.STG_PAN_UNICOS s
      WHERE NOT EXISTS (
        SELECT 1
        FROM   SOPORTEDBA.TABLA_MAESTRA_TARJETAS t
        WHERE  t.NRO_TARJETA_ENCRIPTADA_ORIGINAL = s.CT_NORM
      )';

    v_stage_start := SYSTIMESTAMP;
    EXECUTE IMMEDIATE v_sql INTO p_missing_post;
    log_stage(p_run_id, 'TMT_CONTROL_FALTANTES', v_owner, 'TABLA_MAESTRA_TARJETAS',
              v_stage_start, p_missing_post, 'OK',
              p_notes => 'Cantidad de PAN únicos faltantes post-buckets');

    -- dejar prolijo
    EXECUTE IMMEDIATE 'ALTER SESSION DISABLE PARALLEL DML';
    IF p_parallel > 0 THEN
      EXECUTE IMMEDIATE 'ALTER TABLE SOPORTEDBA.TABLA_MAESTRA_TARJETAS NOPARALLEL';
    END IF;

  END populate_tmt_from_sources;


  /* ======================================================
     MERGES FINALES SOBRE TABLAS DE NEGOCIO
     ====================================================== */
  PROCEDURE merge_business_table(
    p_run_id     IN RAW,
    p_owner      IN VARCHAR2,
    p_parallel   IN PLS_INTEGER,
    p_table      IN VARCHAR2,
    p_card_col   IN VARCHAR2,
    p_mask_col   IN VARCHAR2 DEFAULT NULL
  ) IS
    v_owner       VARCHAR2(128) := DBMS_ASSERT.SIMPLE_SQL_NAME(UPPER(p_owner));
    v_table       VARCHAR2(128) := DBMS_ASSERT.SIMPLE_SQL_NAME(UPPER(p_table));
    v_card_col    VARCHAR2(128) := DBMS_ASSERT.SIMPLE_SQL_NAME(UPPER(p_card_col));
    v_mask_col    VARCHAR2(128);
    v_sql         CLOB;
    v_deg         VARCHAR2(20) := NVL(TO_CHAR(p_parallel),'1');
    v_rows        NUMBER;
    v_stage_start TIMESTAMP(6);
    v_notes       VARCHAR2(4000);
  BEGIN
    IF p_mask_col IS NOT NULL THEN
      v_mask_col := DBMS_ASSERT.SIMPLE_SQL_NAME(UPPER(p_mask_col));
    END IF;

    v_sql := '
      MERGE /*+ USE_HASH(dst src) PARALLEL(dst,'||v_deg||') */
      INTO '||v_owner||'.'||v_table||' dst
      USING (
        SELECT s.RID_UROWID AS RID,
               s.CT_NEW     AS ct_new'||
               CASE WHEN v_mask_col IS NOT NULL THEN
                 ', s.MASK_NEW AS mask_new'
               ELSE '' END||'
        FROM   SOPORTEDBA.STG_CT_RIDS s
        WHERE  s.TABLA_ORIGEN = '''||v_table||'''
          AND  s.CT_NEW IS NOT NULL
      ) src
      ON (dst.ROWID = src.RID)
      WHEN MATCHED THEN UPDATE SET
        dst.'||v_card_col||' = src.ct_new'||
        CASE WHEN v_mask_col IS NOT NULL THEN
          ', dst.'||v_mask_col||' = src.mask_new'
        ELSE '' END||'
      WHERE
           dst.'||v_card_col||' <> src.ct_new
        OR (dst.'||v_card_col||' IS NULL AND src.ct_new IS NOT NULL)
        OR (dst.'||v_card_col||' IS NOT NULL AND src.ct_new IS NULL)'||
        CASE WHEN v_mask_col IS NOT NULL THEN
          ' OR (dst.'||v_mask_col||' <> src.mask_new
               OR (dst.'||v_mask_col||' IS NULL AND src.mask_new IS NOT NULL)
               OR (dst.'||v_mask_col||' IS NOT NULL AND src.mask_new IS NULL))'
        ELSE '' END;

    v_stage_start := SYSTIMESTAMP;
    EXECUTE IMMEDIATE v_sql;
    v_rows := SQL%ROWCOUNT;

    DBMS_OUTPUT.PUT_LINE('Merge '||v_table||' -> '||v_rows||' filas.');
    v_notes := 'Actualizacion de '||v_card_col||
               CASE WHEN v_mask_col IS NOT NULL THEN ' y '||v_mask_col ELSE '' END;
    log_stage(p_run_id, 'MERGE_TABLE', v_owner, v_table, v_stage_start, v_rows, 'OK',
              p_notes => v_notes);
    COMMIT;
  EXCEPTION
    WHEN OTHERS THEN
      DBMS_OUTPUT.PUT_LINE('WARN '||p_table||' ('||p_card_col||'): '||SQLERRM);
      log_stage(p_run_id, 'MERGE_TABLE', p_owner, p_table, v_stage_start, NULL, 'WARN',
                SQLCODE, SQLERRM, 'Actualizacion de '||p_card_col);
  END merge_business_table;

  PROCEDURE merge_tqr4_direct(
    p_run_id   IN RAW,
    p_owner    IN VARCHAR2,
    p_parallel IN PLS_INTEGER
  ) IS
    v_sql         CLOB;
    v_deg         VARCHAR2(20)  := NVL(TO_CHAR(p_parallel),'1');
    v_owner       VARCHAR2(128) := DBMS_ASSERT.SIMPLE_SQL_NAME(UPPER(p_owner));
    v_rows        NUMBER;
    v_stage_start TIMESTAMP(6);
  BEGIN
    v_sql :=
      'MERGE /*+ LEADING(d) USE_HASH(t) PARALLEL(d,'||v_deg||') PARALLEL(t,'||v_deg||') */ '||
      'INTO '||v_owner||'.TQR4_ADQUIRENCIA d '||
      'USING ('||
      '  SELECT /*+ NO_MERGE */ d.ROWID AS rid, t.NRO_TARJETA_ENCRIPTADA_NUEVA AS ct_new '||
      '  FROM '||v_owner||'.TQR4_ADQUIRENCIA d '||
      '  JOIN SOPORTEDBA.TABLA_MAESTRA_TARJETAS t '||
      '    ON t.NRO_TARJETA_ENCRIPTADA_ORIGINAL = d.NRO_TARJETA '||
      '  WHERE t.NRO_TARJETA_ENCRIPTADA_NUEVA IS NOT NULL '||
      '    AND d.NRO_TARJETA IS NOT NULL '||
      ') src '||
      'ON (d.ROWID = src.rid) '||
      'WHEN MATCHED THEN UPDATE SET d.NRO_TARJETA = src.ct_new '||
      'WHERE d.NRO_TARJETA <> src.ct_new '||
      '   OR (d.NRO_TARJETA IS NULL AND src.ct_new IS NOT NULL) '||
      '   OR (d.NRO_TARJETA IS NOT NULL AND src.ct_new IS NULL)';

    v_stage_start := SYSTIMESTAMP;
    EXECUTE IMMEDIATE v_sql;
    v_rows := SQL%ROWCOUNT;

    DBMS_OUTPUT.PUT_LINE('Merge TQR4_ADQUIRENCIA (directo) -> '||v_rows||' filas.');
    log_stage(p_run_id, 'MERGE_TABLE_DIRECT', v_owner, 'TQR4_ADQUIRENCIA', v_stage_start, v_rows, 'OK',
              p_notes => 'Actualizacion directa de NRO_TARJETA');
    COMMIT;
  EXCEPTION
    WHEN OTHERS THEN
      DBMS_OUTPUT.PUT_LINE('WARN TQR4_ADQUIRENCIA (directo): '||SQLERRM);
      log_stage(p_run_id, 'MERGE_TABLE_DIRECT', v_owner, 'TQR4_ADQUIRENCIA', v_stage_start, NULL, 'WARN',
                SQLCODE, SQLERRM, 'Actualizacion directa de NRO_TARJETA');
  END merge_tqr4_direct;

  PROCEDURE merge_tc33a_mask(
    p_run_id   IN RAW,
    p_owner    IN VARCHAR2,
    p_parallel IN PLS_INTEGER
  ) IS
    v_sql         CLOB;
    v_deg         VARCHAR2(20)  := NVL(TO_CHAR(p_parallel),'1');
    v_owner       VARCHAR2(128) := DBMS_ASSERT.SIMPLE_SQL_NAME(UPPER(p_owner));
    v_rows        NUMBER;
    v_stage_start TIMESTAMP(6);
  BEGIN
    v_sql :=
      'MERGE /*+ PARALLEL(tc,'||v_deg||') */ INTO '||v_owner||'.TC33A tc '||
      'USING ( '||
      '  SELECT /*+ USE_HASH(tm c tc) PARALLEL(tm,'||v_deg||') PARALLEL(c,'||v_deg||') PARALLEL(tc,'||v_deg||') */ '||
      '         tc.ROWID AS rid, '||
      '         tm.NRO_TARJETA_ENMASCARADA_NUEVA AS mask_new '||
      '  FROM   '||v_owner||'.TC33A tc '||
      '  JOIN   '||v_owner||'.CONSUMOS c '||
      '         ON c.ID_CONSUMO = tc.ID_TC33A '||
      '  JOIN   SOPORTEDBA.TABLA_MAESTRA_TARJETAS tm '||
      '         ON tm.NRO_TARJETA_ENCRIPTADA_NUEVA = c.NRO_TARJETA '||
      '  WHERE  tm.NRO_TARJETA_ENMASCARADA_NUEVA IS NOT NULL '||
      ') src '||
      'ON (tc.ROWID = src.rid) '||
      'WHEN MATCHED THEN UPDATE SET tc.NRO_TARJETA_ENMASCARADA = src.mask_new '||
      'WHERE tc.NRO_TARJETA_ENMASCARADA <> src.mask_new '||
      '   OR (tc.NRO_TARJETA_ENMASCARADA IS NULL AND src.mask_new IS NOT NULL) '||
      '   OR (tc.NRO_TARJETA_ENMASCARADA IS NOT NULL AND src.mask_new IS NULL)';

    v_stage_start := SYSTIMESTAMP;
    EXECUTE IMMEDIATE v_sql;
    v_rows := SQL%ROWCOUNT;

    DBMS_OUTPUT.PUT_LINE('Merge TC33A NRO_TARJETA_ENMASCARADA -> '||v_rows||' filas.');
    log_stage(p_run_id, 'MERGE_TC33A_MASK', v_owner, 'TC33A', v_stage_start, v_rows, 'OK',
              p_notes => 'Actualizacion de TC33A.NRO_TARJETA_ENMASCARADA via CONSUMOS');
    COMMIT;
  EXCEPTION
    WHEN OTHERS THEN
      DBMS_OUTPUT.PUT_LINE('WARN TC33A (NRO_TARJETA_ENMASCARADA): '||SQLERRM);
      log_stage(p_run_id, 'MERGE_TC33A_MASK', v_owner, 'TC33A', v_stage_start, NULL, 'WARN',
                SQLCODE, SQLERRM||' | '||DBMS_UTILITY.FORMAT_ERROR_STACK,
                'Fallo en paralelo. Se reintenta sin parallel.');

      DBMS_OUTPUT.PUT_LINE('Reintentando TC33A sin parallel...');
      EXECUTE IMMEDIATE 'ALTER SESSION DISABLE PARALLEL DML';

      v_sql :=
        'MERGE INTO '||v_owner||'.TC33A tc '||
        'USING ( '||
        '  SELECT tc.ROWID AS rid, '||
        '         tm.NRO_TARJETA_ENMASCARADA_NUEVA AS mask_new '||
        '  FROM   '||v_owner||'.TC33A tc '||
        '  JOIN   '||v_owner||'.CONSUMOS c '||
        '         ON c.ID_CONSUMO = tc.ID_TC33A '||
        '  JOIN   SOPORTEDBA.TABLA_MAESTRA_TARJETAS tm '||
        '         ON tm.NRO_TARJETA_ENCRIPTADA_NUEVA = c.NRO_TARJETA '||
        '  WHERE  tm.NRO_TARJETA_ENMASCARADA_NUEVA IS NOT NULL '||
        ') src '||
        'ON (tc.ROWID = src.rid) '||
        'WHEN MATCHED THEN UPDATE SET tc.NRO_TARJETA_ENMASCARADA = src.mask_new '||
        'WHERE tc.NRO_TARJETA_ENMASCARADA <> src.mask_new '||
        '   OR (tc.NRO_TARJETA_ENMASCARADA IS NULL AND src.mask_new IS NOT NULL) '||
        '   OR (tc.NRO_TARJETA_ENMASCARADA IS NOT NULL AND src.mask_new IS NULL)';

      BEGIN
        v_stage_start := SYSTIMESTAMP;
        EXECUTE IMMEDIATE v_sql;
        v_rows := SQL%ROWCOUNT;

        DBMS_OUTPUT.PUT_LINE('Merge TC33A serial -> '||v_rows||' filas.');
        log_stage(p_run_id, 'MERGE_TC33A_MASK_SERIAL', v_owner, 'TC33A', v_stage_start, v_rows, 'OK',
                  p_notes => 'Reintento serial de TC33A.NRO_TARJETA_ENMASCARADA via CONSUMOS');
        COMMIT;
      EXCEPTION
        WHEN OTHERS THEN
          DBMS_OUTPUT.PUT_LINE('WARN TC33A serial (NRO_TARJETA_ENMASCARADA): '||SQLERRM);
          log_stage(p_run_id, 'MERGE_TC33A_MASK_SERIAL', v_owner, 'TC33A', v_stage_start, NULL, 'WARN',
                    SQLCODE, SQLERRM||' | '||DBMS_UTILITY.FORMAT_ERROR_STACK,
                    'Tambien fallo el reintento serial de TC33A.');
      END;
  END merge_tc33a_mask;

  PROCEDURE merge_business_tables(
    p_run_id   IN RAW,
    p_owner    IN VARCHAR2,
    p_parallel IN PLS_INTEGER
  ) IS
  BEGIN
    IF p_parallel > 0 THEN
      EXECUTE IMMEDIATE 'ALTER SESSION ENABLE PARALLEL DML';
    ELSE
      EXECUTE IMMEDIATE 'ALTER SESSION DISABLE PARALLEL DML';
    END IF;

    merge_business_table(p_run_id, p_owner, p_parallel, 'AUTORIZACION', 'NRO_TARJETA', 'NRO_TARJETA_ENMASCARADA');
    merge_business_table(p_run_id, p_owner, p_parallel, 'AUTORIZACION_CONSULTA', 'NRO_TARJETA', 'NRO_TARJETA_ENMASCARADA');
    merge_business_table(p_run_id, p_owner, p_parallel, 'AUTORIZACION_ADQUIRENTE_LOG', 'IN_NRO_TARJETA');
    merge_business_table(p_run_id, p_owner, p_parallel, 'CONSUMOS', 'NRO_TARJETA');
    merge_tc33a_mask(p_run_id, p_owner, p_parallel);
    merge_business_table(p_run_id, p_owner, p_parallel, 'IPM', 'NRO_TARJETA');
    merge_business_table(p_run_id, p_owner, p_parallel, 'RESPUESTA_MC_LOG', 'IN_NRO_TARJETA');
    merge_tqr4_direct(p_run_id, p_owner, p_parallel);

    EXECUTE IMMEDIATE 'ALTER SESSION DISABLE PARALLEL DML';
  END merge_business_tables;


  /* =========================================
     3) Orquestador principal RUN_ALL
     ========================================= */
  PROCEDURE RUN_ALL(
    p_owner    IN VARCHAR2,
    p_refresh  IN BOOLEAN,
    p_parallel IN PLS_INTEGER,
    p_buckets  IN PLS_INTEGER
  ) IS
    v_run_id        RAW(16);
    v_inserted_tmt  NUMBER := 0;
    v_inserted_total NUMBER := 0;
    v_missing_post  NUMBER := NULL;

    e_busy     EXCEPTION; PRAGMA EXCEPTION_INIT(e_busy,     -54);
    e_deadlock EXCEPTION; PRAGMA EXCEPTION_INIT(e_deadlock, -60);
  BEGIN
    DBMS_APPLICATION_INFO.SET_MODULE('ENMASCARADO_RUN','RUN_ALL '||p_owner);

    EXECUTE IMMEDIATE 'ALTER SESSION DISABLE PARALLEL DML';
    EXECUTE IMMEDIATE 'ALTER TABLE SOPORTEDBA.STG_CT_RIDS NOPARALLEL';
    COMMIT;

    log_start(
      p_run_id => v_run_id,
      p_owner  => p_owner,
      p_op     => CASE WHEN p_refresh THEN 'REFRESH' ELSE 'INCREMENTAL' END,
      p_notes  => 'PARALLEL='||p_parallel||' BUCKETS='||p_buckets
    );

    verify_sources(p_owner);
    verify_tmt_structure;

    IF p_refresh THEN
      DECLARE
        v_stage_start TIMESTAMP(6) := SYSTIMESTAMP;
      BEGIN
        EXECUTE IMMEDIATE 'TRUNCATE TABLE SOPORTEDBA.TABLA_MAESTRA_TARJETAS';
        log_stage(v_run_id, 'TMT_TRUNCATE', p_owner, 'TABLA_MAESTRA_TARJETAS', v_stage_start, NULL, 'OK');
      END;
    END IF;

    populate_tmt_from_sources(v_run_id, p_owner, p_parallel, p_buckets, v_inserted_tmt, v_missing_post);
    v_inserted_total := v_inserted_total + NVL(v_inserted_tmt,0);
    COMMIT;
    EXECUTE IMMEDIATE 'ALTER SESSION DISABLE PARALLEL DML';

    IF v_missing_post > 0 THEN
      DBMS_OUTPUT.PUT_LINE('Reintento de inserción de faltantes ('||v_missing_post||')…');
      populate_tmt_from_sources(v_run_id, p_owner, p_parallel, p_buckets, v_inserted_tmt, v_missing_post);
      v_inserted_total := v_inserted_total + NVL(v_inserted_tmt,0);
      COMMIT;
      EXECUTE IMMEDIATE 'ALTER SESSION DISABLE PARALLEL DML';
    END IF;

    populate_stg_rids(v_run_id, p_owner, p_parallel);  -- llena STG y hace COMMIT

    merge_business_tables(v_run_id, p_owner, p_parallel);

    log_ok(v_run_id, v_inserted_total, 0, v_missing_post);
    COMMIT;

  EXCEPTION
    WHEN e_busy THEN
      DBMS_OUTPUT.PUT_LINE('ERROR (ORA-00054) recurso ocupado.');
      log_err(v_run_id, SQLCODE, SQLERRM,
              TO_CLOB(DBMS_UTILITY.FORMAT_ERROR_BACKTRACE),
              TO_CLOB(DBMS_UTILITY.FORMAT_CALL_STACK));
      RAISE;
    WHEN e_deadlock THEN
      DBMS_OUTPUT.PUT_LINE('ERROR (ORA-00060) deadlock.');
      log_err(v_run_id, SQLCODE, SQLERRM,
              TO_CLOB(DBMS_UTILITY.FORMAT_ERROR_BACKTRACE),
              TO_CLOB(DBMS_UTILITY.FORMAT_CALL_STACK));
      RAISE;
    WHEN OTHERS THEN
      DBMS_OUTPUT.PUT_LINE('ERROR general: '||SQLERRM);
      log_err(v_run_id, SQLCODE, SQLERRM,
              TO_CLOB(DBMS_UTILITY.FORMAT_ERROR_BACKTRACE),
              TO_CLOB(DBMS_UTILITY.FORMAT_CALL_STACK));
      ROLLBACK;
      RAISE;
  END RUN_ALL;

  /* ======================================================
     verify_sources (privado)
     ====================================================== */
  PROCEDURE verify_sources(p_owner IN VARCHAR2) IS
    v_owner VARCHAR2(128) := DBMS_ASSERT.SIMPLE_SQL_NAME(UPPER(p_owner));
    TYPE t_arr IS TABLE OF VARCHAR2(64);
    l_tabs t_arr := t_arr('AUTORIZACION','AUTORIZACION_ADQUIRENTE_LOG','AUTORIZACION_CONSULTA',
                          'CONSUMOS','IPM','RESPUESTA_MC_LOG','TQR4_ADQUIRENCIA','TC33A');
    l_missing_objs   t_arr := t_arr();
    l_missing_grants t_arr := t_arr();
    l_cnt NUMBER;
  BEGIN
    FOR i IN 1 .. l_tabs.COUNT LOOP
      SELECT COUNT(*) INTO l_cnt
      FROM   all_objects o
      WHERE  o.owner       = v_owner
      AND    o.object_name = l_tabs(i)
      AND    o.object_type IN ('TABLE','VIEW');

      IF l_cnt = 0 THEN
        l_missing_objs.EXTEND;  l_missing_objs(l_missing_objs.COUNT) := l_tabs(i);
      ELSE
        SELECT COUNT(*) INTO l_cnt
        FROM (
          SELECT DISTINCT tp.privilege
          FROM   dba_tab_privs tp
          WHERE  tp.grantee     = 'SOPORTEDBA'
          AND    tp.owner       = v_owner
          AND    tp.table_name  = l_tabs(i)
          AND    tp.privilege   IN ('SELECT','UPDATE')
        )
        WHERE privilege IN ('SELECT','UPDATE');

        IF l_cnt < 2 THEN
          l_missing_grants.EXTEND;  l_missing_grants(l_missing_grants.COUNT) := l_tabs(i);
        END IF;
      END IF;
    END LOOP;

    IF l_missing_objs.COUNT > 0 OR l_missing_grants.COUNT > 0 THEN
      DBMS_OUTPUT.PUT_LINE('Verificación de fuentes:');
      DECLARE
        v_objs_txt   VARCHAR2(4000) := NULL;
        v_grants_txt VARCHAR2(4000) := NULL;
      BEGIN
        IF l_missing_objs.COUNT > 0 THEN
          FOR i IN 1 .. l_missing_objs.COUNT LOOP
            v_objs_txt := v_objs_txt||CASE WHEN i>1 THEN ', ' END||l_missing_objs(i);
          END LOOP;
          DBMS_OUTPUT.PUT_LINE(' - No existen en '||v_owner||': '||v_objs_txt);
        END IF;

        IF l_missing_grants.COUNT > 0 THEN
          FOR i IN 1 .. l_missing_grants.COUNT LOOP
            v_grants_txt := v_grants_txt||CASE WHEN i>1 THEN ', ' END||l_missing_grants(i);
          END LOOP;
          DBMS_OUTPUT.PUT_LINE(' - Falta GRANT SELECT/UPDATE a SOPORTEDBA en: '||v_grants_txt);
        END IF;

        RAISE_APPLICATION_ERROR(-20001,'Fuentes incompletas o sin permisos');
      END;
    END IF;
  END verify_sources;

END PKG_ENMASCARADO_RUN;
/

