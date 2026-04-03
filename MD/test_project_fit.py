# test_project_fit.py
# -*- coding: utf-8 -*-
"""
針對 AI 智慧眼鏡專案的實際用途，完整比較各 AI 服務的適合度。

測試項目：
  A. STT（語音辨識）
     A1. 現有方案：Google Cloud STT v1 串流（基準）
     A2. 新方案：  Google Cloud STT v2 Chirp_2 串流（us-central1）

  B. Gemini 文字生成（導航指令 + 場景描述）
     B1. 現有方案：AI Studio Flash（GEMINI_API_KEY，不吃試用金）
     B2. 新方案：  Vertex AI Flash（試用金）
     B3. 參考：    Vertex AI Pro（試用金，速度對比）

  C. TTS（語音合成）
     C1. 現有方案：Gemini TTS Preview（AI Studio，不吃試用金）
     C2. 新方案：  Google Cloud TTS WaveNet（試用金）

執行方式：
    uv run python MD/test_project_fit.py
"""

import os, sys, time, base64, json, struct, wave, threading, queue
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.stdout.reconfigure(encoding="utf-8")

from config import GOOGLE_CREDENTIALS_PATH, GEMINI_API_KEY

PASS = "[PASS]"
FAIL = "[FAIL]"
WARN = "[WARN]"
INFO = "[INFO]"

# ── 專案實際會用到的測試文字 ──────────────────────────────────────────────────
NAV_PROMPT   = "前方有一條斑馬線，請提示視障者如何安全通行，用一句話回覆。"
SCENE_PROMPT = "你是視障輔助AI助理。請用繁體中文、一句話（15字以內），告知視障者此畫面中，一般物件偵測可能漏掉的潛在危險或重要提示，只說危險/提示，若無危險請回覆「環境安全」。"
TTS_TEXT     = "前方有斑馬線，請直走通過，注意來車。"

# ── 從服務帳號 JSON 讀取 project_id ──────────────────────────────────────────
def get_project_id() -> str:
    try:
        with open(GOOGLE_CREDENTIALS_PATH, encoding="utf-8") as f:
            return json.load(f).get("project_id", "")
    except Exception:
        return ""

PROJECT_ID = get_project_id()

# ── 產生 1 秒中文語音的 PCM（用 TTS 生成，給 STT 辨識用）────────────────────
_TEST_PCM_16K: bytes = b""   # 16kHz PCM16（STT v1/v2 用）

def _prepare_test_audio() -> bool:
    """用 Cloud TTS 先合成一段中文語音，存為測試用 PCM"""
    global _TEST_PCM_16K
    try:
        os.environ["GOOGLE_APPLICATION_CREDENTIALS"] = GOOGLE_CREDENTIALS_PATH
        from google.cloud import texttospeech
        client = texttospeech.TextToSpeechClient()
        resp = client.synthesize_speech(
            input=texttospeech.SynthesisInput(text="哈囉，曼波，前方有斑馬線。"),
            voice=texttospeech.VoiceSelectionParams(
                language_code="cmn-TW", name="cmn-TW-Wavenet-A"),
            audio_config=texttospeech.AudioConfig(
                audio_encoding=texttospeech.AudioEncoding.LINEAR16,
                sample_rate_hertz=16000,
            ),
        )
        _TEST_PCM_16K = resp.audio_content
        print(f"  {INFO} 測試音訊準備完成（{len(_TEST_PCM_16K)} bytes，16kHz）")
        return True
    except Exception as e:
        print(f"  {WARN} 測試音訊準備失敗（後續 STT 測試會用靜音）：{e}")
        _TEST_PCM_16K = b"\x00\x00" * 16000  # 1 秒靜音備用
        return False

# ══════════════════════════════════════════════════════════════════════════════
# A1. STT v1 串流（現有方案，基準）
# ══════════════════════════════════════════════════════════════════════════════

