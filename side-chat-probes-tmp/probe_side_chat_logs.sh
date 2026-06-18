#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "usage: $0 <literal phrase> [parent-thread-id]" >&2
  exit 64
fi

phrase="$1"
parent_id="${2:-}"
codex_home="${CODEX_HOME:-$HOME/.codex}"
state_db="$codex_home/state_5.sqlite"
logs_db="$codex_home/logs_2.sqlite"
sql_phrase="$(printf "%s" "$phrase" | sed "s/'/''/g")"
sql_parent="$(printf "%s" "$parent_id" | sed "s/'/''/g")"
before="${SIDE_PROBE_BEFORE:-}"
sql_before="$(printf "%s" "$before" | sed "s/'/''/g")"

logs_time_filter=""
if [[ -n "$sql_before" ]]; then
  logs_time_filter="and ts <= strftime('%s','$sql_before')"
fi

echo "== Literal JSONL matches =="
rg -nF "$phrase" "$codex_home" -g '*.jsonl' | head -n 20 || true
if [[ -n "$before" ]]; then
  echo "(logs queries filtered with SIDE_PROBE_BEFORE=$before)"
fi

echo
echo "== State DB thread matches =="
if [[ -f "$state_db" ]]; then
  sqlite3 -header -column "$state_db" "
    select id,
           thread_source,
           source,
           datetime(updated_at,'unixepoch') as updated,
           substr(title,1,80) as title,
           substr(first_user_message,1,100) as first_user_message,
           substr(preview,1,100) as preview
      from threads
     where title like '%$sql_phrase%'
        or first_user_message like '%$sql_phrase%'
        or preview like '%$sql_phrase%'
     order by updated_at desc;
  "
else
  echo "missing state DB: $state_db"
fi

echo
echo "== Logs DB phrase matches by thread =="
if [[ -f "$logs_db" ]]; then
  sqlite3 -header -column "$logs_db" "
    select thread_id,
           count(*) as rows,
           datetime(min(ts),'unixepoch') as first_seen,
           datetime(max(ts),'unixepoch') as last_seen,
           max(case when feedback_log_body like '%thread/fork%' then 1 else 0 end) as has_thread_fork,
           max(case when feedback_log_body like '%side-conversation assistant%' then 1 else 0 end) as has_side_boundary,
           max(case when feedback_log_body like '%response.output_text.done%' then 1 else 0 end) as has_output_done
      from logs
     where feedback_log_body like '%$sql_phrase%'
       $logs_time_filter
     group by thread_id
     order by rows desc;
  "

  echo
  echo "== Logs DB phrase snippets =="
  sqlite3 -header -column "$logs_db" "
    select id,
           thread_id,
           datetime(ts,'unixepoch') as ts,
           level,
           target,
           instr(feedback_log_body,'$sql_phrase') as phrase_pos,
           substr(
             replace(replace(feedback_log_body, char(10), ' '), char(13), ' '),
             max(instr(feedback_log_body,'$sql_phrase') - 240, 1),
             520
           ) as around_phrase
     from logs
     where feedback_log_body like '%$sql_phrase%'
       $logs_time_filter
     order by ts, ts_nanos, id
     limit 20;
  "

  if [[ -n "$parent_id" ]]; then
    echo
    echo "== Logs DB rows containing phrase thread and parent id =="
    sqlite3 -header -column "$logs_db" "
      with phrase_threads as (
        select distinct thread_id
          from logs
         where feedback_log_body like '%$sql_phrase%'
           $logs_time_filter
           and thread_id is not null
      )
      select logs.thread_id,
             count(*) as rows,
             datetime(min(ts),'unixepoch') as first_seen,
             datetime(max(ts),'unixepoch') as last_seen
        from logs
        join phrase_threads on phrase_threads.thread_id = logs.thread_id
       where logs.feedback_log_body like '%$sql_parent%'
         $logs_time_filter
       group by logs.thread_id
       order by rows desc;
    "
  fi
else
  echo "missing logs DB: $logs_db"
fi
