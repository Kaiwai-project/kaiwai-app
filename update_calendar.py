"""
KAIWAI 캘린더 자동 수집기 — update_calendar.py
=====================================================
【동작 구조】
  apify-client 라이브러리를 사용해 Apify의 공식 Actor를 호출합니다.
    - Instagram : apify/instagram-scraper
    - Twitter/X : apify/twitter-scraper

【무료 플랜 사용량 가이드】
  Apify 무료 플랜 = 월 $5 크레딧
  브랜드 39개 × 5포스트 수집 ≈ 1회 실행당 약 $0.15~0.30
  → 월 15~30회 실행 가능 (매일 자동 실행 시 약 절반 크레딧 사용)
  결과가 적을수록 비용이 낮아지므로 resultsLimit 을 조정하세요.

【사전 준비】
  1. https://apify.com 가입 (무료)
  2. Settings → Integrations → Personal API tokens → 복사
  3. GitHub → Settings → Secrets → Actions → New secret
     이름 : APIFY_TOKEN
     값   : apify_api_xxxx...
"""

import json
import os
import re
import sys
import time
from datetime import datetime, timedelta
from pathlib import Path

from apify_client import ApifyClient

# Windows 로컬 실행 시 cp949 인코딩 오류 방지
if sys.stdout.encoding and sys.stdout.encoding.lower() != "utf-8":
    sys.stdout.reconfigure(encoding="utf-8")

# ─────────────────────────────────────────────────────────
# 환경 변수
# ─────────────────────────────────────────────────────────
APIFY_TOKEN = os.environ.get("APIFY_TOKEN", "")
OUT_PATH    = Path(__file__).parent / "calendar_data.json"

# ─────────────────────────────────────────────────────────
# Apify Actor ID
# ─────────────────────────────────────────────────────────
ACTOR_IG = "apify/instagram-scraper"    # Instagram 게시물 수집
ACTOR_TW = "apify/twitter-scraper"      # Twitter/X 게시물 수집

# Actor 1회 실행당 최대 대기 시간 (초)
# 짧게 설정할수록 Hang 위험 감소, 단 수집량이 많으면 실패할 수 있음
ACTOR_TIMEOUT_SECS = 90

