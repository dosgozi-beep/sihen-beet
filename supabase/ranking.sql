-- SIHEN BEET 全国ランキング（何回実行しても大丈夫です）
create table if not exists public.beet_players(
  id uuid primary key,
  secret_hash text not null,
  name text not null default 'ななしの羊飼い',
  created_at timestamptz not null default now()
);
create table if not exists public.beet_scores(
  player_id uuid not null references public.beet_players(id) on delete cascade,
  song text not null,
  diff text not null,
  name text not null,
  score int not null,
  mark text not null default '',
  combo int not null default 0,
  updated_at timestamptz not null default now(),
  primary key(player_id,song,diff)
);
create index if not exists beet_scores_board on public.beet_scores(song,diff,score desc,updated_at);

alter table public.beet_players enable row level security;
alter table public.beet_scores enable row level security;
drop policy if exists beet_scores_read on public.beet_scores;
create policy beet_scores_read on public.beet_scores for select using (true);
revoke all on public.beet_players from anon, authenticated;
grant select on public.beet_scores to anon, authenticated;

create or replace function public.beet_player(p_pid uuid, p_secret text, p_name text)
returns void language plpgsql security definer set search_path = public as $$
declare h text := encode(sha256(convert_to(p_secret,'UTF8')),'hex'); cur text;
begin
  if p_pid is null or length(coalesce(p_secret,'')) < 16 then raise exception 'bad player'; end if;
  select secret_hash into cur from beet_players where id = p_pid;
  if cur is null then
    insert into beet_players(id,secret_hash,name) values(p_pid,h,p_name);
  elsif cur <> h then
    raise exception 'bad secret';
  end if;
end $$;

create or replace function public.beet_submit(p_pid uuid, p_secret text, p_song text, p_diff text,
  p_name text, p_score int, p_mark text, p_combo int)
returns int language plpgsql security definer set search_path = public as $$
declare nm text := left(coalesce(nullif(trim(p_name),''),'ななしの羊飼い'),10); best int;
begin
  if p_song !~ '^[a-z0-9_]{1,24}$' or p_diff not in ('NORMAL','HARD','EXPERT','KIDS')
     or p_score < 0 or p_score > 1000000 or p_combo < 0 or p_combo > 5000 then
    raise exception 'bad score';
  end if;
  perform beet_player(p_pid,p_secret,nm);
  update beet_players set name = nm where id = p_pid;
  update beet_scores set name = nm where player_id = p_pid;
  insert into beet_scores(player_id,song,diff,name,score,mark,combo)
    values(p_pid,p_song,p_diff,nm,p_score,coalesce(p_mark,''),p_combo)
  on conflict(player_id,song,diff) do update
    set score = excluded.score, mark = excluded.mark, combo = excluded.combo, updated_at = now()
    where beet_scores.score < excluded.score;
  select score into best from beet_scores where player_id = p_pid and song = p_song and diff = p_diff;
  return 1 + (select count(*) from beet_scores where song = p_song and diff = p_diff and score > best);
end $$;

create or replace function public.beet_set_name(p_pid uuid, p_secret text, p_name text)
returns void language plpgsql security definer set search_path = public as $$
declare nm text := left(coalesce(nullif(trim(p_name),''),'ななしの羊飼い'),10);
begin
  perform beet_player(p_pid,p_secret,nm);
  update beet_players set name = nm where id = p_pid;
  update beet_scores set name = nm where player_id = p_pid;
end $$;

revoke all on function public.beet_player(uuid,text,text) from public, anon, authenticated;
grant execute on function public.beet_submit(uuid,text,text,text,text,int,text,int) to anon, authenticated;
grant execute on function public.beet_set_name(uuid,text,text) to anon, authenticated;
notify pgrst, 'reload schema';
