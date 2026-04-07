from __future__ import annotations

import asyncio
import os
import time
import uuid
from threading import Lock
from typing import Literal

import torch
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel, Field
from transformers import AutoModelForCausalLM, AutoTokenizer


def env_int(name: str, default: int) -> int:
    value = os.getenv(name)
    if value is None or value == "":
        return default
    return int(value)


def env_float(name: str, default: float) -> float:
    value = os.getenv(name)
    if value is None or value == "":
        return default
    return float(value)


def env_bool(name: str, default: bool) -> bool:
    value = os.getenv(name)
    if value is None or value == "":
        return default
    return value.lower() in {"1", "true", "yes", "on"}


def resolve_dtype() -> torch.dtype | None:
    mapping = {
        "auto": None,
        "float32": torch.float32,
        "float": torch.float32,
        "bfloat16": torch.bfloat16,
        "float16": torch.float16,
    }
    key = os.getenv("TORCH_DTYPE", "float32").lower()
    if key not in mapping:
        raise ValueError(f"Unsupported TORCH_DTYPE: {key}")
    return mapping[key]


class ChatMessage(BaseModel):
    role: Literal["system", "user", "assistant", "tool"] = "user"
    content: str


class ChatCompletionRequest(BaseModel):
    model: str | None = None
    messages: list[ChatMessage] = Field(default_factory=list)
    max_tokens: int | None = None
    temperature: float | None = None
    top_p: float | None = None
    top_k: int | None = None
    repetition_penalty: float | None = None
    stream: bool = False


class CompletionRequest(BaseModel):
    model: str | None = None
    prompt: str
    max_tokens: int | None = None
    temperature: float | None = None
    top_p: float | None = None
    top_k: int | None = None
    repetition_penalty: float | None = None
    stream: bool = False


class ModelRuntime:
    def __init__(self) -> None:
        self.model_name = os.getenv("MODEL_ALIAS", "gemma-4")
        self.model_ref = os.getenv("MODEL_PATH") or os.getenv("HF_MODEL_ID")
        if not self.model_ref:
            raise RuntimeError("MODEL_PATH or HF_MODEL_ID must be configured for transformers runtime")
        self.trust_remote_code = env_bool("TRUST_REMOTE_CODE", False)
        self.default_max_tokens = env_int("MAX_NEW_TOKENS", 256)
        self.default_temperature = env_float("TEMPERATURE", 0.2)
        self.default_top_p = env_float("TOP_P", 0.95)
        self.default_top_k = env_int("TOP_K", 40)
        self.default_repetition_penalty = env_float("REPETITION_PENALTY", 1.1)
        self.lock = Lock()
        self.tokenizer = None
        self.model = None

    def load(self) -> None:
        threads = max(1, env_int("TORCH_NUM_THREADS", os.cpu_count() or 1))
        torch.set_num_threads(threads)
        torch.set_num_interop_threads(max(1, min(4, threads)))

        dtype = resolve_dtype()
        tokenizer = AutoTokenizer.from_pretrained(self.model_ref, trust_remote_code=self.trust_remote_code)
        if tokenizer.pad_token_id is None:
            tokenizer.pad_token = tokenizer.eos_token

        model = AutoModelForCausalLM.from_pretrained(
            self.model_ref,
            torch_dtype=dtype,
            low_cpu_mem_usage=True,
            trust_remote_code=self.trust_remote_code,
        )
        model.to("cpu")
        model.eval()

        self.tokenizer = tokenizer
        self.model = model

    def render_chat_prompt(self, messages: list[ChatMessage]) -> str:
        if not messages:
            raise HTTPException(status_code=400, detail="messages must not be empty")

        payload = [{"role": message.role, "content": message.content} for message in messages]
        try:
            return self.tokenizer.apply_chat_template(payload, tokenize=False, add_generation_prompt=True)
        except Exception:
            lines = [f"{message.role}: {message.content}" for message in messages]
            lines.append("assistant:")
            return "\n".join(lines)

    def generate_text(
        self,
        prompt: str,
        max_tokens: int | None,
        temperature: float | None,
        top_p: float | None,
        top_k: int | None,
        repetition_penalty: float | None,
    ) -> dict:
        if self.model is None or self.tokenizer is None:
            raise RuntimeError("model runtime is not initialized")

        resolved_max_tokens = max_tokens or self.default_max_tokens
        resolved_temperature = self.default_temperature if temperature is None else temperature
        resolved_top_p = self.default_top_p if top_p is None else top_p
        resolved_top_k = self.default_top_k if top_k is None else top_k
        resolved_repetition_penalty = (
            self.default_repetition_penalty if repetition_penalty is None else repetition_penalty
        )

        encoded = self.tokenizer(prompt, return_tensors="pt")
        input_ids = encoded["input_ids"].to("cpu")
        attention_mask = encoded.get("attention_mask")
        if attention_mask is not None:
            attention_mask = attention_mask.to("cpu")

        generation_kwargs = {
            "input_ids": input_ids,
            "max_new_tokens": resolved_max_tokens,
            "pad_token_id": self.tokenizer.pad_token_id,
            "eos_token_id": self.tokenizer.eos_token_id,
            "repetition_penalty": resolved_repetition_penalty,
        }

        if attention_mask is not None:
            generation_kwargs["attention_mask"] = attention_mask

        if resolved_temperature > 0:
            generation_kwargs.update(
                {
                    "do_sample": True,
                    "temperature": resolved_temperature,
                    "top_p": resolved_top_p,
                }
            )
            if resolved_top_k > 0:
                generation_kwargs["top_k"] = resolved_top_k
        else:
            generation_kwargs["do_sample"] = False

        with self.lock:
            with torch.inference_mode():
                output = self.model.generate(**generation_kwargs)

        generated_ids = output[0, input_ids.shape[-1] :]
        text = self.tokenizer.decode(generated_ids, skip_special_tokens=True).strip()
        prompt_tokens = int(input_ids.shape[-1])
        completion_tokens = int(generated_ids.shape[-1])

        return {
            "text": text,
            "prompt_tokens": prompt_tokens,
            "completion_tokens": completion_tokens,
        }


