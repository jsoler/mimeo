/*
 *  Refresh based on DML (Insert, Update, Delete)
 */
CREATE FUNCTION refresh_dml(p_destination text, p_limit int default NULL, p_repull boolean DEFAULT false, p_jobmon boolean DEFAULT NULL, p_debug boolean DEFAULT false) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
DECLARE

v_adv_lock              boolean;
v_batch_limit_reached   boolean := false;
v_cols_n_types          text;
v_cols                  text;
v_condition             text;
v_control               text;
v_dblink                int;
v_dblink_name           text;
v_dblink_schema         text;
v_delete_sql            text;
v_dest_table            text;
v_exec_status           text;
v_fetch_sql             text;
v_field                 text;
v_filter                text[];
v_insert_sql            text;
v_job_id                int;
v_jobmon_schema         text;
v_job_name              text;
v_jobmon                boolean;
v_limit                 int; 
v_link_exists           boolean;
v_old_search_path       text;
v_pk_counter            int;
v_pk_name_csv           text;
v_pk_name_type_csv      text := '';
v_pk_name               text[];
v_pk_type               text[];
v_pk_where              text := '';
v_remote_f_sql          text;
v_remote_q_sql          text;
v_rowcount              bigint := 0; 
v_source_table          text;
v_step_id               int;
v_tmp_table             text;
v_total                 bigint := 0;
v_trigger_delete        text; 
v_trigger_update        text;
v_truncate_remote_q     text;
v_with_update           text;

BEGIN

IF p_debug IS DISTINCT FROM true THEN
    PERFORM set_config( 'client_min_messages', 'warning', true );
END IF;

v_job_name := 'Refresh DML: '||p_destination;
v_dblink_name := 'mimeo_dml_refresh_'||p_destination;

SELECT nspname INTO v_dblink_schema FROM pg_namespace n, pg_extension e WHERE e.extname = 'dblink' AND e.extnamespace = n.oid;
SELECT nspname INTO v_jobmon_schema FROM pg_namespace n, pg_extension e WHERE e.extname = 'pg_jobmon' AND e.extnamespace = n.oid;

-- Set custom search path to allow easier calls to other functions, especially job logging
SELECT current_setting('search_path') INTO v_old_search_path;
EXECUTE 'SELECT set_config(''search_path'',''@extschema@,'||COALESCE(v_jobmon_schema||',', '')||v_dblink_schema||',public'',''false'')';

SELECT source_table
    , dest_table
    , 'tmp_'||replace(dest_table,'.','_')
    , dblink
    , control
    , pk_name
    , pk_type
    , filter
    , condition
    , batch_limit 
    , jobmon
INTO v_source_table
    , v_dest_table
    , v_tmp_table
    , v_dblink
    , v_control
    , v_pk_name
    , v_pk_type
    , v_filter
    , v_condition
    , v_limit
    , v_jobmon
FROM refresh_config_dml 
WHERE dest_table = p_destination; 
IF NOT FOUND THEN
   RAISE EXCEPTION 'No configuration found for %',v_job_name; 
END IF;

-- Allow override with parameter
v_jobmon := COALESCE(p_jobmon, v_jobmon);

