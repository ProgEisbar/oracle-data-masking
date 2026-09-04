-- Public contract for the private encryption provider.
--
-- The implementation, key material, IV handling and operational configuration
-- are intentionally not included in this repository. Deploy an internal body
-- that implements this API before running the masking process.

CREATE OR REPLACE PACKAGE SOPORTEDBA.PAN_CRYPTO AS
  C_ENCRYPTION_ALGORITHM CONSTANT VARCHAR2(10) := '3DES';

  FUNCTION DECRYPT_HEX(p_hex IN VARCHAR2) RETURN VARCHAR2;
  FUNCTION ENCRYPT_HEX(p_plain IN VARCHAR2) RETURN VARCHAR2;
END PAN_CRYPTO;
/
