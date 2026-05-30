# audio_stream.py
# -*- coding: utf-8 -*-
import asyncio
from dataclasses import dataclass
from typing import Optional, Set, List, Tuple, Any, Dict
from fastapi import Request
from fastapi.responses import StreamingResponse

# ===== 下行 WAV 流基础参数 =====
from config import STREAM_SR  # 從集中設定檔讀取下行串流採樣率
STREAM_CH = 1
STREAM_SW = 2
BYTES_PER_20MS_16K = STREAM_SR * STREAM_SW * 20 // 1000  # 320B (8kHz)
BYTES_PER_20MS_24K = 24000 * STREAM_SW * 20 // 1000      # 960B (24kHz，APP just_audio 用)

# ===== AI 播放任务总闸 =====
current_ai_task: Optional[asyncio.Task] = None

async def cancel_current_ai():
    """取消当前大模型语音任务，并等待其退出。"""
    global current_ai_task
    task = current_ai_task
    current_ai_task = None
    if task and not task.done():
        task.cancel()
        try:
            await task
        except asyncio.CancelledError:
            pass
        except Exception:
            pass

def is_playing_now() -> bool:
    t = current_ai_task
    return (t is not None) and (not t.done())

# ===== /stream.wav 连接管理 =====
@dataclass(frozen=True)
class StreamClient:
    q: asyncio.Queue
    abort_event: asyncio.Event

stream_clients: "Set[StreamClient]" = set()        # 8k 路：給 ESP32 硬體 / 模擬器 / LOCAL_MODE
stream_clients_24k: "Set[StreamClient]" = set()    # 24k 路：給 APP just_audio（無損 WaveNet 原音）
STREAM_QUEUE_MAX = 96  # 小缓冲，避免积压

def _wav_header_unknown_size(sr=16000, ch=1, sw=2) -> bytes:
    import struct
    byte_rate = sr * ch * sw
    block_align = ch * sw
    data_size = 0x7FFFFFF0
    riff_size = 36 + data_size
    return struct.pack(
        "<4sI4s4sIHHIIHH4sI",
        b"RIFF", riff_size, b"WAVE",
        b"fmt ", 16,
        1, ch, sr, byte_rate, block_align, sw * 8,
        b"data", data_size
    )

async def hard_reset_audio(reason: str = ""):
    """
    **一键清场**：取消当前AI任务 + 清空所有串流佇列中的舊音訊。
    保持 /stream.wav 連線不斷，避免 APP 重連延遲導致後續音訊丟失。
    """
    # 1) 取消当前AI任务
    await cancel_current_ai()

    # 2) 清空兩組客戶端佇列中的殘留音訊（不斷開連線）— 8k 與 24k 雙路一起清
    for clients in (stream_clients, stream_clients_24k):
        dead: list = []
        for sc in list(clients):
            if sc.abort_event.is_set():
                dead.append(sc)
                continue
            # 清空佇列中的舊資料
            while not sc.q.empty():
                try:
                    sc.q.get_nowait()
                except Exception:
                    break
        for sc in dead:
            clients.discard(sc)

    # 3) 日志
    if reason:
        print(f"[HARD-RESET] {reason}")

VOLUME_GAIN = 3  # 輸出音量倍數（調整此值即可）

async def broadcast_pcm16_realtime(pcm16: bytes):
    """以 20ms 节拍把 pcm16 发送给所有仍存活的连接；队列满丢尾，保持实时。"""
    # 【新增】录制音频（在分发之前整体录制，避免分片）
    try:
        import sync_recorder
        sync_recorder.record_audio(pcm16, text="[Omni对话]")
    except Exception:
        pass  # 静默失败，不影响播放

    # 放大音量（audioop.mul 會自動對溢位做截斷，不會爆音）
    if VOLUME_GAIN != 1:
        import audioop
        pcm16 = audioop.mul(pcm16, 2, VOLUME_GAIN)

    # 本機喇叭播放（LOCAL_MODE=true 時同步送給電腦喇叭）
    try:
        import local_device
        if local_device.LOCAL_MODE:
            local_device.play_pcm_locally(pcm16)
    except Exception:
        pass

    if not stream_clients:
        print(f"[STREAM] ⚠ broadcast 但無串流客戶端連線（音訊將丟失）", flush=True)

    loop = asyncio.get_event_loop()
    next_tick = loop.time()
    off = 0
    while off < len(pcm16):
        take = min(BYTES_PER_20MS_16K, len(pcm16) - off)
        piece = pcm16[off:off + take]

        dead: List[StreamClient] = []
        for sc in list(stream_clients):
            if sc.abort_event.is_set():
                dead.append(sc)
                continue
            try:
                if sc.q.full():
                    try: sc.q.get_nowait()
                    except Exception: pass
                sc.q.put_nowait(piece)
            except Exception:
                dead.append(sc)
        for sc in dead:
            try: stream_clients.discard(sc)
            except Exception: pass

        next_tick += 0.020
        now = loop.time()
        if now < next_tick:
            await asyncio.sleep(next_tick - now)
        else:
            next_tick = now
        off += take