def test_a1_stt_v1_streaming():
    print("\n[A1] Google STT v1 串流（現有方案，基準）")
    try:
        os.environ["GOOGLE_APPLICATION_CREDENTIALS"] = GOOGLE_CREDENTIALS_PATH
        from google.cloud import speech as _speech

        t_init = time.time()
        client = _speech.SpeechClient()
        elapsed_init = time.time() - t_init

        config = _speech.RecognitionConfig(
            encoding=_speech.RecognitionConfig.AudioEncoding.LINEAR16,
            sample_rate_hertz=16000,
            language_code="zh-TW",
            alternative_language_codes=["zh-CN"],
            enable_automatic_punctuation=True,
        )
        streaming_config = _speech.StreamingRecognitionConfig(
            config=config, interim_results=True
        )

        # 模擬串流：把 PCM 切成 100ms 小塊送入
        chunk_size = 16000 * 2 // 10  # 100ms 的 bytes
        audio_data = _TEST_PCM_16K or (b"\x00\x00" * 16000)

        def _gen():
            for i in range(0, len(audio_data), chunk_size):
                yield _speech.StreamingRecognizeRequest(
                    audio_content=audio_data[i:i + chunk_size]
                )

        t0 = time.time()
        first_result = None
        for resp in client.streaming_recognize(streaming_config, _gen()):
            for result in resp.results:
                if result.alternatives:
                    transcript = result.alternatives[0].transcript.strip()
                    if transcript and first_result is None:
                        first_result = transcript
                        elapsed_first = time.time() - t0
        elapsed_total = time.time() - t0

        print(f"  {PASS} 初始化：{elapsed_init:.2f}s，首字：{elapsed_first if first_result else 'N/A'}s，總計：{elapsed_total:.2f}s")
        print(f"  辨識結果：{first_result or '（靜音無結果）'}")
        return {"ok": True, "init": elapsed_init, "total": elapsed_total, "result": first_result}
    except Exception as e:
        print(f"  {FAIL} {e}")
        return {"ok": False}

# ══════════════════════════════════════════════════════════════════════════════
# A2. STT v2 Chirp_2 串流（新方案）
# ══════════════════════════════════════════════════════════════════════════════

def test_a2_stt_v2_chirp2_streaming():
    print("\n[A2] Google STT v2 Chirp_2 串流（新方案）")
    try:
        os.environ["GOOGLE_APPLICATION_CREDENTIALS"] = GOOGLE_CREDENTIALS_PATH
        from google.api_core.client_options import ClientOptions
        from google.cloud.speech_v2 import SpeechClient
        from google.cloud.speech_v2.types import cloud_speech

        LOCATION = "us-central1"
        ENDPOINT = "us-central1-speech.googleapis.com"

        t_init = time.time()
        client = SpeechClient(
            client_options=ClientOptions(api_endpoint=ENDPOINT)
        )
        elapsed_init = time.time() - t_init

        # 串流設定
        streaming_config = cloud_speech.StreamingRecognitionConfig(
            config=cloud_speech.RecognitionConfig(
                explicit_decoding_config=cloud_speech.ExplicitDecodingConfig(
                    encoding=cloud_speech.ExplicitDecodingConfig.AudioEncoding.LINEAR16,
                    sample_rate_hertz=16000,
                    audio_channel_count=1,
                ),
                language_codes=["cmn-Hant-TW"],
                model="chirp_2",
            ),
            streaming_features=cloud_speech.StreamingRecognitionFeatures(
                interim_results=True,
            ),
        )

        recognizer = f"projects/{PROJECT_ID}/locations/{LOCATION}/recognizers/_"
        audio_data = _TEST_PCM_16K or (b"\x00\x00" * 16000)
        chunk_size = 16000 * 2 // 10  # 100ms 小塊

        def _gen():
            # 第一個請求必須帶設定
            yield cloud_speech.StreamingRecognizeRequest(
                recognizer=recognizer,
                streaming_config=streaming_config,
            )
            for i in range(0, len(audio_data), chunk_size):
                yield cloud_speech.StreamingRecognizeRequest(
                    audio=audio_data[i:i + chunk_size]
                )

        t0 = time.time()
        first_result = None
        elapsed_first = None
        for resp in client.streaming_recognize(requests=_gen()):
            for result in resp.results:
                if result.alternatives:
                    transcript = result.alternatives[0].transcript.strip()
                    if transcript and first_result is None:
                        first_result = transcript
                        elapsed_first = time.time() - t0
        elapsed_total = time.time() - t0

        print(f"  {PASS} 初始化：{elapsed_init:.2f}s，首字：{elapsed_first or 'N/A'}s，總計：{elapsed_total:.2f}s")
        print(f"  辨識結果：{first_result or '（靜音無結果）'}")
        return {"ok": True, "init": elapsed_init, "total": elapsed_total, "result": first_result}
    except Exception as e:
        err = str(e)
        if "permission" in err.lower() or "403" in err:
            print(f"  {WARN} 權限不足（需在 IAM 新增 roles/speech.client）：{err[:200]}")
        else:
            print(f"  {FAIL} {err[:200]}")
        return {"ok": False, "error": err[:200]}

