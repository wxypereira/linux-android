#!/usr/bin/env python3
"""Validate local Markdown links and GitHub-style heading anchors."""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# Link: [texto](destino "titulo") — o destino é capturado uma única vez,
# separando o título opcional (que não faz parte do destino).
LINK_RE = re.compile(
    r"(?<!!)\[[^\]]*\]\(\s*(?:<([^>]*)>|([^\s)]+))"
    r"(?:\s+(?:\"[^\"]*\"|'[^']*'|\([^)]*\)))?\s*\)"
)
HEADING_RE = re.compile(r"^#{1,6}\s+(.+?)\s*#*\s*$", re.MULTILINE)
INLINE_CODE_RE = re.compile(r"`[^`]*`")


def strip_code_blocks(text: str) -> str:
    """Remove blocos de código cercados (``` ou ~~~) do texto Markdown.

    Conteúdo em bloco de código não é renderizado como link ou heading,
    portanto não deve ser validado. O fechamento segue as regras do
    CommonMark: mesma caractere de cerca, com comprimento >= ao da abertura
    e apenas espaços depois da cerca.
    """
    kept: list[str] = []
    fence_char: str | None = None
    fence_len = 0
    for line in text.splitlines():
        stripped = line.lstrip()
        if fence_char is None:
            match = re.match(r"(`{3,}|~{3,})", stripped)
            if match:
                fence = match.group(1)
                fence_char = fence[0]
                fence_len = len(fence)
                continue
            kept.append(line)
            continue
        match = re.match(r"(`+|~+)(.*)$", stripped)
        if (
            match
            and match.group(1)[0] == fence_char
            and len(match.group(1)) >= fence_len
            and match.group(2).strip() == ""
        ):
            fence_char = None
            fence_len = 0
    return "\n".join(kept)


def slugify(text: str) -> str:
    text = re.sub(r"<[^>]+>", "", text)
    text = re.sub(r"[`*~]", "", text).strip().lower()
    # GitHub remove o "_" apenas quando marca ênfase (delimitador); o
    # underscore dentro da palavra é preservado ("snake_case").
    text = re.sub(r"(^|\s)_+(?=\S)", r"\1", text)
    text = re.sub(r"(?<=\S)_+(?=\s|$)", "", text)
    # GitHub preserva letras Unicode (incluindo acentos) nos anchors.
    text = re.sub(r"[^\w\- ]", "", text, flags=re.UNICODE)
    # Cada espaço vira um hífen: "GPU  fallback" -> "gpu--fallback".
    text = text.replace(" ", "-")
    return text.strip("-")


def anchors(path: Path) -> set[str]:
    text = strip_code_blocks(path.read_text(encoding="utf-8"))
    result: set[str] = set()
    counts: dict[str, int] = {}
    for heading in HEADING_RE.findall(text):
        base = slugify(heading)
        count = counts.get(base, 0)
        counts[base] = count + 1
        result.add(base if count == 0 else f"{base}-{count}")
    return result


def split_destination(raw_destination: str) -> tuple[str, str]:
    """Separa o destino em (caminho, fragmento)."""
    destination = raw_destination.strip()
    path, _, fragment = destination.partition("#")
    return path.strip(), fragment.strip()


def target_path(source: Path, path_part: str, fragment: str = "") -> Path | None:
    if path_part.startswith(("http://", "https://", "mailto:", "tel:")):
        return None
    if not path_part:
        # Link para a própria página ("#secao"): resolve para o próprio arquivo.
        return source if fragment else None
    if path_part.startswith("/"):
        # Links absolutos são resolvidos a partir da raiz do repositório.
        return (ROOT / path_part.lstrip("/")).resolve()
    return (source.parent / path_part).resolve()


def main() -> int:
    errors: list[str] = []
    markdown_files = sorted(ROOT.rglob("*.md"))
    ignored_parts = {".git", "node_modules", ".github"}

    for source in markdown_files:
        if any(part in ignored_parts for part in source.parts):
            continue
        text = strip_code_blocks(source.read_text(encoding="utf-8"))
        # Trechos de código em linha (`...`) também não são links renderizados.
        text = INLINE_CODE_RE.sub(" ", text)
        for match in LINK_RE.finditer(text):
            raw_destination = match.group(1) if match.group(1) is not None else match.group(2)
            path_part, fragment = split_destination(raw_destination)
            target = target_path(source, path_part, fragment)
            if target is None:
                continue
            try:
                target.relative_to(ROOT)
            except ValueError:
                errors.append(f"{source.relative_to(ROOT)}: link externo ao repositório: {raw_destination}")
                continue
            if not target.exists():
                errors.append(f"{source.relative_to(ROOT)}: alvo inexistente: {raw_destination}")
                continue
            if fragment and target.suffix.lower() == ".md":
                anchor = fragment.lower()
                if anchor not in anchors(target):
                    errors.append(f"{source.relative_to(ROOT)}: âncora inexistente: {raw_destination}")

    if errors:
        for error in errors:
            print(f"ERROR: {error}", file=sys.stderr)
        return 1

    print(f"OK: {len(markdown_files)} arquivos Markdown verificados")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
