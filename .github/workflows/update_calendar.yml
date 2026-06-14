"""
KAIWAI 캘린더 자동 수집기 — update_calendar.py
=====================================================
전략:
  1순위 Instagram  → instaloader (무료, 로그인 불필요, 공개 계정)
  2순위 X(Twitter) → Nitter RSS  (무료, API Key 불필요, 여러 인스턴스 폴백)
  3순위 Apify API  → APIFY_TOKEN 환경변수 설정 시 활성화

실행:  python update_calendar.py
결과:  calendar_data.json (index.html과 같은 디렉토리에 저장)
"""

import json
import os
import re
import time
import xml.etree.ElementTree as ET
from datetime import datetime, timedelta

import requests

# ─────────────────────────────────────────────────────────
# 브랜드 마스터 데이터 (CSV 기반)
# 각 브랜드의 instagram_id, x_id, 카테고리 색상 정의
# ─────────────────────────────────────────────────────────
BRANDS = [
    # brand_name,                     instagram_id,                x_id,              color,      emoji
    ("LIZ LISA",                     "lizlisa_official_japan",    "lizlisaofficial",  "#C41055",  "🌸"),
    ("Ank Rouge",                    "ankrouge_official",         "AnkRouge",         "#C41055",  "🎀"),
    ("Honey Cinnamon",               "",                          "honeyc0214",       "#C41055",  "🍯"),
    ("Secret Honey",                 "",                          "SecretHoney_HB",   "#C41055",  "🐰"),
    ("evelyn",                       "evelyn.official",           "evelyn_tokyo",     "#C41055",  "🌼"),
    ("Swankiss",                     "",                          "Swankiss",         "#C41055",  "💗"),
    ("ROJITA",                       "rojita__official",          "ROJITA__jp",       "#C41055",  "🖤"),
    ("NOEMIE",                       "noemie_official_",          "Noemie_shop",      "#C41055",  "🩷"),
    ("Jamie エーエヌケー",            "jamieank_official",         "Jamie_ank",        "#C41055",  "🎀"),
    ("MA*RS",                        "marsofficialjapan",         "mars_amoebamars",  "#C41055",  "♦️"),
    ("EATME",                        "eatme_japan",               "EATME_tweet",      "#C41055",  "🌹"),
    ("DearMyLove",                   "dearmylove_official",       "dearmylove_yume",  "#C41055",  "💕"),
    ("pium",                         "",                          "pium__official",   "#AA7020",  "🌸"),
    ("SNIDEL",                       "snidel_official",           "snidelOfficial",   "#AA7020",  "🌿"),
    ("titty&Co.",                    "tittyandco_com",            "tittyandco_",      "#AA7020",  "🤎"),
    ("GRL",                          "grl_official",              "GRL_official",     "#AA7020",  "🌾"),
    ("DimMoire",                     "",                          "_DimMoire_",       "#7733BB",  "🌑"),
    ("Amilige",                      "amilige_official",          "",                 "#7733BB",  "🖤"),
    ("KRY clothing",                 "kry231",                    "KRY_official_",    "#7733BB",  "🖤"),
    ("REFLEM",                       "",                          "_REFLEM",          "#7733BB",  "⚡"),
    ("TRAVAS TOKYO",                 "travas_tokyo",              "travas_tokyo",     "#7733BB",  "🎮"),
    ("ililil",                       "",                          "",                 "#E05C00",  "💙"),
    ("anonenone",                    "",                          "anonenone_jp",     "#E05C00",  "👼"),
    ("ACDC RAG",                     "acdcrag_harajuku",          "acdcrag",          "#E05C00",  "⚡"),
    ("LISTEN FLAVOR",                "listenflavor_official",     "listenflavor",     "#E05C00",  "🎨"),
    ("NieR Clothing",                "",                          "NieR_tokyo",       "#E05C00",  "🌀"),
    ("HEIHEI",                       "",                          "heihei_official",  "#E05C00",  "🖤"),
    ("BABY THE STARS SHINE BRIGHT",  "babythessbofficial",        "BABY_THE_STARS",   "#BB22CC",  "🌹"),
    ("Angelic Pretty",               "angelicpretty_official",    "",                 "#BB22CC",  "💜"),
    ("Moi-même-Moitié",              "",                          "moitie_official",  "#BB22CC",  "🌙"),
    ("Alice and the Pirates",        "alice_and_the_pirates",     "",                 "#BB22CC",  "🏴‍☠️"),
    ("Atelier Pierrot",              "",                          "atelier_pierrot",  "#BB22CC",  "🌸"),
    ("Amavel",                       "amavel_official",           "_amavel_",         "#BB22CC",  "👑"),
    ("To Alice",                     "toalicejapan",              "toalicejapan",     "#BB22CC",  "🐇"),
    ("BUBBLES",                      "bubbles_tokyo",             "bubbles_tokyo",    "#009966",  "👟"),
    ("Maison de FLEUR",              "maisondefleur_press",       "Maison_de_FLEUR",  "#009966",  "👜"),
    ("Samantha Vega",                "samantha.vega_official",    "samantha_PR_ST",   "#009966",  "💎"),
    ("Vivienne Westwood",            "",                          "VW_JAPAN",         "#009966",  "✨"),
    ("Lafary",                       "lafary_jp",                 "lafary_jp",        "#009966",  "🎀"),
]