# ─────────────────────────────────────────────────────────
# 브랜드 마스터 데이터
# (brand_name, instagram_id, x_id, color, emoji)
# instagram_id 또는 x_id 중 하나만 있어도 수집 가능
# ─────────────────────────────────────────────────────────
BRANDS = [
    # brand_name                        ig_id                        x_id                color      emoji
    ("LIZ LISA",                       "lizlisa_official_japan",    "lizlisaofficial",  "#C41055", "🌸"),
    ("Ank Rouge",                      "ankrouge_official",         "AnkRouge",         "#C41055", "🎀"),
    ("Honey Cinnamon",                 "",                          "honeyc0214",       "#C41055", "🍯"),
    ("Secret Honey",                   "secrethoney_official",      "SecretHoney_HB",   "#C41055", "🐰"),
    ("evelyn",                         "evelyn.official",           "evelyn_tokyo",     "#C41055", "🌼"),
    ("Swankiss",                       "",                          "Swankiss",         "#C41055", "💗"),
    ("ROJITA",                         "rojita__official",          "ROJITA__jp",       "#C41055", "🖤"),
    ("NOEMIE",                         "noemie_official_",          "Noemie_shop",      "#C41055", "🩷"),
    ("Jamie エーエヌケー",              "jamieank_official",         "Jamie_ank",        "#C41055", "🎀"),
    ("MA*RS",                          "marsofficialjapan",         "mars_amoebamars",  "#C41055", "♦️"),
    ("EATME",                          "eatme_japan",               "EATME_tweet",      "#C41055", "🌹"),
    ("DearMyLove",                     "dearmylove_official",       "dearmylove_yume",  "#C41055", "💕"),
    ("pium",                           "",                          "pium__official",   "#AA7020", "🌸"),
    ("SNIDEL",                         "snidel_official",           "snidelOfficial",   "#AA7020", "🌿"),
    ("titty&Co.",                      "tittyandco_com",            "tittyandco_",      "#AA7020", "🤎"),
    ("GRL",                            "grl_official",              "GRL_official",     "#AA7020", "🌾"),
    ("DimMoire",                       "",                          "_DimMoire_",       "#7733BB", "🌑"),
    ("Amilige",                        "amilige_official",          "",                 "#7733BB", "🖤"),
    ("KRY clothing",                   "kry231",                    "KRY_official_",    "#7733BB", "🖤"),
    ("REFLEM",                         "",                          "_REFLEM",          "#7733BB", "⚡"),
    ("TRAVAS TOKYO",                   "travas_tokyo",              "travas_tokyo",     "#7733BB", "🎮"),
    ("ililil",                         "",                          "",                 "#E05C00", "💙"),
    ("anonenone",                      "",                          "anonenone_jp",     "#E05C00", "👼"),
    ("ACDC RAG",                       "acdcrag_harajuku",          "acdcrag",          "#E05C00", "⚡"),
    ("LISTEN FLAVOR",                  "listenflavor_official",     "listenflavor",     "#E05C00", "🎨"),
    ("NieR Clothing",                  "",                          "NieR_tokyo",       "#E05C00", "🌀"),
    ("HEIHEI",                         "",                          "heihei_official",  "#E05C00", "🖤"),
    ("BABY THE STARS SHINE BRIGHT",    "babythessbofficial",        "BABY_THE_STARS",   "#BB22CC", "🌹"),
    ("Angelic Pretty",                 "angelicpretty_official",    "",                 "#BB22CC", "💜"),
    ("Moi-même-Moitié",                "",                          "moitie_official",  "#BB22CC", "🌙"),
    ("Alice and the Pirates",          "alice_and_the_pirates",     "",                 "#BB22CC", "🏴‍☠️"),
    ("Atelier Pierrot",                "",                          "atelier_pierrot",  "#BB22CC", "🌸"),
    ("Amavel",                         "amavel_official",           "_amavel_",         "#BB22CC", "👑"),
    ("To Alice",                       "toalicejapan",              "toalicejapan",     "#BB22CC", "🐇"),
    ("BUBBLES",                        "bubbles_tokyo",             "bubbles_tokyo",    "#009966", "👟"),
    ("Maison de FLEUR",                "maisondefleur_press",       "Maison_de_FLEUR",  "#009966", "👜"),
    ("Samantha Vega",                  "samantha.vega_official",    "samantha_PR_ST",   "#009966", "💎"),
    ("Vivienne Westwood",              "",                          "VW_JAPAN",         "#009966", "✨"),
    ("Lafary",                         "lafary_jp",                 "lafary_jp",        "#009966", "🎀"),
]

# ─────────────────────────────────────────────────────────
# 이벤트 감지 키워드
# ─────────────────────────────────────────────────────────
TYPE_KEYWORDS = {
    "팝업": ["pop-up", "popup", "pop up", "ポップアップ", "팝업", "期間限定ショップ"],
    "수주": ["受注", "受注受付", "pre-order", "수주", "予約受付", "order open"],
    "예약": ["予約開始", "予約受付", "사전예약", "reservation", "先行予約"],
    "신상": ["新作", "新商品", "新発売", "発売", "DROP", "drop", "新入荷",
             "release", "launch", "debut", "신상", "collection", "コレクション"],
}

EVENT_TRIGGERS = [
    "発売", "新作", "新商品", "drop", "release", "launch", "pop",
    "受注", "予約", "debut", "期間限定", "팝업", "신상", "수주",
    "新入荷", "collection", "collaboration", "再入荷", "restock",
]


# ─────────────────────────────────────────────────────────
# 유틸 함수
# ─────────────────────────────────────────────────────────
def parse_date(text: str) -> str:
    """텍스트에서 날짜 추출. 없으면 7일 후 반환."""
    today = datetime.now()
    patterns = [
        (r'(\d{4})[./\-](\d{1,2})[./\-](\d{1,2})', "ymd"),
        (r'(\d{1,2})月(\d{1,2})日',                  "md_jp"),
        (r'(\d{1,2})/(\d{1,2})',                      "md_slash"),
    ]
    for pat, fmt in patterns:
        m = re.search(pat, text)
        if not m:
            continue
        try:
            g = m.groups()
            if fmt == "ymd":
                y, mo, d = int(g[0]), int(g[1]), int(g[2])
            else:
                mo, d = int(g[0]), int(g[1])
                y = today.year if mo >= today.month else today.year + 1
            return datetime(y, mo, d).strftime("%Y-%m-%d")
        except ValueError:
            continue
    return (today + timedelta(days=7)).strftime("%Y-%m-%d")


