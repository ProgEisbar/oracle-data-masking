a) Corrida completa con refresh total de TMT (recomendado por owner)
SET SERVEROUTPUT ON
ALTER SESSION ENABLE PARALLEL DML;
BEGIN
  -- Ejecuta el proceso de enmascarado completo
  SOPORTEDBA.PKG_ENMASCARADO_RUN.RUN_ALL(
    p_owner    => 'ENTIDAD703', -- esquema de la entidad sobre la que se trabajará
    p_refresh  => TRUE,              -- si es TRUE: trunca y recarga completamente la TMT
    p_parallel => 1,                 -- grado de paralelismo usado en los MERGE/INSERT
    p_buckets  => 16                 -- número de bloques de trabajo (reservado, se registra pero no se usa)
  );
END;
/

b) Corrida incremental (no trunca TMT; agrega CT nuevos)
SET SERVEROUTPUT ON
ALTER SESSION ENABLE PARALLEL DML;
BEGIN
  SOPORTEDBA.PKG_ENMASCARADO_RUN.RUN_ALL(
    p_owner    => 'PROD_ENTIDAD700',
    p_refresh  => FALSE,   -- anti-join: inserta en TMT sólo CT no presentes
    p_parallel => 1,
    p_buckets  => 16
  );
END;
/