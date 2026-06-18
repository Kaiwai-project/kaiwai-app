import json
import os
import sys
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path

try:
    from apify_client import ApifyClient
except ImportError:
    ApifyClient = None
try:
    from google import genai
except ImportError:
    genai = None

# 한국 표준시(KST). 슬롯/날짜는 한국 기준으로 계산한다.
KST = timezone(timedelta(hours=9))

# 하루를 8시간씩 3등분한 일정 슬롯 (0시 / 8시 / 16시)
SLOT_TIMES = ["00:00", "08:00", "16:00"]

if sys.stdout.encoding and sys.stdout.encoding.lower() != "utf-8":
    sys.stdout.reconfigure(encoding="utf-8")

APIFY_TOKEN = os.environ.get("APIFY_TOKEN", "")
GEMINI_API_KEY = os.environ.get("GEMINI_API_KEY", "")
IG_COOKIE = os.environ.get("IG_COOKIE", "")
TW_COOKIE = os.environ.get("TW_COOKIE", "")
# 슬롯(시간대) 무시하고 전 브랜드를 한 번에 수집 (workflow_dispatch 수동 강제 갱신용)
FORCE_ALL = os.environ.get("FORCE_ALL", "").lower() == "true"
OUT_PATH = Path(__file__).parent / "calendar_data.json"

ACTOR_IG = "apify/instagram-scraper"
# 구 apify/twitter-scraper 는 폐기되어 "Actor not found" 발생 → 현행 액터로 교체.
# ⚠️ apidojo/tweet-scraper 는 유료(rental) 액터 — 첫 실행 전 Apify 계정에서 사용 가능 여부/요금 확인 권장.
ACTOR_TW = "apidojo/tweet-scraper"

BRANDS_GROUPS = {
    0: [
        {"name": "ROJITA",      "ig": "rojita__official",       "tw": "ROJITA__jp",      "color": "#C41055", "emoji": "🖤"},
        {"name": "Ank Rouge",   "ig": "ankrouge_official",      "tw": "AnkRouge",         "color": "#C41055", "emoji": "🎀"},
        {"name": "LIZ LISA",    "ig": "lizlisa_official_japan", "tw": "lizlisaofficial",  "color": "#C41055", "emoji": "🌸"},
    ],
    1: [
        {"name": "Secret Honey",    "ig": "secrethoney_official", "tw": "SecretHoney_HB", "color": "#C41055", "emoji": "🐰"},
        {"name": "pium",            "ig": "",                     "tw": "pium__official",  "color": "#AA7020", "emoji": "🌸"},
        {"name": "Honey Cinnamon",  "ig": "",                     "tw": "honeyc0214",      "color": "#C41055", "emoji": "🍯"},
    ],
    2: [
        {"name": "NOEMIE",      "ig": "noemie_official_",    "tw": "Noemie_shop",       "color": "#C41055", "emoji": "🩷"},
        {"name": "MA*RS",       "ig": "marsofficialjapan",   "tw": "mars_amoebamars",   "color": "#C41055", "emoji": "♦️"},
        {"name": "DearMyLove",  "ig": "dearmylove_official", "tw": "dearmylove_yume",   "color": "#C41055", "emoji": "💕"},
        {"name": "DimMoire",    "ig": "",                    "tw": "_DimMoire_",         "color": "#7733BB", "emoji": "🌑"},
    ],
}

SYSTEM_PROMPT = """당신은 일본 서브컬처 패션 브랜드의 SNS 게시물을 분석하는 전문가입니다.

주요 역할:
1. 게시물에서 실제 이벤트 정보를 정확히 추출합니다
2. 추출한 내용을 한국 SNS 감성에 맞는 자연스러운 문체로 요약합니다

이벤트 분류 기준:
✅ 이벤트 해당: 신상품 발매·드롭, 팝업 스토어 오픈, 선행예약·수주 시작, 할인·세일 이벤트, 기념 이벤트, 한정 컬렉션 출시
❌ 이벤트 아님: 단순 일상 포스팅, 감사 인사만 있는 글, 팔로워 소통, 단순 착샷 공유, 리포스트

설명문 작성 규칙:
- 50자 이내의 간결하고 자연스러운 한국어
- 직역 금지 — 한국 SNS 감성으로 의역
- 구체적인 이벤트 내용(날짜·종류·혜택)을 포함할 것
- 예시: "5주년 기념 10% 할인 진행 중! 🎉", "6/21 팝업 스토어 오픈 💕", "신작 드레스 드롭 예정 🌸"

응답 형식: JSON 한 줄 또는 null (다른 텍스트 없이)"""

