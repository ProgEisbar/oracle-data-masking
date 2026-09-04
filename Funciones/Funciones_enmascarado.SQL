CREATE OR REPLACE FUNCTION SOPORTEDBA.MD5_HEX(p_text IN VARCHAR2)
  RETURN VARCHAR2
  DETERMINISTIC
AS
  v_out VARCHAR2(32);
BEGIN
  IF p_text IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT RAWTOHEX(
           STANDARD_HASH(
             UTL_I18N.STRING_TO_RAW(p_text, 'AL32UTF8'),
             'MD5'
           )
         )
    INTO v_out
    FROM dual;

  RETURN v_out;
END;
/

CREATE OR REPLACE FUNCTION SOPORTEDBA.MASK_PAN(p_pan IN VARCHAR2)
RETURN VARCHAR2
IS
  v_pan VARCHAR2(40) := REGEXP_REPLACE(p_pan, '[^0-9]', '');
  v_len PLS_INTEGER;
BEGIN
  v_len := LENGTH(v_pan);
  IF v_len < 10 THEN
    RETURN NULL;
  END IF;

  RETURN SUBSTR(v_pan, 1, 6)
         || RPAD('x', v_len - 10, 'x')
         || SUBSTR(v_pan, v_len - 3, 4);
END;
/


CREATE OR REPLACE FUNCTION SOPORTEDBA.GEN_PAN_MODIFICADO(p_pan IN VARCHAR2)
  RETURN VARCHAR2
  DETERMINISTIC
IS
  v_pan        VARCHAR2(40) := REGEXP_REPLACE(p_pan, '[^0-9]', '');
  v_len        PLS_INTEGER;
  v_md5        VARCHAR2(32);
  v_middle6    VARCHAR2(6) := '';
  v_pair       VARCHAR2(2);
  v_digit      PLS_INTEGER;

  v_middle_len PLS_INTEGER;  -- cantidad de dígitos entre los 6 primeros y los 4 últimos
  v_change_len PLS_INTEGER;  -- cuántos del centro vamos a pisar (hasta 6)
  v_tail_len   PLS_INTEGER;  -- resto del centro que queda igual
  v_tail       VARCHAR2(40);
BEGIN
  v_len := LENGTH(v_pan);
  IF v_len < 10 THEN
    -- No parece PAN válido
    RETURN NULL;
  END IF;

  -- Hash determinístico del PAN original
  v_md5 := SOPORTEDBA.MD5_HEX(v_pan);

  -- Generamos 6 dígitos pseudo-random a partir del hash (0-9)
  FOR i IN 0 .. 5 LOOP
    v_pair  := SUBSTR(v_md5, 1 + 2*i, 2);        -- 2 hex -> 0..255
    v_digit := MOD(TO_NUMBER(v_pair, 'XX'), 10); -- 0..9
    v_middle6 := v_middle6 || v_digit;
  END LOOP;

  -- Longitud del "centro" (entre los 6 primeros y los 4 últimos)
  v_middle_len := v_len - 10;
  IF v_middle_len <= 0 THEN
    -- No hay centro, devolvemos sin modificar
    RETURN v_pan;
  END IF;

  -- Pisamos hasta 6 dígitos del centro
  v_change_len := LEAST(6, v_middle_len);
  v_tail_len   := v_middle_len - v_change_len;

  IF v_tail_len > 0 THEN
    -- parte central que queda igual (después de los 6 modificados)
    v_tail := SUBSTR(v_pan, 7 + v_change_len, v_tail_len);
  ELSE
    v_tail := NULL;
  END IF;

  RETURN SUBSTR(v_pan, 1, 6)                 -- primeros 6
         || SUBSTR(v_middle6, 1, v_change_len) -- centro modificado
         || NVL(v_tail, '')                  -- resto del centro sin tocar
         || SUBSTR(v_pan, v_len - 3, 4);     -- últimos 4
END;
/


