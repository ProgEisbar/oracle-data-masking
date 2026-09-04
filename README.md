# Oracle Data Masking

Solución PL/SQL para enmascarar números de tarjeta en ambientes no productivos. El proceso transforma PAN cifrados en valores sustitutos determinísticos, conserva las relaciones necesarias para mantener la consistencia referencial y actualiza las tablas de negocio mediante cargas de staging y operaciones `MERGE`.

## Arquitectura del proceso

1. Identificar PAN únicos en las tablas de origen.
2. Descifrar cada valor mediante un proveedor criptográfico configurable.
3. Generar un PAN sustituto válido y reproducible.
4. Cifrar el nuevo valor y registrar la relación en una tabla maestra.
5. Preparar las filas afectadas en tablas de staging.
6. Actualizar las tablas de negocio por lotes.
7. Registrar tiempos, cantidades y estado de cada etapa.

## Componentes

- `Funciones/Funciones_enmascarado.SQL`: funciones de hash, máscara y generación de PAN sustitutos.
- `Packages/Pan_Crypto.sql`: interfaz del proveedor criptográfico compatible con 3DES.
- `Packages/PKG_ENMASCARADO_RUN.sql`: orquestación general del proceso.
- `Packages/PKG_ENMASCARADO_STG.sql`: preparación de staging y actualización por tabla.
- `Tablas_proceso/`: DDL de tablas maestras, staging, comprobación y logging.
- `Querys auxiliares/`: scripts de instalación, índices, ejecución y operaciones auxiliares.

## Tablas principales

- `TABLA_MAESTRA_TARJETAS`: relaciona el PAN de origen con sus representaciones enmascarada, sustituida y cifrada.
- `STG_PAN_UNICOS`: reúne los PAN únicos pendientes de transformación.
- `STG_CT_RIDS`: conserva las filas que deben actualizarse en cada tabla.
- `LOG_ENMASCARADO`: registra cada ejecución.
- `LOG_ENMASCARADO_DET`: registra duración, filas procesadas y estado por etapa.
- `COMPROBACION`: permite validar resultados del proceso.

## Instalación

Ejecutar los scripts con un usuario que pueda crear los objetos requeridos en el schema técnico:

1. crear las tablas y vistas de `Tablas_proceso/`;
2. instalar las funciones de `Funciones/`;
3. instalar la interfaz criptográfica y proporcionar su implementación para el ambiente;
4. crear `PKG_ENMASCARADO_STG` y `PKG_ENMASCARADO_RUN`;
5. aplicar los grants e índices definidos en `Querys auxiliares/`;
6. comprobar que los objetos queden válidos.

La implementación del proveedor debe respetar la interfaz de `PAN_CRYPTO` y obtener claves e IV desde un mecanismo de gestión de secretos; esos valores no deben incorporarse al código fuente.

## Ejecución

El procedimiento principal acepta el schema objetivo, el modo de actualización y parámetros de paralelismo:

```sql
SET SERVEROUTPUT ON
ALTER SESSION ENABLE PARALLEL DML;

BEGIN
  SOPORTEDBA.PKG_ENMASCARADO_RUN.RUN_ALL(
    p_owner    => 'SCHEMA_ENTIDAD',
    p_refresh  => TRUE,
    p_parallel => 3,
    p_buckets  => 16
  );
END;
/
```

- `p_owner`: schema que contiene las tablas de negocio.
- `p_refresh`: reconstruye la tabla maestra cuando es `TRUE` o ejecuta un proceso incremental cuando es `FALSE`.
- `p_parallel`: grado de paralelismo de las cargas y actualizaciones.
- `p_buckets`: cantidad de particiones lógicas utilizadas para procesar la tabla maestra.

## Monitoreo

```sql
SELECT *
FROM SOPORTEDBA.VW_LOG_ENMASCARADO
ORDER BY STARTED_AT DESC;
```

El detalle de `LOG_ENMASCARADO_DET` permite analizar cada etapa, comparar tiempos y revisar la cantidad de filas procesadas. Para ejecuciones extensas se recomienda utilizar una sesión estable o programar la corrida con `DBMS_SCHEDULER`.
