import json
import os
import re
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
try:
    # IG 직접 API 호출용 — 브라우저 TLS 지문(JA3) 임퍼소네이션이 필요하다.
    # 표준 urllib/requests 기본 지문은 IG 에 429(Too Many Requests)로 차단됨(실측).
    from curl_cffi import requests as cffi_requests
except ImportError:
    cffi_requests = None

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
# IG 웹 클라이언트 공개 app-id (web_profile_info 직접 호출 시 x-ig-app-id 헤더에 사용)
IG_APP_ID = "936619743392459"
IG_UA = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15"

# "id" = index.html 의 브랜드 고유 id(B 배열). 캘린더 이벤트에 bid 로 기록되어
# 앱에서 클릭 시 openM(bid) 로 해당 브랜드 상세 모달을 띄우는 데 쓰인다.
BRANDS_GROUPS = {
    0: [
        {"name": "ROJITA",      "id": 8,  "ig": "rojita__official",       "tw": "ROJITA__jp",      "color": "#C41055", "emoji": "🖤"},
        {"name": "Ank Rouge",   "id": 2,  "ig": "ankrouge_official",      "tw": "AnkRouge",         "color": "#C41055", "emoji": "🎀"},
        {"name": "LIZ LISA",    "id": 1,  "ig": "lizlisa_official_japan", "tw": "lizlisaofficial",  "color": "#C41055", "emoji": "🌸"},
    ],
    1: [
        {"name": "Secret Honey",    "id": 4,  "ig": "secrethoney_official", "tw": "SecretHoney_HB", "color": "#C41055", "emoji": "🐰"},
        {"name": "pium",            "id": 14, "ig": "piumofficial",          "tw": "pium__official",  "color": "#AA7020", "emoji": "🌸"},
        {"name": "Honey Cinnamon",  "id": 3,  "ig": "honey_cinnamon_jp",     "tw": "honeyc0214",      "color": "#C41055", "emoji": "🍯"},
        {"name": "michellMacaron",  "id": 60, "ig": "michellmacaron_official","tw": "michellMacar0n",  "color": "#C41055", "emoji": "🧁"},
    ],
    2: [
        {"name": "NOEMIE",      "id": 9,  "ig": "noemie_official_",    "tw": "Noemie_shop",       "color": "#C41055", "emoji": "🩷"},
        {"name": "MA*RS",       "id": 11, "ig": "marsofficialjapan",   "tw": "mars_amoebamars",   "color": "#C41055", "emoji": "♦️"},
        {"name": "DearMyLove",  "id": 13, "ig": "dearmylove_official", "tw": "dearmylove_yume",   "color": "#C41055", "emoji": "💕"},
        {"name": "DimMoire",    "id": 19, "ig": "dimmoire_official",    "tw": "_DimMoire_",         "color": "#7733BB", "emoji": "🌑"},
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


def fetch_instagram_direct(handle: str, limit: int = 5) -> list[str]:
    """IG 공식 web_profile_info API 직접 호출(Apify 불필요).
    curl_cffi 의 브라우저 TLS 지문이 필수 — 표준 urllib 는 429 로 차단됨(실측).
    ⚠️ GitHub Actions 데이터센터 IP 는 IG 가 더 자주 차단하므로 best-effort
       (실패 시 호출부가 Apify 스크래퍼로 폴백)."""
    if cffi_requests is None:
        return []
    headers = {"x-ig-app-id": IG_APP_ID, "User-Agent": IG_UA}
    if IG_COOKIE:
        headers["Cookie"] = f"sessionid={IG_COOKIE}"
    try:
        resp = cffi_requests.get(
            f"https://i.instagram.com/api/v1/users/web_profile_info/?username={handle}",
            impersonate="safari", headers=headers, timeout=20,
        )
        if resp.status_code != 200:
            print(f"    IG 직접 API 비200 ({handle}): {resp.status_code}")
            return []
        user = resp.json()["data"]["user"]
        edges = user["edge_owner_to_timeline_media"]["edges"][:limit]
        out = []
        for e in edges:
            cap = e["node"]["edge_media_to_caption"]["edges"]
            txt = cap[0]["node"]["text"] if cap else ""
            if txt:
                out.append(txt)
        return out
    except Exception as e:
        print(f"    IG 직접 API 오류 ({handle}): {_short(e)}")
        return []


def fetch_instagram(apify: "ApifyClient | None", handle: str) -> list[str]:
    # 1순위: IG 공식 web_profile_info 직접 API (Apify 불필요·무비용)
    posts = fetch_instagram_direct(handle)
    if posts:
        print(f"    IG 직접 API 성공 ({handle}): {len(posts)}개")
        return posts
    # 2순위: Apify 인스타 스크래퍼 폴백 (직접 API 차단/공백 시 — 잔여 프록시 사용)
    if apify is None:
        return []
    try:
        run = apify.actor(ACTOR_IG).call(run_input={
            "directUrls": [f"https://www.instagram.com/{handle}/"],
            "resultsLimit": 5,
            "cookies": [{"name": "sessionid", "value": IG_COOKIE}] if IG_COOKIE else [],
        })
        out = [
            item.get("caption") or item.get("text") or ""
            for item in apify.dataset(run.default_dataset_id).iterate_items()
        ]
        print(f"    IG Apify 폴백 ({handle}): {len(out)}개")
        return out
    except Exception as e:
        print(f"    IG 오류 ({handle}): {e}")
        return []


def fetch_twitter(apify: ApifyClient, handle: str) -> list[str]:
    # apidojo/tweet-scraper 입력 스키마: twitterHandles(@ 없는 핸들 배열) / maxItems / sort.
    # (이 액터는 자체 프록시·인증을 써서 TW_COOKIE 불필요)
    try:
        run = apify.actor(ACTOR_TW).call(run_input={
            # twitterHandles 만 주면 '검색어'가 없어 noResults 가 반환된다(진단으로 확인).
            # 액터 문서상 계정별 트윗은 'from:핸들' searchTerms 로 직접 검색해야 한다.
            "searchTerms": [f"from:{handle.lstrip('@')}"],
            "maxItems": 5,
            "sort": "Latest",
        })
        items = list(apify.dataset(run.default_dataset_id).iterate_items())
        # 진단: 이 액터의 출력 필드명이 버전마다 달라(text/fullText/rawContent…) 본문이
        # 빈 문자열로 잡혀 트위터 이벤트가 0개가 되는 문제를 잡기 위해 첫 아이템 키를 1회 출력.
        if items:
            print(f"    TW 진단 키: {list(items[0].keys())[:14]}")
        out = []
        for item in items:
            # 여러 후보 필드명을 순서대로 시도(액터 스키마 불일치 방어)
            txt = (item.get("text") or item.get("fullText") or item.get("full_text")
                   or item.get("rawContent") or item.get("content") or item.get("tweetText") or "")
            if txt and not str(txt).startswith("RT "):
                out.append(str(txt))
        return out
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
                "dt":  date,
                "tm":  tm,
                "bid": b["id"],
                "br":  b["name"],
                "d":   tmpl.format(e=b["emoji"]),
                "c":   b["color"],
                "e":   b["emoji"],
                "tp":  tp,
                "seed": True,                        # 실제 수집 시 교체될 데모 데이터 표시
            })
            k += 1
    return out


