-- SIHEN BEET 全国TOP3 プレイ動画（本人の同意 ＋ 運営の承認で公開）
-- 何回実行しても大丈夫です。先に sihen_ranking.sql が実行されている必要があります。

-- 1) 動画の記録
create table if not exists public.beet_videos(
  id uuid primary key default gen_random_uuid(),
  player_id uuid not null references public.beet_players(id) on delete cascade,
  song text not null,
  diff text not null,
  name text not null default '',
  score int not null,
  path text not null unique,
  mime text not null,
  consent_at timestamptz not null default now(),   -- 本人が「公開OK」を押した日時
  uploaded boolean not null default false,
  approved boolean not null default false,          -- ★運営がチェックを入れると公開
  withdrawn boolean not null default false,         -- 本人が取り下げた／新しい動画に置きかわった
  created_at timestamptz not null default now()
);
create index if not exists beet_videos_board on public.beet_videos(song,diff) where approved and uploaded and not withdrawn;

alter table public.beet_videos enable row level security;
drop policy if exists beet_videos_read on public.beet_videos;
create policy beet_videos_read on public.beet_videos for select using (approved and uploaded and not withdrawn);
revoke all on public.beet_videos from anon, authenticated;
grant select on public.beet_videos to anon, authenticated;

-- 2) 保存場所（公開バケット・25MBまで・動画のみ）
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('beet-videos','beet-videos',true,26214400,array['video/mp4','video/webm'])
on conflict (id) do update set public=true,file_size_limit=26214400,allowed_mime_types=array['video/mp4','video/webm'];

-- 本人確認
create or replace function public.beet_auth(p_pid uuid, p_secret text)
returns void language plpgsql security definer set search_path = public as $$
declare cur text;
begin
  select secret_hash into cur from beet_players where id = p_pid;
  if cur is null or cur <> encode(sha256(convert_to(coalesce(p_secret,''),'UTF8')),'hex') then
    raise exception 'bad player';
  end if;
end $$;

-- 3) 公開OKが押されたとき：TOP3 の本人の最新記録だけ、アップロード枠を発行
create or replace function public.beet_video_slot(p_pid uuid, p_secret text, p_song text, p_diff text, p_score int, p_mime text)
returns json language plpgsql security definer set search_path = public as $$
declare best int; nm text; rk int; vid uuid := gen_random_uuid(); pth text; old text[];
begin
  perform beet_auth(p_pid,p_secret);
  if p_diff not in ('NORMAL','HARD','EXPERT') then raise exception 'not allowed'; end if;   -- キッズは対象外
  if p_mime not in ('video/mp4','video/webm') then raise exception 'bad type'; end if;
  select score,name into best,nm from beet_scores where player_id = p_pid and song = p_song and diff = p_diff;
  if best is null or best <> p_score then raise exception 'not best'; end if;
  rk := 1 + (select count(*) from beet_scores where song = p_song and diff = p_diff and score > best);
  if rk > 3 then raise exception 'not top3'; end if;
  if (select count(*) from beet_videos where player_id = p_pid and created_at > now() - interval '1 hour') >= 6 then
    raise exception 'too many';
  end if;
  select coalesce(array_agg(path),'{}') into old from beet_videos where player_id = p_pid and song = p_song and diff = p_diff and not withdrawn;
  update beet_videos set withdrawn = true where player_id = p_pid and song = p_song and diff = p_diff and not withdrawn;
  pth := replace(vid::text,'-','') || case when p_mime = 'video/mp4' then '.mp4' else '.webm' end;
  insert into beet_videos(id,player_id,song,diff,name,score,path,mime) values(vid,p_pid,p_song,p_diff,nm,p_score,pth,p_mime);
  return json_build_object('id',vid,'path',pth,'old',old);
end $$;

-- 4) アップロード完了
create or replace function public.beet_video_done(p_pid uuid, p_secret text, p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform beet_auth(p_pid,p_secret);
  update beet_videos set uploaded = true where id = p_id and player_id = p_pid and not withdrawn;
end $$;

-- 5) 本人による取り下げ（いつでも）
create or replace function public.beet_video_withdraw(p_pid uuid, p_secret text)
returns text[] language plpgsql security definer set search_path = public as $$
declare ps text[];
begin
  perform beet_auth(p_pid,p_secret);
  update beet_videos set withdrawn = true where player_id = p_pid and not withdrawn;
  select coalesce(array_agg(path),'{}') into ps from beet_videos where player_id = p_pid;
  return ps;
end $$;

-- ストレージの許可：発行された枠にだけアップロードでき、取り下げた動画だけ消せる
create or replace function public.beet_video_can_upload(p_name text)
returns boolean language sql stable security definer set search_path = public as $$
  select exists(select 1 from beet_videos where path = p_name and not uploaded and not withdrawn and created_at > now() - interval '20 minutes')
$$;
create or replace function public.beet_video_can_delete(p_name text)
returns boolean language sql stable security definer set search_path = public as $$
  select exists(select 1 from beet_videos where path = p_name and withdrawn)
$$;
drop policy if exists beet_video_insert on storage.objects;
create policy beet_video_insert on storage.objects for insert to anon, authenticated
  with check (bucket_id = 'beet-videos' and public.beet_video_can_upload(name));
drop policy if exists beet_video_select_gone on storage.objects;
create policy beet_video_select_gone on storage.objects for select to anon, authenticated
  using (bucket_id = 'beet-videos' and public.beet_video_can_delete(name));
drop policy if exists beet_video_delete on storage.objects;
create policy beet_video_delete on storage.objects for delete to anon, authenticated
  using (bucket_id = 'beet-videos' and public.beet_video_can_delete(name));

revoke all on function public.beet_auth(uuid,text) from public, anon, authenticated;
revoke all on function public.beet_video_slot(uuid,text,text,text,int,text) from public;
revoke all on function public.beet_video_done(uuid,text,uuid) from public;
revoke all on function public.beet_video_withdraw(uuid,text) from public;
grant execute on function public.beet_video_slot(uuid,text,text,text,int,text) to anon, authenticated;
grant execute on function public.beet_video_done(uuid,text,uuid) to anon, authenticated;
grant execute on function public.beet_video_withdraw(uuid,text) to anon, authenticated;
grant execute on function public.beet_video_can_upload(text) to anon, authenticated;
grant execute on function public.beet_video_can_delete(text) to anon, authenticated;
notify pgrst, 'reload schema';