def detect_type(text: str) -> str:
    t = text.lower()
    for tp, keywords in TYPE_KEYWORDS.items():
        if any(k.lower() in t for k in keywords):
            return tp
    return "신상"


def is_event_post(text: str) -> bool:
    t = text.lower()
    return any(k.lower() in t for k in EVENT_TRIGGERS)


def clean_desc(text: str, max_len: int = 55) -> str:
    text = re.sub(r"https?://\S+", "", text)
    text = re.sub(r"#\S+", "", text)
    text = re.sub(r"@\S+", "", text)
    text = re.sub(r"\s+", " ", text).strip()
    return (text[:max_len] + "…") if len(text) > max_len else text


# ─────────────────────────────────────────────────────────
# Apify — Instagram 수집
# ─────────────────────────────────────────────────────────
def apify_instagram(client: ApifyClient, ig_handle: str, limit: int = 5) -> list[str]:
    """
    apify/instagram-scraper 로 공개 계정의 최근 게시물 캡션을 수집합니다.
    """
    try:
        # .call() 안에서 timeout_secs를 삭제하고 표준 설정만 남깁니다.
        run = client.actor(ACTOR_IG).call(
            run_input={
                "directUrls":   [f"https://www.instagram.com/{ig_handle}/"],
                "resultsType":  "posts",
                "resultsLimit": limit,
                "addParentData": False,
            }
        )
        
        # run 결과가 바로 딕셔너리로 나오는지 확인합니다.
        if not run or "defaultDatasetId" not in run:
            print(f"    ⚠️  Actor 실행 결과 없음 ({ig_handle})")
            return []

        captions = []
        # dataset ID를 사용하여 아이템을 가져옵니다.
        dataset_id = run["defaultDatasetId"]
        for item in client.dataset(dataset_id).iterate_items():
            cap = item.get("caption") or item.get("text") or ""
            if cap:
                captions.append(cap)
        return captions

    except Exception as e:
        print(f"    ⚠️  Instagram Actor 실패 ({ig_handle}): {type(e).__name__}: {str(e)[:80]}")
        return []


# ─────────────────────────────────────────────────────────
# Apify — Twitter/X 수집
# ─────────────────────────────────────────────────────────
def apify_twitter(client: ApifyClient, x_handle: str, limit: int = 5) -> list[str]:
    """
    apify/twitter-scraper 로 공개 계정의 최근 트윗을 수집합니다.
    https://apify.com/apify/twitter-scraper
    """
    handle = x_handle.lstrip("@")
    try:
        run = client.actor(ACTOR_TW).call(
            run_input={
                "startUrls": [{"url": f"https://twitter.com/{handle}"}],
                "maxItems":  limit,
                "addUserInfo": False,
            },
            timeout_secs=ACTOR_TIMEOUT_SECS,
        )
        if run is None:
            print(f"    ⚠️  Actor 실행 결과 없음 (@{handle})")
            return []

        texts = []
        for item in client.dataset(run["defaultDatasetId"]).iterate_items():
            # apify/twitter-scraper 필드명: full_text 또는 text
            txt = item.get("full_text") or item.get("text") or ""
            if txt and not txt.startswith("RT "):   # 리트윗 제외
                texts.append(txt)
        return texts

    except Exception as e:
        print(f"    ⚠️  Twitter Actor 실패 (@{handle}): {type(e).__name__}: {str(e)[:80]}")
        return []


# ─────────────────────────────────────────────────────────
# 게시물 텍스트 → 이벤트 딕셔너리
# ─────────────────────────────────────────────────────────
def posts_to_events(
    texts: list[str], brand_name: str, color: str, emoji: str
) -> list[dict]:
    events = []
    for text in texts:
        if not text or not is_event_post(text):
            continue
        events.append({
            "dt": parse_date(text),
            "br": brand_name,
            "tp": detect_type(text),
            "d":  clean_desc(text),
            "c":  color,
            "e":  emoji,
        })
    return events