_SRC_RANK = {"x": 3, "twitter": 3, "tw": 3, "instagram": 2, "ig": 2, "web": 1, "home": 1, "official": 1}


def _src_rank(s: str) -> int:
    return _SRC_RANK.get(str(s or "").lower(), 0)


def _norm_news(s: str) -> str:
    """내용 비교용 정규화: 영숫자/한글/일문 외 문자(이모지·공백·기호) 제거 + 소문자."""
    return re.sub(r"[^\w가-힣ぁ-んァ-ン一-龥]", "", str(s or "")).lower()


def dedup_events(events: list[dict]) -> list[dict]:
    """같은 브랜드(bid)·날짜(dt)·내용(d 정규화)이면 중복으로 보고 한 건만 남긴다.
    소스 우선순위 X(tw) > IG > 공식홈/기타 순으로 보존."""
    best: dict[tuple, dict] = {}
    for e in events:
        key = (e.get("bid"), e.get("dt"), _norm_news(e.get("d")))
        prev = best.get(key)
        if prev is None or _src_rank(e.get("src")) > _src_rank(prev.get("src")):
            best[key] = e
    return list(best.values())


_CONSOLIDATE_PROMPT = """당신은 일본 서브컬처 패션 브랜드의 캘린더 일정을 정리하는 편집자입니다.
아래는 같은 브랜드의 같은 날짜({date})에 모인 여러 일정 문구입니다.
'확실하게 같은 이벤트'를 가리키는 문구들만 하나로 묶고, 각 묶음의 모든 정보(시간·채널·혜택·매장/웹 구분 등)를 빠짐없이 종합해 한 줄로 정리하세요.

⛔ 가장 중요한 규칙 — 보수적으로 통합:
- 동일 이벤트라고 100% 확신할 때만 합친다 (예: 같은 컬렉션·같은 상품의 발매를 표현만 다르게 쓴 경우)
- 조금이라도 다른 상품/다른 라인/다른 행사일 가능성이 있으면 절대 합치지 말고 그대로 분리 유지
- 한쪽이 '신상 공개' 처럼 막연해서 어떤 상품인지 특정 안 되면 합치지 말 것 (확신 불가 → 분리)
- 애매하면 무조건 분리. '혹시 같을 수도' 정도로는 합치지 않는다

통합 규칙:
- 각 설명은 50자 이내, 한국 SNS 감성의 자연스러운 한국어 (직역 금지)
- 통합 시 흩어진 정보를 합칠 것 (예: '웹 드롭' + '20시' + '매장은 다음날' → 한 문장에)
- 입력 문구의 원래 의미를 바꾸거나 없는 정보를 지어내지 말 것

입력 일정:
{items}

응답은 JSON 한 줄만 (다른 텍스트 없이):
{{"events": ["설명1", "설명2", ...]}}
확실히 같은 이벤트가 없으면 입력 문구를 그대로(다듬어서) 모두 담으세요 — 임의로 줄이지 말 것."""