# ══════════════════════════════════════════════════════════════════════════════
# B1. Gemini Flash — AI Studio（現有方案，基準）
# ══════════════════════════════════════════════════════════════════════════════

def test_b1_gemini_flash_aistudio():
    print("\n[B1] Gemini Flash — AI Studio（現有方案，基準，不吃試用金）")
    import urllib.request, urllib.error
    if not GEMINI_API_KEY:
        print(f"  {WARN} 未設定 GEMINI_API_KEY，跳過")
        return {"ok": False}
    try:
        url = f"https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key={GEMINI_API_KEY}"
        payload = json.dumps({"contents": [{"parts": [{"text": NAV_PROMPT}]}]}).encode()

        t0 = time.time()
        req = urllib.request.Request(url, data=payload,
                                     headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=30) as resp:
            result = json.load(resp)
        elapsed = time.time() - t0

        text = result["candidates"][0]["content"]["parts"][0]["text"].strip()
        print(f"  {PASS} 回應：{elapsed:.2f}s")
        print(f"  內容：{text[:100]}")
        return {"ok": True, "elapsed": elapsed, "text": text}
    except Exception as e:
        print(f"  {FAIL} {e}")
        return {"ok": False}

# ══════════════════════════════════════════════════════════════════════════════
# B2. Gemini Flash — Vertex AI（新方案，試用金）
# ══════════════════════════════════════════════════════════════════════════════

def test_b2_gemini_flash_vertex():
    print("\n[B2] Gemini Flash — Vertex AI（新方案，試用金）")
    try:
        os.environ["GOOGLE_APPLICATION_CREDENTIALS"] = GOOGLE_CREDENTIALS_PATH
        from google import genai

        client = genai.Client(vertexai=True, project=PROJECT_ID, location="us-central1")

        t0 = time.time()
        response = client.models.generate_content(
            model="gemini-2.5-flash",
            contents=NAV_PROMPT,
        )
        elapsed = time.time() - t0

        text = response.text.strip()
        print(f"  {PASS} 回應：{elapsed:.2f}s")
        print(f"  內容：{text[:100]}")
        return {"ok": True, "elapsed": elapsed, "text": text}
    except Exception as e:
        print(f"  {FAIL} {e}")
        return {"ok": False}

# ══════════════════════════════════════════════════════════════════════════════
# B3. Gemini Flash 串流 — Vertex AI（模擬 omni_client 串流模式）
# ══════════════════════════════════════════════════════════════════════════════

def test_b3_gemini_flash_vertex_stream():
    print("\n[B3] Gemini Flash 串流 — Vertex AI（模擬實際串流，試用金）")
    try:
        os.environ["GOOGLE_APPLICATION_CREDENTIALS"] = GOOGLE_CREDENTIALS_PATH
        from google import genai

        client = genai.Client(vertexai=True, project=PROJECT_ID, location="us-central1")

        t0 = time.time()
        first_chunk_time = None
        full_text = ""

        for chunk in client.models.generate_content_stream(
            model="gemini-2.5-flash",
            contents=NAV_PROMPT,
        ):
            if chunk.text and first_chunk_time is None:
                first_chunk_time = time.time() - t0
            if chunk.text:
                full_text += chunk.text

        elapsed_total = time.time() - t0
        print(f"  {PASS} 首 chunk：{first_chunk_time:.2f}s，總計：{elapsed_total:.2f}s")
        print(f"  內容：{full_text.strip()[:100]}")
        return {"ok": True, "first_chunk": first_chunk_time, "total": elapsed_total}
    except Exception as e:
        print(f"  {FAIL} {e}")
        return {"ok": False}

