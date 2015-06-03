SET LOCAL search_path = bdr;
SET bdr.permit_unsafe_ddl_commands = true;
SET bdr.skip_ddl_replication = true;

-- Read-only node support
ALTER TABLE bdr.bdr_nodes ADD COLUMN node_read_only boolean DEFAULT false;

CREATE FUNCTION bdr.bdr_node_set_read_only(
    node_name text,
    read_only boolean
) RETURNS void LANGUAGE C VOLATILE
AS 'MODULE_PATHNAME';

CREATE OR REPLACE FUNCTION bdr.bdr_unsubscribe(node_name text)
RETURNS void LANGUAGE plpgsql VOLATILE
SET search_path = bdr, pg_catalog
SET bdr.permit_unsafe_ddl_commands = on
SET bdr.skip_ddl_replication = on
SET bdr.skip_ddl_locking = on
AS $body$
DECLARE
    localid record;
    remoteid record;
    v_node_name alias for node_name;
BEGIN
    -- Concurrency
    LOCK TABLE bdr.bdr_connections IN EXCLUSIVE MODE;
    LOCK TABLE bdr.bdr_nodes IN EXCLUSIVE MODE;
    LOCK TABLE pg_catalog.pg_shseclabel IN EXCLUSIVE MODE;

    -- Check the node exists
    SELECT node_sysid AS sysid, node_timeline AS timeline,
           node_dboid AS dboid INTO remoteid
    FROM bdr.bdr_nodes
    WHERE bdr_nodes.node_name = v_node_name;

    IF NOT FOUND THEN
        RAISE NOTICE 'Node % not found, nothing done', v_node_name;
        RETURN;
    END IF;

    -- Check the connection is unidirectional
    SELECT sysid, timeline, dboid INTO localid
    FROM bdr.bdr_get_local_nodeid();

    PERFORM 1 FROM bdr_connections
    WHERE conn_sysid = remoteid.sysid
      AND conn_timeline = remoteid.timeline
      AND conn_dboid = remoteid.dboid
      AND conn_origin_sysid = localid.sysid
      AND conn_origin_timeline = localid.timeline
      AND conn_origin_dboid = localid.dboid
      AND conn_is_unidirectional = 't';

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unidirectional connection to node % not found',
            v_node_name;
        RETURN;
    END IF;

    -- Mark the provider node as killed
    UPDATE bdr.bdr_nodes
    SET node_status = 'k'
    WHERE bdr_nodes.node_name = v_node_name;

    --
    -- Check what to do with local node based on active connections
    --
    -- Note the logic here is:
    --  - if this is UDR node and there are still live provider nodes, we keep local node active
    --  - if this is UDR node and all provider nodes were killed, local node will be killed as well
    --  - if this is UDR + BDR node there will be connection pointing towards local node so we keep it active
    --
    PERFORM 1
    FROM bdr.bdr_connections c
        JOIN bdr.bdr_nodes n ON (
            conn_sysid = node_sysid AND
            conn_timeline = node_timeline AND
            conn_dboid = node_dboid
        )
    WHERE node_status <> 'k';

    IF NOT FOUND THEN
        UPDATE bdr.bdr_nodes
        SET node_status = 'k'
        FROM bdr.bdr_get_local_nodeid()
        WHERE node_sysid = sysid
            AND node_timeline = timeline
            AND node_dboid = dboid;
    END IF;

    -- Notify local perdb worker to kill nodes.
    PERFORM bdr.bdr_connections_changed();
END;
$body$;

RESET bdr.permit_unsafe_ddl_commands;
RESET bdr.skip_ddl_replication;
RESET search_path;