# ─────────────────────────────────────────────────────────
# 이벤트 감지 키워드
# ─────────────────────────────────────────────────────────
TYPE_KEYWORDS = {
    "팝업": ["pop-up", "popup", "pop up", "ポップアップ", "팝업", "期間限定ショップ"],
    "수주": ["受注", "受注受付", "pre-order", "수주", "予約受付", "order open"],
    "예약": ["予約開始", "予約受付", "사전예약", "reservation", "先行予約"],
    "신상": ["新作", "新商品", "新発売", "発売", "DROP", "drop", "新入荷",
             "release", "launch", "debut", "신상", "新コレクション", "collection"],
}

EVENT_TRIGGERS = [
    "発売", "新作", "新商品", "drop", "release", "launch", "pop",
    "受注", "予約", "debut", "期間限定", "팝업", "신상", "수주", "예약",
    "新入荷", "コレクション", "collection", "collaboration", "collab",
    "新色", "再入荷", "restock", "restocked",
]

# Nitter 공개 인스턴스 목록 (차단 시 순서대로 폴백)
NITTER_INSTANCES = [
    "https://nitter.privacydev.net",
    "https://nitter.poast.org",
    "https://nitter.unixfox.eu",
    "https://nitter.kavin.rocks",
]


# ─────────────────────────────────────────────────────────
# 날짜 파싱
# ─────────────────────────────────────────────────────────
def parse_date(text: str) -> str:
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
    # 날짜를 찾지 못하면 7일 후로 설정
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
    text = re.sub(r"https?://\S+", "", text)     # URL 제거
    text = re.sub(r"#\S+", "", text)             # 해시태그 제거
    text = re.sub(r"@\S+", "", text)             # 멘션 제거
    text = re.sub(r"\s+", " ", text).strip()
    return (text[:max_len] + "…") if len(text) > max_len else text


# ─────────────────────────────────────────────────────────
# 1순위: Instagram → instaloader
# ─────────────────────────────────────────────────────────
def fetch_instagram(ig_handle: str, limit: int = 5) -> list[str]:
    """
    instaloader로 공개 계정 최근 게시물 캡션을 가져옵니다.
    로그인 불필요, 완전 무료.
    pip install instaloader
    """
    try:
        import instaloader
        L = instaloader.Instaloader(
            quiet=True,
            download_pictures=False,
            download_videos=False,
            download_video_thumbnails=False,
            download_geotags=False,
            download_comments=False,
            save_metadata=False,
        )
        profile = instaloader.Profile.from_username(L.context, ig_handle)
        posts = []
        for i, post in enumerate(profile.get_posts()):
            if i >= limit:
                break
            if post.caption:
                posts.append(post.caption)
        return posts
    except Exception as e:
        print(f"    instaloader 실패 ({ig_handle}): {e}")
        return []


