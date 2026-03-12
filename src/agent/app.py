"""Guess My Number Agent - A fun number guessing game powered by a custom LLM."""

import os
import random
import uuid

from fastapi import FastAPI
from pydantic import BaseModel

import httpx

app = FastAPI(title="Guess My Number Agent")

MODEL_ENDPOINT = os.getenv("MODEL_ENDPOINT", "http://localhost:8000")

# In-memory game state storage (keyed by session_id)
games: dict[str, dict] = {}


class Message(BaseModel):
    role: str
    content: str


class ChatCompletionRequest(BaseModel):
    messages: list[Message]
    model: str = "guess-my-number"
    temperature: float = 0.7
    max_tokens: int = 256
    session_id: str | None = None


async def call_model(system_prompt: str, user_message: str, fallback: str) -> str:
    """Call the custom model for natural language generation, with a fallback."""
    try:
        async with httpx.AsyncClient(timeout=30.0) as client:
            response = await client.post(
                f"{MODEL_ENDPOINT}/v1/chat/completions",
                json={
                    "messages": [
                        {"role": "system", "content": system_prompt},
                        {"role": "user", "content": user_message},
                    ],
                    "max_tokens": 150,
                    "temperature": 0.7,
                },
            )
            response.raise_for_status()
            return response.json()["choices"][0]["message"]["content"]
    except Exception:
        return fallback


def _extract_number(text: str) -> int | None:
    """Extract the first integer from a text string."""
    for word in text.split():
        cleaned = word.strip(".,!?;:()")
        if cleaned.isdigit():
            return int(cleaned)
    return None


@app.post("/v1/chat/completions")
async def chat_completions(request: ChatCompletionRequest):
    session_id = request.session_id or str(uuid.uuid4())

    # Initialize new game if needed
    if session_id not in games:
        games[session_id] = {
            "number": random.randint(0, 100),
            "attempts": 0,
        }

    game = games[session_id]
    user_msg = request.messages[-1].content if request.messages else ""

    guess = _extract_number(user_msg)

    if guess is None:
        hint = (
            "Welcome! I've picked a number between 0 and 100. "
            "Try to guess it! Just type a number."
        )
        response_text = await call_model(
            "You are hosting a 'Guess My Number' game. You picked a secret number "
            "between 0 and 100. The player hasn't guessed a number yet. "
            "Welcome them and ask them to guess. Be fun and brief.",
            user_msg,
            hint,
        )
    else:
        game["attempts"] += 1
        target = game["number"]

        if guess == target:
            attempts = game["attempts"]
            del games[session_id]
            hint = (
                f"Correct! The number was {target}. "
                f"You got it in {attempts} attempt(s)!"
            )
            response_text = await call_model(
                f"The player guessed {guess} which is CORRECT! They won in "
                f"{attempts} attempt(s). Congratulate them! Be fun and brief.",
                f"Is it {guess}?",
                hint,
            )
        elif guess < target:
            hint = f"Higher! The number is higher than {guess}. (Attempt #{game['attempts']})"
            response_text = await call_model(
                f"You're hosting 'Guess My Number'. The player guessed {guess}. "
                f"The correct number is HIGHER. Tell them to go higher. "
                f"Be encouraging and brief. Don't reveal the number!",
                f"Is it {guess}?",
                hint,
            )
        else:
            hint = f"Lower! The number is lower than {guess}. (Attempt #{game['attempts']})"
            response_text = await call_model(
                f"You're hosting 'Guess My Number'. The player guessed {guess}. "
                f"The correct number is LOWER. Tell them to go lower. "
                f"Be encouraging and brief. Don't reveal the number!",
                f"Is it {guess}?",
                hint,
            )

    return {
        "id": f"chatcmpl-{uuid.uuid4().hex[:12]}",
        "object": "chat.completion",
        "model": "guess-my-number",
        "choices": [
            {
                "index": 0,
                "message": {"role": "assistant", "content": response_text},
                "finish_reason": "stop",
            }
        ],
        "usage": {
            "prompt_tokens": 0,
            "completion_tokens": 0,
            "total_tokens": 0,
        },
        "session_id": session_id,
    }


@app.get("/health")
async def health():
    return {"status": "healthy"}


@app.get("/")
async def root():
    return {
        "name": "Guess My Number Agent",
        "description": (
            "An AI-powered number guessing game. "
            "I pick a number between 0 and 100, you try to guess it!"
        ),
        "endpoints": {
            "chat": "/v1/chat/completions",
            "health": "/health",
        },
    }