# ─────────────────────────────────────────────────────────
# 기존 JSON 보존 & 병합
# ─────────────────────────────────────────────────────────
def load_existing() -> list[dict]:
    if OUT_PATH.exists():
        try:
            return json.loads(OUT_PATH.read_text(encoding="utf-8"))
        except Exception:
            pass
    return []


def merge_events(existing: list[dict], new_events: list[dict]) -> list[dict]:
    """
    새 이벤트를 기존 데이터에 병합합니다.
    - 오늘 이후 45일 이내의 기존 이벤트는 보존
    - 같은 (날짜+브랜드)가 있으면 새 데이터로 덮어씀
    """
    today         = datetime.now().strftime("%Y-%m-%d")
    cutoff_future = (datetime.now() + timedelta(days=45)).strftime("%Y-%m-%d")

    merged: dict[str, dict] = {
        f"{e['dt']}-{e['br']}": e
        for e in existing
        if today <= e["dt"] <= cutoff_future
    }
    for e in new_events:
        merged[f"{e['dt']}-{e['br']}"] = e

    return sorted(merged.values(), key=lambda x: x["dt"])


# ─────────────────────────────────────────────────────────
# 메인
# ─────────────────────────────────────────────────────────
def main():
    # ── 토큰 없으면 즉시 종료 ──────────────────────────────
    if not APIFY_TOKEN:
        print("=" * 55)
        print("⚠️  APIFY_TOKEN 환경변수가 설정되지 않았습니다.")
        print("   GitHub Secrets에 APIFY_TOKEN을 등록하세요.")
        print("   https://apify.com → Settings → API tokens")
        print("=" * 55)
        existing = load_existing()
        if existing:
            print(f"✅ 기존 calendar_data.json 유지 ({len(existing)}개 이벤트)")
        return

    # ── Apify 클라이언트 초기화 ────────────────────────────
    client = ApifyClient(APIFY_TOKEN)

    existing  = load_existing()
    all_new:  list[dict] = []
    seen:     set[str]   = set()
    fallback  = (datetime.now() + timedelta(days=7)).strftime("%Y-%m-%d")

    print(f"수집 시작 — 총 {len(BRANDS)}개 브랜드")
    print(f"Actor: {ACTOR_IG}  /  {ACTOR_TW}")
    print("-" * 55)

    for brand_name, ig_id, x_id, color, emoji in BRANDS:
        print(f"\n▶ {brand_name}")
        texts: list[str] = []

        # 1순위: Instagram
        if ig_id:
            print(f"  📷 apify/instagram-scraper  @{ig_id}")
            texts = apify_instagram(client, ig_id, limit=5)
            time.sleep(1)   # Actor 호출 간격

        # 2순위: Twitter/X (Instagram 수집 실패 또는 계정 없을 때)
        if not texts and x_id:
            print(f"  𝕏  apify/twitter-scraper     @{x_id}")
            texts = apify_twitter(client, x_id, limit=5)
            time.sleep(1)

        if not texts:
            print("  — 수집 데이터 없음")
            continue

        events = posts_to_events(texts, brand_name, color, emoji)
        for ev in events:
            # 어제 이전 날짜는 7일 후로 보정
            yesterday = (datetime.now() - timedelta(days=1)).strftime("%Y-%m-%d")
            if ev["dt"] < yesterday:
                ev["dt"] = fallback

            key = f"{ev['dt']}-{ev['br']}"
            if key in seen:
                continue
            seen.add(key)
            all_new.append(ev)
            print(f"  ✅ [{ev['tp']}] {ev['dt']} — {ev['d'][:40]}")

    # ── 기존 데이터와 병합 후 저장 ─────────────────────────
    final = merge_events(existing, all_new)

    OUT_PATH.write_text(
        json.dumps(final, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )

    print("\n" + "=" * 55)
    print(f"✅ 완료 — calendar_data.json 저장")
    print(f"   신규 수집 : {len(all_new)}개")
    print(f"   보존 포함 : {len(final)}개")
    print("=" * 55)


if __name__ == "__main__":
    main()
