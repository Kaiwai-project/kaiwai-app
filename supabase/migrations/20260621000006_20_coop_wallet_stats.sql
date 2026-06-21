-- ============================================================
-- 20_coop_wallet_stats.sql
--   [B안 - 테이블 분리 아키텍처]
--   공개 프로필(profiles)과 민감한 자산/통계 데이터를 물리적으로 분리한다.
--     · user_wallets      : 보증금/포인트(재화) 전용 — 잔액
--     · user_coop_stats   : 총대 신뢰도/패널티(3진 아웃) 전용
--   재화·신뢰도는 프론트에서 절대 직접 조작 불가:
--     - SELECT 는 본인 행만(RLS), INSERT/UPDATE/DELETE 정책 없음
--     - 쓰기는 SECURITY DEFINER RPC(서버사이드) 또는 service_role 로만 가능
-- ============================================================

-- ── 1. user_wallets (재화 · 본인만 조회) ─────────────────────
create table if not exists public.user_wallets (
  user_id    uuid        primary key references auth.users(id) on delete cascade,
  balance    integer     not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  -- 잔액은 절대 음수가 될 수 없다(차감 로직 오류·동시성 인출 방어선).
  constraint user_wallets_balance_nonneg check (balance >= 0)
);
comment on table public.user_wallets is '유저 재화(보증금/포인트) 전용 — 잔액. 쓰기는 RPC/service_role 만.';

-- ── 2. user_coop_stats (총대 신뢰도/패널티 · 본인만 조회) ─────
create table if not exists public.user_coop_stats (
  user_id           uuid        primary key references auth.users(id) on delete cascade,
  trust_score       integer     not null default 100,
  host_cancel_count integer     not null default 0,   -- 총대 귀책 무산 누적
  is_host_suspended boolean      not null default false, -- 영구 정지(3진 아웃)
  suspended_until   timestamptz,                        -- 일시 정지(쿨다운) 해제 시점, null=쿨다운 없음
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  constraint user_coop_stats_trust_nonneg  check (trust_score >= 0),
  constraint user_coop_stats_cancel_nonneg check (host_cancel_count >= 0)
);
comment on table public.user_coop_stats is '총대 신뢰도/패널티(3진 아웃) 전용. 쓰기는 RPC/service_role 만.';

-- ── updated_at 자동 갱신(공용 touch_updated_at 재사용) ───────
drop trigger if exists trg_user_wallets_touch on public.user_wallets;
create trigger trg_user_wallets_touch
  before update on public.user_wallets
  for each row execute function public.touch_updated_at();

drop trigger if exists trg_user_coop_stats_touch on public.user_coop_stats;
create trigger trg_user_coop_stats_touch
  before update on public.user_coop_stats
  for each row execute function public.touch_updated_at();

-- ============================================================
-- 3. 신규 유저 가입 시 wallet/stats 행 자동 생성
--    handle_new_user() 재정의(기존 10_kawaii_nickname 본문 + 2개 insert 추가).
--    insert 들은 on conflict do nothing 으로 멱등(중복/재실행 안전).
-- ============================================================
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  meta      jsonb := coalesce(new.raw_user_meta_data, '{}'::jsonb);
  _username text;
  _display  text;
  adjs      text[] := array[
    '말랑말랑한','딸기맛','폭신한','멘헤라','오컬트','반짝이는',
    '새콤한','몽글몽글한','우유빛','꿈꾸는','울보','새침한',
    '보들보들한','알록달록한','비밀스러운','시럽맛','마시멜로','졸린',
    '수줍은','나른한','복숭아빛','청포도맛','솜털같은','반짝반짝'
  ];
  nouns     text[] := array[
    '아기토끼','마법소녀','솜사탕곰','천사님','악마짱','요정',
    '유령','인형공주','별사탕','리본냥','젤리곰','막대사탕',
    '꼬마마녀','봉제인형','설탕별','푸딩','마카롱','체리',
    '달토끼','구름양','슈크림','복숭아','양젤리','새끼고양이'
  ];
begin
  -- username 후보: 메타데이터 → 없으면 id 앞 8자리 기반 기본값
  _username := coalesce(
    nullif(meta->>'user_name', ''),
    nullif(meta->>'preferred_username', ''),
    nullif(meta->>'nickname', ''),
    'user_' || substr(replace(new.id::text, '-', ''), 1, 8)
  );

  -- username_format(영문/숫자/_ 3~20자) 위반 또는 중복 시 안전한 기본값으로 대체
  if _username !~ '^[a-zA-Z0-9_]{3,20}$'
     or exists (select 1 from public.profiles where username = _username) then
    _username := 'user_' || substr(replace(new.id::text, '-', ''), 1, 12);
  end if;

  -- display_name: 메타데이터의 표시 이름 → 없으면 카이와이 랜덤 닉네임
  _display := nullif(coalesce(meta->>'full_name', meta->>'name', meta->>'nickname'), '');
  if _display is null then
    _display :=
        adjs[1 + floor(random() * array_length(adjs, 1))::int]
     || nouns[1 + floor(random() * array_length(nouns, 1))::int]
     || lpad((floor(random() * 10000))::int::text, 4, '0');
  end if;

  insert into public.profiles (id, username, display_name, avatar_url)
  values (
    new.id,
    _username,
    _display,
    coalesce(meta->>'avatar_url', meta->>'picture', meta->>'profile_image')
  );

  -- 자산/통계 행 자동 생성 (B안 분리 테이블)
  insert into public.user_wallets    (user_id) values (new.id) on conflict (user_id) do nothing;
  insert into public.user_coop_stats (user_id) values (new.id) on conflict (user_id) do nothing;

  return new;
end;
$$;

