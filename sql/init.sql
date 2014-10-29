-- This should be done with pg_regress's --create-role option
-- but it's blocked by bug 37906
CREATE USER nonsuper;
CREATE USER super SUPERUSER;

-- Can't because of bug 37906
--GRANT ALL ON DATABASE regress TO nonsuper;
--GRANT ALL ON DATABASE regress TO nonsuper;

\c postgres
GRANT ALL ON SCHEMA public TO nonsuper;
\c regression
GRANT ALL ON SCHEMA public TO nonsuper;

SELECT pg_sleep(5);

-- emulate the pg_xlog_wait_remote_apply on vanilla postgres
DO $DO$BEGIN
	PERFORM 1 FROM pg_proc WHERE proname = 'pg_xlog_wait_remote_apply';
	IF FOUND THEN
		RETURN;
	END IF;

	PERFORM bdr.bdr_replicate_ddl_command($DDL$
		CREATE OR REPLACE FUNCTION public.pg_xlog_wait_remote_apply(i_pos pg_lsn, i_pid integer) RETURNS VOID
		AS $FUNC$
		BEGIN
			WHILE EXISTS(SELECT true FROM pg_stat_get_wal_senders() s WHERE s.flush_location < i_pos AND (i_pid = 0 OR s.pid = i_pid)) LOOP
				PERFORM pg_sleep(0.01);
			END LOOP;
		END;$FUNC$ LANGUAGE plpgsql;
	$DDL$);
END;$DO$;