# ══════════════════════════════════════════════════════════════════════════════
# B4. Gemini Flash 場景描述 + 圖片 — Vertex AI（模擬 gemini_scene_describer）
# ══════════════════════════════════════════════════════════════════════════════

def test_b4_gemini_scene_vertex():
    print("\n[B4] Gemini Flash 場景描述（含圖片）— Vertex AI")
    try:
        os.environ["GOOGLE_APPLICATION_CREDENTIALS"] = GOOGLE_CREDENTIALS_PATH
        from google import genai
        from google.genai import types
        import numpy as np
        import cv2

        # 產生一張模擬街道場景的測試圖（灰色漸層 320x240）
        img = np.zeros((240, 320, 3), dtype=np.uint8)
        cv2.putText(img, "zebra crossing ahead", (30, 120),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.7, (200, 200, 200), 2)
        _, buf = cv2.imencode(".jpg", img, [cv2.IMWRITE_JPEG_QUALITY, 60])
        b64 = base64.b64encode(buf.tobytes()).decode()

        client = genai.Client(vertexai=True, project=PROJECT_ID, location="us-central1")

        t0 = time.time()
        response = client.models.generate_content(
            model="gemini-2.5-flash",
            contents=[
                types.Part.from_bytes(
                    data=base64.b64decode(b64),
                    mime_type="image/jpeg",
                ),
                types.Part.from_text(text=SCENE_PROMPT),
            ],
        )
        elapsed = time.time() - t0

        text = response.text.strip()
        print(f"  {PASS} 回應：{elapsed:.2f}s")
        print(f"  內容：{text[:100]}")
        return {"ok": True, "elapsed": elapsed}
    except Exception as e:
        print(f"  {FAIL} {e}")
        return {"ok": False}

# ══════════════════════════════════════════════════════════════════════════════
# B1-scene. Gemini Flash 場景描述 + 圖片 — AI Studio（現有方案對比）
# ══════════════════════════════════════════════════════════════════════════════

def test_b1s_gemini_scene_aistudio():
    print("\n[B1s] Gemini Flash 場景描述（含圖片）— AI Studio（現有方案對比）")
    import urllib.request
    if not GEMINI_API_KEY:
        print(f"  {WARN} 未設定 GEMINI_API_KEY，跳過")
        return {"ok": False}
    try:
        import numpy as np
        import cv2
        img = np.zeros((240, 320, 3), dtype=np.uint8)
        cv2.putText(img, "zebra crossing ahead", (30, 120),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.7, (200, 200, 200), 2)
        _, buf = cv2.imencode(".jpg", img, [cv2.IMWRITE_JPEG_QUALITY, 60])
        b64 = base64.b64encode(buf.tobytes()).decode()

        url = f"https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key={GEMINI_API_KEY}"
        payload = json.dumps({
            "contents": [{
                "parts": [
                    {"inline_data": {"mime_type": "image/jpeg", "data": b64}},
                    {"text": SCENE_PROMPT},
                ]
            }]
        }).encode()

        t0 = time.time()
        req = urllib.request.Request(url, data=payload,
                                     headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=30) as resp:
            result = json.load(resp)
        elapsed = time.time() - t0

        text = result["candidates"][0]["content"]["parts"][0]["text"].strip()
        print(f"  {PASS} 回應：{elapsed:.2f}s")
        print(f"  內容：{text[:100]}")
        return {"ok": True, "elapsed": elapsed}
    except Exception as e:
        print(f"  {FAIL} {e}")
        return {"ok": False}

# ══════════════════════════════════════════════════════════════════════════════
# C1. Gemini TTS — AI Studio（現有方案，基準）
# ══════════════════════════════════════════════════════════════════════════════