# ─── Gemini 모델 폴백 체인 ───────────────────────────────────────────────
# 앞에서부터 시도하고, 한 모델이 영구 오류(429 할당량 / 404 없는 모델 / 403 권한)면
# 그 모델을 체인에서 빼고 다음 모델로 넘어간다. 모든 모델이 소진돼야 키워드 폴백으로 전환.
# → 새 GEMINI_API_KEY 만 교체하면 이 중 동작하는 모델 하나가 자동 선택돼 바로 작동한다.
MODEL_CHAIN = [
    "gemini-2.5-flash",        # 권장 워크호스 (무료 티어 보유)
    "gemini-2.5-flash-lite",   # 더 가볍고 할당량 넉넉
    "gemini-2.0-flash",        # 구버전 폴백
    "gemini-flash-latest",     # 롤링 최신 별칭 (미래 대비)
]

# 해당 모델을 체인에서 영구 제거해야 하는 오류 신호 (할당량/없는 모델/권한)
_FATAL_ERR_SIGNS = (
    "429", "quota", "resource_exhausted", "rate limit", "rate_limit",
    "404", "not found", "not_found", "is not found", "unsupported",
    "403", "permission", "permission_denied", "api key not valid",
)


def _short(err: Exception, n: int = 140) -> str:
    """긴 예외 메시지를 로그용으로 한 줄 축약."""
    s = " ".join(str(err).split())
    return s if len(s) <= n else s[:n] + "…"


def _build_prompt(brand_name: str, text: str, today: datetime) -> str:
    return f"""{SYSTEM_PROMPT}

오늘: {today.strftime("%Y년 %m월 %d일")}
브랜드: {brand_name}

SNS 게시물:
---
{text[:1200]}
---

이벤트가 있으면 JSON을, 없으면 null만 출력하세요.
{{"date": "YYYY-MM-DD", "description": "한국 SNS 감성 이벤트 설명 50자 이내"}}

날짜 규칙:
- 연도 명시 없으면 {today.year}년 기준
- 날짜 파악 불가 시 null 반환"""


def _parse_event(raw: str) -> dict | None:
    """Gemini 응답 텍스트에서 이벤트 dict 추출. 이벤트 없으면 None."""
    raw = (raw or "").strip()
    if raw.lower() == "null" or not raw:
        return None
    # ```json ... ``` 마크다운 블록 처리
    if raw.startswith("```"):
        parts = raw.split("```")
        raw = parts[1].lstrip("json").strip() if len(parts) > 1 else raw
    try:
        data = json.loads(raw)
    except (json.JSONDecodeError, ValueError):
        return None
    if not isinstance(data, dict) or not data.get("date") or not data.get("description"):
        return None
    return data


class GeminiAnalyzer:
    """모델 폴백 체인을 관리하는 Gemini 분석기.

    429(할당량)/404(없는 모델)/403(권한) 같은 영구 오류가 나면 그 모델을 체인에서
    제거하고 자동으로 다음 모델을 시도한다. 한 번 동작이 확인된 모델은 이후 게시물에서
    바로 재사용(죽은 모델 재시도 비용 회피)한다. 체인의 모든 모델이 소진되면
    `disabled=True` 가 되어 호출자는 키워드 폴백으로 전환한다."""

    def __init__(self, client: "genai.Client"):
        self.client = client
        self.models = list(MODEL_CHAIN)   # 아직 살아있는 후보 모델
        self.active: str | None = None    # 동작 확인된 현재 모델
        self.disabled = False             # 전 모델 소진 → LLM 비활성

    @staticmethod
    def _is_fatal(err: Exception) -> bool:
        msg = str(err).lower()
        return any(sign in msg for sign in _FATAL_ERR_SIGNS)

    def analyze(self, brand_name: str, text: str, today: datetime) -> tuple[dict | None, bool]:
        """반환 (event, ok):
          - (dict, True)  : 이벤트 추출 성공
          - (None, True)  : 정상 응답인데 이벤트 없음 (또는 이 게시물만 일시 오류)
          - (None, False) : 모든 모델 소진 → 호출자는 키워드 폴백으로 전환"""
        if self.disabled:
            return None, False

        prompt = _build_prompt(brand_name, text, today)

        # 살아있는 모델이 있는 한, 영구 오류면 다음 모델로 넘어가며 재시도
        while self.models:
            model = self.active if self.active in self.models else self.models[0]
            try:
                resp = self.client.models.generate_content(model=model, contents=prompt)
                if self.active != model:
                    print(f"    ✓ Gemini 모델 '{model}' 사용")
                    self.active = model
                return _parse_event(resp.text), True
            except Exception as e:
                if self._is_fatal(e):
                    print(f"    ⚠️ 모델 '{model}' 사용 불가({_short(e)}) → 다음 모델 시도")
                    if model in self.models:
                        self.models.remove(model)
                    self.active = None
                    continue   # 다음 후보 모델로
                # 일시 오류(네트워크 등): 이 게시물만 건너뛰고 모델은 유지
                print(f"    LLM 일시 오류: {_short(e)}")
                return None, True

        # 체인 소진 → LLM 비활성, 이후는 키워드 폴백
        self.disabled = True
        print("    ⚠️ 모든 Gemini 모델 소진 → 키워드 폴백으로 전환")
        return None, False


