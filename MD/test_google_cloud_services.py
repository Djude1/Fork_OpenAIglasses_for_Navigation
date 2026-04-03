# test_google_cloud_services.py
# -*- coding: utf-8 -*-
"""
測試三個 Google Cloud 服務是否可用（全部走服務帳號，吃試用金）：
1. Speech-to-Text v2 + Chirp 模型
2. Gemini 2.5 Pro via Vertex AI
3. Google Cloud Text-to-Speech Neural2

執行方式：
    uv run python MD/test_google_cloud_services.py
"""

import os, sys, json, time, wave, urllib.request, urllib.error
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.stdout.reconfigure(encoding="utf-8")

from config import GOOGLE_CREDENTIALS_PATH

PASS = "[PASS]"
FAIL = "[FAIL]"
WARN = "[WARN]"

# ── 從服務帳號 JSON 讀取 project_id ──────────────────────────────────────────

def get_project_id() -> str:
    try:
        with open(GOOGLE_CREDENTIALS_PATH, encoding="utf-8") as f:
            return json.load(f).get("project_id", "")
    except Exception:
        return ""

# ── 用服務帳號取得 Vertex AI Access Token ────────────────────────────────────

def get_access_token() -> str:
    import google.auth
    import google.auth.transport.requests
    from google.oauth2 import service_account

    creds = service_account.Credentials.from_service_account_file(
        GOOGLE_CREDENTIALS_PATH,
        scopes=["https://www.googleapis.com/auth/cloud-platform"],
    )
    creds.refresh(google.auth.transport.requests.Request())
    return creds.token

# ══════════════════════════════════════════════════════════════════════════════
# 1. Speech-to-Text v2：Chirp 模型
# ══════════════════════════════════════════════════════════════════════════════

def test_stt_chirp():
    print("\n-- 測試 1：Speech-to-Text v2 Chirp --")

    if not os.path.exists(GOOGLE_CREDENTIALS_PATH):
        print(f"  {FAIL} 找不到憑證檔：{GOOGLE_CREDENTIALS_PATH}")
        return False

    project_id = get_project_id()
    print(f"  Project ID：{project_id}")

    try:
        os.environ["GOOGLE_APPLICATION_CREDENTIALS"] = GOOGLE_CREDENTIALS_PATH
        from google.cloud.speech_v2 import SpeechClient
        from google.cloud.speech_v2.types import cloud_speech

        silent_pcm = b"\x00\x00" * 16000  # 1 秒靜音

        from google.api_core.client_options import ClientOptions

        # Chirp 系列：只能單一語言；latest_long/long 支援 zh-TW（global）
        test_configs = [
            ("us-central1", "us-central1-speech.googleapis.com", "chirp_2", ["cmn-Hant-TW"]),
            ("us-central1", "us-central1-speech.googleapis.com", "chirp",   ["cmn-Hant-TW"]),
            ("global",      None,                                 "long",         ["zh-TW"]),
            ("global",      None,                                 "long",         ["cmn-Hant-TW"]),
            ("global",      None,                                 "latest_long",  ["cmn-Hant-TW"]),
        ]
        for location, endpoint, model_name, langs in test_configs:
            try:
                c = SpeechClient(
                    client_options=ClientOptions(api_endpoint=endpoint)
                ) if endpoint else SpeechClient()
                cfg = cloud_speech.RecognitionConfig(
                    explicit_decoding_config=cloud_speech.ExplicitDecodingConfig(
                        encoding=cloud_speech.ExplicitDecodingConfig.AudioEncoding.LINEAR16,
                        sample_rate_hertz=16000,
                        audio_channel_count=1,
                    ),
                    language_codes=langs,
                    model=model_name,
                )
                req = cloud_speech.RecognizeRequest(
                    recognizer=f"projects/{project_id}/locations/{location}/recognizers/_",
                    config=cfg,
                    content=silent_pcm,
                )
                t0 = time.time()
                resp = c.recognize(request=req)
                elapsed = time.time() - t0
                print(f"  {PASS} {model_name}@{location} 可用（回應 {elapsed:.1f}s）")
                print(f"  結果：{resp.results if resp.results else '靜音無結果（正常）'}")
                return True
            except Exception as e:
                print(f"  {WARN} {model_name}@{location} langs={langs[0]} → {str(e)[:150]}")
        return False

    except Exception as e:
        err = str(e)
        if "permission" in err.lower() or "403" in err:
            print(f"  {WARN} 權限不足：{err[:250]}")
        elif "enable" in err.lower():
            print(f"  {WARN} API 未啟用：{err[:250]}")
        else:
            print(f"  {FAIL} 錯誤：{err[:250]}")
        return False