def test_c1_gemini_tts_aistudio():
    print("\n[C1] Gemini TTS — AI Studio（現有方案，基準，不吃試用金）")
    import urllib.request
    if not GEMINI_API_KEY:
        print(f"  {WARN} 未設定 GEMINI_API_KEY，跳過")
        return {"ok": False}
    try:
        url = f"https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash-preview-tts:generateContent?key={GEMINI_API_KEY}"
        payload = json.dumps({
            "contents": [{"parts": [{"text": f"請用自然人聲朗讀：{TTS_TEXT}"}]}],
            "generationConfig": {
                "responseModalities": ["AUDIO"],
                "speechConfig": {
                    "voiceConfig": {
                        "prebuiltVoiceConfig": {"voiceName": "Aoede"}
                    }
                }
            }
        }).encode()

        t0 = time.time()
        req = urllib.request.Request(url, data=payload,
                                     headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=30) as resp:
            result = json.load(resp)
        elapsed = time.time() - t0

        audio_b64 = result["candidates"][0]["content"]["parts"][0]["inlineData"]["data"]
        audio_bytes = base64.b64decode(audio_b64)
        duration_ms = len(audio_bytes) / 2 / 24000 * 1000

        print(f"  {PASS} 回應：{elapsed:.2f}s，音訊：{len(audio_bytes)} bytes，約 {duration_ms:.0f}ms")
        print(f"  品質：自然對話風格（Gemini 神經網路語音）")
        return {"ok": True, "elapsed": elapsed, "bytes": len(audio_bytes)}
    except Exception as e:
        print(f"  {FAIL} {e}")
        return {"ok": False}

# ══════════════════════════════════════════════════════════════════════════════
# C2. Cloud TTS WaveNet（新方案，試用金）
# ══════════════════════════════════════════════════════════════════════════════

def test_c2_cloud_tts_wavenet():
    print("\n[C2] Google Cloud TTS WaveNet（新方案，試用金）")
    try:
        os.environ["GOOGLE_APPLICATION_CREDENTIALS"] = GOOGLE_CREDENTIALS_PATH
        from google.cloud import texttospeech

        client = texttospeech.TextToSpeechClient()
        t0 = time.time()
        resp = client.synthesize_speech(
            input=texttospeech.SynthesisInput(text=TTS_TEXT),
            voice=texttospeech.VoiceSelectionParams(
                language_code="cmn-TW", name="cmn-TW-Wavenet-A"),
            audio_config=texttospeech.AudioConfig(
                audio_encoding=texttospeech.AudioEncoding.LINEAR16,
                sample_rate_hertz=24000,
            ),
        )
        elapsed = time.time() - t0

        raw = resp.audio_content
        duration_ms = len(raw) / 2 / 24000 * 1000
        print(f"  {PASS} 回應：{elapsed:.2f}s，音訊：{len(raw)} bytes，約 {duration_ms:.0f}ms")
        print(f"  品質：WaveNet 神經網路語音（高品質但不如 Gemini 自然）")
        return {"ok": True, "elapsed": elapsed, "bytes": len(raw)}
    except Exception as e:
        print(f"  {FAIL} {e}")
        return {"ok": False}

# ══════════════════════════════════════════════════════════════════════════════
# 主程式
# ══════════════════════════════════════════════════════════════════════════════

