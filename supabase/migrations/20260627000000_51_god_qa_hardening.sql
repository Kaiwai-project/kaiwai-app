-- ============================================================
-- 51_god_qa_hardening.sql  —  QA 점검 후속 보강
--   [Q2] admin_search_users: 1글자 풀스캔 어뷰징 차단 + trigram 인덱스로 ILIKE 가속
--   [B1] god_force_delete_post: 삭제된 게시물의 image_urls 반환 → 클라가 스토리지 고아 정리
--   ※ is_app_admin(마이그33) 은 이미 authenticated 에 grant 되어 클라가 직접 호출 가능(Q3 사용).
-- ============================================================

-- 1) 닉네임/아이디 검색 가속용 trigram 인덱스 ------------------------------------
create extension if not exists pg_trgm;
create index if not exists idx_profiles_display_name_trgm
  on public.profiles using gin (display_name gin_trgm_ops);
create index if not exists idx_profiles_username_trgm
  on public.profiles using gin (username gin_trgm_ops);

-- 2) admin_search_users: 최소 2글자 강제(1글자 전체매칭 풀스캔 연타 차단) -----------
create or replace function public.admin_search_users(p_query text)
returns table (id uuid, display_name text, username text, balance integer)
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_app_admin(auth.uid()) then
    raise exception '관리자 전용 기능입니다' using errcode = '42501';
  end if;
  -- ★[Q2] 1글자(예: 'a')는 거의 전체매칭 → 무거운 풀스캔 연타 가능. 최소 2글자로 상향.
  if coalesce(length(trim(p_query)), 0) < 2 then return; end if;

  return query
    select p.id, p.display_name, p.username, coalesce(w.balance, 0)
      from public.profiles p
      left join public.user_wallets w on w.user_id = p.id
     where p.display_name ilike '%' || p_query || '%'
        or p.username     ilike '%' || p_query || '%'
     order by p.display_name
     limit 20;
end;
$$;
revoke all on function public.admin_search_users(text) from public, anon;
grant execute on function public.admin_search_users(text) to authenticated;

-- 3) god_force_delete_post: 삭제 전 image_urls 확보 후 반환(클라 스토리지 정리용) -----
create or replace function public.god_force_delete_post(p_post_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid  uuid := auth.uid();
  v_imgs text[];
begin
  if v_uid is null then raise exception '인증이 필요합니다' using errcode = '28000'; end if;
  if not public.is_app_admin(v_uid) then
    raise exception '관리자 전용 기능입니다' using errcode = '42501';
  end if;

  select image_urls into v_imgs from public.posts where id = p_post_id for update;
  if not found then
    raise exception '존재하지 않거나 이미 삭제된 게시물입니다' using errcode = 'P0001';
  end if;

  delete from public.posts where id = p_post_id;  -- post_likes 는 ON DELETE CASCADE

  -- image_urls 를 함께 반환 → 클라가 storage 의 고아 객체(부적절 이미지)를 정리한다.
  return jsonb_build_object('deleted', true, 'post_id', p_post_id, 'image_urls', to_jsonb(coalesce(v_imgs, array[]::text[])));
end;
$$;
revoke all on function public.god_force_delete_post(uuid) from public, anon;
grant execute on function public.god_force_delete_post(uuid) to authenticated;
