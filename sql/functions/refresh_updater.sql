/*
 *  Refresh insert/update only table based on timestamp control field
 */
CREATE FUNCTION refresh_updater(p_destination text, p_limit integer DEFAULT NULL, p_repull boolean DEFAULT false, p_repull_start text DEFAULT NULL, p_repull_end text DEFAULT NULL, p_jobmon boolean DEFAULT NULL, p_debug boolean DEFAULT false) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
DECLARE

v_adv_lock              boolean;
v_batch_limit_reached   int := 0;
v_boundary_sql          text;
v_boundary              timestamptz;
v_cols_n_types          text;
v_cols                  text;
v_condition             text;
v_control               text;
v_create_sql            text;
v_dblink                int;
v_dblink_name           text;
v_dblink_schema         text;
v_delete_sql            text;
v_dest_table            text;
v_dst_active            boolean;
v_dst_check             boolean;
v_dst_start             int;
v_dst_end               int;
v_fetch_sql             text;
v_field                 text;
v_filter                text[];
v_full_refresh          boolean := false;
v_insert_sql            text;
v_job_id                int;
v_jobmon                boolean;
v_jobmon_schema         text;
v_job_name              text;
v_last_fetched          timestamptz;
v_last_value            timestamptz;
v_limit                 int;
v_link_exists           boolean;
v_now                   timestamptz := now(); 
v_old_search_path       text;
v_pk_counter            int := 1;
v_pk_name               text[];
v_remote_boundry_sql    text;
v_remote_boundry        timestamptz;
v_remote_sql            text;
v_rowcount              bigint := 0; 
v_source_table          text;
v_step_id               int;
v_tmp_table             text;
v_total                 bigint := 0;

BEGIN

IF p_debug IS DISTINCT FROM true THEN
    PERFORM set_config( 'client_min_messages', 'warning', true );
END IF;

v_job_name := 'Refresh Updater: '||p_destination;
v_dblink_name := 'mimeo_updater_refresh_'||p_destination;

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
    , last_value
    , now() - boundary::interval
    , pk_name
    , filter
    , condition
    , dst_active
    , dst_start
    , dst_end
    , batch_limit  
    , jobmon
INTO v_source_table
    , v_dest_table
    , v_tmp_table
    , v_dblink
    , v_control
    , v_last_value
    , v_boundary
    , v_pk_name
    , v_filter
    , v_condition
    , v_dst_active
    , v_dst_start
    , v_dst_end
    , v_limit
    , v_jobmon
FROM refresh_config_updater
WHERE dest_table = p_destination;
IF NOT FOUND THEN
   RAISE EXCEPTION 'No configuration found for %',v_job_name;
END IF;

-- Allow override with parameter
v_jobmon := COALESCE(p_jobmon, v_jobmon);

-- Take advisory lock to prevent multiple calls to function overlapping
v_adv_lock := pg_try_advisory_lock(hashtext('refresh_updater'), hashtext(v_job_name));
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
END IF;

