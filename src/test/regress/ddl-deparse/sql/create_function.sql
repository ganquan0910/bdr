CREATE FUNCTION check_foreign_key ()
	RETURNS trigger
	AS '/space/sda1/ibarwick/2ndquadrant_bdr/src/test/regress/ddl-deparse/refint.so'
	LANGUAGE C;