-- Take advisory lock to prevent multiple calls to function overlapping
v_adv_lock := pg_try_advisory_lock(hashtext('refresh_dml'), hashtext(v_job_name));
IF v_adv_lock = 'false' THEN
    IF v_jobmon THEN
        v_job_id := add_job(v_job_name);
        v_step_id := add_step(v_job_id,'Obtaining advisory lock for job: '||v_job_name);
        PERFORM update_step(v_step_id, 'WARNING','Found concurrent job. Exiting gracefully');
        PERFORM fail_job(v_job_id, 2);
    END IF;
    PERFORM gdb(p_debug,'Obtaining advisory lock FAILED for job: '||v_job_name);
    EXECUTE 'SELECT set_config(''search_path'','''||v_old_search_path||''',''false'')';
    RETURN;
END IF;

IF v_jobmon THEN
    v_job_id := add_job(v_job_name);
    PERFORM gdb(p_debug,'Job ID: '||v_job_id::text);
    v_step_id := add_step(v_job_id,'Sanity check primary/unique key values');
END IF;

IF v_pk_name IS NULL OR v_pk_type IS NULL THEN
    RAISE EXCEPTION 'Primary key fields in refresh_config_dml must be defined';
END IF;

-- determine column list, column type list
IF v_filter IS NULL THEN 
    SELECT array_to_string(array_agg(attname),','), array_to_string(array_agg(attname||' '||format_type(atttypid, atttypmod)::text),',') 
        INTO v_cols, v_cols_n_types
        FROM pg_attribute WHERE attrelid = p_destination::regclass AND attnum > 0 AND attisdropped is false;
ELSE
    -- ensure all primary key columns are included in any column filters
    FOREACH v_field IN ARRAY v_pk_name LOOP
        IF v_field = ANY(v_filter) THEN
            CONTINUE;
        ELSE
            RAISE EXCEPTION 'Filter list did not contain all columns that compose primary/unique key for %',v_job_name; 
        END IF;
    END LOOP;
    SELECT array_to_string(array_agg(attname),','), array_to_string(array_agg(attname||' '||format_type(atttypid, atttypmod)::text),',') 
        INTO v_cols, v_cols_n_types
        FROM pg_attribute WHERE attrelid = p_destination::regclass AND ARRAY[attname::text] <@ v_filter AND attnum > 0 AND attisdropped is false;
END IF;    

IF p_limit IS NOT NULL THEN
    v_limit := p_limit;
END IF;

v_pk_name_csv := array_to_string(v_pk_name, ',');
v_pk_counter := 1;
WHILE v_pk_counter <= array_length(v_pk_name,1) LOOP
    IF v_pk_counter > 1 THEN
        v_pk_name_type_csv := v_pk_name_type_csv || ', ';
        v_pk_where := v_pk_where ||' AND ';
    END IF;
    v_pk_name_type_csv := v_pk_name_type_csv ||v_pk_name[v_pk_counter]||' '||v_pk_type[v_pk_counter];
    v_pk_where := v_pk_where || ' a.'||v_pk_name[v_pk_counter]||' = b.'||v_pk_name[v_pk_counter];
    v_pk_counter := v_pk_counter + 1;
END LOOP;

IF v_jobmon THEN
    PERFORM update_step(v_step_id, 'OK','Done');
END IF;

PERFORM dblink_connect(v_dblink_name, auth(v_dblink));

-- update remote entries
IF v_jobmon THEN
    v_step_id := add_step(v_job_id,'Updating remote trigger table');
END IF;
v_with_update := 'WITH a AS (SELECT '||v_pk_name_csv||' FROM '|| v_control ||' ORDER BY '||v_pk_name_csv||' LIMIT '|| COALESCE(v_limit::text, 'ALL') ||') UPDATE '||v_control||' b SET processed = true FROM a WHERE '||v_pk_where;
v_trigger_update := 'SELECT dblink_exec('||quote_literal(v_dblink_name)||','|| quote_literal(v_with_update)||')';
PERFORM gdb(p_debug,v_trigger_update);
EXECUTE v_trigger_update INTO v_exec_status;    
IF v_jobmon THEN
    PERFORM update_step(v_step_id, 'OK','Result was '||v_exec_status);
END IF;

IF p_repull THEN
    -- Do truncate of remote queue table here before full data pull is actually started to ensure all new changes are recorded
    IF v_jobmon THEN
        PERFORM update_step(v_step_id, 'OK','Request to repull ALL data from source. This could take a while...');
    END IF;
    PERFORM gdb(p_debug, 'Request to repull ALL data from source. This could take a while...');
    v_truncate_remote_q := 'SELECT dblink_exec('||quote_literal(v_dblink_name)||','||quote_literal('TRUNCATE TABLE '||v_control)||')';
    EXECUTE v_truncate_remote_q;

    IF v_jobmon THEN
        v_step_id := add_step(v_job_id,'Truncating local table');
    END IF;
    PERFORM gdb(p_debug,'Truncating local table');
    EXECUTE 'TRUNCATE '||v_dest_table;
    IF v_jobmon THEN
        PERFORM update_step(v_step_id, 'OK','Done');
    END IF;
    -- Define cursor query
    v_remote_f_sql := 'SELECT '||v_cols||' FROM '||v_source_table;
    IF v_condition IS NOT NULL THEN
        v_remote_f_sql := v_remote_f_sql || ' ' || v_condition;
    END IF;
ELSE
    EXECUTE 'CREATE TEMP TABLE '||v_tmp_table||'_queue ('||v_pk_name_type_csv||', PRIMARY KEY ('||v_pk_name_csv||'))';
    -- Copy queue locally for use in removing updated/deleted rows
    v_remote_q_sql := 'SELECT DISTINCT '||v_pk_name_csv||' FROM '||v_control||' WHERE processed = true';
    PERFORM dblink_open(v_dblink_name, 'mimeo_cursor', v_remote_q_sql);
    IF v_jobmon THEN
        v_step_id := add_step(v_job_id, 'Creating local queue temp table');
    END IF;
    v_rowcount := 0;
    LOOP
        v_fetch_sql := 'INSERT INTO '||v_tmp_table||'_queue ('||v_pk_name_csv||') 
            SELECT '||v_pk_name_csv||' FROM dblink_fetch('||quote_literal(v_dblink_name)||', ''mimeo_cursor'', 50000) AS ('||v_pk_name_type_csv||')';
        EXECUTE v_fetch_sql;
        GET DIAGNOSTICS v_rowcount = ROW_COUNT;
        EXIT WHEN v_rowcount = 0;
        v_total := v_total + coalesce(v_rowcount, 0);
        PERFORM gdb(p_debug,'Fetching rows in batches: '||v_total||' done so far.');
        IF v_jobmon THEN
            PERFORM update_step(v_step_id, 'PENDING', 'Fetching rows in batches: '||v_total||' done so far.');
        END IF;
    END LOOP;
    PERFORM dblink_close(v_dblink_name, 'mimeo_cursor');
    EXECUTE 'CREATE INDEX ON '||v_tmp_table||'_queue ('||v_pk_name_csv||')';
    EXECUTE 'ANALYZE '||v_tmp_table||'_queue';
    IF v_jobmon THEN
        PERFORM update_step(v_step_id, 'OK','Number of rows inserted: '||v_total);
    END IF;
    PERFORM gdb(p_debug,'Temp queue table row count '||v_total::text);

    IF v_jobmon THEN
        v_step_id := add_step(v_job_id,'Deleting records from local table');
    END IF;
    v_delete_sql := 'DELETE FROM '||v_dest_table||' a USING '||v_tmp_table||'_queue b WHERE '|| v_pk_where; 
    PERFORM gdb(p_debug,v_delete_sql);
    EXECUTE v_delete_sql; 
    GET DIAGNOSTICS v_rowcount = ROW_COUNT;
    PERFORM gdb(p_debug,'Rows removed from local table before applying changes: '||v_rowcount::text);
    IF v_jobmon THEN
        PERFORM update_step(v_step_id, 'OK','Removed '||v_rowcount||' records');
    END IF;
    -- Define cursor query
    v_remote_f_sql := 'SELECT '||v_cols||' FROM '||v_source_table||' JOIN ('||v_remote_q_sql||') x USING ('||v_pk_name_csv||')';
    IF v_condition IS NOT NULL THEN
        v_remote_f_sql := v_remote_f_sql || ' ' || v_condition;
    END IF;
END IF;

-- insert records to local table. Have to do temp table in case destination table is partitioned (returns 0 when inserting to parent)
PERFORM dblink_open(v_dblink_name, 'mimeo_cursor', v_remote_f_sql);
IF v_jobmon THEN
    v_step_id := add_step(v_job_id, 'Inserting new records into local table');
END IF;
EXECUTE 'CREATE TEMP TABLE '||v_tmp_table||'_full ('||v_cols_n_types||')';
v_rowcount := 0;
v_total := 0;
LOOP
    v_fetch_sql := 'INSERT INTO '||v_tmp_table||'_full ('||v_cols||') 
        SELECT '||v_cols||' FROM dblink_fetch('||quote_literal(v_dblink_name)||', ''mimeo_cursor'', 50000) AS ('||v_cols_n_types||')';
    EXECUTE v_fetch_sql;
    GET DIAGNOSTICS v_rowcount = ROW_COUNT;
    v_total := v_total + coalesce(v_rowcount, 0);
    EXECUTE 'INSERT INTO '||v_dest_table||' ('||v_cols||') SELECT '||v_cols||' FROM '||v_tmp_table||'_full';
    EXECUTE 'TRUNCATE '||v_tmp_table||'_full';
    EXIT WHEN v_rowcount = 0;
    PERFORM gdb(p_debug,'Fetching rows in batches: '||v_total||' done so far.');
    IF v_jobmon THEN
        PERFORM update_step(v_step_id, 'PENDING', 'Fetching rows in batches: '||v_total||' done so far.');
    END IF;
END LOOP;
PERFORM dblink_close(v_dblink_name, 'mimeo_cursor');
IF v_jobmon THEN
    PERFORM update_step(v_step_id, 'OK','Number of rows inserted: '||v_total);
END IF;

IF p_repull = false AND v_total > (v_limit * .75) THEN
    IF v_jobmon THEN
        v_step_id := add_step(v_job_id, 'Row count warning');
        PERFORM update_step(v_step_id, 'WARNING','Row count fetched ('||v_total||') greater than 75% of batch limit ('||v_limit||'). Recommend increasing batch limit if possible.');
    END IF;
    v_batch_limit_reached := true;
END IF;

-- clean out rows from txn table
IF v_jobmon THEN
    v_step_id := add_step(v_job_id,'Cleaning out rows from txn table');
END IF;
v_trigger_delete := 'SELECT dblink_exec('||quote_literal(v_dblink_name)||','||quote_literal('DELETE FROM '||v_control||' WHERE processed = true')||')'; 
PERFORM gdb(p_debug,v_trigger_delete);
EXECUTE v_trigger_delete INTO v_exec_status;
IF v_jobmon THEN
    PERFORM update_step(v_step_id, 'OK','Result was '||v_exec_status);
END IF;
-- update activity status
IF v_jobmon THEN
    v_step_id := add_step(v_job_id,'Updating last_run in config table');
END IF;
UPDATE refresh_config_dml SET last_run = CURRENT_TIMESTAMP WHERE dest_table = p_destination; 
IF v_jobmon THEN
    PERFORM update_step(v_step_id, 'OK','Last run was '||CURRENT_TIMESTAMP);
END IF;
EXECUTE 'DROP TABLE IF EXISTS '||v_tmp_table||'_full';
EXECUTE 'DROP TABLE IF EXISTS '||v_tmp_table||'_queue';

PERFORM dblink_disconnect(v_dblink_name);

IF v_jobmon THEN
    IF v_batch_limit_reached = false THEN
        PERFORM close_job(v_job_id);
    ELSE
        -- Set final job status to level 2 (WARNING) to bring notice that the batch limit was reached and may need adjusting.
        -- Preventive warning to keep replication from falling behind.
        PERFORM fail_job(v_job_id, 2);
    END IF;
END IF;

-- Ensure old search path is reset for the current session
EXECUTE 'SELECT set_config(''search_path'','''||v_old_search_path||''',''false'')';

PERFORM pg_advisory_unlock(hashtext('refresh_dml'), hashtext(v_job_name));

EXCEPTION
    WHEN QUERY_CANCELED THEN
        EXECUTE 'SELECT '||v_dblink_schema||'.dblink_get_connections() @> ARRAY['||quote_literal(v_dblink_name)||']' INTO v_link_exists;
        IF v_link_exists THEN
            EXECUTE 'SELECT '||v_dblink_schema||'.dblink_disconnect('||quote_literal(v_dblink_name)||')';
        END IF;
        PERFORM pg_advisory_unlock(hashtext('refresh_dml'), hashtext(v_job_name));
        RAISE EXCEPTION '%', SQLERRM;  
    WHEN OTHERS THEN
        EXECUTE 'SELECT '||v_dblink_schema||'.dblink_get_connections() @> ARRAY['||quote_literal(v_dblink_name)||']' INTO v_link_exists;
        IF v_link_exists THEN
            EXECUTE 'SELECT '||v_dblink_schema||'.dblink_disconnect('||quote_literal(v_dblink_name)||')';
        END IF;
        IF v_jobmon THEN
            IF v_job_id IS NULL THEN
                EXECUTE 'SELECT '||v_jobmon_schema||'.add_job(''Refresh DML: '||p_destination||''')' INTO v_job_id;
                EXECUTE 'SELECT '||v_jobmon_schema||'.add_step('||v_job_id||', ''EXCEPTION before job logging started'')' INTO v_step_id;
            END IF;
            IF v_step_id IS NULL THEN
                EXECUTE 'SELECT '||v_jobmon_schema||'.add_step('||v_job_id||', ''EXCEPTION before first step logged'')' INTO v_step_id;
            END IF;
            EXECUTE 'SELECT '||v_jobmon_schema||'.update_step('||v_step_id||', ''CRITICAL'', ''ERROR: '||coalesce(SQLERRM,'unknown')||''')';
            EXECUTE 'SELECT '||v_jobmon_schema||'.fail_job('||v_job_id||')';
        END IF;
        PERFORM pg_advisory_unlock(hashtext('refresh_dml'), hashtext(v_job_name));
        RAISE EXCEPTION '%', SQLERRM;
END
$$;