-- Do not allow this function to run during DST time change if config option is true. Otherwise will miss data from source
IF v_dst_active THEN
    v_dst_check := @extschema@.dst_change(v_now);
    IF v_dst_check THEN 
        IF to_number(to_char(v_now, 'HH24MM'), '0000') > v_dst_start AND to_number(to_char(v_now, 'HH24MM'), '0000') < v_dst_end THEN
            IF v_jobmon THEN
                v_step_id := add_step( v_job_id, 'DST Check');
                PERFORM update_step(v_step_id, 'OK', 'Job CANCELLED - Does not run during DST time change');
                PERFORM close_job(v_job_id);
            END IF;
            UPDATE refresh_config_updater SET last_run = CURRENT_TIMESTAMP WHERE dest_table = p_destination;  
            PERFORM gdb(p_debug, 'Cannot run during DST time change');
            EXECUTE 'SELECT set_config(''search_path'','''||v_old_search_path||''',''false'')';
            PERFORM pg_advisory_unlock(hashtext('refresh_updater'), hashtext(v_job_name));
            RETURN;
        END IF;
    END IF;
END IF;

IF v_jobmon THEN
    v_step_id := add_step(v_job_id,'Building SQL');
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

PERFORM dblink_connect(v_dblink_name, auth(v_dblink));

IF p_limit IS NOT NULL THEN
    v_limit := p_limit;
END IF;

-- Repull old data instead of normal new data pull
IF p_repull THEN
    -- Repull ALL data if no start and end values set
    IF p_repull_start IS NULL AND p_repull_end IS NULL THEN
        IF v_jobmon THEN
            PERFORM update_step(v_step_id, 'OK','Request to repull ALL data from source. This could take a while...');
        END IF;
        EXECUTE 'TRUNCATE '||v_dest_table;
        v_remote_sql := 'SELECT '||v_cols||' FROM '||v_source_table;
        IF v_condition IS NOT NULL THEN
            v_remote_sql := v_remote_sql || ' ' || v_condition;
        END IF;
    ELSE
        IF v_jobmon THEN
            PERFORM update_step(v_step_id, 'OK','Request to repull data from '||p_repull_start||' to '||p_repull_end);
        END IF;
        PERFORM gdb(p_debug,'Request to repull data from '||p_repull_start||' to '||p_repull_end);
        v_remote_sql := 'SELECT '||v_cols||' FROM '||v_source_table;
        IF v_condition IS NOT NULL THEN
            v_remote_sql := v_remote_sql || ' ' || v_condition || ' AND ';
        ELSE
            v_remote_sql := v_remote_sql || ' WHERE ';
        END IF;
        v_remote_sql := v_remote_sql ||v_control||' > '||quote_literal(COALESCE(p_repull_start, '-infinity'))||' AND '
            ||v_control||' < '||quote_literal(COALESCE(p_repull_end, 'infinity'));
        EXECUTE 'DELETE FROM '||v_dest_table||' WHERE '||v_control||' > '||quote_literal(COALESCE(p_repull_start, '-infinity'))||' AND '
            ||v_control||' < '||quote_literal(COALESCE(p_repull_end, 'infinity'));
    END IF;
ELSE
    -- does < for upper boundary to keep missing data from happening on rare edge case where a newly inserted row outside the transaction batch
    -- has the exact same timestamp as the previous batch's max timestamp
    v_remote_sql := 'SELECT '||v_cols||' FROM '||v_source_table;
    IF v_condition IS NOT NULL THEN
        v_remote_sql := v_remote_sql || ' ' || v_condition || ' AND ';
    ELSE
        v_remote_sql := v_remote_sql || ' WHERE ';
    END IF;
    v_remote_sql := v_remote_sql ||v_control||' > '||quote_literal(v_last_value)||' AND '||v_control||' < '||quote_literal(v_boundary)||' ORDER BY '||v_control||' ASC LIMIT '|| COALESCE(v_limit::text, 'ALL');

    v_delete_sql := 'DELETE FROM '||v_dest_table||' USING '||v_tmp_table||' t WHERE ';

    WHILE v_pk_counter <= array_length(v_pk_name,1) LOOP
        IF v_pk_counter > 1 THEN
            v_delete_sql := v_delete_sql ||' AND ';
        END IF;
        v_delete_sql := v_delete_sql ||v_dest_table||'.'||v_pk_name[v_pk_counter]||' = t.'||v_pk_name[v_pk_counter];
        v_pk_counter := v_pk_counter + 1;
    END LOOP;

    IF v_jobmon THEN
        PERFORM update_step(v_step_id, 'OK','Grabbing rows from '||v_last_value::text||' to '||v_boundary::text);
    END IF;
    PERFORM gdb(p_debug,'Grabbing rows from '||v_last_value::text||' to '||v_boundary::text);
END IF;

v_insert_sql := 'INSERT INTO '||v_dest_table||' ('||v_cols||') SELECT '||v_cols||' FROM '||v_tmp_table; 

PERFORM gdb(p_debug,v_remote_sql);
PERFORM dblink_open(v_dblink_name, 'mimeo_cursor', v_remote_sql);
IF v_jobmon THEN
    v_step_id := add_step(v_job_id, 'Inserting new/updated records into local table');
END IF;
v_rowcount := 0;

EXECUTE 'CREATE TEMP TABLE '||v_tmp_table||' ('||v_cols_n_types||')'; 
LOOP            
    v_fetch_sql := 'INSERT INTO '||v_tmp_table||'('||v_cols||') 
        SELECT '||v_cols||' FROM dblink_fetch('||quote_literal(v_dblink_name)||', ''mimeo_cursor'', 50000) AS ('||v_cols_n_types||')';
    EXECUTE v_fetch_sql;
    GET DIAGNOSTICS v_rowcount = ROW_COUNT;
    v_total := v_total + coalesce(v_rowcount, 0);
    EXECUTE 'SELECT max('||v_control||') FROM '||v_tmp_table INTO v_last_fetched;
    IF v_limit IS NULL THEN -- insert into the real table in batches if no limit to avoid excessively large temp tables
        IF p_repull IS FALSE THEN   -- Delete any rows that exist in the current temp table batch. repull delete is done above.
            EXECUTE v_delete_sql;
        END IF;
        EXECUTE v_insert_sql;
        EXECUTE 'TRUNCATE '||v_tmp_table;
    END IF;
    EXIT WHEN v_rowcount = 0;
    PERFORM gdb(p_debug,'Fetching rows in batches: '||v_total||' done so far. Last fetched: '||v_last_fetched);
    IF v_jobmon THEN
        PERFORM update_step(v_step_id, 'PENDING', 'Fetching rows in batches: '||v_total||' done so far. Last fetched: '||v_last_fetched);
    END IF;
END LOOP;
PERFORM dblink_close(v_dblink_name, 'mimeo_cursor');
IF v_jobmon THEN
    PERFORM update_step(v_step_id, 'OK','Rows fetched: '||v_total);     
END IF;
    
IF v_limit IS NULL THEN
    -- nothing else to do
ELSE 
    -- When using batch limits, entire batch must be pulled to temp table before inserting to real table to catch edge cases 
    IF v_jobmon THEN
        v_step_id := add_step(v_job_id,'Checking for batch limit issues');     
    END IF;
    -- Not recommended that the batch actually equal the limit set if possible.
    IF v_total >= v_limit THEN
        PERFORM gdb(p_debug, 'Row count fetched equal to or greater than limit set: '||v_limit||'. Recommend increasing batch limit if possible.'); 
        IF v_jobmon THEN
            PERFORM update_step(v_step_id, 'WARNING','Row count fetched equal to or greater than limit set: '||v_limit||'. Recommend increasing batch limit if possible.');
            v_step_id := add_step(v_job_id, 'Removing high boundary rows from this batch to avoid missing data');       
        END IF;
        EXECUTE 'SELECT max('||v_control||') FROM '||v_tmp_table INTO v_last_value;
        EXECUTE 'DELETE FROM '||v_tmp_table||' WHERE '||v_control||' = '||quote_literal(v_last_value);
        GET DIAGNOSTICS v_rowcount = ROW_COUNT;
        IF v_jobmon THEN
            PERFORM update_step(v_step_id, 'OK', 'Removed '||v_rowcount||' rows. Batch now contains '||v_limit - v_rowcount||' records');
        END IF;
        PERFORM gdb(p_debug, 'Removed '||v_rowcount||' rows from batch. Batch table now contains '||v_limit - v_rowcount||' records');
        v_batch_limit_reached := 2;
        IF (v_limit - v_rowcount) < 1 THEN
            IF v_jobmon THEN
                v_step_id := add_step(v_job_id, 'Reached inconsistent state');
                PERFORM update_step(v_step_id, 'CRITICAL', 'Batch contained max rows ('||v_limit||') or greater and all contained the same timestamp value. Unable to guarentee rows will ever be replicated consistently. Increase row limit parameter to allow a consistent batch.');
            END IF;
            PERFORM gdb(p_debug, 'Batch contained max rows ('||v_limit||') or greater and all contained the same timestamp value. Unable to guarentee rows will be replicated consistently. Increase row limit parameter to allow a consistent batch.');
            v_batch_limit_reached := 3;
        END IF;
    ELSE
        IF v_jobmon THEN
            PERFORM update_step(v_step_id, 'OK','No issues found');
        END IF;
        PERFORM gdb(p_debug, 'No issues found');
    END IF;

    IF v_batch_limit_reached <> 3 THEN
        EXECUTE 'CREATE INDEX ON '||v_tmp_table||' ('||array_to_string(v_pk_name, ',')||')'; -- incase of large batch limit
        EXECUTE 'ANALYZE '||v_tmp_table;       
        IF v_jobmon THEN
            v_step_id := add_step(v_job_id,'Deleting records marked for update in local table');
        END IF;
        PERFORM gdb(p_debug,v_delete_sql);
        EXECUTE v_delete_sql; 
        GET DIAGNOSTICS v_rowcount = ROW_COUNT;
        IF v_jobmon THEN
            PERFORM update_step(v_step_id, 'OK','Deleted '||v_rowcount||' records');
        END IF;

        IF v_jobmon THEN
            v_step_id := add_step(v_job_id,'Inserting new records into local table');
        END IF;
        perform gdb(p_debug,v_insert_sql);
        EXECUTE v_insert_sql; 
        GET DIAGNOSTICS v_rowcount = ROW_COUNT;
        IF v_jobmon THEN
            PERFORM update_step(v_step_id, 'OK','Inserted '||v_rowcount||' records');
        END IF;
    END IF;

END IF; -- end v_limit IF

IF v_batch_limit_reached <> 3 THEN
    IF v_jobmon THEN
        v_step_id := add_step(v_job_id, 'Setting next lower boundary');
    END IF;
    EXECUTE 'SELECT max('||v_control||') FROM '|| v_dest_table INTO v_last_value;
    UPDATE refresh_config_updater set last_value = coalesce(v_last_value, CURRENT_TIMESTAMP), last_run = CURRENT_TIMESTAMP WHERE dest_table = p_destination;  
    IF v_jobmon THEN
        PERFORM update_step(v_step_id, 'OK','Lower boundary value is: '||coalesce(v_last_value, CURRENT_TIMESTAMP));
    END IF;
    PERFORM gdb(p_debug, 'Lower boundary value is: '||coalesce(v_last_value, CURRENT_TIMESTAMP));
END IF;

EXECUTE 'DROP TABLE IF EXISTS '||v_tmp_table;

PERFORM dblink_disconnect(v_dblink_name);

IF v_jobmon THEN
    IF v_batch_limit_reached = 0 THEN
        PERFORM close_job(v_job_id);
    ELSIF v_batch_limit_reached = 2 THEN
        -- Set final job status to level 2 (WARNING) to bring notice that the batch limit was reached and may need adjusting.
        -- Preventive warning to keep replication from falling behind.
        PERFORM fail_job(v_job_id, 2);
    ELSIF v_batch_limit_reached = 3 THEN
        -- Really bad. Critical alert!
        PERFORM fail_job(v_job_id);
    END IF;
END IF;

-- Ensure old search path is reset for the current session
EXECUTE 'SELECT set_config(''search_path'','''||v_old_search_path||''',''false'')';

PERFORM pg_advisory_unlock(hashtext('refresh_updater'), hashtext(v_job_name));

EXCEPTION
    WHEN QUERY_CANCELED THEN
        EXECUTE 'SELECT '||v_dblink_schema||'.dblink_get_connections() @> ARRAY['||quote_literal(v_dblink_name)||']' INTO v_link_exists;
        IF v_link_exists THEN
            EXECUTE 'SELECT '||v_dblink_schema||'.dblink_disconnect('||quote_literal(v_dblink_name)||')';
        END IF;
        PERFORM pg_advisory_unlock(hashtext('refresh_updater'), hashtext(v_job_name));
        RAISE EXCEPTION '%', SQLERRM;  
    WHEN OTHERS THEN
        EXECUTE 'SELECT '||v_dblink_schema||'.dblink_get_connections() @> ARRAY['||quote_literal(v_dblink_name)||']' INTO v_link_exists;
        IF v_link_exists THEN
            EXECUTE 'SELECT '||v_dblink_schema||'.dblink_disconnect('||quote_literal(v_dblink_name)||')';
        END IF;
        IF v_jobmon THEN
            IF v_job_id IS NULL THEN
                EXECUTE 'SELECT '||v_jobmon_schema||'.add_job(''Refresh Updater: '||p_destination||''')' INTO v_job_id;
                EXECUTE 'SELECT '||v_jobmon_schema||'.add_step('||v_job_id||', ''EXCEPTION before job logging started'')' INTO v_step_id;
            END IF;
            IF v_step_id IS NULL THEN
                EXECUTE 'SELECT '||v_jobmon_schema||'.add_step('||v_job_id||', ''EXCEPTION before first step logged'')' INTO v_step_id;
            END IF;
            EXECUTE 'SELECT '||v_jobmon_schema||'.update_step('||v_step_id||', ''CRITICAL'', ''ERROR: '||COALESCE(SQLERRM,'unknown')||''')';
            EXECUTE 'SELECT '||v_jobmon_schema||'.fail_job('||v_job_id||')';
        END IF;
        PERFORM pg_advisory_unlock(hashtext('refresh_updater'), hashtext(v_job_name));
        RAISE EXCEPTION '%', SQLERRM;
END
$$;