-- 기존 유저 백필: 트리거 도입 이전 가입자도 wallet/stats 행 보장
insert into public.user_wallets (user_id)
  select id from auth.users on conflict (user_id) do nothing;
insert into public.user_coop_stats (user_id)
  select id from auth.users on conflict (user_id) do nothing;

-- ============================================================
-- 4. RLS — 본인 행만 조회. 쓰기 정책은 두지 않음(= RPC/service_role 전용).
-- ============================================================
alter table public.user_wallets    enable row level security;
alter table public.user_coop_stats enable row level security;

drop policy if exists "지갑: 본인만 조회" on public.user_wallets;
create policy "지갑: 본인만 조회" on public.user_wallets
  for select to authenticated
  using (user_id = auth.uid());

drop policy if exists "총대통계: 본인만 조회" on public.user_coop_stats;
create policy "총대통계: 본인만 조회" on public.user_coop_stats
  for select to authenticated
  using (user_id = auth.uid());

-- ============================================================
-- 5. rpc_cancel_coop_by_host — 총대 귀책 무산(서버사이드 트랜잭션)
--    호출자(=방장)만 자기 공구를 무산시킬 수 있으며, 한 번의 트랜잭션에서:
--      ① 탑승 파티원 전원에게 보증금(300P) 자동 환불
--      ② 점진적 패널티(3진 아웃) 누적 적용
--      ③ 공구(buses) 삭제 → riders/private cascade
--    보안/동시성:
--      · SECURITY DEFINER + search_path='' (search_path 하이재킹 차단, 객체 전부 스키마 한정)
--      · auth.uid() = buses.owner_id 검증(프론트 위조·타인 공구 무산 차단)
--      · buses 행 FOR UPDATE 잠금 → 중복 호출/동시 호출 직렬화(이중 환불·이중 패널티 차단)
--        (먼저 커밋한 쪽이 행을 삭제하므로, 대기하던 두 번째 호출은 '없음'으로 거부됨)
--      · 통계 행도 FOR UPDATE 로 잠금 → 같은 총대의 동시 무산 시 카운트 경쟁 방지
--      · 환불 upsert 는 user_id 로 group → 멱등(한 행도 두 번 갱신되지 않음)
-- ============================================================
create or replace function public.rpc_cancel_coop_by_host(p_bus_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_deposit   constant integer := 300;  -- 탑승 보증금(환불 단위)
  v_uid       uuid := auth.uid();
  v_owner     uuid;
  v_refunded  integer := 0;
  v_count     integer;
  v_new_count integer;
  v_trust     integer;
  v_suspended boolean;
  v_until     timestamptz;
begin
  if v_uid is null then
    raise exception '인증이 필요합니다.' using errcode = '28000';
  end if;

  -- 공구 잠금 + 소유자 확인(없으면=이미 무산/미존재 → 중복 호출 거부)
  select b.owner_id
    into v_owner
    from public.buses b
   where b.id = p_bus_id
   for update;

  if not found then
    raise exception '이미 무산되었거나 존재하지 않는 공구입니다.' using errcode = 'P0002';
  end if;

  if v_owner <> v_uid then
    raise exception '권한이 없습니다. 방장만 공구를 무산시킬 수 있습니다.' using errcode = '42501';
  end if;

  -- ① 파티원 보증금 환불 (user_id 별 합산 upsert → 멱등)
  insert into public.user_wallets (user_id, balance)
    select r.user_id, count(*) * v_deposit
      from public.bus_riders r
     where r.bus_id = p_bus_id
     group by r.user_id
  on conflict (user_id) do update
    set balance = public.user_wallets.balance + excluded.balance;

  get diagnostics v_refunded = row_count;  -- 환불받은 파티원 수

  -- ② 패널티(3진 아웃) — 통계 행 보장 후 잠금/증가
  insert into public.user_coop_stats (user_id) values (v_uid)
    on conflict (user_id) do nothing;

  select host_cancel_count
    into v_count
    from public.user_coop_stats
   where user_id = v_uid
   for update;

  v_new_count := v_count + 1;

  update public.user_coop_stats
     set host_cancel_count = v_new_count,
         -- 1회 -20 / 2회 -30 / 3회 이상 추가 차감 없음(영구 정지로 대체), 0 미만 방지
         trust_score = greatest(0, trust_score - (case v_new_count
                                                    when 1 then 20
                                                    when 2 then 30
                                                    else 0 end)),
         -- 1회 +7일 / 2회 +30일 / 3회 이상 쿨다운 무의미(영구) → null
         suspended_until = (case
                              when v_new_count >= 3 then null
                              when v_new_count = 2 then now() + interval '30 days'
                              when v_new_count = 1 then now() + interval '7 days'
                              else suspended_until end),
         -- 3회 이상이면 영구 정지(한 번 true 면 계속 true)
         is_host_suspended = (v_new_count >= 3) or is_host_suspended
   where user_id = v_uid
  returning trust_score, is_host_suspended, suspended_until
       into v_trust, v_suspended, v_until;

  -- ③ 공구 무산: 삭제(bus_riders / bus_rider_private 는 FK cascade)
  delete from public.buses where id = p_bus_id;

  return jsonb_build_object(
    'bus_id',            p_bus_id,
    'refunded_riders',   v_refunded,
    'deposit_each',      v_deposit,
    'host_cancel_count', v_new_count,
    'trust_score',       v_trust,
    'is_host_suspended', v_suspended,
    'suspended_until',   v_until
  );
end;
$$;

-- 실행 권한: 로그인 유저만(내부에서 다시 방장 검증). anon/public 차단.
revoke all on function public.rpc_cancel_coop_by_host(uuid) from public, anon;
grant execute on function public.rpc_cancel_coop_by_host(uuid) to authenticated;