def fetch_instagram(apify: ApifyClient, handle: str) -> list[str]:
    try:
        run = apify.actor(ACTOR_IG).call(run_input={
            "directUrls": [f"https://www.instagram.com/{handle}/"],
            "resultsLimit": 5,
            "cookies": [{"name": "sessionid", "value": IG_COOKIE}] if IG_COOKIE else [],
        })
        return [
            item.get("caption") or item.get("text") or ""
            for item in apify.dataset(run.default_dataset_id).iterate_items()
        ]
    except Exception as e:
        print(f"    IG 오류 ({handle}): {e}")
        return []


def fetch_twitter(apify: ApifyClient, handle: str) -> list[str]:
    # apidojo/tweet-scraper 입력 스키마: twitterHandles(@ 없는 핸들 배열) / maxItems / sort.
    # (이 액터는 자체 프록시·인증을 써서 TW_COOKIE 불필요)
    try:
        run = apify.actor(ACTOR_TW).call(run_input={
            "twitterHandles": [handle.lstrip("@")],
            "maxItems": 5,
            "sort": "Latest",
        })
        return [
            item.get("text") or item.get("full_text") or ""
            for item in apify.dataset(run.default_dataset_id).iterate_items()
            if not (item.get("text") or "").startswith("RT ")
        ]
    except Exception as e:
        print(f"    TW 오류 ({handle}): {e}")
        return []


# 시드(데모) 일정 설명 템플릿 — type(tp), 설명 포맷
SEED_TEMPLATES = [
    ("신상",   "신작 컬렉션 입고 예정 {e}"),
    ("예약",   "선행 예약 오픈 {e}"),
    ("팝업",   "팝업 스토어 안내 {e}"),
    ("수주",   "수주 기간 진행 중 {e}"),
    ("이벤트", "한정 이벤트 진행 {e}"),
]


def build_seed_schedule(today: datetime, days: int = 14) -> list[dict]:
    """스크래퍼 키가 없을 때 캘린더를 채우는 데모 스케줄.
    오늘부터 days일간 '하루 3건(0/8/16시), 매일' 고르게 브랜드를 순환 배치한다."""
    roster = [b for group in BRANDS_GROUPS.values() for b in group]
    out, k = [], 0
    for d in range(days):
        date = (today + timedelta(days=d)).strftime("%Y-%m-%d")
        for tm in SLOT_TIMES:                       # 하루 3번, 8시간 간격
            b = roster[k % len(roster)]
            tp, tmpl = SEED_TEMPLATES[k % len(SEED_TEMPLATES)]
            out.append({
                "dt": date,
                "tm": tm,
                "br": b["name"],
                "d":  tmpl.format(e=b["emoji"]),
                "c":  b["color"],
                "e":  b["emoji"],
                "tp": tp,
                "seed": True,                        # 실제 수집 시 교체될 데모 데이터 표시
            })
            k += 1
    return out


