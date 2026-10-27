-- =============================================================
-- RISK DEFENDER
-- Backend de ranking compartido para Supabase
-- =============================================================
-- Ejecutar una sola vez en Supabase > SQL Editor.
-- El navegador utilizará únicamente la Publishable Key.
-- NO usar ni exponer una Secret Key en el HTML.
-- =============================================================

create table if not exists public.risk_defender_scores (
  alias text primary key,
  best_score integer not null default 0,
  games_played integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint risk_defender_alias_length
    check (char_length(alias) between 2 and 100),
  constraint risk_defender_score_range
    check (best_score between 0 and 10000),
  constraint risk_defender_games_range
    check (games_played >= 0)
);

alter table public.risk_defender_scores enable row level security;

-- El navegador NO accede directamente a la tabla.
revoke all on table public.risk_defender_scores from anon, authenticated;

-- -------------------------------------------------------------
-- Registrar una partida.
-- Mantiene únicamente el mejor puntaje del alias y suma partidas.
-- -------------------------------------------------------------
create or replace function public.submit_risk_defender_score(
  p_alias text,
  p_score integer
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_alias text;
  v_best integer;
begin
  v_alias := upper(regexp_replace(trim(coalesce(p_alias,'')), '\s+', ' ', 'g'));

  if char_length(v_alias) < 2 or char_length(v_alias) > 100 then
    raise exception 'Alias inválido';
  end if;

  if v_alias !~ '^[A-ZÁÉÍÓÚÜÑ0-9 _-]+$' then
    raise exception 'Alias contiene caracteres no permitidos';
  end if;

  if p_score is null or p_score < 0 or p_score > 10000 then
    raise exception 'Puntaje inválido';
  end if;

  insert into public.risk_defender_scores as r
    (alias, best_score, games_played, created_at, updated_at)
  values
    (v_alias, p_score, 1, now(), now())
  on conflict (alias) do update
  set
    best_score = greatest(r.best_score, excluded.best_score),
    games_played = r.games_played + 1,
    updated_at = now()
  returning best_score into v_best;

  return jsonb_build_object(
    'alias', v_alias,
    'best_score', v_best
  );
end;
$$;

-- -------------------------------------------------------------
-- Devuelve el ranking que verá el jugador al finalizar.
-- La posición usa ranking denso por puntaje.
-- -------------------------------------------------------------
create or replace function public.get_risk_defender_snapshot(
  p_alias text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_alias text;
  v_best integer;
  v_rank integer;
  v_record integer;
  v_players integer;
  v_games integer;
  v_top jsonb;
begin
  v_alias := upper(regexp_replace(trim(coalesce(p_alias,'')), '\s+', ' ', 'g'));

  select best_score
  into v_best
  from public.risk_defender_scores
  where alias = v_alias;

  select
    coalesce(max(best_score),0),
    count(*)::integer,
    coalesce(sum(games_played),0)::integer
  into v_record, v_players, v_games
  from public.risk_defender_scores;

  if v_best is null then
    v_rank := 0;
  else
    select 1 + count(distinct best_score)::integer
    into v_rank
    from public.risk_defender_scores
    where best_score > v_best;
  end if;

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'alias', q.alias,
        'best_score', q.best_score
      )
      order by q.best_score desc, q.updated_at asc, q.alias asc
    ),
    '[]'::jsonb
  )
  into v_top
  from (
    select alias, best_score, updated_at
    from public.risk_defender_scores
    order by best_score desc, updated_at asc, alias asc
    limit 10
  ) q;

  return jsonb_build_object(
    'alias', v_alias,
    'best_score', coalesce(v_best,0),
    'rank', v_rank,
    'record', v_record,
    'players', v_players,
    'games', v_games,
    'top10', v_top
  );
end;
$$;

-- -------------------------------------------------------------
-- Función preparada para la futura pantalla del TV del stand.
-- -------------------------------------------------------------
create or replace function public.get_risk_defender_top10()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_record integer;
  v_players integer;
  v_games integer;
  v_top jsonb;