app = FastAPI(title="gemma-transformers-cpu", version="0.1.0")
runtime = ModelRuntime()


@app.on_event("startup")
async def startup() -> None:
    await asyncio.to_thread(runtime.load)


@app.get("/healthz")
def healthz() -> dict:
    return {
        "status": "ok",
        "runtime": "transformers",
        "model": runtime.model_name,
    }


@app.get("/v1/models")
def list_models() -> dict:
    return {
        "object": "list",
        "data": [
            {
                "id": runtime.model_name,
                "object": "model",
                "owned_by": "local",
            }
        ],
    }


@app.post("/v1/chat/completions")
async def chat_completions(request: ChatCompletionRequest) -> dict:
    if request.stream:
        raise HTTPException(status_code=400, detail="streaming is not implemented for transformers runtime")

    prompt = runtime.render_chat_prompt(request.messages)
    started_at = int(time.time())
    result = await asyncio.to_thread(
        runtime.generate_text,
        prompt,
        request.max_tokens,
        request.temperature,
        request.top_p,
        request.top_k,
        request.repetition_penalty,
    )

    return {
        "id": f"chatcmpl-{uuid.uuid4().hex}",
        "object": "chat.completion",
        "created": started_at,
        "model": request.model or runtime.model_name,
        "choices": [
            {
                "index": 0,
                "message": {
                    "role": "assistant",
                    "content": result["text"],
                },
                "finish_reason": "stop",
            }
        ],
        "usage": {
            "prompt_tokens": result["prompt_tokens"],
            "completion_tokens": result["completion_tokens"],
            "total_tokens": result["prompt_tokens"] + result["completion_tokens"],
        },
    }


@app.post("/v1/completions")
async def completions(request: CompletionRequest) -> dict:
    if request.stream:
        raise HTTPException(status_code=400, detail="streaming is not implemented for transformers runtime")

    started_at = int(time.time())
    result = await asyncio.to_thread(
        runtime.generate_text,
        request.prompt,
        request.max_tokens,
        request.temperature,
        request.top_p,
        request.top_k,
        request.repetition_penalty,
    )

    return {
        "id": f"cmpl-{uuid.uuid4().hex}",
        "object": "text_completion",
        "created": started_at,
        "model": request.model or runtime.model_name,
        "choices": [
            {
                "index": 0,
                "text": result["text"],
                "finish_reason": "stop",
            }
        ],
        "usage": {
            "prompt_tokens": result["prompt_tokens"],
            "completion_tokens": result["completion_tokens"],
            "total_tokens": result["prompt_tokens"] + result["completion_tokens"],
        },
    }
