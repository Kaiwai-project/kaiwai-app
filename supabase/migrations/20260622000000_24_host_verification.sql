-- ============================================================
-- 24_host_verification.sql  —  [총대 인증 마일스톤] 본인인증 + 정산계좌 + 결합검증
--
--   기존 구멍: verify_host_securely() 가 '아무 검증 없이' verified_host=true 로 승격
--              → 누구나 Mock 버튼만 통과하면 인증 총대가 되어 입금 수령(대포통장 먹튀 가능).
--
--   원칙
--   ① PII 물리분리 + CI는 평문 미보관(해시) — 국가식별자 파생값을 저장하지 않는다.
--   ② 결합검증(Zero-Trust): 계좌 예금주명 == 본인인증 실명 일치해야만 승격(대포통장 차단).
--   ③ 1인 1총대: CI 해시 UNIQUE → 먹튀 후 재인증 차단.
--   ④ 정산계좌는 '탑승자 전용' 공개 — 비탑승자는 총대 계좌번호 열람 불가.
--   ⑤ 승격은 검증 레코드가 있을 때만, service_role(Edge Function) 경유로만.
-- ============================================================

-- ── 0. 이름 정규화 헬퍼(공백제거+소문자) — 결합검증용 ──
create or replace function public._norm_name(p text)
returns text language sql immutable as $$
  select lower(regexp_replace(coalesce(p,''), '\s+', '', 'g'));
$$;

-- ── 1. host_verifications (본인인증 결과 · 민감 PII) ──
create table if not exists public.host_verifications (
  user_id     uuid        primary key references auth.users(id) on delete cascade,
  status      text        not null default 'verified',   -- verified | rejected
  real_name   text        not null,
  phone       text,
  ci_hash     text        not null,                       -- sha256(salt‖CI). 평문 CI 미보관.
  provider    text        not null default 'mock',        -- 'mock' | 'pass' 등
  verified_at timestamptz not null default now(),
  created_at  timestamptz not null default now()
);
comment on table public.host_verifications is '총대 본인인증 결과(민감 PII). CI는 해시만. 쓰기는 service_role/RPC 전용.';
-- 1인 1총대: 동일 CI 로 두 계정 인증 불가
create unique index if not exists uq_host_verif_ci on public.host_verifications(ci_hash);

-- ── 2. host_accounts (정산 계좌 SSOT) ──
create table if not exists public.host_accounts (
  user_id        uuid        primary key references auth.users(id) on delete cascade,
  bank_name      text        not null,
  account_number text        not null,
  account_holder text        not null,                    -- 예금주명(은행 권위값)
  account_verified boolean   not null default false,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);
comment on table public.host_accounts is '총대 정산계좌 원본(SSOT). 쓰기는 service_role/RPC 전용. 라이더는 bus_host_accounts 스냅샷으로만 열람.';
drop trigger if exists trg_host_accounts_touch on public.host_accounts;
create trigger trg_host_accounts_touch before update on public.host_accounts
  for each row execute function public.touch_updated_at();

-- ── 3. bus_host_accounts (공구별 계좌 스냅샷 · 탑승자 전용 공개) ──
create table if not exists public.bus_host_accounts (
  bus_id       uuid        primary key references public.buses(id) on delete cascade,
  host_account jsonb       not null,        -- { bankName, accountNumber, realName }
  created_at   timestamptz not null default now()
);
comment on table public.bus_host_accounts is '공구 개설 시점 계좌 스냅샷. SELECT 는 방장 또는 그 버스 탑승자만(개인정보 보호).';

-- ── 4. RLS ──
alter table public.host_verifications enable row level security;
alter table public.host_accounts      enable row level security;
alter table public.bus_host_accounts  enable row level security;

drop policy if exists "본인인증: 본인만 조회" on public.host_verifications;
create policy "본인인증: 본인만 조회" on public.host_verifications
  for select to authenticated using (user_id = auth.uid());

drop policy if exists "정산계좌: 본인만 조회" on public.host_accounts;
create policy "정산계좌: 본인만 조회" on public.host_accounts
  for select to authenticated using (user_id = auth.uid());

-- 계좌 스냅샷: 방장 또는 그 버스 탑승자만 (비탑승자 차단)
drop policy if exists "계좌스냅샷: 방장/탑승자만" on public.bus_host_accounts;
create policy "계좌스냅샷: 방장/탑승자만" on public.bus_host_accounts
  for select to authenticated using (
    exists (select 1 from public.buses b
              where b.id = bus_host_accounts.bus_id and b.owner_id = auth.uid())
    or exists (select 1 from public.bus_riders r
              where r.bus_id = bus_host_accounts.bus_id and r.user_id = auth.uid())
  );
-- 세 테이블 모두 클라 INSERT/UPDATE/DELETE 정책 없음 → service_role/DEFINER 전용.

-- ============================================================
-- 5. 공구 개설 시 계좌 스냅샷 자동 생성 (서버 파생 = 클라 위조 불가)
--    buses INSERT 후, 방장의 verified 계좌를 bus_host_accounts 에 복사.
-- ============================================================
create or replace function public._snapshot_bus_host_account()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare v_acc record;
begin
  select bank_name, account_number, account_holder
    into v_acc
    from public.host_accounts
   where user_id = new.owner_id and account_verified = true;
  if found then
    insert into public.bus_host_accounts (bus_id, host_account)
    values (new.id, jsonb_build_object(
      'bankName',      v_acc.bank_name,
      'accountNumber', v_acc.account_number,
      'realName',      v_acc.account_holder));
  end if;
  return new;
