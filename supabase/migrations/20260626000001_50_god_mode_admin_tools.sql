-- ============================================================
-- 50_god_mode_admin_tools.sql  —  God Mode 운영도구
--   1) god_force_delete_post : 부적절 피드 게시물 강제삭제 (post_likes cascade)
--   2) admin_grant_points_to : 특정 유저에게 포인트 ±지급 (잔액 0 미만 불가)
--   3) admin_search_users    : 닉네임/아이디로 유저 검색 (지급 대상 선택용)
--   게이트: 전부 is_app_admin(auth.uid()) (마이그33 화이트리스트) 재사용.
-- ============================================================

-- 1) 피드 게시물 강제삭제 -----------------------------------------------------
create or replace function public.god_force_delete_post(p_post_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception '인증이 필요합니다' using errcode = '28000'; end if;
  if not public.is_app_admin(v_uid) then
    raise exception '관리자 전용 기능입니다' using errcode = '42501';
  end if;

  perform 1 from public.posts where id = p_post_id for update;
  if not found then
    raise exception '존재하지 않거나 이미 삭제된 게시물입니다' using errcode = 'P0001';
  end if;

  delete from public.posts where id = p_post_id;  -- post_likes 는 ON DELETE CASCADE

  return jsonb_build_object('deleted', true, 'post_id', p_post_id);
end;
$$;
revoke all on function public.god_force_delete_post(uuid) from public, anon;
grant execute on function public.god_force_delete_post(uuid) to authenticated;

-- 2) 특정 유저 포인트 ±지급 ---------------------------------------------------
create or replace function public.admin_grant_points_to(p_target uuid, p_amount integer)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid    uuid := auth.uid();
  v_reason public.point_reason;
begin
  if v_uid is null then raise exception '인증이 필요합니다' using errcode = '28000'; end if;
  if not public.is_app_admin(v_uid) then
    raise exception '관리자 전용 기능입니다' using errcode = '42501';
  end if;
  if p_target is null then raise exception '대상 유저가 없습니다' using errcode = 'P0001'; end if;
  if p_amount is null or p_amount = 0 or abs(p_amount) > 100000 then
    raise exception '지급/차감액이 올바르지 않습니다 (±1~100000)' using errcode = 'P0001';
  end if;

  v_reason := case when p_amount > 0 then 'admin_grant' else 'admin_revoke' end;
  -- 차감으로 잔액 < 0 이면 _wallet_apply 가 '포인트가 부족합니다'(P0001) raise → 롤백
  return public._wallet_apply(p_target, p_amount, v_reason,
                              null, 'god grant by ' || v_uid::text);
end;
$$;
revoke all on function public.admin_grant_points_to(uuid, integer) from public, anon;
grant execute on function public.admin_grant_points_to(uuid, integer) to authenticated;

-- 3) 유저 검색 (지급 대상 선택용) ---------------------------------------------
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
  if coalesce(length(trim(p_query)), 0) < 1 then return; end if;

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