def main():
    today = datetime.now(KST)
    apify = ApifyClient(APIFY_TOKEN) if (APIFY_TOKEN and ApifyClient) else None
    gemini = genai.Client(api_key=GEMINI_API_KEY) if (GEMINI_API_KEY and genai) else None

    # 스크래퍼 키가 없으면(로컬/테스트) 데모 시드 스케줄로 캘린더를 채우고 종료
    if not apify:
        events = build_seed_schedule(today)
        OUT_PATH.write_text(json.dumps(events, ensure_ascii=False, indent=2), encoding="utf-8")
        print(f"⚠️ APIFY_TOKEN 없음 → 데모 시드 {len(events)}개 생성 (하루 3건·8시간 간격·매일)")
        return

    # FORCE_ALL(수동 강제 갱신): 슬롯 무시하고 전 브랜드를 한 번에 수집
    if FORCE_ALL:
        brands = [b for group in BRANDS_GROUPS.values() for b in group]
        print(f"⚡ 강제 전체 수집: {len(brands)}개 브랜드 (슬롯 무시)")
    else:
        # 하루 3번(8시간 슬롯) 기준으로 그룹 분할: 0~7시→0, 8~15시→1, 16~23시→2
        # (기존 today.day % 3 = 3일에 걸쳐 [3,3,4] 처리하던 방식에서 변경)
        slot = today.hour // 8
        brands = BRANDS_GROUPS.get(slot, [])
        print(f"슬롯 {slot} ({today.hour}시, {len(brands)}개 브랜드) 수집 시작")

    existing = json.loads(OUT_PATH.read_text(encoding="utf-8")) if OUT_PATH.exists() else []
    processing_names = {b["name"] for b in brands}
    # 시드(데모) 이벤트는 실제 수집 시 제거, 현재 그룹 외 실제 이벤트는 유지
    events = [e for e in existing if not e.get("seed") and e.get("br") not in processing_names]

    # 모델 폴백 체인을 관리하는 분석기. 체인의 모든 모델이 소진(429/404/403)되면
    # analyzer.disabled 가 켜지고, 이후 게시물은 인스타+키워드 폴백으로 실데이터가 채워진다.
    analyzer = GeminiAnalyzer(gemini) if gemini else None

    for brand in brands:
        print(f"\n▶ {brand['name']}")
        texts: list[str] = []

        if apify:
            if brand["ig"]:
                ig_posts = fetch_instagram(apify, brand["ig"])
                print(f"  IG {len(ig_posts)}개 수집")
                texts.extend(ig_posts)
            if brand["tw"]:
                tw_posts = fetch_twitter(apify, brand["tw"])
                print(f"  TW {len(tw_posts)}개 수집")
                texts.extend(tw_posts)

        if not texts:
            print("  수집 없음")
            continue

        for i, text in enumerate(texts):
            if not text or not text.strip():
                continue

            result = None
            if analyzer and not analyzer.disabled:
                result, _ok = analyzer.analyze(brand["name"], text, today)
                time.sleep(0.3)

            if result:
                print(f"  ✅ [{result['date']}] {result['description']}")
                events.append({
                    "dt": result["date"],
                    "br": brand["name"],
                    "d":  result["description"],
                    "c":  brand["color"],
                    "e":  brand["emoji"],
                })
            elif analyzer is None or analyzer.disabled:
                # LLM 없음/실패 폴백: 키워드 필터 (일본어·한국어 이벤트 키워드)
                triggers = ["発売", "新作", "ドロップ", "drop", "예약", "팝업", "수주", "발매",
                            "セール", "sale", "限定", "予約", "popup", "pop up", "コラボ", "입고"]
                if any(t.lower() in text.lower() for t in triggers):
                    events.append({
                        "dt": (today + timedelta(days=7)).strftime("%Y-%m-%d"),
                        "br": brand["name"],
                        "d":  text[:50].strip(),
                        "c":  brand["color"],
                        "e":  brand["emoji"],
                    })
            else:
                print(f"  ⏭ 게시물 {i+1}: 이벤트 없음")

        time.sleep(10)

    # 7일 이상 지난 이벤트 제거
    cutoff = (today - timedelta(days=7)).strftime("%Y-%m-%d")
    events = [e for e in events if e.get("dt", "") >= cutoff]

    # 날짜 오름차순 정렬
    events.sort(key=lambda x: x.get("dt", "9999-12-31"))

    OUT_PATH.write_text(json.dumps(events, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"\n✅ 완료: {len(events)}개 이벤트 저장")


if __name__ == "__main__":
    main()
