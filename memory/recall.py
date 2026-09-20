from __future__ import annotations

import math
import re
from collections import Counter
from typing import Any


TOKEN_PATTERN = re.compile(r"[a-zA-Z0-9_]+|[\u3400-\u9fff]")


def tokenize(text: str) -> list[str]:
    return TOKEN_PATTERN.findall(text.lower())


def rank_cards(query: str, cards: list[dict[str, Any]], limit: int = 10) -> list[dict[str, Any]]:
    query_terms = Counter(tokenize(query))
    if not query_terms:
        return []
    document_frequency: Counter[str] = Counter()
    card_terms: list[Counter[str]] = []
    for card in cards:
        terms = Counter(tokenize(" ".join([card["title"], card["content"], *card["tags"]])))
        card_terms.append(terms)
        document_frequency.update(terms.keys())
    ranked: list[dict[str, Any]] = []
    total = len(cards)
    for card, terms in zip(cards, card_terms, strict=True):
        score = sum(
            min(count, terms.get(term, 0)) * (math.log((total + 1) / (document_frequency[term] + 1)) + 1)
            for term, count in query_terms.items()
        )
        if score:
            ranked.append({**card, "score": round(score, 4)})
    ranked.sort(key=lambda item: (-item["score"], item["updated_at"]))
    return ranked[: max(1, min(limit, 100))]