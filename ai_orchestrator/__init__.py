"""Headless production runtime for XinZhaoWrt Arthur."""

from .codex_compat import install_codex_model_cache_workaround


install_codex_model_cache_workaround()

__version__ = "2.0.0"