# ─────────────────────────────────────────────────────────
# 2순위: X(Twitter) → Nitter RSS
# ─────────────────────────────────────────────────────────
def fetch_nitter_rss(x_handle: str, limit: int = 5) -> list[str]:
    """
    Nitter 공개 인스턴스 RSS 피드에서 최근 트윗 텍스트를 가져옵니다.
    API Key 불필요, 완전 무료. 인스턴스 다운 시 자동 폴백.
    """
    handle = x_handle.lstrip("@")
    for base in NITTER_INSTANCES:
        url = f"{base}/{handle}/rss"
        try:
            resp = requests.get(url, timeout=10, headers={
                "User-Agent": "Mozilla/5.0 (compatible; KAIWAIBot/1.0)"
            })
            if resp.status_code != 200:
                continue
            root = ET.fromstring(resp.content)
            ns = {"content": "http://purl.org/rss/1.0/modules/content/"}
            items = root.findall(".//item")[:limit]
            texts = []
            for item in items:
                # <title> 또는 <content:encoded> 에서 텍스트 추출
                title = item.findtext("title") or ""
                content_el = item.find("content:encoded", ns)
                content = content_el.text if content_el is not None else ""
                # HTML 태그 제거
                raw = re.sub(r"<[^>]+>", " ", content or title)
                texts.append(raw.strip())
            if texts:
                print(f"    Nitter OK ({base})")
                return texts
        except Exception as e:
            print(f"    Nitter 폴백 ({base}): {e}")
            time.sleep(1)
    return []


# ─────────────────────────────────────────────────────────
# 3순위: Apify (APIFY_TOKEN 환경변수 설정 시 활성화)
# ─────────────────────────────────────────────────────────
def fetch_apify_instagram(ig_handle: str, limit: int = 5) -> list[str]:
    token = os.environ.get("APIFY_TOKEN", "")
    if not token:
        return []
    url = "https://api.apify.com/v2/acts/apify~instagram-scraper/run-sync-get-dataset-items"
    try:
        resp = requests.post(
            url,
            json={
                "directUrls": [f"https://www.instagram.com/{ig_handle}/"],
                "resultsType": "posts",
                "resultsLimit": limit,
            },
            params={"token": token},
            timeout=120,
        )
        resp.raise_for_status()
        return [p.get("caption", "") for p in resp.json() if p.get("caption")]
    except Exception as e:
        print(f"    Apify 실패 ({ig_handle}): {e}")
        return []


# ─────────────────────────────────────────────────────────
# 게시물 → 이벤트 변환
# ─────────────────────────────────────────────────────────
def posts_to_events(texts: list[str], brand_name: str, color: str, emoji: str) -> list[dict]:
    events = []
    for text in texts:
        if not text or not is_event_post(text):
            continue
        dt   = parse_date(text)
        tp   = detect_type(text)
        desc = clean_desc(text)
        events.append({
            "dt": dt,
            "br": brand_name,
            "tp": tp,
            "d":  desc,
            "c":  color,
            "e":  emoji,
        })
    return events


# ─────────────────────────────────────────────────────────
# 메인
# ─────────────────────────────────────────────────────────
def main():
    cutoff = (datetime.now() - timedelta(days=45)).strftime("%Y-%m-%d")
    all_events: list[dict] = []
    seen: set[str] = set()

    for brand_name, ig_id, x_id, color, emoji in BRANDS:
        print(f"\n▶ {brand_name}")
        texts: list[str] = []

        # 1순위: Instagram (instaloader)
        if ig_id:
            print(f"  📷 Instagram @{ig_id}")
            texts = fetch_instagram(ig_id, limit=6)
            time.sleep(2)  # 인스타 요청 간격

        # 2순위: Nitter RSS (instaloader 실패 또는 ig 없을 때)
        if not texts and x_id:
            print(f"  𝕏  Nitter RSS @{x_id}")
            texts = fetch_nitter_rss(x_id, limit=6)
            time.sleep(1)

        # 3순위: Apify (환경변수 있을 때만)
        if not texts and ig_id:
            print(f"  🔄 Apify fallback @{ig_id}")
            texts = fetch_apify_instagram(ig_id, limit=5)

        events = posts_to_events(texts, brand_name, color, emoji)

        for ev in events:
            # 45일 이전 이벤트 제외
            if ev["dt"] < cutoff:
                ev["dt"] = (datetime.now() + timedelta(days=7)).strftime("%Y-%m-%d")
            key = f"{ev['dt']}-{ev['br']}"
            if key in seen:
                continue
            seen.add(key)
            all_events.append(ev)
            print(f"  ✅ [{ev['tp']}] {ev['dt']} — {ev['d'][:40]}")

    # 날짜순 정렬
    all_events.sort(key=lambda x: x["dt"])

    # 저장 경로: 스크립트와 같은 디렉토리의 상위(=index.html이 있는 곳)
    out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "calendar_data.json")
    with open(out, "w", encoding="utf-8") as f:
        json.dump(all_events, f, ensure_ascii=False, indent=2)

    print(f"\n✅ 저장 완료 → {out} ({len(all_events)}개 이벤트)")


if __name__ == "__main__":
    main()