end;
$$;
drop trigger if exists trg_snapshot_bus_host_account on public.buses;
create trigger trg_snapshot_bus_host_account
  after insert on public.buses
  for each row execute function public._snapshot_bus_host_account();

-- 더 이상 public buses 행에 계좌를 두지 않는다(비탑승자 노출 차단) → 컬럼 제거.
alter table public.buses drop column if exists host_account;

-- 공구 개설 = verified_host + '인증된 정산계좌 보유' 둘 다 강제(무계좌 개설 차단)
drop policy if exists "인증 총대만 개설" on public.buses;
create policy "인증 총대만 개설" on public.buses
  for insert to authenticated
  with check (
    auth.uid() = owner_id
    and exists (select 1 from public.profiles p     where p.id = auth.uid()      and p.verified_host = true)
    and exists (select 1 from public.host_accounts a where a.user_id = auth.uid() and a.account_verified = true)
  );

-- ============================================================
-- 6. finalize_host_verification — 보안 키스톤 (service_role 전용)
--    Edge Function(verify-host)이 mock/실제 제공자에서 권위값을 받아 호출.
--    결합검증(예금주==실명) + CI중복(1인1총대) + 기록 + 승격을 한 트랜잭션에 강제.
-- ============================================================
create or replace function public.finalize_host_verification(
  p_uid            uuid,
  p_real_name      text,
  p_phone          text,
  p_ci_hash        text,
  p_bank_name      text,
  p_account_number text,
  p_account_holder text,
  p_provider       text default 'mock'
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_uid is null then raise exception '대상 유저가 없습니다' using errcode = 'P0001'; end if;
  if coalesce(p_real_name,'') = '' or coalesce(p_account_holder,'') = '' or coalesce(p_ci_hash,'') = '' then
    raise exception '인증 정보가 누락되었습니다' using errcode = 'P0001';
  end if;

  -- ★ 결합검증: 계좌 예금주명 == 본인인증 실명 (대포통장 먹튀 차단)
  if public._norm_name(p_real_name) <> public._norm_name(p_account_holder) then
    raise exception '계좌 예금주명이 본인인증 실명과 일치하지 않습니다.' using errcode = 'P0001';
  end if;

  -- ★ 1인 1총대: 동일 CI 가 '다른' 유저로 이미 인증돼 있으면 거부
  if exists (select 1 from public.host_verifications
              where ci_hash = p_ci_hash and user_id <> p_uid) then
    raise exception '이미 다른 계정에서 인증된 본인인증 정보입니다. (1인 1총대)' using errcode = 'P0001';
  end if;

  -- 본인인증 기록(멱등: 본인 재인증은 갱신)
  insert into public.host_verifications (user_id, status, real_name, phone, ci_hash, provider, verified_at)
  values (p_uid, 'verified', p_real_name, p_phone, p_ci_hash, p_provider, now())
  on conflict (user_id) do update
    set status='verified', real_name=excluded.real_name, phone=excluded.phone,
        ci_hash=excluded.ci_hash, provider=excluded.provider, verified_at=now();

  -- 정산계좌 기록
  insert into public.host_accounts (user_id, bank_name, account_number, account_holder, account_verified)
  values (p_uid, p_bank_name, p_account_number, p_account_holder, true)
  on conflict (user_id) do update
    set bank_name=excluded.bank_name, account_number=excluded.account_number,
        account_holder=excluded.account_holder, account_verified=true;

  -- 승격: 검증 레코드가 확정된 지금만 verified_host=true (트랜잭션-로컬 GUC)
  perform set_config('app.allow_host_verify', '1', true);
  update public.profiles set verified_host = true where id = p_uid;

  return jsonb_build_object('verified', true, 'user_id', p_uid);
end;
$$;
revoke all on function public.finalize_host_verification(uuid,text,text,text,text,text,text,text) from public, anon, authenticated;
grant execute on function public.finalize_host_verification(uuid,text,text,text,text,text,text,text) to service_role;

-- ============================================================
-- 7. 기존 자가승격 RPC 봉인 — 검증 없는 승격 경로 폐쇄
--    클라가 더 이상 verify_host_securely 로 셀프 승격 불가(authenticated revoke).
--    (혹시 호출돼도 본인인증 레코드 없으면 승격 안 하도록 본문도 보강.)
-- ============================================================
create or replace function public.verify_host_securely()
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then raise exception '인증이 필요합니다'; end if;
  -- 본인인증(host_verifications) 이 있을 때만 승격 — 무검증 승격 차단
  if not exists (select 1 from public.host_verifications
                  where user_id = auth.uid() and status = 'verified') then
    raise exception '본인인증 후 이용 가능합니다.' using errcode = 'P0001';
  end if;
  perform set_config('app.allow_host_verify', '1', true);
  update public.profiles set verified_host = true where id = auth.uid();
end;
$$;
revoke all on function public.verify_host_securely() from public, anon, authenticated;