async def broadcast_pcm24k_realtime(pcm24: bytes):
    """以 20ms 节拍把 24k PCM 发送给所有 24k 客户端（APP just_audio 用）。
    與 8k 路 broadcast_pcm16_realtime 並存；不放大音量、不錄音
    （錄音由 8k 路統一處理，避免重複），保留 WaveNet 原音質。"""
    if not stream_clients_24k:
        # 無 client 直接返回，避免 silence pacing 阻塞 caller
        return

    loop = asyncio.get_event_loop()
    next_tick = loop.time()
    off = 0
    while off < len(pcm24):
        take = min(BYTES_PER_20MS_24K, len(pcm24) - off)
        piece = pcm24[off:off + take]

        dead: List[StreamClient] = []
        for sc in list(stream_clients_24k):
            if sc.abort_event.is_set():
                dead.append(sc)
                continue
            try:
                if sc.q.full():
                    try: sc.q.get_nowait()
                    except Exception: pass
                sc.q.put_nowait(piece)
            except Exception:
                dead.append(sc)
        for sc in dead:
            try: stream_clients_24k.discard(sc)
            except Exception: pass

        next_tick += 0.020
        now = loop.time()
        if now < next_tick:
            await asyncio.sleep(next_tick - now)
        else:
            next_tick = now
        off += take

# ===== FastAPI 路由注册器 =====
def register_stream_route(app):
    @app.get("/stream.wav")
    async def stream_wav(_: Request):
        # —— 强制单连接，先拉闸所有旧连接 ——
        old_count = len(stream_clients)
        for sc in list(stream_clients):
            try: sc.abort_event.set()
            except Exception: pass
        stream_clients.clear()

        q: asyncio.Queue[bytes | None] = asyncio.Queue(maxsize=STREAM_QUEUE_MAX)
        abort_event = asyncio.Event()
        sc = StreamClient(q=q, abort_event=abort_event)
        stream_clients.add(sc)
        print(f"[STREAM] 新 /stream.wav 連線（清理 {old_count} 個舊連線，目前 {len(stream_clients)} 個）", flush=True)

        _SILENCE_FRAME = b"\x00" * BYTES_PER_20MS_16K

        async def gen():
            yield _wav_header_unknown_size(STREAM_SR, STREAM_CH, STREAM_SW)
            try:
                while True:
                    if abort_event.is_set():
                        break
                    try:
                        # 以 20ms 為一個節拍輪詢，保持音訊串流速率
                        # 有資料時播放，無資料時送靜音幀（維持 8kHz 即時速率，防止 Android 斷線）
                        chunk = await asyncio.wait_for(q.get(), timeout=0.020)
                    except asyncio.TimeoutError:
                        if not abort_event.is_set():
                            yield _SILENCE_FRAME
                        continue
                    if abort_event.is_set():
                        break
                    if chunk is None:
                        break
                    if chunk:
                        yield chunk
            finally:
                stream_clients.discard(sc)
        return StreamingResponse(gen(), media_type="audio/wav")


def register_stream24k_route(app):
    """24kHz 高品質 PCM 串流端點，給 APP just_audio (ExoPlayer) 用。
    與 /stream.wav (8k, 給 ESP32) 並存，互不干擾。"""
    @app.get("/stream24k.wav")
    async def stream_wav_24k(_: Request):
        # —— 强制单连接，先拉闸所有旧连接 ——
        old_count = len(stream_clients_24k)
        for sc in list(stream_clients_24k):
            try: sc.abort_event.set()
            except Exception: pass
        stream_clients_24k.clear()

        q: asyncio.Queue[bytes | None] = asyncio.Queue(maxsize=STREAM_QUEUE_MAX)
        abort_event = asyncio.Event()
        sc = StreamClient(q=q, abort_event=abort_event)
        stream_clients_24k.add(sc)
        print(f"[STREAM-24K] 新 /stream24k.wav 連線（清理 {old_count} 個舊連線，目前 {len(stream_clients_24k)} 個）", flush=True)

        # silence frame 改 100ms（原 20ms）— 接縫頻率降 5x，緩解 ExoPlayer
        # 解碼 silence→PCM 階躍產生的咔擦雜訊。100ms buffer 給 ExoPlayer 撐
        # 著等下次 PCM，反而降低 underrun 風險。
        _SILENCE_FRAME_24K = b"\x00" * (BYTES_PER_20MS_24K * 5)

        async def gen():
            yield _wav_header_unknown_size(24000, STREAM_CH, STREAM_SW)
            try:
                while True:
                    if abort_event.is_set():
                        break
                    try:
                        chunk = await asyncio.wait_for(q.get(), timeout=0.020)
                    except asyncio.TimeoutError:
                        if not abort_event.is_set():
                            yield _SILENCE_FRAME_24K
                        continue
                    if abort_event.is_set():
                        break
                    if chunk is None:
                        break
                    if chunk:
                        yield chunk
            finally:
                stream_clients_24k.discard(sc)
        return StreamingResponse(gen(), media_type="audio/wav")