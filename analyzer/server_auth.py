"""Shared validation for the analyzer token used by each API."""

# The example docker-compose.yml's values, which anyone can read.
PLACEHOLDER_TOKENS = {"change-me", "change-me-too"}


def token_problem(token: str) -> str | None:
    """Why [token] can't protect the API, or None when it can."""
    if not token:
        return "ANALYZER_TOKEN is not set"
    if token in PLACEHOLDER_TOKENS:
        return "ANALYZER_TOKEN is still the example value"
    return None
