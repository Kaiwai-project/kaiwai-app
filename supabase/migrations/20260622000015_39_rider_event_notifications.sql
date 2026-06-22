-- ============================================================
-- 39_rider_event_notifications.sql  —  [Phase2-1 후속] 방장 액션 → 탑승자 DB 알림
--
--   마이그38 은 탑승/수정요청/승인·반려/마감만 다뤘다. 정작 탑승자가 알아야 할
--   '입금 승인 / 운송장 등록 / 문제(이슈) 발생'은 아직 로컬 토스트(행위자=방장)뿐이라
--   탑승자에게 도달하지 않았다. → bus_riders AFTER UPDATE 트리거로 탑승자에게 알림 생성.
--   생성은 _notify(DEFINER) 경유(self-skip·위조차단 동일). 노쇼는 의도적 클라 전용이라 제외.
-- ============================================================

create or replace function public.notify_rider_events()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  -- 입금 승인 (paid false→true)
  if new.paid = true and coalesce(old.paid, false) = false then
    perform public._notify(new.user_id, '💖 입금 확인 완료',
      '입금이 확인됐어요! 이제 마음 놓으세요. 곧 일괄 주문이 진행됩니다.', 'paid', new.bus_id);
  end if;

  -- 운송장 등록/변경 (tracking_number 가 새로 채워지거나 바뀜)
  if new.tracking_number is not null and new.tracking_number is distinct from old.tracking_number then
    perform public._notify(new.user_id, '📦 택배가 발송됐어요!',
      coalesce(new.courier_name,'택배') || ' ' || new.tracking_number || ' 로 상품이 발송됐어요. 확인해주세요!',
      'shipped', new.bus_id);
  end if;

  -- 문제(이슈) 발생 (issue 가 새로 설정되거나 바뀜)
  if new.issue is not null and new.issue is distinct from old.issue then
    perform public._notify(new.user_id, '⚠️ 공구에 문제가 발생했어요',
      coalesce(nullif(new.issue_text,''), '주문에 문제가 생겼어요.') || ' 공구방에서 확인해주세요.',
      'issue', new.bus_id);
  end if;

  return null;
end;
$$;

drop trigger if exists trg_notify_rider_events on public.bus_riders;
create trigger trg_notify_rider_events
  after update on public.bus_riders
  for each row execute function public.notify_rider_events();