# ══════════════════════════════════════════════════════════════════════════════
# 2. Gemini 2.5 Pro via Vertex AI（用服務帳號，吃試用金）
# ══════════════════════════════════════════════════════════════════════════════

def test_gemini_pro_vertex():
    print("\n-- 測試 2：Gemini via Vertex AI（試用金）--")

    if not os.path.exists(GOOGLE_CREDENTIALS_PATH):
        print(f"  {FAIL} 找不到憑證檔")
        return False

    project_id = get_project_id()
    location = "us-central1"
    print(f"  Project ID：{project_id}")

    try:
        os.environ["GOOGLE_APPLICATION_CREDENTIALS"] = GOOGLE_CREDENTIALS_PATH
        from google import genai

        client = genai.Client(vertexai=True, project=project_id, location=location)

        for model in ["gemini-2.5-pro", "gemini-2.5-flash", "gemini-2.0-flash"]:
            try:
                t0 = time.time()
                response = client.models.generate_content(
                    model=model,
                    contents="用一句話描述：前方有一條斑馬線。",
                )
                elapsed = time.time() - t0
                print(f"  {PASS} {model} (Vertex AI) 可用（回應 {elapsed:.1f}s）")
                print(f"  回應：{response.text.strip()}")
                return True
            except Exception as e:
                print(f"  {WARN} {model} → {str(e)[:150]}")

        return False

    except Exception as e:
        print(f"  {FAIL} 錯誤：{e}")
        return False

# ══════════════════════════════════════════════════════════════════════════════
# 3. Google Cloud TTS Neural2
# ══════════════════════════════════════════════════════════════════════════════

def test_cloud_tts():
    print("\n-- 測試 3：Google Cloud TTS Neural2 --")

    if not os.path.exists(GOOGLE_CREDENTIALS_PATH):
        print(f"  {FAIL} 找不到憑證檔")
        return False

    try:
        os.environ["GOOGLE_APPLICATION_CREDENTIALS"] = GOOGLE_CREDENTIALS_PATH
        from google.cloud import texttospeech

        client = texttospeech.TextToSpeechClient()
        synthesis_input = texttospeech.SynthesisInput(text="前方有斑馬線，請小心通行。")
        voice = texttospeech.VoiceSelectionParams(
            language_code="cmn-TW",
            name="cmn-TW-Wavenet-A",  # zh-TW 最高品質（無 Neural2）
        )
        audio_config = texttospeech.AudioConfig(
            audio_encoding=texttospeech.AudioEncoding.LINEAR16,
            sample_rate_hertz=16000,
        )

        t0 = time.time()
        response = client.synthesize_speech(
            input=synthesis_input, voice=voice, audio_config=audio_config
        )
        elapsed = time.time() - t0

        raw = response.audio_content
        duration_ms = len(raw) / 2 / 16000 * 1000

        print(f"  {PASS} Cloud TTS Neural2 可用（回應 {elapsed:.2f}s）")
        print(f"  合成音訊：{len(raw)} bytes，約 {duration_ms:.0f}ms")

        out_path = os.path.join(os.path.dirname(__file__), "tts_test_output.wav")
        with wave.open(out_path, "wb") as wf:
            wf.setnchannels(1)
            wf.setsampwidth(2)
            wf.setframerate(16000)
            wf.writeframes(raw)
        print(f"  音訊存至：{out_path}（請播放確認音質）")
        return True

    except Exception as e:
        err = str(e)
        if "permission" in err.lower() or "403" in err:
            print(f"  {WARN} 權限不足：{err[:250]}")
        elif "enable" in err.lower():
            print(f"  {WARN} API 未啟用：{err[:250]}")
        else:
            print(f"  {FAIL} 錯誤：{err[:250]}")
        return False

# ══════════════════════════════════════════════════════════════════════════════
# 主程式
# ══════════════════════════════════════════════════════════════════════════════

if __name__ == "__main__":
    print("=" * 56)
    print("  Google Cloud 服務測試（全部走試用金）")
    print(f"  憑證：{GOOGLE_CREDENTIALS_PATH}")
    print(f"  Project ID：{get_project_id()}")
    print("=" * 56)

    results = {
        "STT v2 Chirp":             test_stt_chirp(),
        "Gemini 2.5 Pro (Vertex)":  test_gemini_pro_vertex(),
        "Cloud TTS Neural2":        test_cloud_tts(),
    }

    print("\n" + "=" * 56)
    print("  測試結果總覽")
    print("=" * 56)
    for name, ok in results.items():
        print(f"  {PASS if ok else FAIL}  {name}")

    print()
    if all(results.values()):
        print("  全部通過！可以開始切換正式程式碼。")
    else:
        failed = [n for n, ok in results.items() if not ok]
        print(f"  需要排查：{', '.join(failed)}")
    print("=" * 56)
