CREATE OR REPLACE PACKAGE SOPORTEDBA.PKG_ENMASCARADO_STG AS
  PROCEDURE load_staging(p_owner IN VARCHAR2, p_table IN VARCHAR2, p_ctcol IN VARCHAR2);

  PROCEDURE merge_table(
    p_owner       IN VARCHAR2,
    p_table       IN VARCHAR2,
    p_ctcol       IN VARCHAR2,
    p_maskcol     IN VARCHAR2 DEFAULT NULL,
    p_buckets     IN PLS_INTEGER DEFAULT 16,
    p_parallel_d  IN PLS_INTEGER DEFAULT 1,
    p_rows_merged OUT NUMBER,          -- ¿ filas actualizadas (SET)
    p_rows_scanned OUT NUMBER          -- ¿ filas candidatas (join/bucket)
  );

  PROCEDURE run_table(
    p_owner       IN VARCHAR2,
    p_table       IN VARCHAR2,
    p_ctcol       IN VARCHAR2,
    p_maskcol     IN VARCHAR2 DEFAULT NULL,
    p_buckets     IN PLS_INTEGER DEFAULT 16,
    p_parallel_d  IN PLS_INTEGER DEFAULT 1
  );
END;
/

CREATE OR REPLACE PACKAGE BODY SOPORTEDBA.PKG_ENMASCARADO_STG AS

  ---------------------------------------------------------------------------
  -- PUBLIC: coincide EXACTO con la spec (3 parámetros)
  ---------------------------------------------------------------------------
  PROCEDURE load_staging(
    p_owner IN VARCHAR2,
    p_table IN VARCHAR2,
    p_ctcol IN VARCHAR2
  ) IS
    v_sql        CLOB;
    v_parallel_d PLS_INTEGER := 1; -- si querés paralelismo, elevá esto o habilitalo fuera con ALTER SESSION
  BEGIN
    IF v_parallel_d > 1 THEN
      EXECUTE IMMEDIATE 'ALTER SESSION ENABLE PARALLEL DML';
    END IF;

    v_sql :=
         'INSERT /*+ APPEND */ INTO SOPORTEDBA.STG_CT_RIDS (CT_NORM, RID) '||
         'SELECT /*+ '||
            CASE WHEN v_parallel_d > 1 THEN 'PARALLEL(s,'||v_parallel_d||') ' ELSE '' END||
         '*/ DISTINCT UPPER(TRIM('||p_ctcol||')) AS CT_NORM, ROWID '||
         'FROM '||p_owner||'.'||p_table||' s '||
         'WHERE '||p_ctcol||' IS NOT NULL';

    EXECUTE IMMEDIATE v_sql;
    COMMIT;
  END load_staging;

  ---------------------------------------------------------------------------
  -- PUBLIC: coincide EXACTO con la spec (parámetros y modos)
  ---------------------------------------------------------------------------
  PROCEDURE merge_table(
    p_owner        IN VARCHAR2,
    p_table        IN VARCHAR2,
    p_ctcol        IN VARCHAR2,
    p_maskcol      IN VARCHAR2,
    p_buckets      IN PLS_INTEGER,
    p_parallel_d   IN PLS_INTEGER,
    p_rows_merged  OUT NUMBER,
    p_rows_scanned OUT NUMBER
  ) IS
    v_sql   CLOB;
    v_hint  VARCHAR2(200);
  BEGIN
    p_rows_merged  := 0;
    p_rows_scanned := 0;

    IF p_parallel_d > 1 THEN
      v_hint := '/*+ MONITOR FULL(d) PARALLEL(d,'||p_parallel_d||') */';
      EXECUTE IMMEDIATE 'ALTER SESSION ENABLE PARALLEL DML';
    ELSE
      v_hint := '/*+ MONITOR */';
    END IF;

    v_sql :=
        'MERGE '||v_hint||' INTO '||p_owner||'.'||p_table||' d '||
        'USING ( '||
        '  SELECT /*+ USE_HASH(s m) '||
              CASE WHEN p_parallel_d > 1 THEN
                   'PARALLEL(s,'||p_parallel_d||') PARALLEL(m,'||p_parallel_d||') '
              ELSE '' END||
        '  */ s.RID, '||
        '         m.NRO_TARJETA_ENCRIPTADA_NUEVA  AS CT_NEW '||
        CASE WHEN p_maskcol IS NOT NULL THEN
        '       ,m.NRO_TARJETA_ENMASCARADA_NUEVA AS MASK_NEW '
        ELSE '' END||
        '    FROM SOPORTEDBA.STG_CT_RIDS s '||
        '    JOIN SOPORTEDBA.TABLA_MAESTRA_TARJETAS m '||
        '      ON s.CT_NORM = m.NRO_TARJETA_ENCRIPTADA_ORIGINAL '||
        ') S '||
        'ON (d.ROWID = S.RID) '||
        'WHEN MATCHED THEN UPDATE SET '||
        '  d.'||p_ctcol||' = S.CT_NEW '||
        CASE WHEN p_maskcol IS NOT NULL THEN
        ' ,d.'||p_maskcol||' = S.MASK_NEW '
        ELSE '' END||
        'WHERE (d.'||p_ctcol||' <> S.CT_NEW OR d.'||p_ctcol||' IS NULL OR S.CT_NEW IS NULL) '||
        CASE WHEN p_maskcol IS NOT NULL THEN
        '   OR (d.'||p_maskcol||' <> S.MASK_NEW OR d.'||p_maskcol||' IS NULL OR S.MASK_NEW IS NULL) '
        ELSE '' END;

    EXECUTE IMMEDIATE v_sql;
    p_rows_merged := SQL%ROWCOUNT;
    COMMIT;
  END merge_table;

  ---------------------------------------------------------------------------
  -- PUBLIC: coincide EXACTO con la spec
  ---------------------------------------------------------------------------
  PROCEDURE run_table(
    p_owner      IN VARCHAR2,
    p_table      IN VARCHAR2,
    p_ctcol      IN VARCHAR2,
    p_maskcol    IN VARCHAR2,
    p_buckets    IN PLS_INTEGER,
    p_parallel_d IN PLS_INTEGER
  ) IS
    v_merged NUMBER := 0;
    v_scan   NUMBER := 0;
  BEGIN
    -- 1) staging
    SOPORTEDBA.PKG_ENMASCARADO_STG.LOAD_STAGING(
      p_owner => p_owner, p_table => p_table, p_ctcol => p_ctcol);

    -- 2) merge
    SOPORTEDBA.PKG_ENMASCARADO_STG.MERGE_TABLE(
      p_owner => p_owner, p_table => p_table, p_ctcol => p_ctcol, p_maskcol => p_maskcol,
      p_buckets => p_buckets, p_parallel_d => p_parallel_d,
      p_rows_merged => v_merged, p_rows_scanned => v_scan
    );

    -- 3) log mínimo
    DBMS_OUTPUT.PUT_LINE('OK '||p_owner||'.'||p_table||' - filas actualizadas: '||TO_CHAR(v_merged));
  EXCEPTION
    WHEN OTHERS THEN
      DBMS_OUTPUT.PUT_LINE('ERROR en '||p_owner||'.'||p_table||': '||SQLERRM);
      RAISE;
  END run_table;

END PKG_ENMASCARADO_STG;
/

