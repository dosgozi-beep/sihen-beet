-- SIHEN BEET プレイ回数カウンターと感想コーナー（何回実行しても大丈夫です）
create table if not exists public.beet_stats(
  id int primary key default 1 check (id = 1),
  plays bigint not null default 0,
  notes bigint not null default 0
);
insert into public.beet_stats(id) values(1) on conflict do nothing;

create table if not exists public.beet_feedback(
  id bigserial primary key,
  player_id uuid,
  name text not null default 'ななしの羊飼い',
  song text not null default '',
  message text not null,
  approved boolean not null default false,
  created_at timestamptz not null default now()
);

alter table public.beet_stats enable row level security;
alter table public.beet_feedback enable row level security;
drop policy if exists beet_stats_read on public.beet_stats;
create policy beet_stats_read on public.beet_stats for select using (true);
drop policy if exists beet_feedback_read on public.beet_feedback;
create policy beet_feedback_read on public.beet_feedback for select using (approved);
revoke all on public.beet_stats, public.beet_feedback from anon, authenticated;
grant select on public.beet_stats to anon, authenticated;
grant select (id, name, song, message, created_at, approved) on public.beet_feedback to anon, authenticated;

-- 1曲遊び終わるたびにゲームから呼ばれる
create or replace function public.beet_play(p_pid uuid, p_secret text, p_notes int)
returns void language plpgsql security definer set search_path = public as $$
begin
  if p_notes is null or p_notes < 0 or p_notes > 3000 then raise exception 'bad notes'; end if;
  update beet_stats set plays = plays + 1, notes = notes + p_notes where id = 1;
end $$;

-- 公式サイトの感想フォームから呼ばれる（同じ人は10分に1回まで）
create or replace function public.beet_feedback_post(p_pid uuid, p_name text, p_song text, p_message text)
returns void language plpgsql security definer set search_path = public as $$
declare msg text := trim(coalesce(p_message,''));
begin
  if length(msg) < 2 or length(msg) > 300 then raise exception 'bad message'; end if;
  if p_pid is not null and exists(select 1 from beet_feedback where player_id = p_pid and created_at > now() - interval '10 minutes') then
    raise exception 'too soon';
  end if;
  insert into beet_feedback(player_id,name,song,message)
    values(p_pid, left(coalesce(nullif(trim(p_name),''),'ななしの羊飼い'),12), left(coalesce(p_song,''),24), msg);
end $$;

grant execute on function public.beet_play(uuid,text,int) to anon, authenticated;
grant execute on function public.beet_feedback_post(uuid,text,text,text) to anon, authenticated;
notify pgrst, 'reload schema';