if __name__ == "__main__":
    print("=" * 62)
    print("  AI 智慧眼鏡專案 — 服務適合度完整測試")
    print(f"  Project ID：{PROJECT_ID}")
    print(f"  GEMINI_API_KEY：{'已設定' if GEMINI_API_KEY else '未設定'}")
    print("=" * 62)

    # 先準備測試音訊
    print("\n[準備] 合成測試音訊（供 STT 辨識測試使用）...")
    _prepare_test_audio()

    # 執行各測試
    results = {}
    results["A1_STT_v1_串流"]             = test_a1_stt_v1_streaming()
    results["A2_STT_v2_Chirp2_串流"]      = test_a2_stt_v2_chirp2_streaming()
    results["B1_Gemini_Flash_AIStudio"]   = test_b1_gemini_flash_aistudio()
    results["B1s_Gemini場景_AIStudio"]    = test_b1s_gemini_scene_aistudio()
    results["B2_Gemini_Flash_Vertex"]     = test_b2_gemini_flash_vertex()
    results["B3_Gemini_Flash_Vertex串流"] = test_b3_gemini_flash_vertex_stream()
    results["B4_Gemini場景_Vertex"]       = test_b4_gemini_scene_vertex()
    results["C1_GeminiTTS_AIStudio"]      = test_c1_gemini_tts_aistudio()
    results["C2_CloudTTS_WaveNet"]        = test_c2_cloud_tts_wavenet()

    # ── 總覽 ──────────────────────────────────────────────────────────────────
    print("\n" + "=" * 62)
    print("  測試結果總覽")
    print("=" * 62)
    print(f"  {'項目':<30} {'狀態':<8} {'延遲'}")
    print(f"  {'-'*28} {'-'*6} {'-'*12}")

    for name, r in results.items():
        status = PASS if r.get("ok") else FAIL
        elapsed = r.get("elapsed") or r.get("total") or r.get("first_chunk")
        lat = f"{elapsed:.2f}s" if elapsed else "—"
        print(f"  {name:<30} {status:<8} {lat}")

    # ── 建議 ──────────────────────────────────────────────────────────────────
    print("\n" + "=" * 62)
    print("  適合度建議")
    print("=" * 62)

    # STT 建議
    a1 = results["A1_STT_v1_串流"]
    a2 = results["A2_STT_v2_Chirp2_串流"]
    print("\n  [STT]")
    if a1.get("ok") and a2.get("ok"):
        a1t = a1.get("total", 99)
        a2t = a2.get("total", 99)
        if a2t <= a1t * 1.2:
            print(f"  建議：升級至 Chirp_2（v2），精度更高，速度相當（{a2t:.1f}s vs {a1t:.1f}s）")
        else:
            print(f"  建議：維持現有 v1 串流（Chirp_2 較慢：{a2t:.1f}s vs {a1t:.1f}s）")
    elif a1.get("ok") and not a2.get("ok"):
        print(f"  建議：維持現有 v1 串流（Chirp_2 未通過：{a2.get('error', '')[:60]}）")
    elif not a1.get("ok"):
        print(f"  {WARN} v1 串流也有問題，請檢查服務帳號 IAM 權限")

    # Gemini 建議
    b1 = results["B1_Gemini_Flash_AIStudio"]
    b2 = results["B2_Gemini_Flash_Vertex"]
    b3 = results["B3_Gemini_Flash_Vertex串流"]
    print("\n  [Gemini 文字生成]")
    if b1.get("ok") and b2.get("ok"):
        b1t = b1.get("elapsed", 99)
        b2t = b2.get("elapsed", 99)
        b3fc = b3.get("first_chunk", 99) if b3.get("ok") else 99
        print(f"  AI Studio：{b1t:.2f}s  |  Vertex AI 阻塞：{b2t:.2f}s  |  Vertex AI 串流首字：{b3fc:.2f}s")
        if b2t <= b1t * 1.5:
            print(f"  建議：可切換至 Vertex AI（試用金），速度可接受")
        else:
            print(f"  建議：維持 AI Studio（Vertex AI 明顯較慢）")
    elif b2.get("ok") and not b1.get("ok"):
        print(f"  建議：使用 Vertex AI（AI Studio key 未設定）")

    # TTS 建議
    c1 = results["C1_GeminiTTS_AIStudio"]
    c2 = results["C2_CloudTTS_WaveNet"]
    print("\n  [TTS 語音合成]")
    if c1.get("ok") and c2.get("ok"):
        print(f"  Gemini TTS（AI Studio）：{c1.get('elapsed', 0):.2f}s，自然對話風格")
        print(f"  Cloud TTS WaveNet（試用金）：{c2.get('elapsed', 0):.2f}s，標準神經網路語音")
        print(f"  建議：導航提示 → WaveNet（試用金省錢）；AI 對話回覆 → Gemini TTS（更自然）")
    elif c2.get("ok") and not c1.get("ok"):
        print(f"  建議：使用 Cloud TTS WaveNet（Gemini TTS 不可用）")

    print("\n" + "=" * 62)