def _ai_merge_group(client: "genai.Client", brand: str, date: str, descs: list[str]) -> list[str] | None:
    """같은 브랜드·날짜의 설명 묶음을 Gemini 로 의미 기반 통합.
    반환: 통합된 설명 문자열 리스트, 실패 시 None(호출부는 원본 유지)."""
    items = "\n".join(f"{i+1}. {d}" for i, d in enumerate(descs))
    prompt = _CONSOLIDATE_PROMPT.format(date=date, items=items)
    try:
        resp = client.models.generate_content(model=MODEL_CHAIN[0], contents=f"브랜드: {brand}\n\n{prompt}")
        raw = (resp.text or "").strip()
        if raw.startswith("```"):
            parts = raw.split("```")
            raw = parts[1].lstrip("json").strip() if len(parts) > 1 else raw
        data = json.loads(raw)
        merged = [str(s).strip() for s in data.get("events", []) if str(s).strip()]
        return merged or None
    except Exception as e:
        print(f"    ⚠️ AI 통합 실패({brand} {date}): {_short(e)} → 원본 유지")
        return None


def consolidate_events(events: list[dict], gemini: "genai.Client | None") -> list[dict]:
    """같은 브랜드(bid)·날짜(dt) 그룹 안에서 표현만 다른 '같은 이벤트'를 AI 로 묶어
    정보를 종합한 한 건으로 통합한다. Gemini 가 없으면 원본 그대로(파괴적 변경 회피)."""
    if gemini is None:
        return events
    groups: dict[tuple, list[dict]] = {}
    out: list[dict] = []
    for e in events:
        if e.get("bid") is not None and e.get("dt"):
            groups.setdefault((e["bid"], e["dt"]), []).append(e)
        else:
            out.append(e)
    for (bid, dt), grp in groups.items():
        if len(grp) <= 1:
            out.extend(grp)
            continue
        base = max(grp, key=lambda x: _src_rank(x.get("src")))   # 메타·소스는 최우선 소스 기준
        merged = _ai_merge_group(gemini, base.get("br", ""), dt, [e.get("d", "") for e in grp])
        if not merged:
            out.extend(grp)   # 통합 실패 → 원본 보존
            continue
        if len(merged) < len(grp):
            print(f"    🔗 {base.get('br')} {dt}: {len(grp)}건 → {len(merged)}건 통합")
        for desc in merged:
            out.append({**base, "d": desc})
    return out


