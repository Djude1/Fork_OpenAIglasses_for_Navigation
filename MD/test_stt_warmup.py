# test_stt_warmup.py
# -*- coding: utf-8 -*-
"""
測試 STT v1 與 v2 Chirp_2 在連續多次呼叫下的實際速度（含暖機對比）

執行方式：
    uv run python MD/test_stt_warmup.py
"""

import os, sys, time, json
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.stdout.reconfigure(encoding="utf-8")

from config import GOOGLE_CREDENTIALS_PATH

ROUNDS = 3  # 每種方案測幾輪

def get_project_id():
    try:
        with open(GOOGLE_CREDENTIALS_PATH, encoding="utf-8") as f:
            return json.load(f).get("project_id", "")
    except Exception:
        return ""

PROJECT_ID = get_project_id()

# ── 先用 Cloud TTS 合成測試音訊 ───────────────────────────────────────────────
def make_test_pcm() -> bytes:
    os.environ["GOOGLE_APPLICATION_CREDENTIALS"] = GOOGLE_CREDENTIALS_PATH
    from google.cloud import texttospeech
    client = texttospeech.TextToSpeechClient()
    resp = client.synthesize_speech(
        input=texttospeech.SynthesisInput(text="哈囉曼波，前方有斑馬線。"),
        voice=texttospeech.VoiceSelectionParams(
            language_code="cmn-TW", name="cmn-TW-Wavenet-A"),
        audio_config=texttospeech.AudioConfig(
            audio_encoding=texttospeech.AudioEncoding.LINEAR16,
            sample_rate_hertz=16000,
        ),
    )
    return resp.audio_content

# ── STT v1 串流 ───────────────────────────────────────────────────────────────
def run_v1(pcm: bytes, client=None):
    from google.cloud import speech as _speech
    if client is None:
        os.environ["GOOGLE_APPLICATION_CREDENTIALS"] = GOOGLE_CREDENTIALS_PATH
        client = _speech.SpeechClient()

    config = _speech.RecognitionConfig(
        encoding=_speech.RecognitionConfig.AudioEncoding.LINEAR16,
        sample_rate_hertz=16000,
        language_code="zh-TW",
        alternative_language_codes=["zh-CN"],
        enable_automatic_punctuation=True,
        speech_contexts=[_speech.SpeechContext(
            phrases=["哈囉曼波", "哈囉 曼波", "曼波"],
            boost=20.0,
        )],
    )
    streaming_config = _speech.StreamingRecognitionConfig(
        config=config, interim_results=True
    )
    chunk_size = 16000 * 2 // 10

    def _gen():
        for i in range(0, len(pcm), chunk_size):
            yield _speech.StreamingRecognizeRequest(audio_content=pcm[i:i + chunk_size])

    t0 = time.time()
    first_t = None
    final_text = ""
    for resp in client.streaming_recognize(streaming_config, _gen()):
        for result in resp.results:
            if result.alternatives:
                txt = result.alternatives[0].transcript.strip()
                if txt and first_t is None:
                    first_t = time.time() - t0
                if result.is_final:
                    final_text = txt
    total = time.time() - t0
    return first_t, total, final_text, client

# ── STT v2 Chirp_2 串流 ───────────────────────────────────────────────────────
def run_v2(pcm: bytes, client=None):
    from google.api_core.client_options import ClientOptions
    from google.cloud.speech_v2 import SpeechClient
    from google.cloud.speech_v2.types import cloud_speech

    ENDPOINT = "us-central1-speech.googleapis.com"
    LOCATION  = "us-central1"

    if client is None:
        os.environ["GOOGLE_APPLICATION_CREDENTIALS"] = GOOGLE_CREDENTIALS_PATH
        client = SpeechClient(client_options=ClientOptions(api_endpoint=ENDPOINT))

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
    chunk_size  = 16000 * 2 // 10

    def _gen():
        yield cloud_speech.StreamingRecognizeRequest(
            recognizer=recognizer,
            streaming_config=streaming_config,
        )
        for i in range(0, len(pcm), chunk_size):
            yield cloud_speech.StreamingRecognizeRequest(audio=pcm[i:i + chunk_size])

    t0 = time.time()
    first_t = None
    final_text = ""
    for resp in client.streaming_recognize(requests=_gen()):
        for result in resp.results:
            if result.alternatives:
                txt = result.alternatives[0].transcript.strip()
                if txt and first_t is None:
                    first_t = time.time() - t0
                if result.is_final:
                    final_text = txt
    total = time.time() - t0
    return first_t, total, final_text, client

# ── 主程式 ────────────────────────────────────────────────────────────────────
if __name__ == "__main__":
    print("=" * 60)
    print("  STT 速度對比測試（含暖機）")
    print(f"  每方案連跑 {ROUNDS} 輪，client 物件複用（模擬正式環境）")
    print("=" * 60)

    print("\n[準備] 合成測試音訊...")
    pcm = make_test_pcm()
    duration_s = len(pcm) / 2 / 16000
    print(f"  音訊長度：{duration_s:.2f}s（{len(pcm)} bytes）")

    # ── v1 多輪測試 ────────────────────────────────────────────────────────────
    print(f"\n{'─'*60}")
    print("  STT v1 串流（zh-TW + 熱詞）")
    print(f"{'─'*60}")
    v1_client = None
    v1_times = []
    for i in range(ROUNDS):
        first_t, total, text, v1_client = run_v1(pcm, v1_client)
        v1_times.append(total)
        label = "冷啟動" if i == 0 else f"第 {i+1} 次"
        print(f"  [{label}] 首字：{first_t:.2f}s  總計：{total:.2f}s  結果：{text or '（無）'}")

    # ── v2 多輪測試 ────────────────────────────────────────────────────────────
    print(f"\n{'─'*60}")
    print("  STT v2 Chirp_2 串流（cmn-Hant-TW）")
    print(f"{'─'*60}")
    v2_client = None
    v2_times = []
    for i in range(ROUNDS):
        first_t, total, text, v2_client = run_v2(pcm, v2_client)
        v2_times.append(total)
        label = "冷啟動" if i == 0 else f"第 {i+1} 次"
        print(f"  [{label}] 首字：{first_t:.2f}s  總計：{total:.2f}s  結果：{text or '（無）'}")

    # ── 總結 ───────────────────────────────────────────────────────────────────
    print(f"\n{'='*60}")
    print("  速度總結")
    print(f"{'='*60}")
    v1_avg = sum(v1_times) / len(v1_times)
    v2_avg = sum(v2_times) / len(v2_times)
    v1_warm = sum(v1_times[1:]) / max(len(v1_times[1:]), 1)
    v2_warm = sum(v2_times[1:]) / max(len(v2_times[1:]), 1)

    print(f"  v1 串流：冷啟動 {v1_times[0]:.2f}s，暖機平均 {v1_warm:.2f}s")
    print(f"  v2 Chirp_2：冷啟動 {v2_times[0]:.2f}s，暖機平均 {v2_warm:.2f}s")
    print()
    if v2_warm <= v1_warm * 1.3:
        print("  結論：Chirp_2 暖機後速度可接受，且辨識率更高 → 建議升級")
    else:
        print(f"  結論：Chirp_2 暖機後仍比 v1 慢 {v2_warm/v1_warm:.1f}x → 建議維持 v1")
    print(f"{'='*60}")