begin
  select
    coalesce(max(best_score),0),
    count(*)::integer,
    coalesce(sum(games_played),0)::integer
  into v_record, v_players, v_games
  from public.risk_defender_scores;

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'alias', q.alias,
        'best_score', q.best_score
      )
      order by q.best_score desc, q.updated_at asc, q.alias asc
    ),
    '[]'::jsonb
  )
  into v_top
  from (
    select alias, best_score, updated_at
    from public.risk_defender_scores
    order by best_score desc, updated_at asc, alias asc
    limit 10
  ) q;

  return jsonb_build_object(
    'record', v_record,
    'players', v_players,
    'games', v_games,
    'top10', v_top
  );
end;
$$;

revoke all on function public.submit_risk_defender_score(text,integer) from public;
revoke all on function public.get_risk_defender_snapshot(text) from public;
revoke all on function public.get_risk_defender_top10() from public;

grant execute on function public.submit_risk_defender_score(text,integer) to anon;
grant execute on function public.get_risk_defender_snapshot(text) to anon;
grant execute on function public.get_risk_defender_top10() to anon;

-- Para el navegador no se conceden SELECT/INSERT/UPDATE/DELETE directos
-- sobre risk_defender_scores. Todo pasa por las funciones anteriores.


-- =============================================================
-- RISK DEFENDER v38 · SINCRONIZACIÓN SEGURA / REINTENTOS
-- Ejecutar UNA VEZ en Supabase > SQL Editor.
-- No borra resultados existentes.
-- =============================================================

create table if not exists public.risk_defender_submissions (
  event_id text primary key,
  alias text not null,
  score integer not null,
  created_at timestamptz not null default now(),
  constraint risk_defender_submission_event_length
    check (char_length(event_id) between 8 and 100),
  constraint risk_defender_submission_alias_length
    check (char_length(alias) between 2 and 100),
  constraint risk_defender_submission_score_range
    check (score between 0 and 10000)
);

alter table public.risk_defender_submissions enable row level security;
revoke all on table public.risk_defender_submissions from anon, authenticated;

create or replace function public.submit_risk_defender_score_v2(
  p_event_id text,
  p_alias text,
  p_score integer
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_alias text;
  v_event_id text;
  v_best integer;
  v_inserted_event text;
  v_existing_alias text;
  v_existing_score integer;
begin
  v_event_id := trim(coalesce(p_event_id,''));
  v_alias := upper(regexp_replace(trim(coalesce(p_alias,'')), '\s+', ' ', 'g'));

  if char_length(v_event_id) < 8 or char_length(v_event_id) > 100 then
    raise exception 'ID de partida inválido';
  end if;

  if char_length(v_alias) < 2 or char_length(v_alias) > 100 then
    raise exception 'Alias inválido';
  end if;

  if v_alias !~ '^[A-ZÁÉÍÓÚÜÑ0-9 _-]+$' then
    raise exception 'Alias contiene caracteres no permitidos';
  end if;

  if p_score is null or p_score < 0 or p_score > 10000 then
    raise exception 'Puntaje inválido';
  end if;

  -- Primero registra el ID único de la partida.
  -- Si un reintento llega dos o más veces, solo el primero se procesa.
  insert into public.risk_defender_submissions(event_id,alias,score)
  values(v_event_id,v_alias,p_score)
  on conflict(event_id) do nothing
  returning event_id into v_inserted_event;

  if v_inserted_event is not null then
    insert into public.risk_defender_scores as r
      (alias,best_score,games_played,created_at,updated_at)
    values
      (v_alias,p_score,1,now(),now())
    on conflict(alias) do update
    set
      best_score = greatest(r.best_score,excluded.best_score),
      games_played = r.games_played + 1,
      updated_at = now();
  else
    select alias,score
      into v_existing_alias,v_existing_score
    from public.risk_defender_submissions
    where event_id=v_event_id;

    if v_existing_alias is distinct from v_alias
       or v_existing_score is distinct from p_score then
      raise exception 'Conflicto de ID de partida';
    end if;
  end if;

  select best_score into v_best
  from public.risk_defender_scores
  where alias=v_alias;

  return jsonb_build_object(
    'ok',true,
    'event_id',v_event_id,
    'alias',v_alias,
    'best_score',coalesce(v_best,p_score),
    'duplicate',(v_inserted_event is null)
  );
end;
$$;

grant execute on function public.submit_risk_defender_score_v2(text,text,integer)
to anon, authenticated;


-- Permisos de la función v2 para el navegador
revoke all on function public.submit_risk_defender_score_v2(text,text,integer) from public;
grant execute on function public.submit_risk_defender_score_v2(text,text,integer) to anon, authenticated;