def main():
    today = datetime.now(KST)
    apify = ApifyClient(APIFY_TOKEN) if (APIFY_TOKEN and ApifyClient) else None
    gemini = genai.Client(api_key=GEMINI_API_KEY) if (GEMINI_API_KEY and genai) else None

    # 수집 수단이 전혀 없을 때만(Apify 도 없고 IG 직접 API 도 불가) 데모 시드로 채우고 종료.
    # curl_cffi 가 있으면 APIFY_TOKEN 없이도 IG 직접 API 로 실데이터를 수집한다.
    if not apify and cffi_requests is None:
        events = build_seed_schedule(today)
        OUT_PATH.write_text(json.dumps(events, ensure_ascii=False, indent=2), encoding="utf-8")
        print(f"⚠️ 수집 수단 없음(Apify·curl_cffi 모두 부재) → 데모 시드 {len(events)}개 생성")
        return
    if not apify:
        print("ℹ️ APIFY_TOKEN 없음 → IG 직접 API 단독 수집 모드 (트위터·Apify 폴백 비활성)")

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
        # (text, src) 튜플로 수집 — src 는 중복제거 시 우선순위(X>IG>공홈)에 사용
        texts: list[tuple[str, str]] = []

        # IG 는 직접 API(Apify 불필요)라 apify 유무와 무관하게 수집 시도
        if brand["ig"]:
            ig_posts = fetch_instagram(apify, brand["ig"])
            print(f"  IG {len(ig_posts)}개 수집")
            texts.extend((t, "ig") for t in ig_posts)
        # 트위터는 Apify 액터 의존(직접 경로 429) → apify 있을 때만
        if apify and brand["tw"]:
            tw_posts = fetch_twitter(apify, brand["tw"])
            print(f"  TW {len(tw_posts)}개 수집")
            texts.extend((t, "tw") for t in tw_posts)

        if not texts:
            print("  수집 없음")
            continue

        for i, (text, src) in enumerate(texts):
            if not text or not text.strip():
                continue

            result = None
            if analyzer and not analyzer.disabled:
                result, _ok = analyzer.analyze(brand["name"], text, today)
                time.sleep(0.3)

            if result:
                print(f"  ✅ [{result['date']}] ({src}) {result['description']}")
                events.append({
                    "dt":  result["date"],
                    "bid": brand["id"],
                    "br":  brand["name"],
                    "d":   result["description"],
                    "c":   brand["color"],
                    "e":   brand["emoji"],
                    "src": src,
                })
            elif analyzer is None or analyzer.disabled:
                # LLM 없음/실패 폴백: 키워드 필터 (일본어·한국어 이벤트 키워드)
                triggers = ["発売", "新作", "ドロップ", "drop", "예약", "팝업", "수주", "발매",
                            "セール", "sale", "限定", "予約", "popup", "pop up", "コラボ", "입고"]
                if any(t.lower() in text.lower() for t in triggers):
                    events.append({
                        "dt":  (today + timedelta(days=7)).strftime("%Y-%m-%d"),
                        "bid": brand["id"],
                        "br":  brand["name"],
                        "d":   text[:50].strip(),
                        "c":   brand["color"],
                        "e":   brand["emoji"],
                        "src": src,
                    })
            else:
                print(f"  ⏭ 게시물 {i+1}: 이벤트 없음")

        time.sleep(10)

    # 7일 이상 지난 이벤트 제거
    cutoff = (today - timedelta(days=7)).strftime("%Y-%m-%d")
    events = [e for e in events if e.get("dt", "") >= cutoff]

    # 중복 소식 제거: 같은 브랜드·날짜·내용이면 한 건만, 소스 우선순위 X(tw)>IG>공홈 보존
    events = dedup_events(events)

    # AI 의미 기반 통합: 표현만 다른 '같은 이벤트'(예: pium 웹 드롭/오텀 컬렉션/20시…)를
    # 같은 브랜드·날짜 안에서 묶어 정보를 종합한 한 건으로 합친다. dedup 으로 못 잡는 케이스 처리.
    events = consolidate_events(events, gemini)
    events = dedup_events(events)   # 통합 결과 중 완전 동일 설명이 생기면 한 번 더 정리

    # 날짜 오름차순 정렬
    events.sort(key=lambda x: x.get("dt", "9999-12-31"))

    OUT_PATH.write_text(json.dumps(events, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"\n✅ 완료: {len(events)}개 이벤트 저장")


if __name__ == "__main__":
    main()
